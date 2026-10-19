// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";

import "../../contracts/disputes/AppealVerificationRound.sol";
import "../../contracts/interfaces/IAppealVerificationRound.sol";
import "../../contracts/interfaces/ISTakeVault.sol";
import "../../contracts/StakeVault.sol";
import "../../contracts/ClaimRegistry.sol";
import "../../contracts/governance/ParameterVersionRegistry.sol";
import "../../contracts/MockReputationOracle.sol";
import "../../contracts/MockERC20.sol";
import "../../contracts/governance/GovernanceController.sol";

/**
 * @title AppealBoundsTest
 * @notice Foundry security proofs for V2-SC-059 (bound appeal rounds and prevent
 *         griefing) on {AppealVerificationRound} (SC-017).
 *
 * Security properties proven:
 *   1. Bond-gated opening: no appeal round exists without its {ISTakeVault} bond
 *      lock; zero-allowance openers revert before custody, zero-balance openers
 *      cannot grief a lock (fail closed).
 *   2. Bounded ladder: a claim's appeal path can never exceed the frozen
 *      `maxAppealRounds`; terminal paths are sealed irreversibly — even when the
 *      configured cap is later raised by governance.
 *   3. Bond escalation & custody: `appealBond <= requiredBond <= maxAppealBond`,
 *      the vault ledger reconciles 1:1 with the round record, and the module never
 *      disposes bonds (reserved for V2-SC-018).
 *   4. Bounded processing: voter floods past the per-round cap are rejected.
 *   5. Fail-closed config: invalid bond/cap/voter configuration is rejected at
 *      construction and on update.
 */
