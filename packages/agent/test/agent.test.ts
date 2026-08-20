import { strict as assert } from "node:assert";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { recoverTypedDataAddress } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { assessAnthropic, AssessmentError, LIVE_STATE_EVIDENCE_ID, __test as assessTest } from "../src/assess.js";
import { canonicalJson, hashCanonicalJson } from "../src/canonical.js";
import { loadCorpus } from "../src/evidence.js";
import { assessGemini } from "../src/gemini.js";
import { assessRouter } from "../src/router.js";
import { assessmentRunnerFor } from "../src/model.js";
import { MemoryDecisionStore } from "../src/store.js";
import { assertDeploymentPair, ConfigError, loadConfig } from "../src/config.js";
import { __test as chainTest } from "../src/chain.js";
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
    mode: "pricing",
    environment: "testnet",
    chainId: 1952,
    rpcUrl: "https://example.invalid",
    deployment: deployment("testnet"),
    modelProvider: "anthropic",
    modelApiKey: "test-key",
    modelName: "test-model",
    pricerPrivateKey: privateKey,
    engineVersion: "pricing-test/xlayer-usdt",
    quoteValidityBlocks: 20n,
    corpusPath: "unused",
    decisionStorePath: "unused",
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

test("provider selection routes Anthropic, Gemini, and Alibaba explicitly", () => {
  assert.equal(assessmentRunnerFor("anthropic"), assessAnthropic);
  assert.equal(assessmentRunnerFor("gemini"), assessGemini);
  assert.equal(assessmentRunnerFor("alibaba"), assessRouter);
});

test("Aave data provider ABI matches the live twelve-field reserve tuple", () => {
  const reserveData = chainTest.dataProviderAbi.find((item) => item.name === "getReserveData");
  assert(reserveData);
  assert.deepEqual(
    reserveData.outputs?.map((output) => output.type),
    ["uint256", "uint256", "uint256", "uint256", "uint256", "uint256", "uint256", "uint256", "uint256", "uint256", "uint256", "uint40"],
  );
  const reserveConfiguration = chainTest.dataProviderAbi.find((item) => item.name === "getReserveConfigurationData");
  assert(reserveConfiguration);
  assert.deepEqual(
    reserveConfiguration.outputs?.map((output) => output.type),
    ["uint256", "uint256", "uint256", "uint256", "uint256", "bool", "bool", "bool", "bool", "bool"],
  );
});

test("configuration selects Gemini credentials without reading Anthropic credentials", () => {
  const root = mkdtempSync(join(tmpdir(), "xcover-config-"));
  mkdirSync(join(root, "deployments"));
  writeFileSync(join(root, "deployments", "xlayer-testnet.json"), JSON.stringify(deployment("testnet")));
  const loaded = loadConfig({
    PRICING_MODE: "pricing",
    XCOVER_ENVIRONMENT: "testnet",
    XLAYER_TESTNET_RPC: "https://example.invalid",
    PRICING_MODEL_PROVIDER: "gemini",
    GEMINI_API_KEY: "gemini-key",
    GEMINI_MODEL: "gemini-test-model",
    PRICER_PRIVATE_KEY: privateKey,
    PRICING_ENGINE_VERSION: "pricing-test/xlayer-usdt",
    PRICING_CONFIDENCE_THRESHOLD_BPS: "7000",
    PRICING_MAX_ENSEMBLE_DISAGREEMENT_BPS: "500",
    PRICING_MAX_UNCERTAINTY_LOADING_BPS: "2000",
    PRICING_CAPITAL_COST_MARGIN_BPS: "100",
    PRICING_ORACLE_MAX_AGE_SECONDS: "3600",
    PRICING_ORACLE_MAX_DEVIATION_BPS: "100",
    PRICING_DEPEG_LOWER_BOUND_8DP: "97000000",
    PRICING_MAX_PREMIUM_RATE_RAY: "1000000000000000000000000000",
    QUOTE_TTL_BLOCKS: "20",
  }, root);
  assert.equal(loaded.modelProvider, "gemini");
  assert.equal(loaded.modelApiKey, "gemini-key");
  assert.equal(loaded.modelName, "gemini-test-model");
});

