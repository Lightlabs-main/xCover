import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { isAddress, getAddress, type Address, type PublicClient } from "viem";
import { assertLivePairing, makePublicClient, readChainState } from "./chain.js";
import { loadCorpus } from "./evidence.js";
import type { AgentConfig, SignedDecision } from "./types.js";
import { makeDecision } from "./decision.js";
import type { DecisionStore } from "./store.js";
import { FileDecisionStore } from "./store.js";

function jsonSafe(value: unknown): unknown {
  if (typeof value === "bigint") return value.toString();
  if (Array.isArray(value)) return value.map(jsonSafe);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, jsonSafe(item)]));
  }
  return value;
}

function send(response: ServerResponse, status: number, body: unknown, contentType = "application/json"): void {
  const payload = typeof body === "string" ? body : JSON.stringify(jsonSafe(body));
  response.writeHead(status, {
    "content-type": `${contentType}; charset=utf-8`,
    "access-control-allow-origin": "*",
    "access-control-allow-headers": "content-type",
    "access-control-allow-methods": "GET,POST,OPTIONS",
  });
  response.end(payload);
}

const DASHBOARD_FILES: Record<string, { file: string; contentType: string }> = {
  "/": { file: "index.html", contentType: "text/html" },
  "/index.html": { file: "index.html", contentType: "text/html" },
  "/app.js": { file: "app.js", contentType: "text/javascript" },
  "/styles.css": { file: "styles.css", contentType: "text/css" },
};

async function serveDashboard(pathname: string, response: ServerResponse): Promise<boolean> {
  const requested = DASHBOARD_FILES[pathname];
  if (!requested) return false;
  const candidateRoots = [resolve(process.cwd(), "apps/web"), resolve(process.cwd(), "../../apps/web")];
  const root = candidateRoots.find((item) => existsSync(item));
  if (!root) return false;
  const file = resolve(root, requested.file);
  if (!file.startsWith(`${root}/`)) return false;
  try {
    send(response, 200, await readFile(file, "utf8"), requested.contentType);
    return true;
  } catch {
    return false;
  }
}

async function serveProjectGuide(pathname: string, response: ServerResponse): Promise<boolean> {
  if (pathname !== "/docs/project-guide.md") return false;
  const candidateRoots = [resolve(process.cwd(), "docs"), resolve(process.cwd(), "../../docs")];
  const root = candidateRoots.find((item) => existsSync(item));
  if (!root) return false;
  const file = resolve(root, "project-guide.md");
  if (!file.startsWith(`${root}/`)) return false;
  try {
    send(response, 200, await readFile(file, "utf8"), "text/markdown");
    return true;
  } catch {
    return false;
  }
}

async function proxyRpc(
  request: IncomingMessage,
  response: ServerResponse,
  config: AgentConfig,
): Promise<boolean> {
  if (request.method !== "POST") return false;

  const payload = await body(request);
  const fallback = config.environment === "mainnet" ? process.env.XLAYER_MAINNET_RPC_FALLBACK : undefined;
  const endpoints = [config.rpcUrl, fallback].filter((value, index, list): value is string => Boolean(value) && list.indexOf(value) === index);
  let lastError = "RPC request failed";

  for (const endpoint of endpoints) {
    try {
      const upstream = await fetch(endpoint, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(payload),
      });
      const text = await upstream.text();
      if (upstream.ok && text) {
        send(response, upstream.status, text, "application/json");
        return true;
      }
      lastError = `RPC returned HTTP ${upstream.status}`;
    } catch (error) {
      lastError = error instanceof Error ? error.message : String(error);
    }
  }

  throw new Error(lastError);
}

async function body(request: IncomingMessage): Promise<unknown> {
  let content = "";
  for await (const chunk of request) {
    content += chunk.toString();
    if (content.length > 1_000_000) throw new Error("request body exceeds 1 MB");
  }
  try {
    return JSON.parse(content || "{}");
  } catch {
    throw new Error("request body must be JSON");
  }
}

function requestValues(value: unknown, configuredAsset: Address): { reserve: Address; coverAmount: bigint; nonce?: bigint } {
  if (!value || typeof value !== "object") throw new Error("request must be an object");
  const request = value as Record<string, unknown>;
  const reserveValue = request.reserve === undefined ? configuredAsset : request.reserve;
  if (typeof reserveValue !== "string" || !isAddress(reserveValue)) throw new Error("reserve must be an EVM address");
  const reserve = getAddress(reserveValue);
  if (reserve.toLowerCase() !== configuredAsset.toLowerCase()) throw new Error("reserve is not the configured launch asset");
  if (typeof request.coverAmount !== "string" || !/^\d+$/.test(request.coverAmount)) {
    throw new Error("coverAmount must be a decimal integer string");
  }
  const coverAmount = BigInt(request.coverAmount);
  if (coverAmount <= 0n) throw new Error("coverAmount must be greater than zero");
  let nonce: bigint | undefined;
  if (request.nonce !== undefined) {
    if (typeof request.nonce !== "string" || !/^\d+$/.test(request.nonce)) throw new Error("nonce must be a decimal integer string");
    nonce = BigInt(request.nonce);
  }
  return { reserve, coverAmount, nonce };
}