contract AppealBoundsTest is Test {
    // ---------------------------------------------------------------------------
    // Deployed world
    // ---------------------------------------------------------------------------

    address internal constant ADMIN = address(0xA11CE);
    address internal constant OUTSIDER = address(0x0FF1CE);
    address internal constant OPENER = address(0xB0B);
    address internal constant APPELLANT1 = address(0xAA1);
    address internal constant APPELLANT2 = address(0xAA2);

    bytes32 internal constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // ClaimRegistry imposes CID_MIN_LENGTH = 46.
    string internal constant SAMPLE_CID = "Qm1234567890abcdef1234567890abcdef1234567890abcd";

    MockERC20 internal token;
    MockReputationOracle internal oracle;
    GovernanceController internal govController;
    ClaimRegistry internal claimRegistry;
    StakeVault internal vault;
    AppealVerificationRound internal appeal;

    uint256 internal claimId;

    // Default config (escalation 1.5x, capped at 5k from a 1k base).
    IAppealVerificationRound.AppealRoundConfig internal defaultCfg;

    function setUp() public {
        token = new MockERC20("Reward", "RWD");
        oracle = new MockReputationOracle();
        govController = new GovernanceController(ADMIN);

        ParameterVersionRegistry paramReg = new ParameterVersionRegistry(ADMIN, ADMIN);
        claimRegistry = new ClaimRegistry(ADMIN, address(paramReg));

        vault = new StakeVault(ADMIN, address(token));

        defaultCfg = IAppealVerificationRound.AppealRoundConfig({
            roundDuration: 1 days,
            minStakeAmount: 1e18,
            stakeMultiplierBps: 15_000,
            maxWeightCap: 1_000_000e18,
            parameterVersion: 1,
            maxAppealRounds: 2,
            appealBond: 1_000e18,
            appealBondEscalationBps: 15_000,
            maxAppealBond: 5_000e18,
            maxVotersPerRound: 200
        });

        appeal = new AppealVerificationRound(
            address(token),
            address(claimRegistry),
            address(oracle),
            address(vault),
            defaultCfg,
            address(govController),
            ADMIN
        );

        vm.prank(ADMIN);
        vault.grantRole(OPERATOR_ROLE, address(appeal));

        // Fund the permissionless opener + appellants
        token.mint(OPENER, 1_000_000e18);
        token.mint(APPELLANT1, 10_000e18);
        token.mint(APPELLANT2, 10_000e18);

        vm.prank(OPENER);
        token.approve(address(vault), type(uint256).max);
        vm.prank(APPELLANT1);
        token.approve(address(appeal), type(uint256).max);
        vm.prank(APPELLANT2);
        token.approve(address(appeal), type(uint256).max);

        // A claim exists in the canonical registry
        vm.prank(ADMIN);
        claimId = claimRegistry.createClaim("Appeal claim", SAMPLE_CID, uint64(block.timestamp + 1 days));
    }

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    function _config(
        uint256 bond,
        uint256 escalationBps,
        uint256 maxBond,
        uint256 maxRounds,
        uint256 maxVoters
    ) internal view returns (IAppealVerificationRound.AppealRoundConfig memory) {
        return IAppealVerificationRound.AppealRoundConfig({
            roundDuration: 1 days,
            minStakeAmount: 1e18,
            stakeMultiplierBps: 15_000,
            maxWeightCap: 1_000_000e18,
            parameterVersion: 1,
            maxAppealRounds: maxRounds,
            appealBond: bond,
            appealBondEscalationBps: escalationBps,
            maxAppealBond: maxBond,
            maxVotersPerRound: maxVoters
        });
    }

    function _applyConfig(IAppealVerificationRound.AppealRoundConfig memory cfg) internal {
        vm.prank(ADMIN);
        appeal.setDefaultConfig(cfg);
    }

    function _open() internal {
        vm.prank(OPENER);
        appeal.openAppealRound(claimId);
    }

    function _openIfNotTerminal() internal {
        if (!appeal.isAppealPathTerminal(claimId)) _open();
    }

    function _close() internal {
        IAppealVerificationRound.AppealRound memory round = appeal.getAppealRound(claimId);
        vm.warp(round.deadline + 1);
        vm.prank(OUTSIDER);
        appeal.closeAppealRound(claimId);
    }

    function _fundVoter(address voter) internal {
        token.mint(voter, 10_000e18);
        vm.prank(voter);
        token.approve(address(appeal), type(uint256).max);
    }

    /// @notice Reference escalation implementation (independent, integer-arithmetic).
    function _refBond(uint256 appealBond, uint256 escBps, uint256 maxBond, uint256 roundIndex)
        internal
        pure
        returns (uint256)
    {
        if (roundIndex == 0) return 0;
        uint256 bond = appealBond;
        if (bond >= maxBond) return maxBond;
        for (uint256 i = 1; i < roundIndex; i++) {
            bond = (bond * escBps) / 10_000;
            if (bond >= maxBond) return maxBond;
        }
        return bond;
    }

    // ---------------------------------------------------------------------------
    // R1-premise: bond custody FIRST — no round without its vault lock
    // ---------------------------------------------------------------------------

    function test_openersWithNoAllowanceCannotOpen() public {
        uint256 before = vault.totalLocked();
        vm.prank(OUTSIDER); // never approved the vault
        vm.expectRevert(IAppealVerificationRound.InsufficientBondAllowance.selector);
        appeal.openAppealRound(claimId);
        assertEq(vault.totalLocked(), before, "ledger must stay untouched");
    }

    function test_openersWithAllowanceButNoBalanceCannotGriefLock() public {
        // approve() does not require funds; the vault transfer fails and the open
        // must roll back atomically — no lock and no round state.
        vm.prank(OUTSIDER);
        token.approve(address(vault), type(uint256).max);

        vm.expectRevert(IAppealVerificationRound.CustodyTransitionFailed.selector);
        vm.prank(OUTSIDER);
        appeal.openAppealRound(claimId);

        assertEq(vault.totalLocked(), 0, "no custody without funds");
        assertEq(uint256(appeal.getAppealRound(claimId).status), 0, "NONE");
    }

    function test_openLocksExactlyTheRequiredBondBeforeAnyRoundState() public {
        _open();

        IAppealVerificationRound.AppealRound memory round = appeal.getAppealRound(claimId);
        assertEq(round.requiredBond, 1_000e18, "round 1 bond == base appeal bond");
        assertEq(vault.totalLocked(), 1_000e18);

        ISTakeVault.BondLock memory lock = vault.getLock(round.bondLockId);
        assertEq(lock.depositor, OPENER, "bond deposited by the opener");
        assertEq(lock.amount, 1_000e18);
        assertEq(lock.token, address(token));
        assertFalse(lock.released, "issued bonds are not auto-disposed");

        ISTakeVault.BondLock memory ledgerLock = appeal.getAppealBondLock(claimId);
        assertEq(ledgerLock.lockId, round.bondLockId, "module ledger points at the vault lock");
        assertEq(ledgerLock.amount, 1_000e18);
    }

    // ---------------------------------------------------------------------------
    // R2: bounded ladder & irreversible terminality
    // ---------------------------------------------------------------------------

    function test_deadlineEqualityRejectsVoteAndAllowsPermissionlessClose() public {
        _open();
        IAppealVerificationRound.AppealRound memory round = appeal.getAppealRound(claimId);
        vm.warp(round.deadline);

        vm.expectRevert(
            abi.encodeWithSelector(
                AppealVerificationRound.AppealRoundExpired.selector,
                claimId,
                block.timestamp,
                round.deadline
            )
        );
        vm.prank(APPELLANT1);
        appeal.submitAppealVote(claimId, true, 1e18);
        assertEq(appeal.getAppealRound(claimId).verifierCount, 0);

        vm.prank(OUTSIDER);
        appeal.closeAppealRound(claimId);

        assertEq(uint256(appeal.getAppealRound(claimId).status), 2, "round closes at deadline");
        assertEq(vault.totalLocked(), round.requiredBond, "outage cannot release the appeal bond");
    }

    function test_bondEscalatesPerRoundAndIsCapped(uint256 escBps) public {
        escBps = bound(escBps, 10_000, 40_000);
        _applyConfig(_config(1_000e18, escBps, 10_000e18, 3, 200));

        assertEq(appeal.requiredAppealBond(1), 1_000e18);
        assertEq(appeal.requiredAppealBond(2), _refBond(1_000e18, escBps, 10_000e18, 2));
        assertEq(appeal.requiredAppealBond(3), _refBond(1_000e18, escBps, 10_000e18, 3));

        // Open rounds sequentially and reconcile the ledger 1:1
        for (uint256 r = 1; r <= 3; r++) {
            _openIfNotTerminal();
            IAppealVerificationRound.AppealRound memory cur = appeal.getAppealRound(claimId);
            assertEq(cur.roundIndex, r);
            assertEq(cur.requiredBond, appeal.requiredAppealBond(r), "round bond must match view");
            ISTakeVault.BondLock memory lock = vault.getLock(cur.bondLockId);
            assertEq(lock.amount, cur.requiredBond, "ledger reconciles 1:1");
            if (r < 3) _close();
        }
    }

    function test_finalRoundCloseSealsThePathTerminal() public {
        _open();
        _close();
        assertFalse(appeal.isAppealPathTerminal(claimId), "intermediate close not terminal");

        _open(); // round 2 of 2
        _close();

        assertTrue(appeal.isAppealPathTerminal(claimId), "final close seals the path");
        assertEq(uint256(appeal.getAppealRound(claimId).status), 3, "RESOLVED");
    }

    function test_terminalPathCanNeverReopen(uint256 bondAttempt) public {
        bondAttempt = bound(bondAttempt, 1e18, 5_000e18 - 1);
        _applyConfig(_config(bondAttempt, 10_000, 5_000e18, 1, 200));

        _open();
        _close();

        assertTrue(appeal.isAppealPathTerminal(claimId));
        vm.expectRevert(abi.encodeWithSelector(IAppealVerificationRound.AppealPathTerminal.selector, claimId));
        _open();
    }

    function test_openingBeyondLoweredCapReverts() public {
        _open();
        _close();

        _applyConfig(_config(1_000e18, 15_000, 5_000e18, 1, 200));

        vm.prank(OPENER);
        vm.expectRevert(abi.encodeWithSelector(IAppealVerificationRound.MaxAppealRoundsExceeded.selector, claimId, 2, 1));
        appeal.openAppealRound(claimId);
    }

    function test_governanceCannotResurrectTerminalPathByRaisingCap() public {
        // Terminal at cap = 1 ...
        _applyConfig(_config(1_000e18, 15_000, 5_000e18, 1, 200));
        _open();
        _close();
        assertTrue(appeal.isAppealPathTerminal(claimId));

        // ... governance raises the cap to the hard maximum ...
        _applyConfig(_config(1_000e18, 15_000, 5_000e18, 3, 200));

        // ... a terminal path still cannot be reopened.
        vm.expectRevert(abi.encodeWithSelector(IAppealVerificationRound.AppealPathTerminal.selector, claimId));
        _open();
    }

    function test_finalizeSealsTerminalPathOnceAndNeverAgain() public {
        assertEq(uint256(appeal.getAppealRound(claimId).status), 0, "NONE");
        vm.expectRevert(abi.encodeWithSelector(IAppealVerificationRound.AppealRoundNotClosed.selector, claimId));
        vm.prank(OUTSIDER);
        appeal.finalizeAppealRound(claimId);

        _open();
        // OPEN but not expired -> cannot finalize
        vm.expectRevert(
            abi.encodeWithSelector(
                AppealVerificationRound.AppealRoundNotExpired.selector,
                claimId,
                block.timestamp,
                appeal.getAppealRound(claimId).deadline
            )
        );
        vm.prank(OUTSIDER);
        appeal.finalizeAppealRound(claimId);

        // OPEN-but-expired -> one call closes and finalizes
        IAppealVerificationRound.AppealRound memory round = appeal.getAppealRound(claimId);
        vm.warp(round.deadline + 1);
        vm.prank(OUTSIDER);
        appeal.finalizeAppealRound(claimId);

        assertTrue(appeal.isAppealPathTerminal(claimId));
        assertEq(uint256(appeal.getAppealRound(claimId).status), 3, "RESOLVED");

        vm.expectRevert(abi.encodeWithSelector(IAppealVerificationRound.AppealPathAlreadyFinalized.selector, claimId));
        vm.prank(OUTSIDER);
        appeal.finalizeAppealRound(claimId);
    }

    function test_finalizeOnClosedNonTerminalRoundLocksTheLadder() public {
        _open();
        _close(); // round 1 of 2 closed, path still open
        assertFalse(appeal.isAppealPathTerminal(claimId));

        vm.prank(OUTSIDER);
        appeal.finalizeAppealRound(claimId);

        assertTrue(appeal.isAppealPathTerminal(claimId));
        assertEq(uint256(appeal.getAppealRound(claimId).status), 3, "RESOLVED");
    }

    // ---------------------------------------------------------------------------
    // R3: bounded processing — voter floods
    // ---------------------------------------------------------------------------

    function test_voterFloodIsBounded(uint256 maxVoters) public {
        maxVoters = bound(maxVoters, 1, 3);

        address[] memory voters = new address[](maxVoters + 1);
        for (uint256 i = 0; i <= maxVoters; i++) {
            voters[i] = address(uint160(0xB00 + i));
            _fundVoter(voters[i]);
        }

        _applyConfig(_config(1_000e18, 15_000, 5_000e18, 1, maxVoters));
        _open();

        for (uint256 v = 0; v < maxVoters; v++) {
            vm.prank(voters[v]);
            appeal.submitAppealVote(claimId, true, 1e18);
        }

        IAppealVerificationRound.AppealRound memory round = appeal.getAppealRound(claimId);
        assertLe(round.verifierCount, maxVoters, "cap must never be exceeded");

        vm.expectRevert(abi.encodeWithSelector(IAppealVerificationRound.VoterLimitExceeded.selector, claimId, maxVoters));
        vm.prank(voters[maxVoters]);
        appeal.submitAppealVote(claimId, true, 1e18);
    }

    // ---------------------------------------------------------------------------
    // R4: fail-closed configuration
    // ---------------------------------------------------------------------------

    function test_constructorRejectsInvalidConfig() public {
        IAppealVerificationRound.AppealRoundConfig memory valid = defaultCfg;

        valid.maxAppealRounds = 0;
        _expectDeployRevert(abi.encodeWithSelector(IAppealVerificationRound.InvalidMaxAppealRounds.selector, 0), valid);

        valid = defaultCfg;
        valid.maxAppealRounds = 4;
        _expectDeployRevert(abi.encodeWithSelector(IAppealVerificationRound.InvalidMaxAppealRounds.selector, 4), valid);

        valid = defaultCfg;
        valid.appealBond = 0;
        _expectDeployRevert(abi.encodeWithSelector(IAppealVerificationRound.InvalidAppealBond.selector, 0), valid);

        valid = defaultCfg;
        valid.appealBondEscalationBps = 9_999;
        _expectDeployRevert(abi.encodeWithSelector(IAppealVerificationRound.InvalidBondEscalation.selector, 9_999), valid);

        valid = defaultCfg;
        valid.appealBondEscalationBps = 40_001;
        _expectDeployRevert(abi.encodeWithSelector(IAppealVerificationRound.InvalidBondEscalation.selector, 40_001), valid);

        valid = defaultCfg;
        valid.maxAppealBond = valid.appealBond - 1;
        _expectDeployRevert(
            abi.encodeWithSelector(
                IAppealVerificationRound.InvalidMaxAppealBond.selector, valid.maxAppealBond, valid.appealBond
            ),
            valid
        );

        valid = defaultCfg;
        valid.maxVotersPerRound = 0;
        _expectDeployRevert(abi.encodeWithSelector(IAppealVerificationRound.InvalidMaxVotersPerRound.selector, 0), valid);

        valid = defaultCfg;
        valid.maxVotersPerRound = 201;
        _expectDeployRevert(abi.encodeWithSelector(IAppealVerificationRound.InvalidMaxVotersPerRound.selector, 201), valid);
    }

    function _expectDeployRevert(bytes memory expected, IAppealVerificationRound.AppealRoundConfig memory cfg)
        internal
    {
        vm.expectRevert(expected);
        new AppealVerificationRound(
            address(token),
            address(claimRegistry),
            address(oracle),
            address(vault),
            cfg,
            address(govController),
            ADMIN
        );
    }

    function test_setDefaultConfigRejectsInvalidValues() public {
        _applyConfigExpectRevert(
            abi.encodeWithSelector(IAppealVerificationRound.InvalidMaxAppealRounds.selector, 0),
            _config(1_000e18, 15_000, 5_000e18, 0, 200)
        );
        _applyConfigExpectRevert(
            abi.encodeWithSelector(IAppealVerificationRound.InvalidMaxAppealRounds.selector, 4),
            _config(1_000e18, 15_000, 5_000e18, 4, 200)
        );
        _applyConfigExpectRevert(
            abi.encodeWithSelector(IAppealVerificationRound.InvalidAppealBond.selector, 0),
            _config(0, 15_000, 5_000e18, 2, 200)
        );
        _applyConfigExpectRevert(
            abi.encodeWithSelector(IAppealVerificationRound.InvalidBondEscalation.selector, 9_999),
            _config(1_000e18, 9_999, 5_000e18, 2, 200)
        );
        _applyConfigExpectRevert(
            abi.encodeWithSelector(IAppealVerificationRound.InvalidBondEscalation.selector, 40_001),
            _config(1_000e18, 40_001, 5_000e18, 2, 200)
        );
        _applyConfigExpectRevert(
            abi.encodeWithSelector(IAppealVerificationRound.InvalidMaxAppealBond.selector, 999e18, 1_000e18),
            _config(1_000e18, 15_000, 999e18, 2, 200)
        );
        _applyConfigExpectRevert(
            abi.encodeWithSelector(IAppealVerificationRound.InvalidMaxVotersPerRound.selector, 0),
            _config(1_000e18, 15_000, 5_000e18, 2, 0)
        );
        _applyConfigExpectRevert(
            abi.encodeWithSelector(IAppealVerificationRound.InvalidMaxVotersPerRound.selector, 201),
            _config(1_000e18, 15_000, 5_000e18, 2, 201)
        );
    }

    function _applyConfigExpectRevert(bytes memory expected, IAppealVerificationRound.AppealRoundConfig memory cfg)
        internal
    {
        vm.prank(ADMIN);
        vm.expectRevert(expected);
        appeal.setDefaultConfig(cfg);
    }

    // ---------------------------------------------------------------------------
    // Fuzz: bond math under arbitrary (valid) configuration
    // ---------------------------------------------------------------------------

    function testFuzz_requiredAppealBondMatchesReference(
        uint256 appealBond,
        uint256 escBps,
        uint256 maxBond,
        uint256 roundIndex
    ) public {
        appealBond = bound(appealBond, 1, 1e31);
        escBps = bound(escBps, 10_000, 40_000);
        roundIndex = bound(roundIndex, 0, 8);
        maxBond = bound(maxBond, appealBond, 1e36);

        _applyConfig(_config(appealBond, escBps, maxBond, 1, 200));

        assertEq(
            appeal.requiredAppealBond(roundIndex),
            _refBond(appealBond, escBps, maxBond, roundIndex),
            "bond math must match escalation reference"
        );
    }

    function testFuzz_requiredAppealBondMonotonicAndCapped(
        uint256 appealBond,
        uint256 escBps,
        uint256 maxBond,
        uint256 roundIndex
    ) public {
        appealBond = bound(appealBond, 1, 1e31);
        escBps = bound(escBps, 10_000, 40_000);
        roundIndex = bound(roundIndex, 0, 8);
        maxBond = bound(maxBond, appealBond, 1e36);

        _applyConfig(_config(appealBond, escBps, maxBond, 1, 200));

        uint256 bond = appeal.requiredAppealBond(roundIndex);
        assertLe(bond, maxBond, "cap: bond never exceeds maxAppealBond");
        if (roundIndex > 0) {
            assertGe(bond, appealBond, "floor: bond never below the base appealBond");
            uint256 next = appeal.requiredAppealBond(roundIndex + 1);
            assertLe(next, maxBond, "cap: next bond never exceeds maxAppealBond");
            assertGe(next, bond, "monotonic: bonds never decrease as the ladder grows");
        }
    }
}

