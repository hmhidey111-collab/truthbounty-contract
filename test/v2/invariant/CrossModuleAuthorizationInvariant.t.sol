// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "../../../contracts/v2/StakeVault.sol";
import "../../../contracts/v2/FinalRewardAllocator.sol";
import "../../../contracts/v2/interfaces/IFinalRewardAllocator.sol";
import "../../../contracts/v2/interfaces/IModuleRegistry.sol";
import {IModuleLookupStub} from "../ModuleLookupStub.sol";
import "../../../contracts/v2/interfaces/IV2Module.sol";
import "../../../contracts/v2/interfaces/IV2Types.sol";
import "../../../contracts/v2/libraries/V2Errors.sol";
import "../../../contracts/mocks/MockModuleRegistry.sol";
import "../../../contracts/MockERC20.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice A registry that keeps a stale implementation address after
///         deregistration: `module()` still answers, `isRegistered()` says no.
/// @dev Used to separate the two authorization styles in the V2 modules.
///      `StakeVault` consults `isRegistered` and then the address; the
///      `FinalRewardAllocator` consults only the address. A registry is
///      *supposed* to return zero for unknown ids, so this is a conformance
///      stress case rather than a reachable production state — but it is exactly
///      the case that tells the two trust models apart.
contract StaleEntryRegistry is ERC165, IModuleLookupStub {
    mapping(bytes32 => address) private _impl;
    mapping(bytes32 => bool) private _live;

    function protocolVersion() external pure override returns (uint16, uint16) {
        return (2, 0);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IModuleRegistry).interfaceId || interfaceId == type(IV2Module).interfaceId
            || super.supportsInterface(interfaceId);
    }

    function registerModule(bytes32 moduleId, address implementation) external override {
        _impl[moduleId] = implementation;
        _live[moduleId] = true;
        emit ModuleRegistered(moduleId, implementation, 2, 0);
    }

    /// @dev Deliberately leaves `_impl` in place.
    function removeModule(bytes32 moduleId) external override {
        _live[moduleId] = false;
        emit ModuleRemoved(moduleId, _impl[moduleId]);
    }

    function module(bytes32 moduleId) external view override returns (address, uint16, uint16) {
        return (_impl[moduleId], 2, 0);
    }

    function isRegistered(bytes32 moduleId) external view override returns (bool) {
        return _live[moduleId];
    }
}

