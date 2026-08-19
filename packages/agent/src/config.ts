import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { getAddress, isAddress, type Address, type Hex } from "viem";
import type { AgentConfig, DeploymentRecord, Environment, ModelProvider } from "./types.js";

export class ConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ConfigError";
  }
}

const CHAIN_IDS: Record<Environment, number> = {
  testnet: 1952,
  mainnet: 196,
};

function required(env: NodeJS.ProcessEnv, name: string): string {
  const value = env[name]?.trim();
  if (!value) throw new ConfigError(`missing required environment variable ${name}`);
  return value;
}

function parseBigInt(env: NodeJS.ProcessEnv, name: string): bigint {
  const value = required(env, name);
  try {
    const parsed = BigInt(value);
    if (parsed < 0n) throw new Error("negative");
    return parsed;
  } catch {
    throw new ConfigError(`${name} must be a non-negative integer`);
  }
}

function parseAddress(value: string, name: string): Address {
  if (!isAddress(value)) throw new ConfigError(`${name} must be an EVM address`);
  return getAddress(value);
}

function parsePrivateKey(value: string): Hex {
  if (!/^0x[0-9a-fA-F]{64}$/.test(value)) {
    throw new ConfigError("PRICER_PRIVATE_KEY must be a 32-byte hex private key");
  }
  return value as Hex;
}

export function assertDeploymentPair(
  environment: Environment,
  deployment: DeploymentRecord,
): void {
  const expectedChainId = CHAIN_IDS[environment];
  if (deployment.chainId !== expectedChainId) {
    throw new ConfigError(
      `deployment chain ${deployment.chainId} does not match ${environment} (${expectedChainId})`,
    );
  }

  const expectedVenue = environment === "testnet" ? "custody-only/xlayer-testnet" : "aave-v3/xlayer-mainnet";
  const expectedYieldSource = environment === "mainnet";
  if (deployment.venueName !== expectedVenue || deployment.hasYieldSource !== expectedYieldSource) {
    throw new ConfigError(
      `deployment venue ${deployment.venueName}/${deployment.hasYieldSource} does not match ${environment}`,
    );
  }
}

function loadDeployment(rootDir: string, environment: Environment): DeploymentRecord {
  const file = resolve(rootDir, "deployments", `xlayer-${environment}.json`);
  if (!existsSync(file)) {
    throw new ConfigError(`deployment record is missing: ${file}`);
  }

  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(readFileSync(file, "utf8")) as Record<string, unknown>;
  } catch (error) {
    throw new ConfigError(`cannot parse deployment record ${file}: ${String(error)}`);
  }

  const deployment: DeploymentRecord = {
    ...parsed,
    asset: parseAddress(String(parsed.asset ?? ""), "deployment.asset"),
    chainId: Number(parsed.chainId),
    coverPool: parseAddress(String(parsed.coverPool ?? ""), "deployment.coverPool"),
    pricingRegistry: parseAddress(String(parsed.pricingRegistry ?? ""), "deployment.pricingRegistry"),
    venue: parseAddress(String(parsed.venue ?? ""), "deployment.venue"),
    venueName: String(parsed.venueName ?? ""),
    hasYieldSource: parsed.hasYieldSource === true,
  };

  if (!Number.isSafeInteger(deployment.chainId)) {
    throw new ConfigError("deployment.chainId must be an integer");
  }
  assertDeploymentPair(environment, deployment);
  return deployment;
}

function quoteValidityBlocks(env: NodeJS.ProcessEnv): bigint {
  if (env.QUOTE_TTL_BLOCKS?.trim()) return parseBigInt(env, "QUOTE_TTL_BLOCKS");
  const seconds = parseBigInt(env, "QUOTE_TTL_SECONDS");
  const blockSeconds = parseBigInt(env, "XLAYER_BLOCK_TIME_SECONDS");
  if (blockSeconds === 0n) throw new ConfigError("XLAYER_BLOCK_TIME_SECONDS must be greater than zero");
  const blocks = seconds / blockSeconds;
  if (blocks === 0n) throw new ConfigError("quote TTL must span at least one block");
  return blocks;
}

