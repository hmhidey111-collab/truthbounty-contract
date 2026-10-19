// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { IConsumerGuarantees } from "./interfaces/IConsumerGuarantees.sol";
import { IV2Module } from "./interfaces/IV2Module.sol";
import { V2Errors } from "./libraries/V2Errors.sol";
import { V2Guarantees } from "./libraries/V2Guarantees.sol";
import { V2SafeCast } from "./libraries/V2SafeCast.sol";

/// @title ConsumerGuaranteesAnchor
/// @notice Read-only discovery anchor that publishes the authoritative chain
///         reorganization consumer guarantees for one canonical V2 deployment.
/// @dev    V2-SC-134. Deployment-scoped, immutable after construction, and
///         strictly passive: the anchor never holds funds, never authorizes a
///         caller, and exposes no state-changing function beyond the
///         constructor. Consumers read `consumerGuarantees()` or index the
///         `ConsumerGuaranteesPublished` event; no off-chain actor gains any
///         settlement or treasury authority from this contract.
contract ConsumerGuaranteesAnchor is ERC165, IV2Module, IConsumerGuarantees {
    /// @notice The immutable guarantees fields for this deployment.
    /// @dev Published individually as immutables (structs are not value types);
    ///      `consumerGuarantees()` reassembles the authoritative record.
    uint64 private immutable _confirmationDepth;
    uint8 private immutable _maxFinalityClass;
    uint64 private immutable _maxReorgDepth;
    bool private immutable _eventsAreReplayable;
    bool private immutable _eventKeysAreUnique;
    bool private immutable _eventsAreTerminalOnEmission;

    /// @notice Chain ID this anchor is bound to, fixed at deployment.
    /// @dev Snapshot of block.chainid at construction; deployment manifests
    ///      must declare the same value.
    uint64 public immutable CHAIN_ID;

    /// @notice Deployer/admin recorded for provenance only. It carries no
    ///         runtime authority: the anchor has no functions it could call.
    address public immutable deployer;

    /// @param guarantees_ The validated guarantees record to publish.
    /// @param deployer_   Deployment provenance address; must not be zero.
    constructor(ConsumerGuarantees memory guarantees_, address deployer_) {
        if (deployer_ == address(0)) {
            revert V2Errors.ZeroAddress();
        }
        V2Guarantees.validate(guarantees_);
        _confirmationDepth = guarantees_.confirmationDepth;
        _maxFinalityClass = guarantees_.maxFinalityClass;
        _maxReorgDepth = guarantees_.maxReorgDepth;
        _eventsAreReplayable = guarantees_.eventsAreReplayable;
        _eventKeysAreUnique = guarantees_.eventKeysAreUnique;
        _eventsAreTerminalOnEmission = guarantees_.eventsAreTerminalOnEmission;
        // V2-SC-161: EIP-155 chain ids are not bounded by the EVM; refuse to truncate one.
        CHAIN_ID = V2SafeCast.toUint64(block.chainid, V2SafeCast.FIELD_GUARANTEES_CHAIN_ID);
        deployer = deployer_;
        emit ConsumerGuaranteesPublished(guarantees_);
    }

    /// @inheritdoc IConsumerGuarantees
    function consumerGuarantees() external view override returns (ConsumerGuarantees memory) {
        return ConsumerGuarantees({
            confirmationDepth: _confirmationDepth,
            maxFinalityClass: _maxFinalityClass,
            maxReorgDepth: _maxReorgDepth,
            eventsAreReplayable: _eventsAreReplayable,
            eventKeysAreUnique: _eventKeysAreUnique,
            eventsAreTerminalOnEmission: _eventsAreTerminalOnEmission
        });
    }

    /// @notice Immutable protocol version marker shared by canonical V2 modules.
    function protocolVersion() external pure returns (uint16 major, uint16 minor) {
        return (2, 0);
    }

    /// @notice ERC-165: advertises IV2Module, IConsumerGuarantees, and ERC-165.
    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IV2Module).interfaceId || interfaceId == type(IConsumerGuarantees).interfaceId
            || super.supportsInterface(interfaceId);
    }
}
