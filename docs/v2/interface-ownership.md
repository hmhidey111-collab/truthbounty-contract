# TruthBounty V2 Canonical Interface Ownership

This document is the review map for `contracts/v2/interfaces`. Interfaces define authority boundaries only; they do not grant API callers, treasury modules, or guardians permission to decide claim outcomes. Implementations MUST reject zero-address dependencies, bound paginated reads, and keep payout execution pull-based.

| Interface | Responsibility | State-changing callers | Read-only surface | Coordination boundary | Specification mapping |
|---|---|---|---|---|---|
| `IConfiguration` | Protocol parameters and dependency addresses | Governance only | `getUint`, `getAddress` | No claim outcome authority | §§3–5 |
| `IModuleRegistry` | Canonical module discovery + versioned, timelocked registration | Governance (replace/deprecate/forbid) and deployment (register/activate); guardian excluded | `module`, `isRegistered`, `getModule`, `canonicalModuleIds`, `canonicalDependencies`, preflight views | Registry does not settle funds | §§3–5, 26 |
| `IClaims` | Claim lifecycle | Claimant for creation/cancel; authorized modules for transitions | Claim/status reads | No API/guardian outcome decision | §§17–20 |
| `IEvidence` | Evidence commitment lifecycle | Claim participants and authorized verifier module | Bounded paginated reads | Hash commitments only | §§17–20 |
| `IStakeCustody` | Escrowed verifier stake | Verifier deposit; authorized settlement/slashing hooks | Stake balances | No arbitrary treasury withdrawal | §§17–20 |
| `IVerification` | Verifier attestations | Eligible verifiers | Bounded paginated reads | Calls stake custody | §§17–20 |
| `IAggregation` | Deterministic verification outcome | Aggregation coordinator only | Final outcome | Cannot move funds | §§17–20 |
| `ISettlement` | Timelocked claim settlement | Authorized settlement coordinator; anyone may execute queued payout | Settlement status | Pull-based execution | §§18–20 |
| `IDisputes` | Dispute lifecycle | Eligible opener; governance-appointed resolver | Dispute data | Cannot bypass aggregation | §§19–20 |
| `IRewards` | Accounting and pull claims | Authorized engines; account claims own rewards | Claimable balance | No outcome authority | §§20, 26 |
| `ISlashing` | Proposed and authorized stake penalties | Governance/verification coordination | Proposal amount | Requires custody hook | §§19–20 |
| `ITreasury` | Bucketed protocol funds | Governance-authorized accounting modules | Bucket balances | No privileged settlement shortcut | §§3–5, 26 |
| `IReputationRoots` | Epoch root publication and proofs | Governance/root publisher | Root/proof verification | No claim settlement authority | §§17–20 |
| `IGovernanceHooks` | Explicit governance authorization | Governance only | Authorization status | Selector/data-hash scoped | §§3–5, 26 |
| `IEmergencyControls` | Scoped pause/unpause | Emergency role only | Pause status | Pause is not adjudication | §§3–5, 26 |

Each module MUST implement ERC-165 and advertise both `type(IV2Module).interfaceId` and its own interface ID. Canonical V2 deliberately omits legacy aliases and unbounded batch payout methods.

The canonical module registry (`IModuleRegistry`/`ModuleRegistry`, see
[`module-registry.md`](./module-registry.md) for the V2-SC-005 review map) is the single stable-key
discovery point for the suite: 14 canonical keys, versioned registrations, a two-day timelocked
governance replacement path, preflight views, reusable dependency validation, and rejection of
EOA/self/duplicate-proxy/forbidden registrations.
