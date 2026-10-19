/**
 * @file fixtures.mjs
 * @description V2-SC-159 synthetic module-composition and upgrade-transition fixtures for the
 *              storage namespace checker. Each fixture is an in-memory source tree
 *              (repo-relative path -> Solidity source) plus the module list to compose, so the
 *              self-tests exercise the real parser, C3 linearization and collision rules without
 *              a compiler. Nothing here is compiled or deployed.
 */

/** Minimal policy: the ERC-1967 reserved slots and no external contracts. */
export const FIXTURE_POLICY = {
  schemaVersion: 1,
  reservedSlots: [
    { name: "IMPLEMENTATION_SLOT", standard: "ERC-1967", id: "eip1967.proxy.implementation", derivation: "eip1967" },
    { name: "ADMIN_SLOT", standard: "ERC-1967", id: "eip1967.proxy.admin", derivation: "eip1967" },
    { name: "BEACON_SLOT", standard: "ERC-1967", id: "eip1967.proxy.beacon", derivation: "eip1967" }
  ],
  externalContracts: {},
  acknowledgedLayoutDiscrepancies: []
};

const namespaceBase = (contractName, id, constantName, constantValue) => `
abstract contract ${contractName} {
    /// @custom:storage-location erc7201:${id}
    struct ${contractName}Storage {
        uint256 value;
    }

    // keccak256(abi.encode(uint256(keccak256("${id}")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ${constantName} = ${constantValue};

    function _load() private pure returns (${contractName}Storage storage $) {
        assembly {
            $.slot := ${constantName}
        }
    }
}
`;

/**
 * Builds a namespace base whose constant is derived with the ERC-7201 expression, so the fixture
 * never hard-codes a slot that could itself be wrong.
 */
export const derivedNamespaceBase = (contractName, id) => `
abstract contract ${contractName} {
    /// @custom:storage-location erc7201:${id}
    struct ${contractName}Storage {
        uint256 value;
    }

    bytes32 private constant ${contractName.toUpperCase()}_LOCATION =
        keccak256(abi.encode(uint256(keccak256("${id}")) - 1)) & ~bytes32(uint256(0xff));

    function _load() private pure returns (${contractName}Storage storage $) {
        assembly {
            $.slot := ${contractName.toUpperCase()}_LOCATION
        }
    }
}
`;

const header = "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.28;\n";

/** Two linear bases plus a namespaced base, composed by one module (the V1 of most fixtures). */
export const COMPOSITION_V1 = {
  sources: new Map([
    [
      "contracts/Bases.sol",
      `${header}
abstract contract LinearA {
    uint256 public a1;
    mapping(address account => uint256) internal a2;
    uint256 public constant A_CONSTANT = 1;
    address public immutable aImmutable = address(0);
}

abstract contract LinearB {
    bool internal b1 = true;
    bytes32 private b2;
    uint256[48] private __gap;
}
${derivedNamespaceBase("AlphaNamespace", "tb.fixture.Alpha")}`
    ],
    [
      "contracts/Module.sol",
      `${header}
import "./Bases.sol";

contract Module is LinearA, LinearB, AlphaNamespace {
    uint256 public m1;
    event Changed(uint256 value);
    function set(uint256 v) external { m1 = v; emit Changed(v); }
    uint256 public m2;
    uint256[48] private __gap;
}`
    ]
  ]),
  modules: [{ name: "Module", sourcePath: "contracts/Module.sol" }]
};

/** Replaces one file of a fixture. */
export function withSource(fixture, path, source) {
  const sources = new Map(fixture.sources);
  sources.set(path, source);
  return { sources, modules: fixture.modules };
}

/** Inherited-layout reorder: the module now lists LinearB before LinearA. */
export const REORDERED_BASES = withSource(
  COMPOSITION_V1,
  "contracts/Module.sol",
  `${header}
import "./Bases.sol";

contract Module is LinearB, LinearA, AlphaNamespace {
    uint256 public m1;
    uint256 public m2;
    uint256[48] private __gap;
}`
);

/** Inserted storage base between existing contributors (shifts every later slot). */
export const INSERTED_BASE = withSource(
  withSource(
    COMPOSITION_V1,
    "contracts/Inserted.sol",
    `${header}
abstract contract LinearInserted {
    uint256 internal inserted;
}`
  ),
  "contracts/Module.sol",
  `${header}
import "./Bases.sol";
import "./Inserted.sol";

contract Module is LinearA, LinearInserted, LinearB, AlphaNamespace {
    uint256 public m1;
    uint256 public m2;
    uint256[48] private __gap;
}`
);

