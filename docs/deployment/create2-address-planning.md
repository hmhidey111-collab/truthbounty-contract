# Deterministic CREATE2 Address Planning (`V2-SC-069`)

## Overview

`Create2AddressPlanner` reserves collision-safe deterministic addresses for TruthBounty V2
module implementations before broadcast, then gates registry intake on bytecode verification
and on-chain deployment confirmation.

## Flow

1. **Review salt** — operators supply a non-zero reviewed salt per module key.
2. **Plan** — `planAddress` domain-separates the salt (`keccak256(moduleId, reviewedSalt)`),
   predicts the CREATE2 address, and rejects salt reuse, address collisions, and targets that
   already contain code.
3. **Verify bytecode** — `verifyBytecode` / `setExpectedRuntimeCodeHash` bind the plan to a
   runtime code hash.
4. **Confirm deployment** — after CREATE2 broadcast, `confirmDeployment` checks `extcodehash`
   at the predicted address.
5. **Register** — `isReadyForRegistration` is true only when reserved + verified + confirmed.

## Security properties

- Fail-closed on zero module id, salt, init-code hash, or deployer.
- Domain-separated salts prevent cross-module collisions from identical reviewed salts.
- No Stellar / Soroban / Freighter dependencies; Optimism/EVM CREATE2 only.
- Authorization via `PLANNER_ROLE` / `DEFAULT_ADMIN_ROLE`.
