import type { Address, Hex } from "viem";

export type Environment = "testnet" | "mainnet";

export type DeploymentRecord = {
  asset: Address;
  chainId: number;
  coverPool: Address;
  pricingRegistry: Address;
  venue: Address;
  venueName: string;
  hasYieldSource: boolean;
  [key: string]: unknown;
};

export type AgentConfig = {
  environment: Environment;
  chainId: number;
  rpcUrl: string;
  deployment: DeploymentRecord;
  pricerPrivateKey: Hex;
  engineVersion: string;
  quoteValidityBlocks: bigint;
  corpusPath: string;
  decisionStorePath: string;
  anthropicApiKey?: string;
  anthropicModel?: string;
  pricing: {
    confidenceThresholdBps: bigint;
    maxEnsembleDisagreementBps: bigint;
    maxUncertaintyLoadingBps: bigint;
    capitalCostMarginBps: bigint;
    oracleMaxAgeSeconds: bigint;
    oracleMaxDeviationBps: bigint;
    depegLowerBound8dp: bigint;
    maxPremiumRateRay: bigint;
  };
};

export type ChainState = {
  chainId: bigint;
  blockNumber: bigint;
  blockTimestamp: bigint;
  reserve: Address;
  assetDecimals: bigint;
  totalAssetSupply: bigint;
  venueName: string;
  hasYieldSource: boolean;
  venueTotalAssets: bigint;
  reserveDeficit: bigint;
  oraclePrice: bigint;
  redeemableLiquidity: bigint;
  totalSupplied: bigint;
  utilizationBps: bigint | null;
  totalBorrows: bigint | null;
  reserveConfiguration: {
    decimals: bigint;
    reserveFactorBps: bigint;
    ltvBps: bigint;
    liquidationThresholdBps: bigint;
    isActive: boolean;
    isFrozen: boolean;
    isPaused: boolean;
  } | null;
  oracleFeed: {
    answer: bigint;
    updatedAt: bigint;
    answeredInRound: bigint;
  } | null;
  poolCapital: bigint;
  poolOutstandingCover: bigint;
  missingFacts: string[];
};

export type Evidence = {
  id: string;
  title: string;
  sourceUrl: string;
  publishedAt: string;
  protocol: string;
  outcome: string;
  excerpt: string;
};

export type Assessment = {
  framing: string;
  baseHazardPpmPerBlock: bigint;
  uncertaintyLoadingBps: bigint;
  confidenceBps: bigint;
  hazardFactors: Array<{
    name: string;
    severityBps: bigint;
    rationale: string;
    evidenceIds: string[];
  }>;
  concerns: string[];
  missingFacts: string[];
  conclusions: Array<{
    text: string;
    evidenceIds: string[];
  }>;
  model: string;
};

export type Computation = {
  baseHazardPpmPerBlock: bigint;
  utilizationMultiplierBps: bigint;
  concentrationMultiplierBps: bigint;
  uncertaintyMultiplierBps: bigint;
  capitalCostMultiplierBps: bigint;
  premiumRateRay: bigint;
};

export type GateResult = {
  verdict: "QUOTE" | "DECLINE_TO_QUOTE";
  reasons: string[];
  confidenceBps: bigint;
  thresholdBps: bigint;
  ensembleDisagreementBps: bigint | null;
};

export type DecisionDocument = {
  schema: "xcover.pricing-decision.v1";
  engineVersion: string;
  request: {
    reserve: Address;
    coverAmount: string;
    nonce: string;
  };
  chain: {
    chainId: string;
    blockNumber: string;
    blockTimestamp: string;
    venueName: string;
    hasYieldSource: boolean;
  };
  inputs: {
    chainState: unknown;
    evidence: Evidence[];
  };
  assessments: {
    passA: AssessmentDocument | null;
    passB: AssessmentDocument | null;
    disagreementBps: string | null;
  };
  computation: ComputationDocument;
  gate: {
    verdict: GateResult["verdict"];
    reasons: string[];
    confidenceBps: string;
    thresholdBps: string;
    ensembleDisagreementBps: string | null;
  };
  verdict: GateResult["verdict"];
  declineReason: string | null;
};

export type AssessmentDocument = {
  framing: string;
  baseHazardPpmPerBlock: string;
  uncertaintyLoadingBps: string;
  confidenceBps: string;
  hazardFactors: Array<{
    name: string;
    severityBps: string;
    rationale: string;
    evidenceIds: string[];
  }>;
  concerns: string[];
  missingFacts: string[];
  conclusions: Array<{
    text: string;
    evidenceIds: string[];
  }>;
  model: string;
};

export type ComputationDocument = {
  baseHazardPpmPerBlock: string;
  utilizationMultiplierBps: string;
  concentrationMultiplierBps: string;
  uncertaintyMultiplierBps: string;
  capitalCostMultiplierBps: string;
  premiumRateRay: string;
};

export type SignedDecision = {
  quoteHash: Hex;
  decisionHash: Hex;
  decision: {
    reserve: Address;
    coverAmount: bigint;
    premiumRateRay: bigint;
    validUntilBlock: bigint;
    declined: boolean;
    decisionHash: Hex;
    engineVersion: string;
    nonce: bigint;
  };
  signature: Hex;
  canonicalJson: string;
  document: DecisionDocument;
};
