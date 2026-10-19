# Repository Structure Steering

- `contracts/` contains Solidity protocol contracts and supporting modules.
- `test/` contains Foundry and Hardhat tests, including gas and security coverage.
- `scripts/` contains build, release, and validation automation.
- `config/` contains reviewed machine-readable gates and protocol budgets.
- `docs/` contains audit, verification, release, and operational documentation.
- `.github/workflows/` contains CI workflows that enforce repository gates.
- `.kiro/specs/<feature>/` contains feature requirements, design, and implementation tasks.

Keep changes within the owning module and its tests/configuration. Generated artifacts must be deterministic and reproducible from the documented pinned toolchain. Preserve unrelated worktree changes.
