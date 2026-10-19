#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
Usage: ./scripts/symbolic-check.sh [--tool auto|mythril|slither] [--dry-run] [--install] [--help]

Runs bounded symbolic / static security checks for the critical protocol paths.

Options:
  --tool <name>   Prefer a specific analyzer: mythril, slither, or auto (default)
  --dry-run       Print the exact analyzer commands without executing them
  --install       Attempt to install the supported analyzers in the current environment
  --help          Show this help message
EOF
}

TOOL="auto"
DRY_RUN=0
INSTALL_DEPS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tool)
      TOOL="${2:-auto}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --install)
      INSTALL_DEPS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

CRITICAL_CONTRACTS=(
  "contracts/DisputeResolution.sol"
  "contracts/StakeVault.sol"
  "contracts/TruthBountyWeighted.sol"
  "contracts/treasury/TreasuryManagement.sol"
  "contracts/settlement/ProvisionalSettlementEngine.sol"
  "contracts/tokenomics/TokenomicsEngine.sol"
  "contracts/verification/VerificationAggregator.sol"
  "contracts/governance/v2/GovernanceRoleTopology.sol"
)

install_dependencies() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to install the static-analysis dependencies." >&2
    exit 1
  fi

  python3 -m pip install --user --upgrade pip >/dev/null
  python3 -m pip install --user mythril slither-analyzer >/dev/null
}

print_banner() {
  echo "============================================================"
  echo "TruthBounty V2 Symbolic / Static Security Check"
  echo "============================================================"
}

run_mythril() {
  local contract
  for contract in "${CRITICAL_CONTRACTS[@]}"; do
    if [[ ! -f "$contract" ]]; then
      echo "Missing critical contract: $contract" >&2
      exit 1
    fi

    echo "Analyzing ${contract} with Mythril..."
    myth analyze "$contract" \
      --execution-timeout 60 \
      --max-depth 20 \
      --loop-bound 3 \
      --solver-timeout 60000 \
      --outform text
  done
}

run_slither() {
  echo "Running Slither across the protocol sources..."
  slither . --filter-paths '(lib|test|node_modules)' --ignore-compile --triage-database "slither.db" || {
    echo "Slither reported a security finding or configuration issue." >&2
    return 1
  }
}

if [[ "$INSTALL_DEPS" -eq 1 ]]; then
  install_dependencies
  exit 0
fi

print_banner

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run: forge build"
  echo "Dry run: critical contracts: ${CRITICAL_CONTRACTS[*]}"
  case "$TOOL" in
    auto)
      if command -v myth >/dev/null 2>&1; then
        echo "Would run Mythril on each critical contract."
      elif command -v slither >/dev/null 2>&1; then
        echo "Would run Slither on the protocol sources."
      else
        echo "No analyzer is installed. Install one with: ./scripts/symbolic-check.sh --install"
      fi
      ;;
    mythril)
      echo "Would run Mythril on each critical contract."
      ;;
    slither)
      echo "Would run Slither on the protocol sources."
      ;;
    *)
      echo "Unsupported tool: $TOOL" >&2
      exit 2
      ;;
  esac
  exit 0
fi

if ! command -v forge >/dev/null 2>&1; then
  echo "Foundry is required for contract compilation before security analysis." >&2
  exit 1
fi

echo "Compiling protocol contracts..."
forge build

case "$TOOL" in
  auto)
    if command -v myth >/dev/null 2>&1; then
      echo "Mythril detected; running bounded symbolic checks."
      run_mythril
    elif command -v slither >/dev/null 2>&1; then
      echo "Mythril not found; falling back to Slither."
      run_slither
    else
      echo "Neither Mythril nor Slither is installed in this environment." >&2
      echo "Install them with: ./scripts/symbolic-check.sh --install" >&2
      exit 1
    fi
    ;;
  mythril)
    if ! command -v myth >/dev/null 2>&1; then
      echo "Mythril was requested but is not installed." >&2
      exit 1
    fi
    run_mythril
    ;;
  slither)
    if ! command -v slither >/dev/null 2>&1; then
      echo "Slither was requested but is not installed." >&2
      exit 1
    fi
    run_slither
    ;;
  *)
    echo "Unsupported tool: $TOOL" >&2
    exit 2
    ;;
 esac

echo "Symbolic/static security analysis completed successfully."