// =============================================================================
// Invariant harness: the ladder can never exceed the frozen cap, and every open
// leaves exactly one vault lock that reconciles 1:1 with the round record.
// =============================================================================

contract AppealBoundsHandler is Test {
    AppealVerificationRound internal appeal;
    StakeVault internal vault;

    address internal opener;
    address internal outsider;

    uint256 internal claimId;

    uint256 internal ghostOpens;
    uint256 internal ghostLocked;

    constructor(
        AppealVerificationRound _appeal,
        StakeVault _vault,
        ClaimRegistry _registry,
        address _opener,
        address _outsider
    ) {
        appeal = _appeal;
        vault = _vault;
        opener = _opener;
        outsider = _outsider;

        vm.prank(_opener);
        claimId = _registry.createClaim(
            "Invariant appeal claim",
            "Qm1234567890abcdef1234567890abcdef1234567890abcd",
            uint64(block.timestamp + 1 days)
        );
    }

    function open() external {
        vm.prank(opener);
        try appeal.openAppealRound(claimId) {
            ghostOpens++;
            IAppealVerificationRound.AppealRound memory r = appeal.getAppealRound(claimId);
            ghostLocked += r.requiredBond;
        } catch {}
    }

    function closeIfExpired() external {
        IAppealVerificationRound.AppealRound memory r = appeal.getAppealRound(claimId);
        if (r.status == IAppealVerificationRound.AppealRoundStatus.OPEN && block.timestamp >= r.deadline) {
            vm.prank(outsider);
            try appeal.closeAppealRound(claimId) {} catch {}
        }
    }

    function skipTime(uint256 t) external {
        t = bound(t, 1, 60 days);
        vm.warp(block.timestamp + t);
    }

    function finalize() external {
        vm.prank(outsider);
        try appeal.finalizeAppealRound(claimId) {} catch {}
    }

    // ---- view accessors for the invariant checks ---------------------------

    function openCount() external view returns (uint256) {
        return ghostOpens;
    }

    function ghostLockedTotal() external view returns (uint256) {
        return ghostLocked;
    }

    function appealContract() external view returns (AppealVerificationRound) {
        return appeal;
    }

    function vaultTotalLocked() external view returns (uint256) {
        return vault.totalLocked();
    }

    function currentStatus() external view returns (IAppealVerificationRound.AppealRoundStatus) {
        return appeal.getAppealRound(claimId).status;
    }

    function isTerminal() external view returns (bool) {
        return appeal.isAppealPathTerminal(claimId);
    }

    function currentRound() external view returns (IAppealVerificationRound.AppealRound memory) {
        return appeal.getAppealRound(claimId);
    }
}