/// @title CrossModuleAuthorizationTest
/// @notice V2-SC-093 — cross-module authorization invariant harness.
///
/// @dev Every module-to-module caller edge in the canonical V2 surface, and the
///      proof that they cannot be confused with one another or escalated.
///
///      There are two distinct authorization tiers, and the whole point of this
///      file is that holding the lower one must never imply the higher one:
///
///      - **Tier 1, lock mutation** (`StakeVault._onlyAuthorizedMutator`):
///        satisfied by an explicit `lockMutators` entry *or* by the registered
///        SLASHING, SETTLEMENT, or VERIFICATION module. Grants `lock`, `unlock`,
///        `allocateLocked`, `releaseStake`, `slashStake`.
///
///      - **Tier 2, settlement execution** (`_onlySettlementModule`): satisfied
///        only by the registered SETTLEMENT module. Grants the typed settlement
///        hooks, and on `FinalRewardAllocator`, treasury funding and finalization.
///
///      So SLASHING and VERIFICATION are tier 1 but not tier 2. StakeVault's
///      NatSpec states this ("a true result is necessary but not sufficient for
///      settlement hooks"); here it is enforced rather than asserted in prose.
///
///      Role authority is a third, orthogonal axis: `ADMIN_ROLE` can *appoint* a
///      mutator but is not itself one, and no module can appoint itself.
contract CrossModuleAuthorizationTest is Test {
    StakeVault internal vault;
    FinalRewardAllocator internal allocator;
    MockModuleRegistry internal registry;
    MockERC20 internal token;

    address internal governance = makeAddr("governance");

    address internal settlementModule = makeAddr("settlementModule");
    address internal slashingModule = makeAddr("slashingModule");
    address internal verificationModule = makeAddr("verificationModule");
    address internal explicitMutator = makeAddr("explicitMutator");

    address internal user = makeAddr("user");
    address internal guardian = makeAddr("guardian");
    address internal rotatedOut = makeAddr("rotatedOutModule");
    address internal stranger = makeAddr("stranger");

    bytes32 internal adminRole;
    bytes32 internal defaultAdminRole;

    uint256 internal constant CLAIM = 1;
    uint256 internal constant ROUND = 0;
    uint256 internal constant STAKE = 100 ether;

    function setUp() public {
        registry = new MockModuleRegistry();
        token = new MockERC20("Stake", "STK");

        vault = new StakeVault(address(registry), address(token), governance);
        allocator = new FinalRewardAllocator(address(registry), 5);

        adminRole = vault.ADMIN_ROLE();
        defaultAdminRole = vault.DEFAULT_ADMIN_ROLE();

        registry.permitModule(vault.MODULE_SETTLEMENT(), settlementModule);
        registry.permitModule(vault.MODULE_SLASHING(), slashingModule);
        registry.permitModule(vault.MODULE_VERIFICATION(), verificationModule);

        vm.prank(governance);
        vault.setLockMutator(explicitMutator, true);

        // A funded, locked position for the hooks to act on.
        token.mint(user, 1_000 ether);
        vm.startPrank(user);
        token.approve(address(vault), type(uint256).max);
        vault.depositStake(CLAIM, STAKE);
        vm.stopPrank();
    }

    // =========================================================================
    // The caller-edge matrix
    // =========================================================================

    function _tier1Callers() internal view returns (address[4] memory) {
        return [slashingModule, settlementModule, verificationModule, explicitMutator];
    }

    function _unauthorizedCallers() internal view returns (address[5] memory) {
        return [user, guardian, stranger, rotatedOut, governance];
    }

    /// @dev Tier 1 is exactly the four authorized principals, and nobody else.
    function test_tier1AuthorityIsExactlyTheDocumentedSet() public view {
        address[4] memory allowed = _tier1Callers();
        for (uint256 i; i < allowed.length; ++i) {
            assertTrue(vault.isAuthorizedMutator(allowed[i]), "expected tier-1 authority");
        }

        address[5] memory denied = _unauthorizedCallers();
        for (uint256 i; i < denied.length; ++i) {
            assertFalse(vault.isAuthorizedMutator(denied[i]), "unexpected tier-1 authority");
        }
    }

    /// @dev No unauthorized principal can mutate a lock through any tier-1 entry
    ///      point. Governance is in this set on purpose: holding ADMIN_ROLE does
    ///      not make you a mutator.
    function test_unauthorizedCallersCannotMutateLocks() public {
        address[5] memory denied = _unauthorizedCallers();

        for (uint256 i; i < denied.length; ++i) {
            address who = denied[i];

            vm.prank(who);
            vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedModule.selector, who));
            vault.lock(address(token), user, CLAIM, ROUND, IV2Types.LockCategory.VERIFIER_PRINCIPAL, 1);

            vm.prank(who);
            vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedModule.selector, who));
            vault.unlock(address(token), user, CLAIM, ROUND, IV2Types.LockCategory.VERIFIER_PRINCIPAL, 1);

            vm.prank(who);
            vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedModule.selector, who));
            vault.allocateLocked(
                address(token), user, CLAIM, ROUND, IV2Types.LockCategory.VERIFIER_PRINCIPAL, 1, bytes32("x")
            );

            vm.prank(who);
            vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedModule.selector, who));
            vault.slashStake(CLAIM, user, 1, bytes32("x"));

            vm.prank(who);
            vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedModule.selector, who));
            vault.releaseStake(CLAIM, user, 1);
        }
    }

    // =========================================================================
    // Tier 1 must not imply tier 2 — the confusion this harness exists for
    // =========================================================================

    /// @dev SLASHING, VERIFICATION and an explicit governance mutator all hold
    ///      tier-1 authority. None of them may execute a settlement hook. If any
    ///      one of them could, a slashing module would be able to declare a
    ///      settlement outcome and release or redirect principal.
    function test_tier1AuthorityDoesNotGrantSettlementHooks() public {
        address[3] memory tier1NotSettlement = [slashingModule, verificationModule, explicitMutator];

        for (uint256 i; i < tier1NotSettlement.length; ++i) {
            address who = tier1NotSettlement[i];
            assertTrue(vault.isAuthorizedMutator(who), "precondition: holds tier 1");

            vm.prank(who);
            vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedModule.selector, who));
            vault.settleConclusive(address(token), user, CLAIM, ROUND, 1, 0);

            vm.prank(who);
            vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedModule.selector, who));
            vault.refundInconclusive(address(token), user, CLAIM, ROUND, 1);

            vm.prank(who);
            vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedModule.selector, who));
            vault.carryForwardAppeal(address(token), user, CLAIM, ROUND, ROUND + 1, 1);

            vm.prank(who);
            vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedModule.selector, who));
            vault.rolloverRound(address(token), user, CLAIM, ROUND, ROUND + 1, 1);

            vm.prank(who);
            vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedModule.selector, who));
            vault.finalUnlock(address(token), user, CLAIM, ROUND, 1);
        }
    }

    /// @dev The registered SETTLEMENT module does hold tier 2. Proving the denial
    ///      set matters only if the allow path is live.
    function test_settlementModuleHoldsTier2() public {
        vm.prank(settlementModule);
        vault.finalUnlock(address(token), user, CLAIM, ROUND, 1);

        assertEq(
            uint8(vault.settlementOutcome(CLAIM, ROUND)),
            uint8(IV2Types.SettlementOutcome.UNLOCKED),
            "settlement module must be able to settle"
        );
    }

    /// @dev Tier 2 on the vault does not imply treasury authority elsewhere by
    ///      accident: the allocator authorizes against the same SETTLEMENT id, so
    ///      a slashing module is refused there too.
    function test_tier1AuthorityCannotFundOrFinalizeRewards() public {
        token.mint(slashingModule, 10);

        vm.startPrank(slashingModule);
        token.approve(address(allocator), 10);
        vm.expectRevert(
            abi.encodeWithSelector(FinalRewardAllocator.UnauthorizedSettlementModule.selector, slashingModule)
        );
        allocator.fund(address(token), 10, bytes32("s1"));
        vm.stopPrank();
    }

    // =========================================================================
    // Role authority is orthogonal and cannot be self-granted
    // =========================================================================

    function test_onlyAdminRoleMayAppointMutatorsOrAssets() public {
        vm.prank(slashingModule);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, slashingModule, adminRole
            )
        );
        vault.setLockMutator(stranger, true);

        vm.prank(settlementModule);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, settlementModule, adminRole
            )
        );
        vault.setSupportedAsset(address(token), false);
    }

    /// @dev A module cannot promote itself, and an appointed mutator cannot
    ///      promote itself to admin.
    function test_modulesCannotEscalateToAdmin() public {
        vm.prank(explicitMutator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, explicitMutator, defaultAdminRole
            )
        );
        vault.grantRole(adminRole, explicitMutator);

        assertFalse(vault.hasRole(adminRole, explicitMutator));
        assertFalse(vault.hasRole(adminRole, settlementModule));
        assertFalse(vault.hasRole(adminRole, slashingModule));
    }

    /// @dev Governance holds ADMIN_ROLE but is not a mutator and not settlement.
    ///      Appointing itself is the supported route, and it is an explicit,
    ///      auditable act rather than an implicit consequence of the role.
    function test_adminRoleIsNotImplicitlyAMutator() public {
        assertFalse(vault.isAuthorizedMutator(governance), "admin must not be an implicit mutator");

        vm.prank(governance);
        vault.setLockMutator(governance, true);

        assertTrue(vault.isAuthorizedMutator(governance), "appointment is explicit");

        // Even then, tier 2 stays closed.
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedModule.selector, governance));
        vault.finalUnlock(address(token), user, CLAIM, ROUND, 1);
    }

    // =========================================================================
    // Rotation and removal revoke immediately
    // =========================================================================

    /// @dev Re-pointing an id must revoke the previous holder in the same block.
    ///      Grandfathering here would leave a rotated-out module with live
    ///      settlement authority.
    function test_rotatingSettlementModuleRevokesThePreviousOne() public {
        address replacement = makeAddr("newSettlement");
        registry.permitModule(vault.MODULE_SETTLEMENT(), replacement);

        vm.prank(settlementModule);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedModule.selector, settlementModule));
        vault.finalUnlock(address(token), user, CLAIM, ROUND, 1);

        vm.prank(replacement);
        vault.finalUnlock(address(token), user, CLAIM, ROUND, 1);
        assertEq(uint8(vault.settlementOutcome(CLAIM, ROUND)), uint8(IV2Types.SettlementOutcome.UNLOCKED));
    }

    function test_removingAModuleRevokesTier1() public {
        assertTrue(vault.isAuthorizedMutator(slashingModule));

        registry.removeModule(vault.MODULE_SLASHING());

        assertFalse(vault.isAuthorizedMutator(slashingModule), "removal must revoke");

        vm.prank(slashingModule);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedModule.selector, slashingModule));
        vault.allocateLocked(
            address(token), user, CLAIM, ROUND, IV2Types.LockCategory.VERIFIER_PRINCIPAL, 1, bytes32("x")
        );
    }

    /// @dev An explicit mutator survives registry changes by design, because it
    ///      is a governance override rather than a registry fact. Revoking it is
    ///      also a governance act.
    function test_explicitMutatorIsIndependentOfTheRegistry() public {
        registry.removeModule(vault.MODULE_SLASHING());
        registry.removeModule(vault.MODULE_SETTLEMENT());
        registry.removeModule(vault.MODULE_VERIFICATION());

        assertTrue(vault.isAuthorizedMutator(explicitMutator), "override is registry-independent");

        vm.prank(governance);
        vault.setLockMutator(explicitMutator, false);
        assertFalse(vault.isAuthorizedMutator(explicitMutator), "and revocable");
    }

    // =========================================================================
    // Deployment isolation
    // =========================================================================

    /// @dev A settlement module registered in one registry has no authority over
    ///      a vault wired to a different registry. Module identity is
    ///      per-deployment, not global.
    function test_settlementModuleOfAnotherDeploymentHasNoAuthority() public {
        MockModuleRegistry otherRegistry = new MockModuleRegistry();
        StakeVault otherVault = new StakeVault(address(otherRegistry), address(token), governance);
        address otherSettlement = makeAddr("otherSettlement");
        otherRegistry.permitModule(otherVault.MODULE_SETTLEMENT(), otherSettlement);

        vm.prank(otherSettlement);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedModule.selector, otherSettlement));
        vault.finalUnlock(address(token), user, CLAIM, ROUND, 1);

        vm.prank(settlementModule);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedModule.selector, settlementModule));
        otherVault.finalUnlock(address(token), user, CLAIM, ROUND, 1);
    }

    // =========================================================================
    // The two trust models, made visible
    // =========================================================================

    /// @dev StakeVault fails closed on `isRegistered` before comparing the
    ///      address, so a deregistered module with a stale address is denied.
    function test_stakeVaultDeniesDeregisteredModuleWithStaleAddress() public {
        StaleEntryRegistry stale = new StaleEntryRegistry();
        StakeVault staleVault = new StakeVault(address(stale), address(token), governance);
        stale.registerModule(staleVault.MODULE_SETTLEMENT(), settlementModule);
        stale.removeModule(staleVault.MODULE_SETTLEMENT());

        (address impl,,) = stale.module(staleVault.MODULE_SETTLEMENT());
        assertEq(impl, settlementModule, "precondition: address is still returned");
        assertFalse(stale.isRegistered(staleVault.MODULE_SETTLEMENT()), "precondition: not registered");

        assertFalse(staleVault.isAuthorizedMutator(settlementModule), "isRegistered gate holds");

        vm.prank(settlementModule);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedModule.selector, settlementModule));
        staleVault.finalUnlock(address(token), user, CLAIM, ROUND, 1);
    }

    /// @dev FinalRewardAllocator authorizes on the returned address alone and
    ///      never consults `isRegistered`, so against the same registry it still
    ///      accepts the deregistered module.
    ///
    ///      This documents a divergence, not a live exploit: `IModuleRegistry`
    ///      requires an implementation to revert or return zero for unknown ids,
    ///      so a conforming registry never reaches this state. It is recorded
    ///      because the two canonical modules disagree about how much they trust
    ///      the registry, and the weaker of the two guards treasury funding.
    ///      Hardening would be one `isRegistered` check in
    ///      `FinalRewardAllocator._onlySettlementModule`, matching StakeVault.
    function test_finalRewardAllocatorTrustsTheAddressAloneKnownDivergence() public {
        StaleEntryRegistry stale = new StaleEntryRegistry();
        FinalRewardAllocator staleAllocator = new FinalRewardAllocator(address(stale), 5);
        stale.registerModule(staleAllocator.MODULE_SETTLEMENT(), settlementModule);
        stale.removeModule(staleAllocator.MODULE_SETTLEMENT());

        assertFalse(stale.isRegistered(staleAllocator.MODULE_SETTLEMENT()), "precondition: not registered");

        token.mint(settlementModule, 10);
        vm.startPrank(settlementModule);
        token.approve(address(staleAllocator), 10);
        // Accepted today. Asserted so that hardening this guard shows up here as
        // a deliberate, reviewed behaviour change rather than a silent one.
        staleAllocator.fund(address(token), 10, bytes32("s1"));
        vm.stopPrank();

        assertEq(staleAllocator.funded(address(token)), 10, "address-only authorization accepted the call");
    }

    /// @dev A zero implementation must never authorize anyone, in either module.
    function test_unregisteredIdAuthorizesNobody() public {
        MockModuleRegistry empty = new MockModuleRegistry();
        StakeVault emptyVault = new StakeVault(address(empty), address(token), governance);

        assertFalse(emptyVault.isAuthorizedMutator(settlementModule));
        assertFalse(emptyVault.isAuthorizedMutator(address(0)));

        vm.prank(settlementModule);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.UnauthorizedModule.selector, settlementModule));
        emptyVault.finalUnlock(address(token), user, CLAIM, ROUND, 1);
    }

    // =========================================================================
    // Users keep their own authority and nothing more
    // =========================================================================

    /// @dev A user may act on their own balance and never on anyone else's.
    function test_userAuthorityIsLimitedToTheirOwnBalance() public {
        vm.prank(settlementModule);
        vault.finalUnlock(address(token), user, CLAIM, ROUND, STAKE);

        uint256 before = token.balanceOf(user);

        vm.prank(user);
        vault.withdraw(address(token), STAKE);
        assertEq(token.balanceOf(user) - before, STAKE, "own balance is withdrawable");

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(V2Errors.InsufficientClaimable.selector, stranger, 1, 0)
        );
        vault.withdraw(address(token), 1);
    }
}

