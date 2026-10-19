// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IV2Module} from "./IV2Module.sol";
import {IV2Types} from "./IV2Types.sol";

/// @notice Dispute opening and resolution interface.
/// @dev Only the configured dispute authority may resolve a dispute, and the allowed state machine must be enforced before storage changes.
/// @dev Deadline semantics: a deadline is the last inclusive timestamp at which an action is still valid. An action at timestamp == deadline is valid; an action at timestamp > deadline is expired.
/// @dev Appeal rollover must preserve principal and custody exactly; rollover inputs are bounded and multi-round appeals must not lose, duplicate, or strand principal.
interface IDisputes is IV2Module {
    /// @notice Emitted when a dispute is opened against a claim.
    /// @param disputeId Newly assigned dispute identifier.
    /// @param claimId Disputed claim.
    /// @param opener Account that opened the dispute.
    /// @param reasonHash Digest of the off-chain dispute reason.
    event DisputeOpened(uint256 indexed disputeId, uint256 indexed claimId, address indexed opener, bytes32 reasonHash);

    /// @notice Emitted when an authorized resolver reaches a terminal decision.
    /// @param disputeId Resolved dispute.
    /// @param status Terminal or escalated status selected by the authority.
    /// @param resolver Authorized resolver that made the decision.
    event DisputeResolved(uint256 indexed disputeId, IV2Types.DisputeStatus status, address indexed resolver);

    /// @notice Emitted when an appeal rolls over to a new round.
    /// @param disputeId Dispute whose appeal rolled over.
    /// @param fromRound Round that was closed.
    /// @param toRound New round identifier.
    /// @param principal Principal carried into the new round.
    event AppealRolled(uint256 indexed disputeId, uint256 indexed fromRound, uint256 indexed toRound, uint256 principal);

    /// @notice Opens a dispute during the configured challenge window.
    /// @dev Must validate claim existence, window, reason digest, opener authorization, and any required bond before creating the dispute.
    /// The challenge window closes inclusively at `deadline`: an action at `block.timestamp == deadline` is valid, and an action at `block.timestamp > deadline` fails with the canonical expired error.
    /// @param claimId Claim to dispute.
    /// @param reasonHash Digest of the reason; raw reason data remains off-chain.
    /// @param evidence Opaque evidence commitment or reference bytes.
    /// @return disputeId Newly assigned dispute identifier.
    function openDispute(uint256 claimId, bytes32 reasonHash, bytes caldata evidence) external returns (uint256 disputeId);

    /// @notice Resolves or escalates a dispute under the resolver authority.
    /// @dev Must enforce the configured transition graph, resolver role, and evidence/decision validation; invalid decisions leave state unchanged.
    /// @param disputeId Dispute to update.
    /// @param status New permitted status.
    /// @param decision Opaque decision payload or commitment; the EVM does not infer its meaning.
    function resolveDispute(uint256 disputeId, IV2Types.DisputeStatus status, bytes caldata decision) external;

    /// @notice Rolls an appeal into the next round, preserving principal and custody.
    /// @dev The appeal window closes inclusively at the round's deadline. Rollover inputs are bounded; an appeal at `block.timestamp > deadline` fails with the canonical expired error. Principal carried into the next round must equal the principal of the closed round, and custody must remain with the dispute contract.
    /// @param disputeId Dispute to appeal.
    /// @param evidence Opaque evidence commitment or reference bytes for the new round.
    /// @return newRound Newly opened appeal round identifier.
    function appeal(uint256 disputeId, bytes caldata evidence) external returns (uint256 newRound);

    /// @notice Reads a dispute record.
    /// @param disputeId Dispute to inspect.
    /// @return dispute Stored dispute fields.
    function getDispute(uint256 disputeId) external view returns (IV2Types.Dispute memory dispute);

    /// @notice Reads the deadline for a dispute round.
    /// @dev Returns the last inclusive timestamp at which an appeal is valid.
    /// @param disputeId Dispute to inspect.
    /// @param round Round to inspect.
    /// @return deadline Last inclusive timestamp for the round.
    function getRoundDeadline(uint256 disputeId, uint256 round) external view returns (uint256 deadline);

    /// @notice Reads the principal and custody accounting for a dispute round.
    /// @dev Principal is the amount that must be carried forward on rollover; custody must always equal the dispute contract address.
    /// @param disputeId Dispute to inspect.
    /// @param round Round to inspect.
    /// @return principal Principal carried by the round.
    /// @return custodian Address that must hold the principal.
    function getRoundPrincipalAndCustody(uint256 disputeId, uint256 round) external view returns (uint256 principal, address custodian);
}