export class PricingAgent {
  private readonly corpus;

  constructor(
    readonly config: AgentConfig,
    private readonly client: PublicClient,
    private readonly store: DecisionStore,
  ) {
    this.corpus = loadCorpus(config.corpusPath);
  }

  async initialize(): Promise<void> {
    await assertLivePairing(this.client, this.config);
  }

  get corpusSize(): number {
    return this.corpus.length;
  }

  async decide(reserve: Address, coverAmount: bigint, nonce?: bigint): Promise<SignedDecision> {
    const state = await readChainState(this.client, this.config, reserve);
    const result = await makeDecision(this.config, state, this.corpus, coverAmount, nonce);
    await this.store.put(result.decisionHash, result.canonicalJson);
    return result;
  }

  async getDecision(hash: `0x${string}`): Promise<string | null> {
    return this.store.get(hash);
  }
}

export async function startServer(
  config: AgentConfig,
  options: { client?: PublicClient; store?: DecisionStore; port?: number; host?: string } = {},
): Promise<{ server: Server; agent: PricingAgent; port: number }> {
  const agent = new PricingAgent(
    config,
    options.client ?? makePublicClient(config),
    options.store ?? new FileDecisionStore(config.decisionStorePath),
  );
  // Environment pairing is checked before route registration or listen().
  await agent.initialize();
  const server = createServer(async (request, response) => {
    try {
      if (request.method === "OPTIONS") {
        send(response, 204, "", "text/plain");
        return;
      }
      const url = new URL(request.url ?? "/", "http://localhost");
      if (request.method === "GET" && await serveDashboard(url.pathname, response)) return;
      if (request.method === "GET" && await serveProjectGuide(url.pathname, response)) return;
      if (url.pathname === "/rpc" && await proxyRpc(request, response, config)) return;
      if (request.method === "GET" && url.pathname === "/health") {
        send(response, 200, {
          status: "ok",
          mode: config.mode,
          calibration: config.mode === "calibration_in_progress" || config.mode === "provisional_pricing"
            ? {
                status: "in_progress",
                thresholdDerived: false,
                quotesEnabled: config.mode === "provisional_pricing",
                unaudited: config.mode === "provisional_pricing",
              }
            : null,
          environment: config.environment,
          chainId: config.chainId,
          venue: config.deployment.venueName,
          corpusEntries: agent.corpusSize,
        });
        return;
      }
      if (request.method === "GET" && url.pathname === "/deployment") {
        send(response, 200, { ...config.deployment, rpcUrl: config.rpcUrl, mode: config.mode });
        return;
      }
      const decisionMatch = url.pathname.match(/^\/decision\/(0x[0-9a-fA-F]{64})$/);
      if (request.method === "GET" && decisionMatch) {
        // Hashes are content addresses, not identifiers the caller chose; a hash typed or
        // pasted in upper case addresses the same decision document.
        const hash = decisionMatch[1].toLowerCase() as `0x${string}`;
        const document = await agent.getDecision(hash);
        if (!document) {
          send(response, 404, { error: "decision not found" });
          return;
        }
        send(response, 200, document);
        return;
      }
      if (request.method === "POST" && url.pathname === "/decision") {
        const values = requestValues(await body(request), config.deployment.asset);
        const result = await agent.decide(values.reserve, values.coverAmount, values.nonce);
        send(response, 200, {
          quoteHash: result.quoteHash,
          decisionHash: result.decisionHash,
          decision: result.decision,
          signature: result.signature,
          decisionDocumentUrl: `/decision/${result.decisionHash}`,
          canonicalJson: result.canonicalJson,
        });
        return;
      }
      send(response, 404, { error: "not found" });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      const status = message.includes("request") || message.includes("coverAmount") || message.includes("reserve") ? 400 : 503;
      send(response, status, { error: message });
    }
  });
  const port = options.port ?? Number(process.env.PORT ?? 8787);
  const host = options.host ?? process.env.HOST ?? "127.0.0.1";
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, host, () => resolve());
  });
  return { server, agent, port };
}
