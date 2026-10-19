// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IClaimRegistry} from "../interfaces/IClaimRegistry.sol";

/**
 * @notice Mock evidence claim registry used by tests that exercise the
 *         evidence pagination surface. The mock keeps the canonical claim
 *         state and exposes a deterministic ordering of evidence items so that
 *         consumers can traverse the full history without offset drift.
 *
 *         Evidence items are appended to a monotonically increasing sequence
 *         per claim. Cursors bind the claim id, the release id, and the last
 *         consumed evidence order key, so concurrent appends between pages do
 *         not shift the window. Duplicate CIDs are rejected and finalization
 *         freezes the historical read surface.
 */
contract MockEvidenceClaimRegistry is IClaimRegistry {
    uint256 public constant MAX_PAGE_LIMIT = 100;

    struct EvidenceItem {
        uint256 claimId;
        uint256 releaseId;
        uint256 orderKey;
        bytes32 cid;
        uint64 appendedAt;
    }

    struct Cursor {
        uint256 claimId;
        uint256 releaseId;
        uint256 orderKey;
    }

    mapping(uint256 => Claim) private _claims;
    mapping(uint256 => bool) private _exists;

    mapping(uint256 => uint256[]) private _claimEvidenceOrders;
    mapping(uint256 => mapping(uint256 => EvidenceItem)) private _evidence;
    mapping(uint256 => mapping(bytes32 => bool)) private _evidenceCidUsed;
    mapping(uint256 => bool) private _finalized;

    uint256 private _nextOrderKey;

    event EvidenceAppended(uint256 indexed claimId, uint256 indexed releaseId, uint256 indexed orderKey, bytes32 cid);
    event ClaimFinalized(uint256 indexed claimId);

    error InvalidLimit(uint256 limit);
    error InvalidCursor(uint256 claimId, uint256 releaseId, uint256 orderKey);
    error DuplicateEvidenceCid(uint256 claimId, bytes32 cid);
    error ClaimFinalized(uint256 claimId);
    error ClaimNotFound(uint256 claimId);

    function setClaim(uint256 claimId, address creator, uint64 verificationDeadline, ClaimStatus status) external {
        _claims[claimId] = Claim({
            id: claimId,
            creator: creator,
            statement: "",
            evidenceCID: "",
            status: status,
            createdAt: uint64(block.timestamp),
            verificationDeadline: verificationDeadline
        });
        _exists[claimId] = true;
    }

    function setClaimStatus(uint256 claimId, ClaimStatus status) external {
        _claims[claimId].status = status;
    }

    /**
     * @dev Append an evidence item to a claim. The order key is assigned
     *      monotonically and is the stable cursor component for traversal.
     */
    function appendEvidence(uint256 claimId, uint256 releaseId, bytes32 cid) external returns (uint256 orderKey) {
        if (!_exists[claimId]) revert ClaimNotFound(claimId);
        if (_finalized[claimId]) revert ClaimFinalized(claimId);
        if (_evidenceCidUsed[claimId][cid]) revert DuplicateEvidenceCid(claimId, cid);

        orderKey = _nextOrderKey++;
        _evidence[claimId][orderKey] = EvidenceItem({
            claimId: claimId,
            releaseId: releaseId,
            orderKey: orderKey,
            cid: cid,
            appendedAt: uint64(block.timestamp)
        });
        _claimEvidenceOrders[claimId].push(orderKey);
        _evidenceCidUsed[claimId][cid] = true;

        emit EvidenceAppended(claimId, releaseId, orderKey, cid);
    }

    /**
     * @dev Return a stable page of evidence items. The cursor binds the
     *      claim id, release id, and last consumed order key. A zero cursor
     *      means "start from the beginning".
     */
    function getEvidencePage(uint256 claimId, uint256 releaseId, uint256 cursorOrderKey, uint256 limit)
        external
        view
        returns (EvidenceItem[] memory items, uint256 nextCursorOrderKey, bool hasMore)
    {
        if (!isValidLimit(limit)) revert InvalidLimit(limit);
        if (!_exists[claimId]) revert ClaimNotFound(claimId);

        uint256[] storage orders = _claimEvidenceOrders[claimId];
        uint256 total = orders.length;
        uint256 start = _binarySearch(orders, cursorOrderKey);
        uint256 end = start + limit;
        if (end > total) end = total;

        items = new EvidenceItem[](end - start);
        for (uint256 i = start; i < end; ++i) {
            EvidenceItem storage item = _evidence[claimId][orders[i]];
            if (item.releaseId != releaseId) revert InvalidCursor(claimId, releaseId, cursorOrderKey);
            items[i - start] = item;
        }

        hasMore = end < total;
        nextCursorOrderKey = hasMore ? orders[end - 1] : cursorOrderKey;
    }

    /**
     * @dev Full traversal helper that returns every evidence item exactly once.
     */
    function getAllEvidence(uint256 claimId, uint256 releaseId)
        external
        view
        returns (EvidenceItem[] memory items)
    {
        if (!_exists[claimId]) revert ClaimNotFound(claimId);
        uint256[] storage orders = _claimEvidenceOrders[claimId];
        items = new EvidenceItem[](orders.length);
        for (uint256 i = 0; i < orders.length; ++i) {
            EvidenceItem storage item = _evidence[claimId][orders[i]];
            if (item.releaseId != releaseId) revert InvalidCursor(claimId, releaseId, 0);
            items[i] = item;
        }
    }

    function finalizeClaim(uint256 claimId) external {
        if (!_exists[claimId]) revert ClaimNotFound(claimId);
        _finalized[claimId] = true;
        emit ClaimFinalized(claimId);
    }

    function isFinalized(uint256 claimId) external view returns (bool) {
        return _finalized[claimId];
    }

    function evidenceCount(uint256 claimId) external view returns (uint256) {
        return _claimEvidenceOrders[claimId].length;
    }

    function isValidLimit(uint256 limit) public pure returns (bool) {
        return limit > 0 && limit <= MAX_PAGE_LIMIT;
    }

    function _binarySearch(uint256[] storage arr, uint256 target) private view returns (uint256) {
        uint256 low = 0;
        uint256 high = arr.length;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (arr[mid] <= target) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return low;
    }

    function createClaim(string calldata, string calldata, uint64) external pure returns (uint256) {
        revert("not implemented");
    }

    function updateClaimStatus(uint256, ClaimStatus) external pure {
        revert("not implemented");
    }

    function createCanonicalClaim(address, address, uint256, bytes32, bytes32, uint256)
        external
        pure
        returns (bytes32)
    {
        revert("not implemented");
    }

    function createCanonicalClaim(address, address, uint256, bytes32, bytes32, uint256, uint256)
        external
        pure
        returns (bytes32)
    {
        revert("not implemented");
    }

    function currentConfigVersion() external pure returns (uint256) {
        return 1;
    }

    function setSupportedAsset(address, bool, uint256, uint256) external pure {
        revert("not implemented");
    }

    function isSupportedAsset(address) external pure returns (bool) {
        return false;
    }

    function getAssetBounds(address) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function computeClaimId(address, uint256, bytes32) external pure returns (bytes32) {
        revert("not implemented");
    }

    function claimIdFor(address, uint256, bytes32) external pure returns (bytes32) {
        revert("not implemented");
    }

    function getCanonicalClaim(bytes32) external pure returns (CanonicalClaim memory) {
        revert("not implemented");
    }

    function claimExists(bytes32) external pure returns (bool) {
        return false;
    }

    function getClaim(uint256 claimId) external view returns (Claim memory) {
        if (!_exists[claimId]) revert ClaimNotFound(claimId);
        return _claims[claimId];
    }

    function claimExists(uint256 claimId) external view returns (bool) {
        return _exists[claimId];
    }

    function totalClaims() external pure returns (uint256) {
        return 0;
    }

    function getClaimCreator(uint256 claimId) external view returns (address) {
        if (!_exists[claimId]) revert ClaimNotFound(claimId);
        return _claims[claimId].creator;
    }

    function getClaimStatus(uint256 claimId) external view returns (ClaimStatus) {
        if (!_exists[claimId]) revert ClaimNotFound(claimId);
        return _claims[claimId].status;
    }
}