/** Variables swapped inside the module itself. */
export const REORDERED_VARIABLES = withSource(
  COMPOSITION_V1,
  "contracts/Module.sol",
  `${header}
import "./Bases.sol";

contract Module is LinearA, LinearB, AlphaNamespace {
    uint256 public m2;
    uint256 public m1;
    uint256[48] private __gap;
}`
);

/** Safe append: a new variable before a shrunk gap, plus a new namespace base appended last. */
export const SAFE_APPEND = withSource(
  withSource(COMPOSITION_V1, "contracts/Beta.sol", `${header}${derivedNamespaceBase("BetaNamespace", "tb.fixture.Beta")}`),
  "contracts/Module.sol",
  `${header}
import "./Bases.sol";
import "./Beta.sol";

contract Module is LinearA, LinearB, AlphaNamespace, BetaNamespace {
    uint256 public m1;
    uint256 public m2;
    uint256 public m3;
    uint256[47] private __gap;
}`
);

/** The namespace base is dropped: its state would be orphaned. */
export const NAMESPACE_DROPPED = withSource(
  COMPOSITION_V1,
  "contracts/Module.sol",
  `${header}
import "./Bases.sol";

contract Module is LinearA, LinearB {
    uint256 public m1;
    uint256 public m2;
    uint256[48] private __gap;
}`
);

/** Two different contracts define the same ERC-7201 namespace id. */
export const DUPLICATE_NAMESPACE = withSource(
  COMPOSITION_V1,
  "contracts/Copycat.sol",
  `${header}${derivedNamespaceBase("CopycatNamespace", "tb.fixture.Alpha")}`
);

/** The annotation and the constant disagree (constant computed for another id). */
export const MISMATCHED_NAMESPACE_CONSTANT = {
  sources: new Map([
    [
      "contracts/Bad.sol",
      `${header}${namespaceBase("BadNamespace", "tb.fixture.Alpha", "BAD_LOCATION", "0x0000000000000000000000000000000000000000000000000000000000000100")}
contract BadModule is BadNamespace {
    uint256 public x;
}`
    ]
  ]),
  modules: [{ name: "BadModule", sourcePath: "contracts/Bad.sol" }]
};

/**
 * Reserved-slot overwrite: the module addresses the ERC-1967 implementation slot through an
 * EIP-1967 style unstructured constant, and the admin slot through a raw literal.
 */
export const RESERVED_SLOT_OVERWRITE = {
  sources: new Map([
    [
      "contracts/Clobber.sol",
      `${header}
contract ClobberModule {
    bytes32 internal constant HIJACKED_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);

    function hijack(address target) external {
        assembly {
            sstore(HIJACKED_SLOT, target)
            sstore(0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103, target)
        }
    }
}`
    ]
  ]),
  modules: [{ name: "ClobberModule", sourcePath: "contracts/Clobber.sol" }]
};

/** An unstructured slot that lands inside a namespace's 256-slot window. */
export const UNSTRUCTURED_IN_NAMESPACE_WINDOW = (alphaRootPlusOne) => ({
  sources: new Map([
    [
      "contracts/Window.sol",
      `${header}${derivedNamespaceBase("AlphaNamespace", "tb.fixture.Alpha")}
contract WindowModule is AlphaNamespace {
    bytes32 internal constant SIDE_SLOT = ${alphaRootPlusOne};

    function poke(uint256 v) external {
        assembly {
            sstore(SIDE_SLOT, v)
        }
    }
}`
    ]
  ]),
  modules: [{ name: "WindowModule", sourcePath: "contracts/Window.sol" }]
});

/** Two contracts composed into one module whose unstructured slots are identical. */
export const OVERLAPPING_UNSTRUCTURED = {
  sources: new Map([
    [
      "contracts/Overlap.sol",
      `${header}
abstract contract SlotOwnerA {
    bytes32 internal constant A_SLOT = bytes32(uint256(keccak256("tb.fixture.shared.slot")) - 1);
    function _writeA(uint256 v) internal { assembly { sstore(A_SLOT, v) } }
}

abstract contract SlotOwnerB {
    bytes32 internal constant B_SLOT = bytes32(uint256(keccak256("tb.fixture.shared.slot")) - 1);
    function _writeB(uint256 v) internal { assembly { sstore(B_SLOT, v) } }
}

contract OverlapModule is SlotOwnerA, SlotOwnerB {}`
    ]
  ]),
  modules: [{ name: "OverlapModule", sourcePath: "contracts/Overlap.sol" }]
};