/// @notice Handler that lets unauthorized principals hammer every privileged
///         entry point on the canonical V2 modules.
/// @dev Each call is expected to revert. The invariant is that after an arbitrary
///      sequence of them, no protocol value has moved at all.
contract UnauthorizedCallerHandler is Test {
    StakeVault public vault;
    FinalRewardAllocator public allocator;
    MockModuleRegistry public registry;
    MockERC20 public token;

    address public victim = makeAddr("victim");
    /// @dev Deliberately not the handler: the handler must hold no authority.
    address public governance = makeAddr("vaultGovernance");
    address[4] public attackers;

    uint256 public constant CLAIM = 7;
    uint256 public constant STAKE = 500 ether;

    uint256 public attempts;

    constructor() {
        registry = new MockModuleRegistry();
        token = new MockERC20("Stake", "STK");
        vault = new StakeVault(address(registry), address(token), governance);
        allocator = new FinalRewardAllocator(address(registry), 5);

        // A real settlement module exists but is never used by the attackers.
        registry.permitModule(vault.MODULE_SETTLEMENT(), makeAddr("realSettlement"));

        attackers[0] = makeAddr("attacker0");
        attackers[1] = makeAddr("attacker1");
        attackers[2] = makeAddr("attacker2");
        attackers[3] = address(this); // holds nothing either

        token.mint(victim, 1_000 ether);
        vm.startPrank(victim);
        token.approve(address(vault), type(uint256).max);
        vault.depositStake(CLAIM, STAKE);
        vm.stopPrank();

        for (uint256 i; i < attackers.length; ++i) {
            token.mint(attackers[i], 1_000 ether);
            vm.prank(attackers[i]);
            token.approve(address(allocator), type(uint256).max);
        }
    }

    function _attacker(uint256 seed) internal view returns (address) {
        return attackers[seed % attackers.length];
    }

    function tryMutateLock(uint256 seed, uint256 rawAmount) public {
        address who = _attacker(seed);
        uint256 amount = bound(rawAmount, 1, STAKE);
        attempts++;

        vm.prank(who);
        try vault.lock(address(token), victim, CLAIM, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL, amount) {} catch {}

        vm.prank(who);
        try vault.unlock(address(token), victim, CLAIM, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL, amount) {} catch {}
    }

    function trySlash(uint256 seed, uint256 rawAmount) public {
        address who = _attacker(seed);
        uint256 amount = bound(rawAmount, 1, STAKE);
        attempts++;

        vm.prank(who);
        try vault.slashStake(CLAIM, victim, amount, bytes32("x")) {} catch {}

        vm.prank(who);
        try vault.allocateLocked(
            address(token), victim, CLAIM, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL, amount, bytes32("x")
        ) {} catch {}
    }

    function trySettlementHook(uint256 seed, uint256 rawAmount) public {
        address who = _attacker(seed);
        uint256 amount = bound(rawAmount, 1, STAKE);
        attempts++;

        vm.prank(who);
        try vault.settleConclusive(address(token), victim, CLAIM, 0, amount, 0) {} catch {}

        vm.prank(who);
        try vault.finalUnlock(address(token), victim, CLAIM, 0, amount) {} catch {}

        vm.prank(who);
        try vault.carryForwardAppeal(address(token), victim, CLAIM, 0, 1, amount) {} catch {}
    }

    function tryTreasury(uint256 seed, uint256 rawAmount) public {
        address who = _attacker(seed);
        uint256 amount = bound(rawAmount, 1, 100);
        attempts++;

        vm.prank(who);
        try allocator.fund(address(token), amount, bytes32("s1")) {} catch {}
    }

    function tryWithdrawSomeoneElsesBalance(uint256 seed, uint256 rawAmount) public {
        address who = _attacker(seed);
        uint256 amount = bound(rawAmount, 1, STAKE);
        attempts++;

        vm.prank(who);
        try vault.withdraw(address(token), amount) {} catch {}
    }

    function tryRoleEscalation(uint256 seed) public {
        address who = _attacker(seed);
        attempts++;

        vm.prank(who);
        try vault.grantRole(vault.ADMIN_ROLE(), who) {} catch {}

        vm.prank(who);
        try vault.setLockMutator(who, true) {} catch {}

        vm.prank(who);
        try vault.setSupportedAsset(address(token), false) {} catch {}
    }
}

