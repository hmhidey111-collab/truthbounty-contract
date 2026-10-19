// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { ConsumerGuaranteesAnchor } from "../../contracts/v2/ConsumerGuaranteesAnchor.sol";
import { IConsumerGuarantees } from "../../contracts/v2/interfaces/IConsumerGuarantees.sol";
import { V2Guarantees } from "../../contracts/v2/libraries/V2Guarantees.sol";

contract ConsumerGuaranteesFuzzTest is Test {
    ConsumerGuaranteesAnchor internal anchor;

    function setUp() public {
        vm.chainId(11155420);
        anchor = new ConsumerGuaranteesAnchor(V2Guarantees.defaultGuarantees(), address(this));
    }

    // =========================================================================
    // Fuzz: every in-range confirmation depth yields a publishable anchor and
    // the exact depth round-trips through the getter.
    // =========================================================================

    function testFuzz_ConfirmationDepthRoundTrip(uint64 depth) public {
        depth = uint64(bound(depth, V2Guarantees.MIN_CONFIRMATION_DEPTH, V2Guarantees.MAX_CONFIRMATION_DEPTH));
        IConsumerGuarantees.ConsumerGuarantees memory g = _mutableDefault();
        g.confirmationDepth = depth;
        ConsumerGuaranteesAnchor a = new ConsumerGuaranteesAnchor(g, address(this));
        assertEq(a.consumerGuarantees().confirmationDepth, depth);
    }

    // =========================================================================
    // Fuzz: any field mutation that violates a bound must revert — publication
    // can never silently widen a guarantee (fail-closed validation).
    // =========================================================================

    function testFuzz_DepthAboveMaximumAlwaysReverts(uint64 depth) public {
        depth = uint64(bound(depth, V2Guarantees.MAX_CONFIRMATION_DEPTH + 1, type(uint64).max));
        IConsumerGuarantees.ConsumerGuarantees memory g = _mutableDefault();
        g.confirmationDepth = depth;
        vm.expectRevert(
            abi.encodeWithSelector(V2Guarantees.InvalidGuarantees.selector, "confirmationDepth above maximum")
        );
        new ConsumerGuaranteesAnchor(g, address(this));
    }

    function testFuzz_ReorgDepthAboveMaximumAlwaysReverts(uint64 depth) public {
        depth = uint64(bound(depth, V2Guarantees.MAX_REORG_DEPTH + 1, type(uint64).max));
        IConsumerGuarantees.ConsumerGuarantees memory g = _mutableDefault();
        g.maxReorgDepth = depth;
        vm.expectRevert(abi.encodeWithSelector(V2Guarantees.InvalidGuarantees.selector, "maxReorgDepth above maximum"));
        new ConsumerGuaranteesAnchor(g, address(this));
    }

    function testFuzz_ReorgDepthZeroAlwaysReverts(uint64 confirmationDepth) public {
        confirmationDepth =
            uint64(bound(confirmationDepth, V2Guarantees.MIN_CONFIRMATION_DEPTH, V2Guarantees.MAX_CONFIRMATION_DEPTH));
        IConsumerGuarantees.ConsumerGuarantees memory g = _mutableDefault();
        g.confirmationDepth = confirmationDepth;
        g.maxReorgDepth = 0;
        vm.expectRevert(
            abi.encodeWithSelector(V2Guarantees.InvalidGuarantees.selector, "maxReorgDepth must be positive")
        );
        new ConsumerGuaranteesAnchor(g, address(this));
    }

    // =========================================================================
    // Fuzz: finality for depth — the decisive consumer rule.
    // =========================================================================

    function testFuzz_FinalityBelowDepthIsNone(uint64 confirmed, uint64 published) public view {
        published = uint64(bound(published, V2Guarantees.MIN_CONFIRMATION_DEPTH, V2Guarantees.MAX_CONFIRMATION_DEPTH));
        confirmed = uint64(bound(confirmed, 0, published - 1));
        IConsumerGuarantees.ConsumerGuarantees memory g = _mutableDefault();
        g.confirmationDepth = published;
        assertEq(V2Guarantees.finalityForDepth(g, confirmed), uint8(IConsumerGuarantees.FinalityClass.None));
    }

    function testFuzz_FinalityAtOrAboveDepthIsSoftConfirmation(uint64 published, uint64 extra) public view {
        published = uint64(bound(published, V2Guarantees.MIN_CONFIRMATION_DEPTH, V2Guarantees.MAX_CONFIRMATION_DEPTH));
        extra = uint64(bound(extra, 0, V2Guarantees.MAX_CONFIRMATION_DEPTH));
        IConsumerGuarantees.ConsumerGuarantees memory g = _mutableDefault();
        g.confirmationDepth = published;
        assertEq(
            V2Guarantees.finalityForDepth(g, published + extra),
            uint8(IConsumerGuarantees.FinalityClass.SoftConfirmation)
        );
    }

    // =========================================================================
    // Fuzz: canonical event identity is injective over every field.
    // =========================================================================

    function testFuzz_EventKeyInjectivePerField(
        uint64 chainIdSeed,
        uint160 moduleSeed,
        uint64 blockNumber,
        bytes32 blockHash,
        bytes32 txHash,
        uint64 logIndex,
        uint256 field
    ) public view {
        uint64 chainId = uint64(bound(chainIdSeed, 1, type(uint32).max));
        address module = address(uint160(bound(moduleSeed, 1, type(uint160).max - 1)));
        blockNumber = uint64(bound(blockNumber, 0, type(uint32).max));
        logIndex = uint64(bound(logIndex, 0, type(uint16).max));
        field = bound(field, 0, 5);

        bytes32 base = V2Guarantees.eventKey(chainId, module, blockNumber, blockHash, txHash, logIndex);

        if (field == 0) {
            assertTrue(base != V2Guarantees.eventKey(chainId ^ 1, module, blockNumber, blockHash, txHash, logIndex));
        } else if (field == 1) {
            assertTrue(
                base
                    != V2Guarantees.eventKey(
                        chainId, address(uint160(uint160(module) ^ 1)), blockNumber, blockHash, txHash, logIndex
                    )
            );
        } else if (field == 2) {
            assertTrue(base != V2Guarantees.eventKey(chainId, module, blockNumber ^ 1, blockHash, txHash, logIndex));
        } else if (field == 3) {
            assertTrue(
                base
                    != V2Guarantees.eventKey(
                        chainId, module, blockNumber, bytes32(uint256(blockHash) ^ 1), txHash, logIndex
                    )
            );
        } else if (field == 4) {
            assertTrue(
                base
                    != V2Guarantees.eventKey(
                        chainId, module, blockNumber, blockHash, bytes32(uint256(txHash) ^ 1), logIndex
                    )
            );
        } else {
            assertTrue(base != V2Guarantees.eventKey(chainId, module, blockNumber, blockHash, txHash, logIndex ^ 1));
        }
    }

    // =========================================================================
    // Fuzz: guarantees commitment is deterministic and deployment-bound.
    // =========================================================================

    function testFuzz_GuaranteesCommitmentDeterministic(uint64 chainId, uint160 moduleSeed) public view {
        chainId = uint64(bound(chainId, 1, type(uint32).max));
        address module = address(uint160(bound(moduleSeed, 1, type(uint160).max - 1)));
        IConsumerGuarantees.ConsumerGuarantees memory g = anchor.consumerGuarantees();
        bytes32 a = V2Guarantees.guaranteesCommitment(g, chainId, module);
        bytes32 b = V2Guarantees.guaranteesCommitment(g, chainId, module);
        assertEq(a, b);
        assertTrue(a != V2Guarantees.guaranteesCommitment(g, chainId + 1, module));
        assertTrue(a != V2Guarantees.guaranteesCommitment(g, chainId, address(uint160(uint160(module) ^ 1))));
    }

    function _mutableDefault() private view returns (IConsumerGuarantees.ConsumerGuarantees memory g) {
        g = V2Guarantees.defaultGuarantees();
    }
}
