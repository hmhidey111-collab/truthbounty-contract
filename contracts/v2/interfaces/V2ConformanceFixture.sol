// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IClaims} from "./IClaims.sol";
import {IAggregation} from "./IAggregation.sol";
import {IV2Module} from "./IV2Module.sol";
import {IV2Types} from "./IV2Types.sol";
import {V2SafeCast} from "../libraries/V2SafeCast.sol";

/// @dev Compile-time fixture proving representative modules can implement the canonical surface.
contract V2ConformanceFixture is ERC165, IClaims, IAggregation {
    uint256 private _nextClaimId = 1;
    mapping(uint256 => IV2Types.Claim) private _claims;
    mapping(uint256 => bool) private _finalized;
    mapping(uint256 => IV2Types.ClaimState) private _claimStates;

    function protocolVersion() external pure override returns (uint16 major, uint16 minor) { return (2, 0); }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IClaims).interfaceId || interfaceId == type(IAggregation).interfaceId
            || interfaceId == type(IV2Module).interfaceId || super.supportsInterface(interfaceId);
    }

    function createClaim(bytes32 subject, uint256 reward, bytes calldata) external override returns (uint256 claimId) {
        claimId = _nextClaimId++;
        _claims[claimId] = IV2Types.Claim(claimId, msg.sender, subject, reward, V2SafeCast.timestamp64(V2SafeCast.FIELD_FIXTURE_TIMESTAMP), IV2Types.ClaimStatus.OPEN);
        _claimStates[claimId] = IV2Types.ClaimState.VerificationOpen;
        emit ClaimCreated(claimId, msg.sender, subject, reward);
    }

    function cancelClaim(uint256 claimId) external override {
        IV2Types.Claim storage claim = _claims[claimId];
        require(claim.claimant == msg.sender, "not claimant");
        IV2Types.ClaimState previous = _claimStates[claimId];
        claim.status = IV2Types.ClaimStatus.CANCELLED;
        _claimStates[claimId] = IV2Types.ClaimState.None;
        emit ClaimStateChanged(claimId, previous, IV2Types.ClaimState.None, msg.sender, V2SafeCast.timestamp64(V2SafeCast.FIELD_FIXTURE_TIMESTAMP), bytes32("cancelled"));
    }

    function getClaim(uint256 claimId) external view override returns (IV2Types.Claim memory) { return _claims[claimId]; }
    function stateOf(uint256 claimId) external view override returns (IV2Types.ClaimState) { return _claimStates[claimId]; }
    function finalizeAggregation(uint256 claimId) external override { _finalized[claimId] = true; emit AggregationFinalized(claimId, true, 0, 0); }
    function outcome(uint256 claimId) external view override returns (bool finalized, bool accepted, uint256 supportingWeight, uint256 opposingWeight) { return (_finalized[claimId], true, 0, 0); }
}
