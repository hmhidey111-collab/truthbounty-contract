// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../upgrade/UpgradeInitializerHarness.sol";

/**
 * @title UpgradeInitializerHandler
 * @notice Stateful handler for V2-SC-122 invariant testing.
 *
 * Every fuzzer action goes through this contract, which mirrors the state it expects
 * in ghost variables and records violations in flags rather than assertions: the
 * invariant run is configured with `fail_on_revert = false`, so a flag that survives
 * the call is what makes a violation observable.
 */
contract UpgradeInitializerHandler is Test {
    UpgradeInitializerHarness public proxied;
    address public admin = address(0xA11CE);
    address public attacker = address(0xBAD);

    /// @notice Highest version the contract accepted, and the value written with it.
    uint64 public ghostHighestAcceptedVersion;
    uint256 public ghostValueAtHighestAcceptedVersion;

    /// @notice Last version observed on the contract, for the monotonicity check.
    uint64 public ghostLastObservedVersion;

    uint256 public ghostAttempts;
    uint256 public ghostSuccesses;
    uint256 public ghostRejections;

    /// @notice Violation flags — any of these being true fails an invariant.
    bool public ghostVersionDecreased;
    bool public ghostVersionAcceptedTwice;
    bool public ghostInitializerRanAgain;
    bool public ghostHigherVersionRejected;

    mapping(uint64 => bool) internal _acceptedVersion;

    constructor(UpgradeInitializerHarness proxied_, address admin_, uint256 initialValue) {
        proxied = proxied_;
        admin = admin_;
        ghostHighestAcceptedVersion = proxied_.initializedVersion();
        ghostLastObservedVersion = ghostHighestAcceptedVersion;
        ghostValueAtHighestAcceptedVersion = initialValue;
        _acceptedVersion[ghostHighestAcceptedVersion] = true;
    }

    /// @notice The initializer must never execute again, from any caller, with any args.
    function attemptInitialize(address newAdmin, uint256 newValue) external {
        ghostAttempts++;
        address candidate = newAdmin == address(0) ? attacker : newAdmin;

        vm.startPrank(attacker);
        try proxied.initializeHarness(candidate, address(0), address(0), newValue) {
            ghostInitializerRanAgain = true;
        } catch {
            ghostRejections++;
        }
        vm.stopPrank();

        _observe();
    }

    /// @notice Reinitialization is accepted exactly for strictly increasing versions.
    function attemptReinitialize(uint64 version, uint256 newValue) external {
        ghostAttempts++;
        version = uint64(bound(uint256(version), 1, 64));
        uint64 before = proxied.initializedVersion();

        vm.startPrank(admin);
        try proxied.reinitializeAt(version, newValue) {
            ghostSuccesses++;

            if (version <= before || _acceptedVersion[version]) {
                ghostVersionAcceptedTwice = true;
            }
            if (version < before) {
                ghostVersionDecreased = true;
            }

            _acceptedVersion[version] = true;
            ghostHighestAcceptedVersion = version;
            ghostValueAtHighestAcceptedVersion = newValue;
        } catch {
            ghostRejections++;
            if (version > before) {
                ghostHigherVersionRejected = true;
            }
        }
        vm.stopPrank();

        _observe();
    }

    function _observe() internal {
        uint64 current = proxied.initializedVersion();
        if (current < ghostLastObservedVersion) {
            ghostVersionDecreased = true;
        }
        ghostLastObservedVersion = current;
    }
}

/**
 * @title UpgradeInitializerInvariantTest
 * @notice V2-SC-122 — invariants that must hold across arbitrary initialization
 *         and reinitialization sequences.
 *
 * INV-1  The initialized version never decreases.
 * INV-2  No version is ever accepted twice.
 * INV-3  `initialize` can never execute on an initialized proxy.
 * INV-4  A strictly increasing reinitializer is never rejected.
 * INV-5  On-chain version and value always match the highest accepted version.
 * INV-6  The admin granted by the initializer keeps the role forever.
 * INV-7  Every attempt is accounted for as a success or a rejection.
 */
contract UpgradeInitializerInvariantTest is StdInvariant, Test {
    address internal constant ADMIN = address(0xA11CE);
    uint256 internal constant INITIAL_VALUE = 7;

    UpgradeInitializerHarness internal implementation;
    UpgradeInitializerHarness internal proxied;
    UpgradeInitializerHandler internal handler;

    function setUp() public {
        implementation = new UpgradeInitializerHarness();
        proxied = UpgradeInitializerHarness(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        UpgradeInitializerHarness.initializeHarness, (ADMIN, address(0), address(0), INITIAL_VALUE)
                    )
                )
            )
        );

        handler = new UpgradeInitializerHandler(proxied, ADMIN, INITIAL_VALUE);
        targetContract(address(handler));
    }

    function invariant_VersionNeverDecreases() public view {
        assertFalse(handler.ghostVersionDecreased(), "INV-1: initialized version decreased");
        assertEq(
            proxied.initializedVersion(),
            handler.ghostLastObservedVersion(),
            "INV-1: on-chain version drifted from the observed version"
        );
    }

    function invariant_NoVersionIsAcceptedTwice() public view {
        assertFalse(handler.ghostVersionAcceptedTwice(), "INV-2: a version was accepted twice");
    }

    function invariant_InitializerNeverRunsAgain() public view {
        assertFalse(handler.ghostInitializerRanAgain(), "INV-3: initialize executed on an initialized proxy");
    }

    function invariant_HigherVersionIsNeverRejected() public view {
        assertFalse(handler.ghostHigherVersionRejected(), "INV-4: a strictly increasing version was rejected");
    }

    function invariant_StateMatchesHighestAcceptedVersion() public view {
        assertEq(
            proxied.initializedVersion(),
            handler.ghostHighestAcceptedVersion(),
            "INV-5: version does not match the highest accepted version"
        );
        assertEq(
            proxied.value(),
            handler.ghostValueAtHighestAcceptedVersion(),
            "INV-5: value does not match the version it was written with"
        );
    }

    function invariant_AdminRoleIsPermanent() public view {
        assertTrue(proxied.hasRole(proxied.DEFAULT_ADMIN_ROLE(), ADMIN), "INV-6: initializer's admin lost the role");
    }

    function invariant_EveryAttemptIsAccountedFor() public view {
        assertEq(
            handler.ghostSuccesses() + handler.ghostRejections(),
            handler.ghostAttempts(),
            "INV-7: attempt accounting does not balance"
        );
    }
}