/// @title CrossModuleAuthorizationInvariantTest
/// @notice V2-SC-093 — no sequence of unauthorized calls moves protocol value.
contract CrossModuleAuthorizationInvariantTest is StdInvariant, Test {
    UnauthorizedCallerHandler internal handler;

    uint256 internal initialLocked;
    uint256 internal initialCustody;

    function setUp() public {
        handler = new UnauthorizedCallerHandler();
        targetContract(address(handler));

        initialLocked = handler.vault().lockedPrincipal(
            address(handler.token()),
            handler.victim(),
            handler.CLAIM(),
            0,
            IV2Types.LockCategory.VERIFIER_PRINCIPAL
        );
        initialCustody = handler.vault().totalCustody(address(handler.token()));
    }

    /// @notice The victim's locked principal is untouched.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 40
    function invariant_unauthorizedCallersCannotMoveLockedPrincipal() public view {
        assertEq(
            handler.vault().lockedPrincipal(
                address(handler.token()),
                handler.victim(),
                handler.CLAIM(),
                0,
                IV2Types.LockCategory.VERIFIER_PRINCIPAL
            ),
            initialLocked,
            "locked principal moved without authorization"
        );
    }

    /// @notice Nothing was slashed, so protocol allocation never grew.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 40
    function invariant_unauthorizedCallersCannotSlash() public view {
        assertEq(
            handler.vault().protocolAllocation(address(handler.token())),
            0,
            "protocol allocation grew without authorization"
        );
    }

    /// @notice No settlement outcome was ever recorded.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 40
    function invariant_unauthorizedCallersCannotRecordSettlement() public view {
        assertEq(
            uint8(handler.vault().settlementOutcome(handler.CLAIM(), 0)),
            uint8(IV2Types.SettlementOutcome.NONE),
            "settlement outcome recorded without authorization"
        );
        assertEq(
            uint8(handler.vault().settlementOutcome(handler.CLAIM(), 1)),
            uint8(IV2Types.SettlementOutcome.NONE),
            "settlement outcome recorded without authorization"
        );
    }

    /// @notice No treasury funding was accepted.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 40
    function invariant_unauthorizedCallersCannotFundTheAllocator() public view {
        assertEq(handler.allocator().funded(address(handler.token())), 0, "allocator funded without authorization");
    }

    /// @notice Custody is unchanged and still reconciles.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 40
    function invariant_custodyUnchangedAndReconciled() public view {
        address asset = address(handler.token());
        (uint256 custody, uint256 obligations, uint256 actualBalance) = handler.vault().conservation(asset);

        assertEq(custody, initialCustody, "custody changed without authorization");
        assertEq(custody, obligations, "custody does not equal obligations");
        assertEq(custody, actualBalance, "custody does not equal token balance");
    }

    /// @notice Nobody escalated into a role.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 40
    function invariant_noRoleWasEscalated() public view {
        StakeVault vault = handler.vault();
        for (uint256 i; i < 4; ++i) {
            address who = handler.attackers(i);
            assertFalse(vault.hasRole(vault.ADMIN_ROLE(), who), "ADMIN_ROLE escalation");
            assertFalse(vault.lockMutators(who), "lock mutator escalation");
        }
    }

    /// @notice Proves the handler's unauthorized calls are actually attempted and
    ///         actually denied, so the invariants above are not vacuous.
    function test_handlerAttemptsAreMadeAndAllDenied() public {
        handler.tryMutateLock(0, 1 ether);
        handler.trySlash(1, 1 ether);
        handler.trySettlementHook(2, 1 ether);
        handler.tryTreasury(3, 10);
        handler.tryRoleEscalation(0);

        assertGt(handler.attempts(), 0, "no unauthorized call was attempted");

        StakeVault vault = handler.vault();
        assertEq(vault.protocolAllocation(address(handler.token())), 0, "a slash landed");
        assertEq(handler.allocator().funded(address(handler.token())), 0, "treasury funding landed");
        assertEq(
            uint8(vault.settlementOutcome(handler.CLAIM(), 0)),
            uint8(IV2Types.SettlementOutcome.NONE),
            "a settlement outcome landed"
        );
        assertEq(
            vault.lockedPrincipal(
                address(handler.token()),
                handler.victim(),
                handler.CLAIM(),
                0,
                IV2Types.LockCategory.VERIFIER_PRINCIPAL
            ),
            handler.STAKE(),
            "locked principal moved"
        );
    }
}
