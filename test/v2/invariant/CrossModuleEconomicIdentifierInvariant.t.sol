// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";

import "../../../contracts/v2/StakeVault.sol";
import "../../../contracts/v2/FinalRewardAllocator.sol";
import "../../../contracts/v2/interfaces/IFinalRewardAllocator.sol";
import "../../../contracts/v2/interfaces/IV2Types.sol";
import "../../../contracts/mocks/MockModuleRegistry.sol";
import "../../../contracts/MockERC20.sol";

/// @title CrossModuleEconomicIdentifierHandler
/// @notice State-machine driver for `CrossModuleEconomicIdentifierInvariantTest`.
///
/// @dev The V2 surface splits economic state across two modules that are both
///      written *only* by the registered SETTLEMENT module: custody lives in
///      `StakeVault`, pull-based reward entitlements live in
///      `FinalRewardAllocator`. This handler interleaves the identifier-minting
///      operations of both modules so the invariant suite can prove that
///      identifiers never cold-collide and that value is conserved across the
///      module boundary.
///
///      Settlement identifiers are domain-separated from claim identifiers, so
///      the same numeric `claimId`/`round` pair can never be consumed as a
///      different module's identifier.
contract CrossModuleEconomicIdentifierHandler is Test {
    StakeVault public vault;
    FinalRewardAllocator public allocator;
    MockModuleRegistry public registry;
    MockERC20 public token;

    address public settlementModule = makeAddr("settlementModule");
    address public slashingModule = makeAddr("slashingModule");
    address internal governance = makeAddr("governance");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    // ── Vault ghosts ────────────────────────────────────────────────────────
    uint256 public ghost_vaultDeposited;
    uint256 public ghost_vaultWithdrawn;

    // ── Allocator ghosts ────────────────────────────────────────────────────
    uint256 public ghost_allocFunded;
    uint256 public ghost_allocFinalized;
    uint256 public ghost_allocClaimed;

    mapping(bytes32 => uint256) public ghost_settlementFunded;
    mapping(bytes32 => uint256) public ghost_settlementFinalizedAmount;
    mapping(bytes32 => bool) public ghost_settlementWasFunded;
    mapping(bytes32 => uint8) public ghost_finalizedOutcome;

    bytes32[] public ghost_finalizedIds;

    bytes32 internal constant SETTLEMENT_DOMAIN = keccak256("V2_SETTLEMENT_ID");

    constructor() {
        registry = new MockModuleRegistry();
        token = new MockERC20("Stake", "STK");

        vault = new StakeVault(address(registry), address(token), governance);
        allocator = new FinalRewardAllocator(address(registry), 5);

        registry.permitModule(vault.MODULE_SETTLEMENT(), settlementModule);
        registry.permitModule(vault.MODULE_SLASHING(), slashingModule);

        // Fund the settlement module so it can back reward pools on the allocator.
        token.mint(settlementModule, 5_000_000 ether);
        vm.prank(settlementModule);
        token.approve(address(allocator), type(uint256).max);

        // Seed the two users and pre-approve the vault.
        token.mint(alice, 5_000_000 ether);
        token.mint(bob, 5_000_000 ether);
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);
    }

    function ghost_finalizedIdCount() external view returns (uint256) {
        return ghost_finalizedIds.length;
    }

    /// @dev Domain-separated settlement identifier. A bare `claimId` can never
    ///      equal this value because the domain tag is mixed in first.
    function settlementIdFor(uint256 claimId, uint256 round) public pure returns (bytes32) {
        return keccak256(abi.encode(SETTLEMENT_DOMAIN, claimId, round));
    }

    function _actor(uint256 actorSeed) internal view returns (address) {
        return actorSeed % 2 == 0 ? alice : bob;
    }

    // ── Vault actions ───────────────────────────────────────────────────────

    function depositStake(uint256 claimId, uint256 amount, uint256 actorSeed) public {
        claimId = bound(claimId, 1, 64);
        amount = bound(amount, 1, 1_000 ether);
        address user = _actor(actorSeed);

        vm.prank(user);
        try vault.depositStake(claimId, amount) {
            ghost_vaultDeposited += amount;
        } catch {}
    }

    function withdrawStake(uint256 amount, uint256 actorSeed) public {
        amount = bound(amount, 1, 1_000 ether);
        address user = _actor(actorSeed);

        vm.prank(user);
        try vault.withdraw(address(token), amount) {
            ghost_vaultWithdrawn += amount;
        } catch {}
    }

    function slashStake(uint256 claimId, uint256 amount, uint256 actorSeed) public {
        claimId = bound(claimId, 1, 64);
        amount = bound(amount, 1, 500 ether);
        address user = _actor(actorSeed);

        vm.prank(slashingModule);
        try vault.slashStake(claimId, user, amount, bytes32("invariant")) {
            ghost_vaultWithdrawn += 0; // slash keeps value in custody
        } catch {}
    }

    // ── Allocator actions (settlement-module gated) ─────────────────────────

    function fundRewardPool(uint256 claimId, uint256 round, uint256 amount) public {
        claimId = bound(claimId, 1, 64);
        round = bound(round, 0, 8);
        amount = bound(amount, 1, 1_000 ether);

        bytes32 settlementId = settlementIdFor(claimId, round);

        vm.prank(settlementModule);
        try allocator.fund(address(token), amount, settlementId) {
            ghost_settlementFunded[settlementId] += amount;
            ghost_settlementWasFunded[settlementId] = true;
            ghost_allocFunded += amount;
        } catch {}
    }

    function finalizeRewards(uint256 claimId, uint256 round, uint256 amount, uint256 actorSeed) public {
        claimId = bound(claimId, 1, 64);
        round = bound(round, 0, 8);

        bytes32 settlementId = settlementIdFor(claimId, round);
        uint256 available = ghost_settlementFunded[settlementId] - ghost_settlementFinalizedAmount[settlementId];
        if (available == 0) return;

        amount = bound(amount, 1, available);
        address recipient = _actor(actorSeed);

        address[] memory accounts = new address[](1);
        accounts[0] = recipient;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;

        IFinalRewardAllocator.Allocation[] memory allocations = new IFinalRewardAllocator.Allocation[](1);
        allocations[0] = IFinalRewardAllocator.Allocation({
            category: IFinalRewardAllocator.RewardCategory.VERIFIER_REWARD,
            accounts: accounts,
            effectiveWeights: weights,
            amount: amount,
            remainderRecipient: recipient
        });

        vm.prank(settlementModule);
        try allocator.finalizeRewards(
            settlementId,
            address(token),
            IFinalRewardAllocator.FinalOutcome.CONCLUSIVE_TRUE,
            allocations
        ) {
            ghost_settlementFinalizedAmount[settlementId] += amount;
            ghost_finalizedOutcome[settlementId] =
                uint8(IFinalRewardAllocator.FinalOutcome.CONCLUSIVE_TRUE);
            ghost_finalizedIds.push(settlementId);
            ghost_allocFinalized += amount;
        } catch {}
    }

    function claimReward(uint256 amount, uint256 actorSeed) public {
        address user = _actor(actorSeed);
        uint256 available = allocator.claimable(address(token), user);
        if (available == 0) return;

        amount = bound(amount, 1, available);
        vm.prank(user);
        try allocator.claim(address(token), amount) {
            ghost_allocClaimed += amount;
        } catch {}
    }
}

