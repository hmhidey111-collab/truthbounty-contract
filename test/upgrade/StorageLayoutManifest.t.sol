// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @title StorageLayoutManifestTest (V2-SC-121)
/// @notice Verifies the frozen storage-layout manifest artifact from Solidity:
///         1. the canonical hash preimage implemented in
///            scripts/storageLayoutManifest.ts is reproduced exactly here, so
///            the TypeScript generator and any on-chain commitment path agree;
///         2. the frozen manifest is structurally sound (schema, inventory,
///            per-contract hash integrity, bounded slot maps);
///         3. any single-field mutation of a layout entry changes the canonical
///            hash (fuzz: drift is never silently digestible).
/// @dev Variable labels contain an at-sign, which JSONPath treats specially,
///      so all lookups use bracketed quoted segments instead of dotted paths.
contract StorageLayoutManifestTest is Test {
    using stdJson for string;

    string internal manifestJson;

    string[] internal contractNames;

    /// The reviewed inventory that the frozen manifest must cover.
    string[] internal TRACKED = _trackedNames();

    function setUp() public {
        manifestJson = vm.readFile("storage-layouts/manifest.json");
        require(vm.keyExistsJson(manifestJson, "$.schemaVersion"), "manifest missing schemaVersion");
        require(vm.keyExistsJson(manifestJson, "$.contracts"), "manifest missing contracts");
        contractNames = vm.parseJsonKeys(manifestJson, "$.contracts");
        require(contractNames.length > 0, "manifest has no contracts");
    }

    // -------------------------------------------------------------------------
    // Canonical hash — must mirror scripts/storageLayoutManifest.ts exactly:
    //   keccak256("TB-STORAGE-LAYOUT-V1" ||
    //             uint256(1) ||
    //             uint256(len(sourcePath)) || sourcePath ||
    //             uint256(len(entryJson))  || entryJson)
    //   entryJson = {"slots":<canonical slots JSON>}
    //   canonical JSON: recursively sorted keys, no insignificant whitespace
    // -------------------------------------------------------------------------

    function _canonicalHash(string memory sourcePath, string memory slotsJson)
        internal
        pure
        returns (bytes32)
    {
        string memory entryJson = string.concat('{"slots":', slotsJson, "}");
        return keccak256(
            abi.encodePacked(
                "TB-STORAGE-LAYOUT-V1",
                uint256(1),
                uint256(bytes(sourcePath).length),
                bytes(sourcePath),
                uint256(bytes(entryJson).length),
                bytes(entryJson)
            )
        );
    }

    /// Rebuild the canonical slots JSON for one contract from the frozen
    /// manifest: sorted keys, no whitespace, fields in the canonical order
    /// (numberOfBytes, offset, slot, type) with verbatim solc strings.
    function _canonicalSlotsJson(string memory contractName) internal view returns (string memory) {
        string memory slotsPath = string.concat('$.contracts["', contractName, '"].slots');
        string[] memory labels = vm.parseJsonKeys(manifestJson, slotsPath);
        require(labels.length > 0, "no slot labels");
        _sortStrings(labels);
        string memory out = "{";
        for (uint256 i = 0; i < labels.length; i++) {
            string memory varBase = string.concat(slotsPath, '["', labels[i], '"]');
            if (i > 0) out = string.concat(out, ",");
            out = string.concat(
                out,
                _jsonString(labels[i]),
                ":{",
                '"numberOfBytes":',
                _jsonString(manifestJson.readString(string.concat(varBase, ".numberOfBytes"))),
                ',"offset":',
                _uintToString(manifestJson.readUint(string.concat(varBase, ".offset"))),
                ',"slot":',
                _jsonString(manifestJson.readString(string.concat(varBase, ".slot"))),
                ',"type":',
                _jsonString(manifestJson.readString(string.concat(varBase, ".type"))),
                "}"
            );
        }
        return string.concat(out, "}");
    }

    // -------------------------------------------------------------------------
    // Structural checks over the frozen artifact
    // -------------------------------------------------------------------------

    function test_Manifest_SchemaVersion_Is_Frozen_V1() public view {
        assertEq(manifestJson.readUint("$.schemaVersion"), 1, "schema must stay v1 until a reviewed migration");
    }

    function test_Manifest_Covers_Tracked_Inventory() public view {
        for (uint256 i = 0; i < TRACKED.length; i++) {
            string memory path = string.concat('$.contracts["', TRACKED[i], '"]');
            assertTrue(vm.keyExistsJson(manifestJson, path), string.concat("missing tracked contract: ", TRACKED[i]));
        }
    }

    function test_Every_Entry_Has_CanonicalHash_And_Kind() public view {
        for (uint256 i = 0; i < contractNames.length; i++) {
            string memory base = string.concat('$.contracts["', contractNames[i], '"]');
            string memory hash = manifestJson.readString(string.concat(base, ".canonicalHash"));
            assertTrue(
                bytes(hash).length == 66 && _startsWith(hash, "0x"),
                string.concat("malformed canonicalHash for ", contractNames[i])
            );
            string memory kind = manifestJson.readString(string.concat(base, ".kind"));
            assertTrue(
                _equals(kind, "upgradeable") || _equals(kind, "proxy"),
                string.concat("malformed kind for ", contractNames[i])
            );
        }
    }

    function test_Every_Slot_Entry_Is_Complete() public view {
        for (uint256 i = 0; i < contractNames.length; i++) {
            string memory slotsPath = string.concat('$.contracts["', contractNames[i], '"].slots');
            string[] memory labels = vm.parseJsonKeys(manifestJson, slotsPath);
            assertTrue(labels.length > 0, string.concat("empty slot map for ", contractNames[i]));
            for (uint256 j = 0; j < labels.length; j++) {
                string memory varBase = string.concat(slotsPath, '["', labels[j], '"]');
                assertTrue(vm.keyExistsJson(manifestJson, string.concat(varBase, ".slot")), labels[j]);
                assertTrue(vm.keyExistsJson(manifestJson, string.concat(varBase, ".offset")), labels[j]);
                assertTrue(vm.keyExistsJson(manifestJson, string.concat(varBase, ".type")), labels[j]);
                assertTrue(vm.keyExistsJson(manifestJson, string.concat(varBase, ".numberOfBytes")), labels[j]);
            }
        }
    }

    function test_CanonicalHash_Matches_Slot_Map_For_Every_Contract() public view {
        for (uint256 i = 0; i < contractNames.length; i++) {
            string memory name = contractNames[i];
            string memory base = string.concat('$.contracts["', name, '"]');
            string memory sourcePath = manifestJson.readString(string.concat(base, ".sourcePath"));
            string memory slotsJson = _canonicalSlotsJson(name);
            bytes32 expected = _canonicalHash(sourcePath, slotsJson);
            bytes32 recorded = vm.parseBytes32(manifestJson.readString(string.concat(base, ".canonicalHash")));
            assertEq(recorded, expected, string.concat("hash mismatch for ", name));
        }
    }

    function test_Upgradeable_Entries_Reserve_Gap_Headroom() public view {
        // Every canonical upgradeable layout must reserve proxy-upgrade headroom
        // (__gap) or be a proxy-shell entry; this is the enforceable shape of
        // the append-only policy at freeze time.
        for (uint256 i = 0; i < contractNames.length; i++) {
            string memory name = contractNames[i];
            string memory base = string.concat('$.contracts["', name, '"]');
            if (_equals(manifestJson.readString(string.concat(base, ".kind")), "proxy")) continue;
            string[] memory labels = vm.parseJsonKeys(manifestJson, string.concat(base, ".slots"));
            bool hasGap = false;
            for (uint256 j = 0; j < labels.length; j++) {
                if (_startsWith(labels[j], "__gap@")) hasGap = true;
            }
            assertTrue(hasGap, string.concat("upgradeable entry without __gap: ", name));
        }
    }

    // -------------------------------------------------------------------------
    // Drift-sensitivity: any field mutation must change the hash (fuzz)
    // -------------------------------------------------------------------------

    function testFuzz_Mutation_Of_Any_Slot_Field_Changes_Hash(uint256 seed, uint8 field, uint256 delta) public pure {
        string[3] memory types = [
            "t_mapping(t_bytes32,udt:struct AccessControl.RoleData:64b)",
            "t_address",
            "t_array(t_uint256)50_storage"
        ];
        string memory baseType = types[seed % 3];
        string memory slotsA = _slotsFor(baseType, 3, "32");
        string memory slotsB;
        uint256 f = field % 3;
        if (f == 0) {
            slotsB = _slotsFor(baseType, uint64(3 + (delta % 7) + 1), "32");
        } else if (f == 1) {
            slotsB = _slotsFor(baseType, 3, _stringOf(delta % 5 + 1));
        } else {
            slotsB = _slotsFor(_nextType(baseType), 3, "32");
        }
        assertTrue(
            _canonicalHash("contracts/x.sol", slotsA) != _canonicalHash("contracts/x.sol", slotsB),
            "a layout mutation must change the canonical hash"
        );
    }

    function testFuzz_SourcePath_Mutation_Changes_Hash(uint256 seed) public pure {
        string memory pathA = "contracts/x.sol";
        string memory pathB = string.concat("contracts/x", _stringOf(seed % 9 + 1), ".sol");
        string memory slots = _slotsFor("t_address", 0, "32");
        assertTrue(_canonicalHash(pathA, slots) != _canonicalHash(pathB, slots));
    }

    function testFuzz_Entry_Addition_Changes_Hash(uint256 seed) public pure {
        string memory slotsA = _slotsFor("t_address", 0, "32");
        string memory slotsB = string.concat(
            '{"x@0":{"numberOfBytes":"32","offset":0,"slot":"0","type":"t_address"},',
            '"y@1":{"numberOfBytes":"32","offset":0,"slot":"1","type":"t_uint256"},',
            '"z@',
            _stringOf(seed % 5 + 2),
            '":{"numberOfBytes":"1","offset":0,"slot":"2","type":"t_bool"}}'
        );
        assertTrue(_canonicalHash("contracts/x.sol", slotsA) != _canonicalHash("contracts/x.sol", slotsB));
    }

    function test_Domain_Separation_Constants() public pure {
        // Mirrors HASH_DOMAIN in scripts/storageLayoutManifest.ts: the same
        // entry under a different domain tag must not collide.
        bytes32 tag = keccak256("TB-STORAGE-LAYOUT-V1");
        assertTrue(tag != keccak256("TB-STORAGE-LAYOUT"));
        assertTrue(tag != keccak256("TB-EVENT-SCHEMA-V1"));
        assertTrue(tag != keccak256(""));
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _slotsFor(string memory varType, uint64 slot, string memory bytes_)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            '{"x@',
            _uintToString(slot),
            '":{"numberOfBytes":"',
            bytes_,
            '","offset":0,"slot":"',
            _uintToString(slot),
            '","type":"',
            varType,
            '"}}'
        );
    }

    function _nextType(string memory current) internal pure returns (string memory) {
        if (_equals(current, "t_address")) return "t_bool";
        if (_equals(current, "t_bool")) return "t_bytes32";
        if (_equals(current, "t_mapping(t_bytes32,udt:struct AccessControl.RoleData:64b)")) {
            return "t_mapping(t_address,udt:struct AccessControl.RoleData:64b)";
        }
        return "t_array(t_uint256)49_storage";
    }

    function _trackedNames() internal pure returns (string[] memory names) {
        names = new string[](14);
        names[0] = "ClaimLifecycle";
        names[1] = "DisputeResolution";
        names[2] = "FeeManager";
        names[3] = "GovernanceOwnable";
        names[4] = "ProtocolUpgradeable";
        names[5] = "ReputationDecay";
        names[6] = "ReputationEngine";
        names[7] = "StakeVault";
        names[8] = "TimelockOwnedProxyAdmin";
        names[9] = "TokenomicsEngine";
        names[10] = "TreasuryManagement";
        names[11] = "TruthBounty";
        names[12] = "TruthBountyToken";
        names[13] = "VerificationRoundManager";
    }

    function _jsonString(string memory s) internal pure returns (string memory) {
        return string.concat('"', s, '"');
    }

    function _uintToString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 digits;
        for (uint256 t = v; t > 0; t /= 10) digits++;
        bytes memory buf = new bytes(digits);
        while (v > 0) {
            buf[--digits] = bytes1(uint8(48 + (v % 10)));
            v /= 10;
        }
        return string(buf);
    }

    function _stringOf(uint256 v) internal pure returns (string memory) {
        // Deterministic non-numeric suffix for mutation tests.
        return string.concat("m", _uintToString(v));
    }

    function _equals(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _startsWith(string memory s, string memory prefix) internal pure returns (bool) {
        bytes memory sb = bytes(s);
        bytes memory pb = bytes(prefix);
        if (sb.length < pb.length) return false;
        for (uint256 i = 0; i < pb.length; i++) {
            if (sb[i] != pb[i]) return false;
        }
        return true;
    }

    function _sortStrings(string[] memory arr) internal pure {
        // Insertion sort with byte-lexicographic ordering — must match the
        // sorted-key ordering of canonicalJsonStringify (JS default sort).
        for (uint256 i = 1; i < arr.length; i++) {
            string memory key = arr[i];
            uint256 j = i;
            while (j > 0 && _greater(arr[j - 1], key)) {
                arr[j] = arr[j - 1];
                j--;
            }
            arr[j] = key;
        }
    }

    function _greater(string memory a, string memory b) internal pure returns (bool) {
        bytes memory ab = bytes(a);
        bytes memory bb = bytes(b);
        uint256 n = ab.length < bb.length ? ab.length : bb.length;
        for (uint256 i = 0; i < n; i++) {
            if (ab[i] != bb[i]) return uint8(ab[i]) > uint8(bb[i]);
        }
        return ab.length > bb.length;
    }
}