test("calibration-in-progress configuration starts without model or pricing controls", () => {
  const root = mkdtempSync(join(tmpdir(), "xcover-calibration-config-"));
  mkdirSync(join(root, "deployments"));
  writeFileSync(join(root, "deployments", "xlayer-mainnet.json"), JSON.stringify(deployment("mainnet")));
  const loaded = loadConfig({
    PRICING_MODE: "calibration_in_progress",
    XCOVER_ENVIRONMENT: "mainnet",
    XLAYER_MAINNET_RPC: "https://example.invalid",
    PRICER_PRIVATE_KEY: privateKey,
  }, root);
  assert.equal(loaded.mode, "calibration_in_progress");
  assert.equal(loaded.modelApiKey, undefined);
  assert.equal(loaded.quoteValidityBlocks, 1n);
});

test("missing model evidence produces a signed first-class refusal", async () => {
  const refusalConfig = config({ modelApiKey: undefined, modelName: undefined });
  const result = await makeDecision(refusalConfig, state(), [], 50_000n, 1n);

  assert.equal(result.document.verdict, "DECLINE_TO_QUOTE");
  assert.equal(result.decision.declined, true);
  assert.equal(result.decision.premiumRateRay, 0n);
  assert.match(result.document.gate.reasons.join(","), /model_credentials_missing/);
  assert.equal(result.decisionHash, hashCanonicalJson(result.document));
  assert.equal(JSON.parse(result.canonicalJson).verdict, "DECLINE_TO_QUOTE");
});