contract AppealBoundsInvariantTest is StdInvariant, Test {
    AppealBoundsHandler internal handler;
    AppealVerificationRound internal appeal;
    StakeVault internal vault;
    MockERC20 internal token;

    function setUp() public {
        token = new MockERC20("Reward", "RWD");
        MockReputationOracle oracle = new MockReputationOracle();
        GovernanceController govController = new GovernanceController(address(0xC011));
        ParameterVersionRegistry paramReg = new ParameterVersionRegistry(address(0xC011), address(0xC011));
        ClaimRegistry registry = new ClaimRegistry(address(0xC011), address(paramReg));
        vault = new StakeVault(address(0xC011), address(token));

        IAppealVerificationRound.AppealRoundConfig memory cfg = IAppealVerificationRound.AppealRoundConfig({
            roundDuration: 1 days,
            minStakeAmount: 1e18,
            stakeMultiplierBps: 15_000,
            maxWeightCap: 1_000_000e18,
            parameterVersion: 1,
            maxAppealRounds: 3,
            appealBond: 1_000e18,
            appealBondEscalationBps: 15_000,
            maxAppealBond: 5_000e18,
            maxVotersPerRound: 200
        });

        appeal = new AppealVerificationRound(
            address(token),
            address(registry),
            address(oracle),
            address(vault),
            cfg,
            address(govController),
            address(0xC011)
        );
        vm.prank(address(0xC011));
        vault.grantRole(keccak256("OPERATOR_ROLE"), address(appeal));

        address opener = address(0xB0B5);
        token.mint(opener, 1_000_000e18);
        vm.prank(opener);
        token.approve(address(vault), type(uint256).max);

        handler = new AppealBoundsHandler(appeal, vault, registry, opener, address(0x0FF2CE));

        targetContract(address(handler));
    }

    function invariant_openCountNeverExceedsFrozenCap() public view {
        IAppealVerificationRound.AppealRound memory r = handler.currentRound();
        if (r.roundIndex > 0) {
            assertLe(handler.openCount(), r.maxRounds, "ladder must respect the frozen cap");
            assertEq(handler.openCount(), r.roundIndex, "opens must be strictly sequential");
        }
    }

    function invariant_terminalPathsAreFinalized() public view {
        if (handler.isTerminal()) {
            assertEq(
                uint256(handler.currentStatus()),
                uint256(IAppealVerificationRound.AppealRoundStatus.RESOLVED),
                "terminal path must be RESOLVED"
            );
        }
    }

    function invariant_everyBondIsVaultedAndReconciles() public view {
        assertEq(handler.vaultTotalLocked(), handler.ghostLockedTotal(), "ledger must reconcile 1:1");
        assertEq(token.balanceOf(address(vault)), handler.ghostLockedTotal(), "custody must hold the bonds");
    }

    function invariant_roundBasedBondBounds() public view {
        IAppealVerificationRound.AppealRound memory r = handler.currentRound();
        if (r.roundIndex > 0) {
            assertGe(r.requiredBond, 1_000e18, "floor: no below-base bonds");
            assertLe(r.requiredBond, 5_000e18, "cap: no above-ceiling bonds");
            assertEq(r.requiredBond, appeal.requiredAppealBond(r.roundIndex), "matches the escalation view");
        }
    }
}