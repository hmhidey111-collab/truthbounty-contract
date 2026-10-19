// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ProtocolExecutionBounds} from "./ProtocolExecutionBounds.sol";

/**
 * @title LoopBoundsCatalog
 * @notice On-chain catalog of defensible loop bounds for audit and projection (V2-SC-038).
 */
contract LoopBoundsCatalog {
    struct LoopBound {
        string module;
        string functionName;
        string loopVariable;
        uint256 maxIterations;
        string mitigation;
    }

    function catalogSize() external pure returns (uint256) {
        return 14;
    }

    function getLoopBound(uint256 index) external pure returns (LoopBound memory) {
        if (index == 0) {
            return LoopBound({
                module: "VerificationAggregation",
                functionName: "_calculateWeights",
                loopVariable: "voterCount",
                maxIterations: ProtocolExecutionBounds.MAX_VERIFIERS_PER_CLAIM,
                mitigation: "Capped by MAX_VERIFICATION_COUNT constant"
            });
        }
        if (index == 1) {
            return LoopBound({
                module: "VerificationAggregator",
                functionName: "calculateWeights",
                loopVariable: "voterCount",
                maxIterations: ProtocolExecutionBounds.MAX_VERIFIERS_PER_CLAIM,
                mitigation: "Source voter list bounded by protocol stake design"
            });
        }
        if (index == 2) {
            return LoopBound({
                module: "TruthBountyClaims",
                functionName: "settleClaimsBatch",
                loopVariable: "beneficiaries.length",
                maxIterations: ProtocolExecutionBounds.MAX_SETTLEMENT_BATCH_SIZE,
                mitigation: "Hard cap MAX_BATCH_SIZE"
            });
        }
        if (index == 3) {
            return LoopBound({
                module: "PullSettlementLedger",
                functionName: "creditBatch",
                loopVariable: "beneficiaries.length",
                maxIterations: ProtocolExecutionBounds.MAX_SETTLEMENT_BATCH_SIZE,
                mitigation: "Hard cap; pull withdrawals decouple recipient behavior"
            });
        }
        if (index == 4) {
            return LoopBound({
                module: "RewardEngine",
                functionName: "claimRewardsBatch",
                loopVariable: "distributionIds.length",
                maxIterations: ProtocolExecutionBounds.MAX_REWARD_BATCH_SIZE,
                mitigation: "Hard cap MAX_DISTRIBUTION_BATCH_SIZE"
            });
        }
        if (index == 5) {
            return LoopBound({
                module: "TokenomicsEngine",
                functionName: "distributeBatch",
                loopVariable: "recipients.length",
                maxIterations: ProtocolExecutionBounds.MAX_TOKENOMICS_BATCH_SIZE,
                mitigation: "Hard cap MAX_BATCH_SIZE"
            });
        }
        if (index == 6) {
            return LoopBound({
                module: "InsuranceFund",
                functionName: "processPayoutPage",
                loopVariable: "page size",
                maxIterations: ProtocolExecutionBounds.MAX_INSURANCE_PAGE_SIZE,
                mitigation: "Hard cap MAX_BATCH_SIZE"
            });
        }
        if (index == 7) {
            return LoopBound({
                module: "EvidenceManager",
                functionName: "getEvidencePage",
                loopVariable: "page length",
                maxIterations: ProtocolExecutionBounds.MAX_EVIDENCE_PER_CLAIM,
                mitigation: "Hard cap MAX_EVIDENCE_PER_CLAIM on writes"
            });
        }
        if (index == 8) {
            return LoopBound({
                module: "FeeManager",
                functionName: "allocateFees",
                loopVariable: "targets.length",
                maxIterations: 20,
                mitigation: "Hard cap MAX_ALLOCATION_TARGETS"
            });
        }
        if (index == 9) {
            return LoopBound({
                module: "VerifierSlashing",
                functionName: "slashBatch",
                loopVariable: "batch length",
                maxIterations: 50,
                mitigation: "Hard cap MAX_BATCH_SIZE"
            });
        }
        if (index == 10) {
            return LoopBound({
                module: "ReputationEngine",
                functionName: "batchUpdate",
                loopVariable: "verifiers.length",
                maxIterations: 200,
                mitigation: "Caller-supplied array; bounded by upstream module pages"
            });
        }
        if (index == 11) {
            return LoopBound({
                module: "TreasuryAccounting",
                functionName: "paginateHistory",
                loopVariable: "page length",
                maxIterations: 200,
                mitigation: "Fixed page size in view pagination"
            });
        }
        if (index == 12) {
            return LoopBound({
                module: "Claims",
                functionName: "createClaim",
                loopVariable: "claimsInWindow",
                maxIterations: ProtocolExecutionBounds.MAX_CLAIMS_PER_ACCOUNT_WINDOW,
                mitigation: "AntiGriefing per-account sliding window (V2-SC-105)"
            });
        }
        if (index == 13) {
            return LoopBound({
                module: "ClaimRegistry",
                functionName: "createClaim",
                loopVariable: "openClaimCount",
                maxIterations: ProtocolExecutionBounds.MAX_OPEN_CLAIMS_PER_CREATOR,
                mitigation: "Open-claim inventory cap frees on terminal status (V2-SC-105)"
            });
        }
        if (index == 12) {
            return LoopBound({
                module: "V2Lifecycle",
                functionName: "validateParameterSet",
                loopVariable: "supportedAssets.length",
                maxIterations: ProtocolExecutionBounds.MAX_SUPPORTED_ASSETS,
                mitigation: "Hard cap before validation and storage copy"
            });
        }
        if (index == 13) {
            return LoopBound({
                module: "EvidenceRegistry",
                functionName: "commitEvidence",
                loopVariable: "claimEvidenceIds[claimId].length",
                maxIterations: ProtocolExecutionBounds.MAX_EVIDENCE_PER_CLAIM,
                mitigation: "Hard cap with paginated claimEvidence reads"
            });
        }
        revert("IndexOutOfBounds");
    }
}
