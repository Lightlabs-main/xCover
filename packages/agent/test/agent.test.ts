import { strict as assert } from "node:assert";
import { test } from "node:test";
import { recoverTypedDataAddress } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { canonicalJson, hashCanonicalJson } from "../src/canonical.js";
import { assertDeploymentPair, ConfigError } from "../src/config.js";
import { makeDecision, __test as decisionTest } from "../src/decision.js";
import type { AgentConfig, Assessment, ChainState, DeploymentRecord, Evidence } from "../src/types.js";

const asset = "0x1111111111111111111111111111111111111111" as const;
const registry = "0x2222222222222222222222222222222222222222" as const;
const venue = "0x3333333333333333333333333333333333333333" as const;
const privateKey = "0x0000000000000000000000000000000000000000000000000000000000000001" as const;

function deployment(environment: "testnet" | "mainnet"): DeploymentRecord {
  return {
    asset,
    chainId: environment === "testnet" ? 1952 : 196,
    coverPool: "0x4444444444444444444444444444444444444444",
    pricingRegistry: registry,
    venue,
    venueName: environment === "testnet" ? "custody-only/xlayer-testnet" : "aave-v3/xlayer-mainnet",
    hasYieldSource: environment === "mainnet",
  };
}

function config(overrides: Partial<AgentConfig> = {}): AgentConfig {
  return {
    environment: "testnet",
    chainId: 1952,
    rpcUrl: "https://example.invalid",
    deployment: deployment("testnet"),
    pricerPrivateKey: privateKey,
    engineVersion: "pricing-test/xlayer-usdt",
    quoteValidityBlocks: 20n,
    corpusPath: "unused",
    decisionStorePath: "unused",
    anthropicApiKey: "test-key",
    anthropicModel: "test-model",
    pricing: {
      confidenceThresholdBps: 7_000n,
      maxEnsembleDisagreementBps: 500n,
      maxUncertaintyLoadingBps: 2_000n,
      capitalCostMarginBps: 100n,
      oracleMaxAgeSeconds: 3_600n,
      oracleMaxDeviationBps: 100n,
      depegLowerBound8dp: 97_000_000n,
      maxPremiumRateRay: 10n ** 27n,
    },
    ...overrides,
  };
}

function state(overrides: Partial<ChainState> = {}): ChainState {
  return {
    chainId: 1952n,
    blockNumber: 100n,
    blockTimestamp: 1_000n,
    reserve: asset,
    assetDecimals: 6n,
    totalAssetSupply: 10_000_000n,
    venueName: "custody-only/xlayer-testnet",
    hasYieldSource: false,
    venueTotalAssets: 1_000_000n,
    reserveDeficit: 0n,
    oraclePrice: 100_000_000n,
    redeemableLiquidity: 1_000_000n,
    totalSupplied: 1_000_000n,
    utilizationBps: null,
    totalBorrows: null,
    reserveConfiguration: null,
    oracleFeed: null,
    poolCapital: 1_000_000n,
    poolOutstandingCover: 0n,
    missingFacts: [],
    ...overrides,
  };
}

function evidence(): Array<Evidence & { text: string }> {
  return [{
    id: "incident-1",
    title: "Aave V3 reserve incident review",
    sourceUrl: "https://example.com/incident-1",
    publishedAt: "2026-01-01",
    protocol: "Aave V3",
    outcome: "resolved",
    excerpt: "A documented protocol event and its outcome.",
    text: "A documented protocol event and its outcome.",
  }];
}

function assessment(framing: string): Assessment {
  return {
    framing,
    baseHazardPpmPerBlock: 100n,
    uncertaintyLoadingBps: 100n,
    confidenceBps: 9_000n,
    hazardFactors: [{ name: "history", severityBps: 100n, rationale: "documented", evidenceIds: ["incident-1"] }],
    concerns: [],
    missingFacts: [],
    conclusions: [{ text: "The evidence is bounded.", evidenceIds: ["incident-1"] }],
    model: "test-model",
  };
}

test("canonical JSON is stable and independently hashable", () => {
  const first = { z: "last", a: "first", nested: { b: true, a: null } };
  const second = { nested: { a: null, b: true }, a: "first", z: "last" };
  assert.equal(canonicalJson(first), canonicalJson(second));
  assert.equal(hashCanonicalJson(first), hashCanonicalJson(second));
});

test("environment pairing rejects the wrong venue before startup", () => {
  assert.throws(
    () => assertDeploymentPair("mainnet", deployment("testnet")),
    (error: unknown) => error instanceof ConfigError,
  );
  assert.doesNotThrow(() => assertDeploymentPair("testnet", deployment("testnet")));
});

test("missing model evidence produces a signed first-class refusal", async () => {
  const refusalConfig = config({ anthropicApiKey: undefined, anthropicModel: undefined });
  const result = await makeDecision(refusalConfig, state(), [], 50_000n, 1n);

  assert.equal(result.document.verdict, "DECLINE_TO_QUOTE");
  assert.equal(result.decision.declined, true);
  assert.equal(result.decision.premiumRateRay, 0n);
  assert.match(result.document.gate.reasons.join(","), /model_credentials_missing/);
  assert.equal(result.decisionHash, hashCanonicalJson(result.document));
  assert.equal(JSON.parse(result.canonicalJson).verdict, "DECLINE_TO_QUOTE");
});

test("a bounded two-pass assessment produces a signed quote", async () => {
  const result = await makeDecision(
    config(),
    state(),
    evidence(),
    50_000n,
    2n,
    async (_key, _model, framing) => assessment(framing),
  );

  assert.equal(result.document.verdict, "QUOTE");
  assert.equal(result.decision.declined, false);
  assert(result.decision.premiumRateRay > 0n);
  assert.equal(result.decisionHash, hashCanonicalJson(result.document));
  const account = privateKeyToAccount(privateKey);
  const recovered = await recoverTypedDataAddress({
    domain: { name: "xCover PricingRegistry", version: "1", chainId: 1952, verifyingContract: registry },
    types: decisionTest.decisionTypes,
    primaryType: "Decision",
    message: result.decision,
    signature: result.signature,
  });
  assert.equal(recovered, account.address);
});

test("a live deficit is a deterministic refusal even with model output", async () => {
  const result = await makeDecision(
    config(),
    state({ reserveDeficit: 1n }),
    evidence(),
    50_000n,
    3n,
    async (_key, _model, framing) => assessment(framing),
  );
  assert.equal(result.document.verdict, "DECLINE_TO_QUOTE");
  assert(result.document.gate.reasons.includes("reserve_deficit_nonzero"));
});