export function loadConfig(
  env: NodeJS.ProcessEnv = process.env,
  rootDir = workspaceRoot(),
): AgentConfig {
  const rawEnvironment = required(env, "XCOVER_ENVIRONMENT");
  if (rawEnvironment !== "testnet" && rawEnvironment !== "mainnet") {
    throw new ConfigError("XCOVER_ENVIRONMENT must be testnet or mainnet");
  }
  const environment = rawEnvironment as Environment;
  const chainId = CHAIN_IDS[environment];
  const rpcUrl = required(env, environment === "testnet" ? "XLAYER_TESTNET_RPC" : "XLAYER_MAINNET_RPC");
  const deployment = loadDeployment(rootDir, environment);

  const rawProvider = required(env, "PRICING_MODEL_PROVIDER");
  if (rawProvider !== "anthropic" && rawProvider !== "gemini") {
    throw new ConfigError("PRICING_MODEL_PROVIDER must be anthropic or gemini");
  }
  const modelProvider = rawProvider as ModelProvider;

  const confidenceThresholdBps = parseBigInt(env, "PRICING_CONFIDENCE_THRESHOLD_BPS");
  const maxEnsembleDisagreementBps = parseBigInt(env, "PRICING_MAX_ENSEMBLE_DISAGREEMENT_BPS");
  const maxUncertaintyLoadingBps = parseBigInt(env, "PRICING_MAX_UNCERTAINTY_LOADING_BPS");
  const capitalCostMarginBps = parseBigInt(env, "PRICING_CAPITAL_COST_MARGIN_BPS");
  const oracleMaxAgeSeconds = parseBigInt(env, "PRICING_ORACLE_MAX_AGE_SECONDS");
  const oracleMaxDeviationBps = parseBigInt(env, "PRICING_ORACLE_MAX_DEVIATION_BPS");
  const depegLowerBound8dp = parseBigInt(env, "PRICING_DEPEG_LOWER_BOUND_8DP");
  const maxPremiumRateRay = parseBigInt(env, "PRICING_MAX_PREMIUM_RATE_RAY");
  for (const [name, value] of [
    ["PRICING_CONFIDENCE_THRESHOLD_BPS", confidenceThresholdBps],
    ["PRICING_MAX_ENSEMBLE_DISAGREEMENT_BPS", maxEnsembleDisagreementBps],
    ["PRICING_MAX_UNCERTAINTY_LOADING_BPS", maxUncertaintyLoadingBps],
    ["PRICING_CAPITAL_COST_MARGIN_BPS", capitalCostMarginBps],
    ["PRICING_ORACLE_MAX_DEVIATION_BPS", oracleMaxDeviationBps],
  ] as const) {
    if (value > 10_000n) throw new ConfigError(`${name} cannot exceed 10000 bp`);
  }
  if (oracleMaxAgeSeconds === 0n) throw new ConfigError("PRICING_ORACLE_MAX_AGE_SECONDS must be greater than zero");
  if (depegLowerBound8dp === 0n || depegLowerBound8dp > 100_000_000n) {
    throw new ConfigError("PRICING_DEPEG_LOWER_BOUND_8DP must be between 1 and 100000000");
  }
  if (maxPremiumRateRay === 0n) throw new ConfigError("PRICING_MAX_PREMIUM_RATE_RAY must be greater than zero");

  const modelApiKey = (modelProvider === "gemini" ? env.GEMINI_API_KEY : env.ANTHROPIC_API_KEY)?.trim() || undefined;
  const modelName = (modelProvider === "gemini" ? env.GEMINI_MODEL : env.ANTHROPIC_MODEL)?.trim() || undefined;
  if (modelApiKey && !modelName) {
    throw new ConfigError(`${modelProvider === "gemini" ? "GEMINI_MODEL" : "ANTHROPIC_MODEL"} is required when the selected API key is set`);
  }

  return {
    environment,
    chainId,
    rpcUrl,
    deployment,
    modelProvider,
    modelApiKey,
    modelName,
    pricerPrivateKey: parsePrivateKey(required(env, "PRICER_PRIVATE_KEY")),
    engineVersion: required(env, "PRICING_ENGINE_VERSION"),
    quoteValidityBlocks: quoteValidityBlocks(env),
    corpusPath: resolve(rootDir, env.PRICING_CORPUS_PATH?.trim() || "bench/data/corpus.jsonl"),
    decisionStorePath: resolve(rootDir, env.PRICING_DECISION_STORE_PATH?.trim() || "data/pricing-decisions"),
    pricing: {
      confidenceThresholdBps,
      maxEnsembleDisagreementBps,
      maxUncertaintyLoadingBps,
      capitalCostMarginBps,
      oracleMaxAgeSeconds,
      oracleMaxDeviationBps,
      depegLowerBound8dp,
      maxPremiumRateRay,
    },
  };
}

function workspaceRoot(): string {
  let candidate = resolve(process.cwd());
  while (true) {
    if (existsSync(resolve(candidate, "deployments"))) return candidate;
    const parent = dirname(candidate);
    if (parent === candidate) return resolve(process.cwd());
    candidate = parent;
  }
}

export function expectedChainId(environment: Environment): number {
  return CHAIN_IDS[environment];
}
