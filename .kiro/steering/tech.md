# Technology Steering

The repository contains Solidity contracts and uses both Foundry and Hardhat for compilation and tests, with JavaScript/TypeScript test and automation code managed through npm.

`foundry.toml` pins Solidity compiler 0.8.28 and configures optimizer runs 200 with `via_ir = true`. Verify the effective compiler and build settings in every relevant tool configuration before producing deterministic artifacts; an npm `solc` dependency alone does not establish the compiler used by a particular workflow.

Gas and security checks are release controls. Do not make a failing gate advisory, skip missing artifacts, weaken thresholds, or accept a new baseline without explicit review. Preserve exact arithmetic, governance/timelock authority, scoped pause behavior, the approved V2 Optimism/EVM topology, and consumer interface handoffs.
