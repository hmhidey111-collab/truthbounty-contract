// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { ConsumerGuaranteesAnchor } from "../../contracts/v2/ConsumerGuaranteesAnchor.sol";
import { IConsumerGuarantees } from "../../contracts/v2/interfaces/IConsumerGuarantees.sol";
import { V2Guarantees } from "../../contracts/v2/libraries/V2Guarantees.sol";

/// @title ConsumerGuaranteesManifest
/// @notice Deployment-artifact drift validation: the published manifest at
///         deployments/config/consumer-guarantees.json must agree field-by-field
///         with the on-chain guarantees produced from the same constants. A
///         maintainer editing either side without the other fails CI here.
contract ConsumerGuaranteesManifestTest is Test {
    string internal manifestJson;
    string internal manifestPath;

    function setUp() public {
        // forge-repo-root relative path; the cheatcode reads from the repository
        // root so the manifest is validated exactly as committed.
        manifestPath = "deployments/config/consumer-guarantees.json";
        manifestJson = vm.readFile(manifestPath);
    }

    function test_ManifestExistsAndParses() public view {
        assertTrue(bytes(manifestJson).length > 0, "manifest must not be empty");
        assertEq(vm.parseJsonUint(manifestJson, ".manifestVersion"), 1);
        assertEq(vm.parseJsonString(manifestJson, ".issue"), "V2-SC-134");
    }

    function test_ManifestGuaranteesMatchContractDefaults() public view {
        IConsumerGuarantees.ConsumerGuarantees memory expected = V2Guarantees.defaultGuarantees();

        assertEq(
            vm.parseJsonUint(manifestJson, ".consumerGuarantees.confirmationDepth"),
            expected.confirmationDepth,
            "confirmationDepth drift"
        );
        assertEq(
            vm.parseJsonUint(manifestJson, ".consumerGuarantees.maxFinalityClass"),
            expected.maxFinalityClass,
            "maxFinalityClass drift"
        );
        assertEq(
            vm.parseJsonUint(manifestJson, ".consumerGuarantees.maxReorgDepth"),
            expected.maxReorgDepth,
            "maxReorgDepth drift"
        );
        assertTrue(
            vm.parseJsonBool(manifestJson, ".consumerGuarantees.eventsAreReplayable") == expected.eventsAreReplayable,
            "eventsAreReplayable drift"
        );
        assertTrue(
            vm.parseJsonBool(manifestJson, ".consumerGuarantees.eventKeysAreUnique") == expected.eventKeysAreUnique,
            "eventKeysAreUnique drift"
        );
        assertTrue(
            vm.parseJsonBool(manifestJson, ".consumerGuarantees.eventsAreTerminalOnEmission")
                == expected.eventsAreTerminalOnEmission,
            "eventsAreTerminalOnEmission drift"
        );
    }

    function test_ManifestFinalityVocabularyMatchesEnum() public view {
        assertEq(
            vm.parseJsonUint(manifestJson, ".finalityClassVocabulary.None"),
            uint8(IConsumerGuarantees.FinalityClass.None)
        );
        assertEq(
            vm.parseJsonUint(manifestJson, ".finalityClassVocabulary.SoftConfirmation"),
            uint8(IConsumerGuarantees.FinalityClass.SoftConfirmation)
        );
        assertEq(
            vm.parseJsonUint(manifestJson, ".finalityClassVocabulary.ProtocolFinalized"),
            uint8(IConsumerGuarantees.FinalityClass.ProtocolFinalized)
        );
    }

    function test_ManifestChainIdAndIdentityRulesPresent() public view {
        assertEq(vm.parseJsonUint(manifestJson, ".chainId"), 11155420);
        assertFalse(bytes(vm.parseJsonString(manifestJson, ".canonicalEventIdentity.keyFormula")).length == 0);
        assertFalse(bytes(vm.parseJsonString(manifestJson, ".canonicalEventIdentity.removalRule")).length == 0);
        assertFalse(bytes(vm.parseJsonString(manifestJson, ".canonicalEventIdentity.replayRule")).length == 0);
    }

    function test_ManifestValuesPassLibraryValidation() public {
        IConsumerGuarantees.ConsumerGuarantees memory g = IConsumerGuarantees.ConsumerGuarantees({
            confirmationDepth: uint64(vm.parseJsonUint(manifestJson, ".consumerGuarantees.confirmationDepth")),
            maxFinalityClass: uint8(vm.parseJsonUint(manifestJson, ".consumerGuarantees.maxFinalityClass")),
            maxReorgDepth: uint64(vm.parseJsonUint(manifestJson, ".consumerGuarantees.maxReorgDepth")),
            eventsAreReplayable: vm.parseJsonBool(manifestJson, ".consumerGuarantees.eventsAreReplayable"),
            eventKeysAreUnique: vm.parseJsonBool(manifestJson, ".consumerGuarantees.eventKeysAreUnique"),
            eventsAreTerminalOnEmission: vm.parseJsonBool(
                manifestJson, ".consumerGuarantees.eventsAreTerminalOnEmission"
            )
        });
        // Must not revert: the manifest never publishes an invalid guarantee.
        V2Guarantees.validate(g);
        // And the anchor built from manifest values must expose them verbatim.
        vm.chainId(vm.parseJsonUint(manifestJson, ".chainId"));
        ConsumerGuaranteesAnchor anchor = new ConsumerGuaranteesAnchor(g, address(this));
        IConsumerGuarantees.ConsumerGuarantees memory published = anchor.consumerGuarantees();
        assertEq(published.confirmationDepth, g.confirmationDepth);
        assertEq(published.maxFinalityClass, g.maxFinalityClass);
        assertEq(published.maxReorgDepth, g.maxReorgDepth);
    }
}
