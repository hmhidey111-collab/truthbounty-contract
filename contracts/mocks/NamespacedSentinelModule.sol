// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

// Sentinel values written before an upgrade and read back after it (V2-SC-159).
// `linear*` fields live in the linear (slot 0..n) region, ``namespaced*` fields live in the
// ERC-7201 namespace `truthbounty.storage.mocks.SentinelModule`.
struct SentinelValues {
    uint256 linearValue;
    bytes32 linearTag;
    uint256 mappingKey;
    uint256 linearMapped;
    uint256 namespacedCounter;
    bytes32 namespacedTag;
    address namespacedAccount;
    uint256 namespacedMapped;
}

/**
 * @title SentinelModuleNamespace
 * @notice Single definer of the `truthbounty.storage.mocks.SentinelModule` ERC-7201 namespace.
 * @dev Both implementation versions inherit this contract instead of redeclaring the namespace,
 *      so the V2-SC-159 checker sees exactly one definer (redeclaring it in V2 would be reported
 *      as a duplicate namespace).
 */
abstract contract SentinelModuleNamespace {
    /// @custom:storage-location erc7201:truthbounty.storage.mocks.SentinelModule
    struct SentinelModuleStorage {
        uint256 counter;
        bytes32 tag;
        address account;
        mapping(uint256 => uint256) values;
    }

    // keccak-256(abi.encode(uint256(keccak-256("truthbounty.storage.mocks.SentinelModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SENTINEL_MODULE_STORAGE_LOCATION =
        0x0eab85e4f8b66098f0fe3e32d0f8534f99289b249fd05f879f59cda00bcdc900;

    function _sentinelModuleStorage() internal pure returns (SentinelModuleStorage storage $) {
        assembly {
            $.slot := SENTINEL_MODULE_STORAGE_LOCATION
        }
    }
}

/**
 * @title SentinelModuleExtensionNamespace
 * @notice Namespace appended by the V2 implementation. Adding a namespace is an append: it does
 *         not move any linear slot and cannot overlap an existing namespace.
 */
abstract contract SentinelModuleExtensionNamespace {
    /// @custom:storage-location erc7201:truthbounty.storage.mocks.SentinelModuleExtension
    struct SentinelModuleExtensionStorage {
        uint256 appendedCounter;
        bytes32 appendedTag;
    }

    // keccak-256(abi.encode(uint256(keccak-256("truthbounty.storage.mocks.SentinelModuleExtension")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SENTINEL_MODULE_EXTENSION_STORAGE_LOCATION =
        0xd4e6ecf0182150744c92978296b1ae82a4e18debf43f77e205c22d1a5f902400;

    function _sentinelModuleExtensionStorage() internal pure returns (SentinelModuleExtensionStorage storage $) {
        assembly {
            $.slot := SENTINEL_MODULE_EXTENSION_STORAGE_LOCATION
        }
    }
}

/**
 * @title NamespacedSentinelModuleCore
 * @notice Shared logic and the frozen V1 linear layout of the sentinel module.
 * @dev Linear layout: owner (0), linearValue (1), linearTag (2), linearValues (3). Concrete
 *      versions append after these and shrink their `__gap` by the appended size.
 */
abstract contract NamespacedSentinelModuleCore is Initializable, UUPSUpgradeable, SentinelModuleNamespace {
    /// @notice Caller is not the module owner.
    error NotOwner(address caller);

    /// @notice Module owner; authorizes writes and UUPS upgrades.
    address public owner;
    /// @notice Linear sentinel word.
    uint256 public linearValue;
    /// @notice Linear sentinel tag.
    bytes32 public linearTag;
    /// @notice Linear sentinel mapping.
    mapping(uint256 => uint256) public linearValues;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    /// @notice Writes every V1 sentinel (linear and namespaced).
    /// @param values Sentinel values.
    function writeSentinels(SentinelValues calldata values) external onlyOwner {
        linearValue = values.linearValue;
        linearTag = values.linearTag;
        linearValues[values.mappingKey] = values.linearMapped;
        SentinelModuleStorage storage $ = _sentinelModuleStorage();
        $.counter = values.namespacedCounter;
        $.tag = values.namespacedTag;
        $.account = values.namespacedAccount;
        $.values[values.mappingKey] = values.namespacedMapped;
    }

    /// @notice Reads every V1 sentinel back.
    /// @param mappingKey Key used for both mappings.
    /// @return values Sentinel values currently stored.
    function readSentinels(uint256 mappingKey) external view returns (SentinelValues memory values) {
        SentinelModuleStorage storage $ = _sentinelModuleStorage();
        values = SentinelValues({
            linearValue: linearValue,
            linearTag: linearTag,
            mappingKey: mappingKey,
            linearMapped: linearValues[mappingKey],
            namespacedCounter: $.counter,
            namespacedTag: $.tag,
            namespacedAccount: $.account,
            namespacedMapped: $.values[mappingKey]
        });
    }

    /// @notice Initialized version recorded in the OpenZeppelin `Initializable` namespace.
    function initializedVersion() external view returns (uint64) {
        return _getInitializedVersion();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}

/**
 * @title NamespacedSentinelModuleV1
 * @notice Upgrade-fixture implementation V1 for the V2-SC-159 sentinel-state upgrade tests.
 */
contract NamespacedSentinelModuleV1 is NamespacedSentinelModuleCore {
    uint256[46] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the proxy.
    /// @param owner_ Module owner.
    function initialize(address owner_) external initializer {
        owner = owner_;
    }

    /// @notice Implementation version.
    function version() external pure returns (uint256) {
        return 1;
    }
}

/**
 * @title NamespacedSentinelModuleV2
 * @notice Upgrade-fixture implementation V2: a safe append. It adds one linear variable after the
 *         frozen V1 variables (shrinking `__gap` from 46 to 45) and appends a new namespace base.
 */
contract NamespacedSentinelModuleV2 is NamespacedSentinelModuleCore, SentinelModuleExtensionNamespace {
    /// @notice Linear variable appended by V2 (slot 4, previously `__gap[0]`).
    uint256 public appendedValue;
    uint256[45] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice V2 migration hook, run once through `upgradeToAndCall`.
    /// @param appendedValue_ Initial value of the appended linear variable.
    function initializeV2(uint256 appendedValue_) external reinitializer(2) {
        appendedValue = appendedValue_;
    }

    /// @notice Writes the V2-only sentinels.
    function writeAppended(uint256 counter, bytes32 tag) external onlyOwner {
        SentinelModuleExtensionStorage storage $ = _sentinelModuleExtensionStorage();
        $.appendedCounter = counter;
        $.appendedTag = tag;
    }

    /// @notice Reads the V2-only namespaced sentinels.
    function readAppended() external view returns (uint256 counter, bytes32 tag) {
        SentinelModuleExtensionStorage storage $ = _sentinelModuleExtensionStorage();
        return ($.appendedCounter, $.appendedTag);
    }

    /// @notice Implementation version.
    function version() external pure returns (uint256) {
        return 2;
    }
}
