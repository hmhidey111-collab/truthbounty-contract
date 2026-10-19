#!/usr/bin/env bash
set -euo pipefail

# Focused V2-SC-154 validation, supplementary to every existing repository CI gate.
# Compile the affected dependency closure with the pinned Hardhat release settings.
# This does not alter the default Foundry configuration or bypass its CI workflows.
RECOVERY_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECOVERY_CONFIG_DIR="$(mktemp -d)"
trap 'rm -rf "$RECOVERY_CONFIG_DIR"' EXIT
mkdir -p "$RECOVERY_CONFIG_DIR/empty"
# Stable virtual source names keep Solidity metadata and creation gas independent of checkout paths.
cp -R "$RECOVERY_REPO_ROOT/contracts" "$RECOVERY_CONFIG_DIR/contracts"
cp -R "$RECOVERY_REPO_ROOT/test" "$RECOVERY_CONFIG_DIR/test"
mkdir -p "$RECOVERY_CONFIG_DIR/lib"
for RECOVERY_LIBRARY in forge-std openzeppelin-contracts openzeppelin-contracts-upgradeable; do
    cp -R "$RECOVERY_REPO_ROOT/lib/$RECOVERY_LIBRARY" "$RECOVERY_CONFIG_DIR/lib/$RECOVERY_LIBRARY"
done
cat > "$RECOVERY_CONFIG_DIR/foundry.toml" <<TOML
[profile.default]
src = "contracts/recovery"
test = "test/recovery"
script = "$RECOVERY_CONFIG_DIR/empty"
out = "$RECOVERY_REPO_ROOT/out/asset-recovery"
cache_path = "$RECOVERY_REPO_ROOT/cache/asset-recovery"
solc = "0.8.28"
evm_version = "cancun"
optimizer = true
optimizer_runs = 200
via_ir = true
extra_output = ["storageLayout"]
libs = ["lib"]
auto_detect_remappings = false
remappings = ["@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/", "@openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/", "forge-std/=lib/forge-std/src/"]
fs_permissions = [{ access = "read", path = "$RECOVERY_REPO_ROOT/" }]
[profile.default.fuzz]
runs = 1000
seed = "0x0000000000000000000000000000000000000000000000000000000000000633"
[profile.default.invariant]
runs = 500
depth = 20
fail_on_revert = false
TOML
if [[ $# -eq 0 ]]; then set -- test --match-path "test/recovery/*.t.sol"; fi
cd "$RECOVERY_REPO_ROOT"
forge "$@" --config-path "$RECOVERY_CONFIG_DIR/foundry.toml"
