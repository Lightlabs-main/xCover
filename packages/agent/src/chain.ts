import {
  createPublicClient,
  http,
  type Address,
  type PublicClient,
} from "viem";
import { xLayer, xLayerTestnet } from "viem/chains";
import { ConfigError } from "./config.js";
import type { AgentConfig, ChainState } from "./types.js";

export const MAINNET_AAVE_DATA_PROVIDER = "0x6C505C31714f14e8af2A03633EB2Cdfb4959138F" as Address;
export const MAINNET_USDT_PRICE_FEED = "0x7ec7E5497EAf312FE82F8307D05eb0E5f0f157D3" as Address;

const venueAbi = [
  { type: "function", name: "asset", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "venueName", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
  { type: "function", name: "hasYieldSource", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
  { type: "function", name: "totalAssets", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  {
    type: "function",
    name: "observeReserve",
    stateMutability: "view",
    inputs: [{ name: "reserve", type: "address" }, { name: "aToken", type: "address" }],
    outputs: [
      { name: "deficit", type: "uint256" },
      { name: "price", type: "uint256" },
      { name: "redeemableLiquidity", type: "uint256" },
      { name: "totalSupplied", type: "uint256" },
    ],
  },
] as const;

const erc20Abi = [
  { type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
  { type: "function", name: "totalSupply", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
] as const;

const coverPoolAbi = [
  { type: "function", name: "capital", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "outstandingCover", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
] as const;

const dataProviderAbi = [
  {
    type: "function",
    name: "getReserveData",
    stateMutability: "view",
    inputs: [{ name: "asset", type: "address" }],
    outputs: [
      { name: "unbacked", type: "uint256" },
      { name: "accruedToTreasuryScaled", type: "uint256" },
      { name: "totalAToken", type: "uint256" },
      { name: "totalStableDebt", type: "uint256" },
      { name: "totalVariableDebt", type: "uint256" },
      { name: "liquidityRate", type: "uint256" },
      { name: "variableBorrowRate", type: "uint256" },
      { name: "stableBorrowRate", type: "uint256" },
      { name: "lastUpdateTimestamp", type: "uint40" },
      { name: "id", type: "uint16" },
    ],
  },
  {
    type: "function",
    name: "getReserveConfigurationData",
    stateMutability: "view",
    inputs: [{ name: "asset", type: "address" }],
    outputs: [
      { name: "decimals", type: "uint256" },
      { name: "ltv", type: "uint256" },
      { name: " liquidationThreshold", type: "uint256" },
      { name: "liquidationBonus", type: "uint256" },
      { name: "reserveFactor", type: "uint256" },
      { name: "usageAsCollateralEnabled", type: "bool" },
      { name: "borrowingEnabled", type: "bool" },
      { name: "stableBorrowRateEnabled", type: "bool" },
      { name: "isActive", type: "bool" },
      { name: "isFrozen", type: "bool" },
      { name: "isPaused", type: "bool" },
      { name: "isSiloedBorrowing", type: "bool" },
      { name: "isBorrowableInIsolation", type: "bool" },
      { name: "isFlashloanable", type: "bool" },
    ],
  },
] as const;

const priceFeedAbi = [
  {
    type: "function",
    name: "latestRoundData",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "roundId", type: "uint80" },
      { name: "answer", type: "int256" },
      { name: "startedAt", type: "uint256" },
      { name: "updatedAt", type: "uint256" },
      { name: "answeredInRound", type: "uint80" },
    ],
  },
] as const;

const aaveOracleAbi = [
  {
    type: "function",
    name: "getAssetPrice",
    stateMutability: "view",
    inputs: [{ name: "asset", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
] as const;

type ReadOptions = { blockNumber: bigint };

function asBigInt(value: unknown, label: string): bigint {
  if (typeof value !== "bigint") throw new Error(`${label} was not returned as uint256`);
  return value;
}

export function makePublicClient(config: AgentConfig): PublicClient {
  // The chain descriptor must match the environment. Handing the client a mainnet chain while
  // pointed at the testnet RPC is exactly the pairing mistake §1.2.5 exists to prevent, and it
  // would only be caught later, by the chain-id check in assertLivePairing.
  return createPublicClient({
    chain: config.environment === "mainnet" ? xLayer : xLayerTestnet,
    transport: http(config.rpcUrl),
  });
}

export async function assertLivePairing(client: PublicClient, config: AgentConfig): Promise<void> {
  const chainId = await client.getChainId();
  if (chainId !== config.chainId) {
    throw new ConfigError(`RPC chain ${chainId} does not match ${config.environment} (${config.chainId})`);
  }

  const [venueAsset, venueName, hasYieldSource] = await Promise.all([
    client.readContract({ address: config.deployment.venue, abi: venueAbi, functionName: "asset" }),
    client.readContract({ address: config.deployment.venue, abi: venueAbi, functionName: "venueName" }),
    client.readContract({ address: config.deployment.venue, abi: venueAbi, functionName: "hasYieldSource" }),
  ]);

  if (venueAsset.toLowerCase() !== config.deployment.asset.toLowerCase()) {
    throw new ConfigError(`venue asset ${venueAsset} does not match deployment asset ${config.deployment.asset}`);
  }
  const expectedVenue = config.environment === "testnet" ? "custody-only/xlayer-testnet" : "aave-v3/xlayer-mainnet";
  if (venueName !== expectedVenue || hasYieldSource !== (config.environment === "mainnet")) {
    throw new ConfigError(`live venue ${venueName}/${hasYieldSource} does not match ${config.environment}`);
  }
}

export async function readChainState(
  client: PublicClient,
  config: AgentConfig,
  reserve: Address,
): Promise<ChainState> {
  if (reserve.toLowerCase() !== config.deployment.asset.toLowerCase()) {
    throw new Error(`only the deployed launch asset is supported: ${config.deployment.asset}`);
  }

  const block = await client.getBlock({ blockTag: "latest" });
  if (block.number === null) throw new Error("latest block has no number");
  const options: ReadOptions = { blockNumber: block.number };
  const [assetDecimals, totalAssetSupply, venueName, hasYieldSource, venueTotalAssets, observed, poolCapital, poolOutstandingCover] =
    await Promise.all([
      client.readContract({ address: reserve, abi: erc20Abi, functionName: "decimals", ...options }),
      client.readContract({ address: reserve, abi: erc20Abi, functionName: "totalSupply", ...options }),
      client.readContract({ address: config.deployment.venue, abi: venueAbi, functionName: "venueName", ...options }),
      client.readContract({ address: config.deployment.venue, abi: venueAbi, functionName: "hasYieldSource", ...options }),
      client.readContract({ address: config.deployment.venue, abi: venueAbi, functionName: "totalAssets", ...options }),
      client.readContract({
        address: config.deployment.venue,
        abi: venueAbi,
        functionName: "observeReserve",
        args: [reserve, "0x0000000000000000000000000000000000000000"],
        ...options,
      }),
      client.readContract({ address: config.deployment.coverPool, abi: coverPoolAbi, functionName: "capital", ...options }),
      client.readContract({ address: config.deployment.coverPool, abi: coverPoolAbi, functionName: "outstandingCover", ...options }),
    ]);

  const [reserveDeficit, oraclePrice, redeemableLiquidity, totalSupplied] = observed;
  let utilizationBps: bigint | null = null;
  let totalBorrows: bigint | null = null;
  let reserveConfiguration: ChainState["reserveConfiguration"] = null;
  let oracleFeed: ChainState["oracleFeed"] = null;
  const missingFacts: string[] = [];

  if (config.environment === "mainnet") {
    const [reserveData, reserveConfig, feedData] = await Promise.all([
      client.readContract({ address: MAINNET_AAVE_DATA_PROVIDER, abi: dataProviderAbi, functionName: "getReserveData", args: [reserve], ...options }),
      client.readContract({ address: MAINNET_AAVE_DATA_PROVIDER, abi: dataProviderAbi, functionName: "getReserveConfigurationData", args: [reserve], ...options }),
      client.readContract({ address: MAINNET_USDT_PRICE_FEED, abi: priceFeedAbi, functionName: "latestRoundData", ...options }),
    ]);
    const totalAToken = asBigInt(reserveData[2], "totalAToken");
    const stableDebt = asBigInt(reserveData[3], "totalStableDebt");
    const variableDebt = asBigInt(reserveData[4], "totalVariableDebt");
    totalBorrows = stableDebt + variableDebt;
    utilizationBps = totalAToken === 0n ? null : (totalBorrows * 10_000n) / totalAToken;
    if (utilizationBps === null) missingFacts.push("aave.utilisation denominator is zero");
    reserveConfiguration = {
      decimals: asBigInt(reserveConfig[0], "reserve decimals"),
      ltvBps: asBigInt(reserveConfig[1], "ltv"),
      liquidationThresholdBps: asBigInt(reserveConfig[2], "liquidation threshold"),
      reserveFactorBps: asBigInt(reserveConfig[4], "reserve factor"),
      isActive: Boolean(reserveConfig[8]),
      isFrozen: Boolean(reserveConfig[9]),
      isPaused: Boolean(reserveConfig[10]),
    };
    oracleFeed = {
      answer: BigInt(feedData[1]),
      updatedAt: asBigInt(feedData[3], "oracle updatedAt"),
      answeredInRound: asBigInt(feedData[4], "oracle answeredInRound"),
    };
  }

  return {
    chainId: BigInt(config.chainId),
    blockNumber: block.number,
    blockTimestamp: block.timestamp,
    reserve,
    assetDecimals: BigInt(assetDecimals),
    totalAssetSupply: asBigInt(totalAssetSupply, "total asset supply"),
    venueName,
    hasYieldSource,
    venueTotalAssets: asBigInt(venueTotalAssets, "venue total assets"),
    reserveDeficit: asBigInt(reserveDeficit, "reserve deficit"),
    oraclePrice: asBigInt(oraclePrice, "oracle price"),
    redeemableLiquidity: asBigInt(redeemableLiquidity, "redeemable liquidity"),
    totalSupplied: asBigInt(totalSupplied, "total supplied"),
    utilizationBps,
    totalBorrows,
    reserveConfiguration,
    oracleFeed,
    poolCapital: asBigInt(poolCapital, "pool capital"),
    poolOutstandingCover: asBigInt(poolOutstandingCover, "pool outstanding cover"),
    missingFacts,
  };
}

export const __test = { venueAbi, erc20Abi, coverPoolAbi, dataProviderAbi, priceFeedAbi, aaveOracleAbi };