test("calibration-in-progress mode signs a refusal without calling a model", async () => {
  const result = await makeDecision(
    config({ mode: "calibration_in_progress", modelApiKey: undefined, modelName: undefined }),
    state(),
    [],
    50_000n,
    9n,
    async () => { throw new Error("model must not be called in calibration mode"); },
  );

  assert.equal(result.document.mode, "calibration_in_progress");
  assert.deepEqual(result.document.calibration, { status: "in_progress", thresholdDerived: false });
  assert.equal(result.document.declineReason, "calibration_in_progress");
  assert.equal(result.document.gate.reasons[0], "calibration_in_progress");
  assert.equal(result.decision.declined, true);
  assert.equal(result.decision.premiumRateRay, 0n);
  assert.equal(result.decisionHash, hashCanonicalJson(result.document));
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

test("an assessment may cite live chain state but not an invented source", () => {
  const raw = {
    baseHazardPpmPerBlock: 10,
    uncertaintyLoadingBps: 100,
    confidenceBps: 9_000,
    hazardFactors: [{ name: "deficit", severityBps: 100, rationale: "read at the block", evidenceIds: [LIVE_STATE_EVIDENCE_ID] }],
    concerns: [],
    missingFacts: [],
    conclusions: [{ text: "Bounded.", evidenceIds: ["incident-1"] }],
  };
  const parsed = assessTest.parseResponse(raw, "framing", "test-model", evidence());
  assert.deepEqual(parsed.hazardFactors[0].evidenceIds, [LIVE_STATE_EVIDENCE_ID]);

  assert.throws(
    () => assessTest.parseResponse(
      { ...raw, hazardFactors: [{ ...raw.hazardFactors[0], evidenceIds: ["a-source-that-was-not-supplied"] }] },
      "framing",
      "test-model",
      evidence(),
    ),
    (error: unknown) => error instanceof AssessmentError,
  );
});

test("Gemini-shaped decimal-string output passes the common assessment validator", () => {
  const parsed = assessTest.parseResponse({
    baseHazardPpmPerBlock: "10",
    uncertaintyLoadingBps: "100",
    confidenceBps: "9000",
    hazardFactors: [{ name: "deficit", severityBps: "100", rationale: "read at the block", evidenceIds: [LIVE_STATE_EVIDENCE_ID] }],
    concerns: [],
    missingFacts: [],
    conclusions: [{ text: "Bounded.", evidenceIds: [LIVE_STATE_EVIDENCE_ID] }],
  }, "framing", "gemini-2.5-flash-lite", []);
  assert.equal(parsed.baseHazardPpmPerBlock, 10n);
  assert.equal(parsed.confidenceBps, 9_000n);
});

test("the prompt names every permitted evidence id", () => {
  const prompt = assessTest.promptFor("framing", state(), evidence());
  assert.match(prompt, /incident-1/);
  assert.match(prompt, new RegExp(LIVE_STATE_EVIDENCE_ID));
});

test("the corpus cannot claim the reserved live-state id", () => {
  const file = join(mkdtempSync(join(tmpdir(), "xcover-corpus-")), "corpus.jsonl");
  const row = {
    id: LIVE_STATE_EVIDENCE_ID,
    title: "t",
    sourceUrl: "https://example.com/a",
    publishedAt: "2026-01-01",
    protocol: "Aave V3",
    outcome: "resolved",
    text: "body",
  };
  writeFileSync(file, `${JSON.stringify(row)}\n`);
  assert.throws(() => loadCorpus(file), /reserved id/);
  writeFileSync(file, `${JSON.stringify({ ...row, id: "incident-2" })}\n`);
  assert.equal(loadCorpus(file).length, 1);
});

test("a decision document is replayable by a hash in any case", async () => {
  const store = new MemoryDecisionStore();
  const result = await makeDecision(config(), state(), [], 50_000n, 4n);
  await store.put(result.decisionHash, result.canonicalJson);
  const upper = `0x${result.decisionHash.slice(2).toUpperCase()}` as `0x${string}`;
  assert.equal(await store.get(upper), result.canonicalJson);
});

// Each gate condition below is a distinct reason a deposit does not receive cover, and the user
// is owed the actual one. A single "declined" assertion cannot tell them apart.
const quoting = async (
  stateOverrides: Partial<ChainState> = {},
  configOverrides: Partial<AgentConfig> = {},
  assessments: (framing: string) => Assessment = assessment,
) =>
  (await makeDecision(
    config(configOverrides),
    state(stateOverrides),
    evidence(),
    50_000n,
    5n,
    async (_key, _model, framing) => assessments(framing),
  )).document;

test("the gate quotes only when every condition holds, and names the one that fails", async () => {
  assert.equal((await quoting()).verdict, "QUOTE");

  const cases: Array<[string, Awaited<ReturnType<typeof quoting>>]> = [
    ["pool_capacity_insufficient", await quoting({ poolCapital: 1n })],
    ["reserve_has_no_supply", await quoting({ totalSupplied: 0n })],
    ["oracle_price_zero", await quoting({ oraclePrice: 0n })],
    ["oracle_depeg", await quoting({ oraclePrice: 96_000_000n })],
    ["utilization_above_100pct", await quoting({ utilizationBps: 10_001n })],
    ["reserve_not_active", await quoting({
      reserveConfiguration: { decimals: 6n, reserveFactorBps: 1_000n, ltvBps: 7_500n, liquidationThresholdBps: 7_800n, isActive: false, isFrozen: false },
    })],
    ["oracle_stale", await quoting({
      blockTimestamp: 100_000n,
      oracleFeed: { answer: 100_000_000n, updatedAt: 1_000n, answeredInRound: 1n },
    })],
    ["oracle_sources_disagree", await quoting({
      oracleFeed: { answer: 150_000_000n, updatedAt: 1_000n, answeredInRound: 1n },
    })],
    ["missing_chain_fact:aave.utilisation denominator is zero", await quoting({ missingFacts: ["aave.utilisation denominator is zero"] })],
    ["confidence_below_threshold", await quoting({}, {}, (framing) => ({ ...assessment(framing), confidenceBps: 100n }))],
    ["uncertainty_loading_above_bound", await quoting({}, {}, (framing) => ({ ...assessment(framing), uncertaintyLoadingBps: 9_000n }))],
    ["model_missing_fact:the loss history for this venue", await quoting({}, {}, (framing) => ({ ...assessment(framing), missingFacts: ["the loss history for this venue"] }))],
    ["premium_rate_above_bound", await quoting({}, { pricing: { ...config().pricing, maxPremiumRateRay: 1n } })],
    ["computed_rate_zero", await quoting({}, {}, (framing) => ({ ...assessment(framing), baseHazardPpmPerBlock: 0n }))],
  ];

  for (const [reason, document] of cases) {
    assert.equal(document.verdict, "DECLINE_TO_QUOTE", `${reason} should refuse`);
    assert(document.gate.reasons.includes(reason), `expected reason ${reason}, got ${document.gate.reasons.join(",")}`);
    assert.equal(document.declineReason !== null, true);
  }
});

test("the framings are allowed to disagree, and a disagreement past the bound refuses", async () => {
  const divergent = (framing: string): Assessment =>
    framing.startsWith("Analyse")
      ? assessment(framing)
      : { ...assessment(framing), baseHazardPpmPerBlock: 5_000n };
  const document = await quoting({}, {}, divergent);
  assert.equal(document.verdict, "DECLINE_TO_QUOTE");
  assert(document.gate.reasons.includes("ensemble_disagreement_above_bound"));
  assert.equal(document.assessments.disagreementBps, "4900");

  // Inside the bound the same disagreement is priced, not refused.
  const narrow = await quoting({}, { pricing: { ...config().pricing, maxEnsembleDisagreementBps: 10_000n } }, divergent);
  assert.equal(narrow.verdict, "QUOTE");
});
