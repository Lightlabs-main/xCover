import { randomBytes } from "node:crypto";
import {
  hashTypedData,
  keccak256,
  stringToHex,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { assess } from "./assess.js";
import { canonicalJson, hashCanonicalJson } from "./canonical.js";
import { retrieveEvidence, type CorpusEntry } from "./evidence.js";
import type {
  AgentConfig,
  Assessment,
  AssessmentDocument,
  ChainState,
  Computation,
  ComputationDocument,
  DecisionDocument,
  GateResult,
  SignedDecision,
} from "./types.js";

export type AssessmentRunner = (
  apiKey: string,
  model: string,
  framing: string,
  state: ChainState,
  evidence: import("./types.js").Evidence[],
) => Promise<Assessment>;

const RAY = 1_000_000_000_000_000_000_000_000_000n;
const BPS = 10_000n;

function absDifference(a: bigint, b: bigint): bigint {
  return a >= b ? a - b : b - a;
}

function asDocumentAssessment(value: Assessment): AssessmentDocument {
  return {
    framing: value.framing,
    baseHazardPpmPerBlock: value.baseHazardPpmPerBlock.toString(),
    uncertaintyLoadingBps: value.uncertaintyLoadingBps.toString(),
    confidenceBps: value.confidenceBps.toString(),
    hazardFactors: value.hazardFactors.map((factor) => ({
      name: factor.name,
      severityBps: factor.severityBps.toString(),
      rationale: factor.rationale,
      evidenceIds: factor.evidenceIds,
    })),
    concerns: value.concerns,
    missingFacts: value.missingFacts,
    conclusions: value.conclusions,
    model: value.model,
  };
}

function stateDocument(state: ChainState): Record<string, unknown> {
  return {
    chainId: state.chainId.toString(),
    blockNumber: state.blockNumber.toString(),
    blockTimestamp: state.blockTimestamp.toString(),
    reserve: state.reserve,
    assetDecimals: state.assetDecimals.toString(),
    totalAssetSupply: state.totalAssetSupply.toString(),
    venueName: state.venueName,
    hasYieldSource: state.hasYieldSource,
    venueTotalAssets: state.venueTotalAssets.toString(),
    reserveDeficit: state.reserveDeficit.toString(),
    oraclePrice: state.oraclePrice.toString(),
    redeemableLiquidity: state.redeemableLiquidity.toString(),
    totalSupplied: state.totalSupplied.toString(),
    utilizationBps: state.utilizationBps?.toString() ?? null,
    totalBorrows: state.totalBorrows?.toString() ?? null,
    reserveConfiguration: state.reserveConfiguration
      ? {
          decimals: state.reserveConfiguration.decimals.toString(),
          reserveFactorBps: state.reserveConfiguration.reserveFactorBps.toString(),
          ltvBps: state.reserveConfiguration.ltvBps.toString(),
          liquidationThresholdBps: state.reserveConfiguration.liquidationThresholdBps.toString(),
          isActive: state.reserveConfiguration.isActive,
          isFrozen: state.reserveConfiguration.isFrozen,
          isPaused: state.reserveConfiguration.isPaused,
        }
      : null,
    oracleFeed: state.oracleFeed
      ? {
          answer: state.oracleFeed.answer.toString(),
          updatedAt: state.oracleFeed.updatedAt.toString(),
          answeredInRound: state.oracleFeed.answeredInRound.toString(),
        }
      : null,
    poolCapital: state.poolCapital.toString(),
    poolOutstandingCover: state.poolOutstandingCover.toString(),
    missingFacts: state.missingFacts,
  };
}

function compute(
  state: ChainState,
  config: AgentConfig,
  assessments: [Assessment, Assessment] | null,
  coverAmount: bigint,
): { computation: Computation; disagreementBps: bigint | null; confidenceBps: bigint } {
  if (!assessments) {
    return {
      computation: {
        baseHazardPpmPerBlock: 0n,
        utilizationMultiplierBps: BPS,
        concentrationMultiplierBps: BPS,
        uncertaintyMultiplierBps: BPS,
        capitalCostMultiplierBps: BPS + config.pricing.capitalCostMarginBps,
        premiumRateRay: 0n,
      },
      disagreementBps: null,
      confidenceBps: 0n,
    };
  }

  const [first, second] = assessments;
  const baseHazardPpmPerBlock = (first.baseHazardPpmPerBlock + second.baseHazardPpmPerBlock) / 2n;
  const uncertaintyLoadingBps = (first.uncertaintyLoadingBps + second.uncertaintyLoadingBps) / 2n;
  const confidenceBps = first.confidenceBps < second.confidenceBps ? first.confidenceBps : second.confidenceBps;
  const disagreementBps = [
    absDifference(first.baseHazardPpmPerBlock, second.baseHazardPpmPerBlock),
    absDifference(first.uncertaintyLoadingBps, second.uncertaintyLoadingBps),
    absDifference(first.confidenceBps, second.confidenceBps),
  ].reduce((largest, value) => (value > largest ? value : largest), 0n);
  const utilizationMultiplierBps = BPS + (state.utilizationBps ?? 0n);
  const concentrationMultiplierBps = state.poolCapital === 0n
    ? 2n * BPS
    : BPS + ((coverAmount * BPS) / state.poolCapital > BPS ? BPS : (coverAmount * BPS) / state.poolCapital);
  const uncertaintyMultiplierBps = BPS + uncertaintyLoadingBps;
  const capitalCostMultiplierBps = BPS + config.pricing.capitalCostMarginBps;
  const premiumRateRay =
    (baseHazardPpmPerBlock * RAY * utilizationMultiplierBps * concentrationMultiplierBps * uncertaintyMultiplierBps * capitalCostMultiplierBps) /
    (1_000_000n * BPS ** 4n);

  return {
    computation: {
      baseHazardPpmPerBlock,
      utilizationMultiplierBps,
      concentrationMultiplierBps,
      uncertaintyMultiplierBps,
      capitalCostMultiplierBps,
      premiumRateRay,
    },
    disagreementBps,
    confidenceBps,
  };
}

function gate(
  state: ChainState,
  config: AgentConfig,
  assessments: [Assessment, Assessment] | null,
  computation: Computation,
  disagreementBps: bigint | null,
  confidenceBps: bigint,
  assessmentFailure: string | null,
  evidenceEmpty: boolean,
  coverAmount: bigint,
): GateResult {
  const reasons: string[] = [];
  reasons.push(...state.missingFacts.map((fact) => `missing_chain_fact:${fact}`));
  if (evidenceEmpty) reasons.push("evidence_corpus_empty");
  if (assessmentFailure) reasons.push(assessmentFailure);
  if (!assessments) reasons.push("model_assessment_unavailable");
  if (assessments) {
    const missing = [...new Set(assessments.flatMap((item) => item.missingFacts))];
    reasons.push(...missing.map((fact) => `model_missing_fact:${fact}`));
  }
  if (state.reserveDeficit > 0n) reasons.push("reserve_deficit_nonzero");
  if (state.totalSupplied === 0n) reasons.push("reserve_has_no_supply");
  if (state.utilizationBps !== null && state.utilizationBps > BPS) reasons.push("utilization_above_100pct");
  if (state.poolCapital < state.poolOutstandingCover + coverAmount) reasons.push("pool_capacity_insufficient");
  if (state.reserveConfiguration && (!state.reserveConfiguration.isActive || state.reserveConfiguration.isFrozen || state.reserveConfiguration.isPaused)) {
    reasons.push("reserve_not_active");
  }
  if (state.oraclePrice === 0n) reasons.push("oracle_price_zero");
  if (state.oracleFeed) {
    if (state.oracleFeed.answer <= 0n) reasons.push("oracle_feed_nonpositive");
    if (state.oracleFeed.updatedAt > state.blockTimestamp) reasons.push("oracle_timestamp_in_future");
    else if (state.blockTimestamp - state.oracleFeed.updatedAt > config.pricing.oracleMaxAgeSeconds) reasons.push("oracle_stale");
    if (state.oracleFeed.answer > 0n) {
      const deviation = absDifference(state.oraclePrice, state.oracleFeed.answer) * BPS / state.oracleFeed.answer;
      if (deviation > config.pricing.oracleMaxDeviationBps) reasons.push("oracle_sources_disagree");
    }
  }
  if (state.oraclePrice < config.pricing.depegLowerBound8dp) reasons.push("oracle_depeg");
  if (assessments && disagreementBps !== null && disagreementBps > config.pricing.maxEnsembleDisagreementBps) {
    reasons.push("ensemble_disagreement_above_bound");
  }
  if (confidenceBps < config.pricing.confidenceThresholdBps) reasons.push("confidence_below_threshold");
  if (assessments && assessments.some((item) => item.uncertaintyLoadingBps > config.pricing.maxUncertaintyLoadingBps)) {
    reasons.push("uncertainty_loading_above_bound");
  }
  if (computation.premiumRateRay > config.pricing.maxPremiumRateRay) reasons.push("premium_rate_above_bound");
  if (computation.premiumRateRay === 0n && reasons.length === 0) reasons.push("computed_rate_zero");

  return {
    verdict: reasons.length === 0 ? "QUOTE" : "DECLINE_TO_QUOTE",
    reasons: [...new Set(reasons)],
    confidenceBps,
    thresholdBps: config.pricing.confidenceThresholdBps,
    ensembleDisagreementBps: disagreementBps,
  };
}

function computationDocument(value: Computation): ComputationDocument {
  return {
    baseHazardPpmPerBlock: value.baseHazardPpmPerBlock.toString(),
    utilizationMultiplierBps: value.utilizationMultiplierBps.toString(),
    concentrationMultiplierBps: value.concentrationMultiplierBps.toString(),
    uncertaintyMultiplierBps: value.uncertaintyMultiplierBps.toString(),
    capitalCostMultiplierBps: value.capitalCostMultiplierBps.toString(),
    premiumRateRay: value.premiumRateRay.toString(),
  };
}

const decisionTypes = {
  Decision: [
    { name: "reserve", type: "address" },
    { name: "coverAmount", type: "uint256" },
    { name: "premiumRateRay", type: "uint256" },
    { name: "validUntilBlock", type: "uint64" },
    { name: "declined", type: "bool" },
    { name: "decisionHash", type: "bytes32" },
    { name: "engineVersion", type: "string" },
    { name: "nonce", type: "uint256" },
  ],
} as const;

export async function makeDecision(
  config: AgentConfig,
  state: ChainState,
  corpus: CorpusEntry[],
  coverAmount: bigint,
  nonce = BigInt(`0x${randomBytes(16).toString("hex")}`),
  assessmentRunner: AssessmentRunner = assess,
): Promise<SignedDecision> {
  if (coverAmount <= 0n) throw new Error("cover amount must be greater than zero");
  const evidence = retrieveEvidence(corpus, state);
  let assessments: [Assessment, Assessment] | null = null;
  let assessmentFailure: string | null = null;
  if (!config.anthropicApiKey) {
    assessmentFailure = "model_credentials_missing";
  } else if (!config.anthropicModel) {
    assessmentFailure = "model_configuration_missing";
  } else if (evidence.length === 0) {
    assessmentFailure = null;
  } else {
    const results = await Promise.allSettled([
      assessmentRunner(config.anthropicApiKey, config.anthropicModel, "Analyse historical hazard first; be conservative about extrapolating across deployments.", state, evidence),
      assessmentRunner(config.anthropicApiKey, config.anthropicModel, "Stress-test the first framing; search for missing facts and reasons not to commit capital.", state, evidence),
    ]);
    if (results[0].status === "fulfilled" && results[1].status === "fulfilled") {
      assessments = [results[0].value, results[1].value];
    } else {
      assessmentFailure = "model_assessment_failed";
    }
  }

  const { computation, disagreementBps, confidenceBps } = compute(state, config, assessments, coverAmount);
  const gateResult = gate(
    state,
    config,
    assessments,
    computation,
    disagreementBps,
    confidenceBps,
    assessmentFailure,
    evidence.length === 0,
    coverAmount,
  );
  const document: DecisionDocument = {
    schema: "xcover.pricing-decision.v1",
    engineVersion: config.engineVersion,
    request: { reserve: state.reserve, coverAmount: coverAmount.toString(), nonce: nonce.toString() },
    chain: {
      chainId: state.chainId.toString(),
      blockNumber: state.blockNumber.toString(),
      blockTimestamp: state.blockTimestamp.toString(),
      venueName: state.venueName,
      hasYieldSource: state.hasYieldSource,
    },
    inputs: {
      chainState: stateDocument(state),
      evidence,
    },
    assessments: {
      passA: assessments ? asDocumentAssessment(assessments[0]) : null,
      passB: assessments ? asDocumentAssessment(assessments[1]) : null,
      disagreementBps: disagreementBps?.toString() ?? null,
    },
    computation: computationDocument(computation),
    gate: {
      verdict: gateResult.verdict,
      reasons: gateResult.reasons,
      confidenceBps: gateResult.confidenceBps.toString(),
      thresholdBps: gateResult.thresholdBps.toString(),
      ensembleDisagreementBps: gateResult.ensembleDisagreementBps?.toString() ?? null,
    },
    verdict: gateResult.verdict,
    declineReason: gateResult.verdict === "DECLINE_TO_QUOTE" ? gateResult.reasons[0] ?? "gate_refused" : null,
  };
  const canonical = canonicalJson(document);
  const decisionHash = hashCanonicalJson(document);
  const declined = gateResult.verdict === "DECLINE_TO_QUOTE";
  const premiumRateRay = declined ? 0n : computation.premiumRateRay;
  const validUntilBlock = state.blockNumber + config.quoteValidityBlocks;
  const decision = {
    reserve: state.reserve,
    coverAmount,
    premiumRateRay,
    validUntilBlock,
    declined,
    decisionHash,
    engineVersion: config.engineVersion,
    nonce,
  };
  const account = privateKeyToAccount(config.pricerPrivateKey);
  const domain = {
    name: "xCover PricingRegistry",
    version: "1",
    chainId: Number(state.chainId),
    verifyingContract: config.deployment.pricingRegistry,
  } as const;
  const quoteHash = hashTypedData({ domain, types: decisionTypes, primaryType: "Decision", message: decision });
  const signature = await account.signTypedData({ domain, types: decisionTypes, primaryType: "Decision", message: decision });
  if (keccak256(stringToHex(canonical)) !== decisionHash) throw new Error("decision hash changed during signing");
  return { quoteHash, decisionHash, decision, signature, canonicalJson: canonical, document };
}

export const __test = { compute, gate, stateDocument, decisionTypes };
