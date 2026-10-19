// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IConfiguration} from "./IConfiguration.sol";
import {IModuleRegistry} from "./IModuleRegistry.sol";
import {IClaims} from "./IClaims.sol";
import {IEvidence} from "./IEvidence.sol";
import {IStakeCustody} from "./IStakeCustody.sol";
import {IVerification} from "./IVerification.sol";
import {IAggregation} from "./IAggregation.sol";
import {ISettlement} from "./ISettlement.sol";
import {IDisputes} from "./IDisputes.sol";
import {IRewards} from "./IRewards.sol";
import {ISlashing} from "./ISlashing.sol";
import {ITreasury} from "./ITreasury.sol";
import {IReputationRoots} from "./IReputationRoots.sol";
import {IGovernanceHooks} from "./IGovernanceHooks.sol";
import {IEmergencyControls} from "./IEmergencyControls.sol";

/// @notice Aggregate ABI manifest for the complete TruthBounty V2 module topology.
/// @dev This interface is a discovery and integration contract, not a permission boundary. Each inherited module remains responsible for its own authority, validation, and fail-closed behavior. Implementations must not assume that registry membership grants broader authority than the target module enforces.
interface ICanonicalV2 is IConfiguration, IModuleRegistry, IClaims, IEvidence, IStakeCustody, IVerification, IAggregation, ISettlement, IDisputes, IRewards, ISlashing, ITreasury, IReputationRoots, IGovernanceHooks, IEmergencyControls {}
