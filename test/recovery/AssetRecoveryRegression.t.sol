// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Exercise the existing custody, settlement rounding and hostile-withdrawal suites
// against the recovery-enabled implementations. No existing assertion is changed.
import { StakeVaultTest as BondCustodyRegression } from "../StakeVault.t.sol";
import { StakeVaultTest as CanonicalCustodyRegression } from "../v2/StakeVault.t.sol";
import "../v2/RewardAllocationRounding.t.sol";
import "../v2/RewardWithdrawalLiveness.t.sol";
