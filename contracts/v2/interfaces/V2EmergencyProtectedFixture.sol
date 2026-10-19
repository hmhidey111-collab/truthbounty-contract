// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IEmergencyControls} from "./IEmergencyControls.sol";
import {IV2Module} from "./IV2Module.sol";
import {IV2Types} from "./IV2Types.sol";
import {IClaims} from "./IClaims.sol";
import {V2Errors} from "../libraries/V2Errors.sol";
import {V2SafeCast} from "../libraries/V2SafeCast.sol";

/**
 * @title V2EmergencyProtectedFixture
 * @notice Reviewable canonical V2 fixture demonstrating production mutation path gating
 *         via IEmergencyControls.
 * @dev Enforces scoped and global pause states on protocol mutation paths while
 *      preserving unblocked read access and deterministic event emission.
 */
contract V2EmergencyProtectedFixture is ERC165, IClaims {
    IEmergencyControls public immutable emergencyControls;
    bytes32 public constant SCOPE_CLAIMS = keccak256("CLAIMS");

    uint256 private _nextClaimId = 1;
    mapping(uint256 => IV2Types.Claim) private _claims;
    mapping(uint256 => IV2Types.ClaimState) private _claimStates;

    constructor(address controls) {
        if (controls == address(0)) revert V2Errors.ZeroAddress();
        emergencyControls = IEmergencyControls(controls);
    }

    modifier whenNotPaused(bytes32 scope) {
        if (emergencyControls.paused(scope)) revert V2Errors.ProtocolPaused();
        _;
    }

    function protocolVersion() external pure override returns (uint16 major, uint16 minor) {
        return (2, 0);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IClaims).interfaceId || interfaceId == type(IV2Module).interfaceId || super.supportsInterface(interfaceId);
    }

    function createClaim(bytes32 subject, uint256 reward, bytes calldata)
        external
        override
        whenNotPaused(SCOPE_CLAIMS)
        returns (uint256 claimId)
    {
        claimId = _nextClaimId++;
        _claims[claimId] = IV2Types.Claim(claimId, msg.sender, subject, reward, V2SafeCast.timestamp64(V2SafeCast.FIELD_FIXTURE_TIMESTAMP), IV2Types.ClaimStatus.OPEN);
        _claimStates[claimId] = IV2Types.ClaimState.VerificationOpen;
        emit ClaimCreated(claimId, msg.sender, subject, reward);
    }

    function cancelClaim(uint256 claimId)
        external
        override
        whenNotPaused(SCOPE_CLAIMS)
    {
        IV2Types.Claim storage claim = _claims[claimId];
        require(claim.claimant == msg.sender, "not claimant");
        IV2Types.ClaimState previous = _claimStates[claimId];
        claim.status = IV2Types.ClaimStatus.CANCELLED;
        _claimStates[claimId] = IV2Types.ClaimState.None;
        emit ClaimStateChanged(claimId, previous, IV2Types.ClaimState.None, msg.sender, V2SafeCast.timestamp64(V2SafeCast.FIELD_FIXTURE_TIMESTAMP), bytes32("cancelled"));
    }

    function getClaim(uint256 claimId) external view override returns (IV2Types.Claim memory) {
        return _claims[claimId];
    }

    function stateOf(uint256 claimId) external view override returns (IV2Types.ClaimState) {
        return _claimStates[claimId];
    }
}