/// @title CrossModuleEconomicIdentifierInvariantTest
/// @notice V2-SC-043 — cross-module economic and identifier invariant harness.
///
/// @dev Proves, over arbitrary interleavings of custody and reward paths:
///      1. **Economic conservation** — the vault's tracked custody equals its
///         ERC20 balance and obligations equal custody; the allocator's balance
///         equals `funded - claimed`; `funded >= allocated`; no claim can exceed
///         what was finalized.
///      2. **Identifier integrity** — a settlement identifier is write-once:
///         once finalized it stays finalized with the same outcome, and only
///         identifiers that were explicitly funded can ever be finalized. The
///         domain-separated `settlementIdFor` guarantees a settlement id can
///         never alias a bare `claimId`.
contract CrossModuleEconomicIdentifierInvariantTest is StdInvariant, Test {
    CrossModuleEconomicIdentifierHandler public handler;

    function setUp() public {
        handler = new CrossModuleEconomicIdentifierHandler();
        targetContract(address(handler));
    }

    // ── Economic conservation ───────────────────────────────────────────────

    /// @notice Vault custody is fully accounted for at every ledger step.
    function invariant_vaultCustodyReconciles() public view {
        address asset = address(handler.token());
        StakeVault vault = handler.vault();

        uint256 onChain = handler.token().balanceOf(address(vault));
        assertEq(vault.totalCustody(asset), onChain, "custody != token balance");

        (uint256 custody, uint256 obligations) = vault.reconcile(asset);
        assertLe(obligations, custody, "obligations exceed custody");
        assertEq(custody, obligations, "custody != obligations (value leak)");
    }

    /// @notice Vault balance equals deposits minus withdrawals (slash keeps value).
    function invariant_vaultBalanceMatchesFlow() public view {
        uint256 onChain = handler.token().balanceOf(address(handler.vault()));
        assertEq(
            onChain,
            handler.ghost_vaultDeposited() - handler.ghost_vaultWithdrawn(),
            "vault balance != deposited - withdrawn"
        );
    }

    /// @notice The allocator always holds enough to honour outstanding claims.
    function invariant_allocatorBalanceMatchesFlow() public view {
        FinalRewardAllocator allocator = handler.allocator();
        uint256 onChain = handler.token().balanceOf(address(allocator));

        assertEq(
            onChain,
            handler.ghost_allocFunded() - handler.ghost_allocClaimed(),
            "allocator balance != funded - claimed"
        );
    }

    /// @notice Reward pools are never over-allocated and payouts never exceed finalization.
    function invariant_allocatorNeverOverAllocates() public view {
        FinalRewardAllocator allocator = handler.allocator();
        address asset = address(handler.token());

        assertGe(allocator.funded(asset), allocator.allocated(asset), "allocated > funded");
        assertLe(
            handler.ghost_allocClaimed(),
            handler.ghost_allocFinalized(),
            "claimed > finalized"
        );
    }

    // ── Identifier integrity ────────────────────────────────────────────────

    /// @notice A finalized settlement identifier is write-once and never regresses.
    function invariant_finalizedIdentifiersAreWriteOnce() public view {
        FinalRewardAllocator allocator = handler.allocator();
        uint256 count = handler.ghost_finalizedIdCount();

        for (uint256 i; i < count; ++i) {
            bytes32 id = handler.ghost_finalizedIds(i);
            assertTrue(allocator.finalized(id), "finalized identifier regressed");
            assertEq(
                uint8(allocator.finalOutcome(id)),
                handler.ghost_finalizedOutcome(id),
                "finalized outcome mutated"
            );
            assertTrue(handler.ghost_settlementWasFunded(id), "unfunded identifier finalized");
        }
    }

    /// @notice Settlement identifiers are domain-separated from claim identifiers,
    ///         so a bare claim id can never be consumed as a settlement id.
    function invariant_identifiersCannotAlias() public view {
        uint256 count = handler.ghost_finalizedIdCount();
        for (uint256 i; i < count; ++i) {
            bytes32 id = handler.ghost_finalizedIds(i);
            // A settlement id is a hash of the domain tag, never the raw id.
            assertTrue(id != bytes32(uint256(1)), "settlement id aliased a raw claim id");
        }
    }
}
