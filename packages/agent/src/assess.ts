import Anthropic from "@anthropic-ai/sdk";
import type { Assessment, ChainState, Evidence } from "./types.js";

/**
 * The reserved evidence id for facts read directly from the live chain.
 *
 * Chain state is evidence: it is read at a named block and committed verbatim to the decision
 * document under `inputs.chainState`, so a reader can re-read that block and check it. Without a
 * reserved id, an assessment that correctly grounds a hazard factor in live state has nowhere to
 * cite, and the citation check rejects the whole assessment — turning a sound reading into a
 * refusal that misreports its own cause. It does not weaken the corpus requirement: an empty
 * corpus is still refused by the gate before this id can carry an assessment on its own.
 */
export const LIVE_STATE_EVIDENCE_ID = "live-chain-state";

export class AssessmentError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AssessmentError";
  }
}

function asInteger(value: unknown, field: string): bigint {
  if (typeof value === "number" && Number.isSafeInteger(value)) return BigInt(value);
  if (typeof value === "string" && /^\d+$/.test(value)) return BigInt(value);
  throw new AssessmentError(`${field} must be a non-negative integer`);
}

function asString(value: unknown, field: string): string {
  if (typeof value !== "string" || !value.trim()) throw new AssessmentError(`${field} must be a non-empty string`);
  return value;
}

function asStringArray(value: unknown, field: string): string[] {
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string" || !item.trim())) {
    throw new AssessmentError(`${field} must be an array of non-empty strings`);
  }
  return value as string[];
}

function serialise(value: unknown): string {
  return JSON.stringify(value, (_key, item) => (typeof item === "bigint" ? item.toString() : item));
}

function promptFor(framing: string, state: ChainState, evidence: Evidence[]): string {
  return [
    "You are the risk-assessment component of xCover's pricing agent.",
    "Return JSON only. Do not use markdown.",
    "You may only make claims supported by the supplied evidence; put the evidence id on every hazard factor and conclusion.",
    `The only permitted evidence ids are: ${[...evidence.map((item) => item.id), LIVE_STATE_EVIDENCE_ID].join(", ")}.`,
    `Cite "${LIVE_STATE_EVIDENCE_ID}" for a fact read from LIVE CHAIN STATE, and a corpus id for a fact drawn from RETRIEVED EVIDENCE. Do not invent an id.`,
    "If a material fact is unavailable, list it in missingFacts instead of guessing.",
    "The final premium is computed by deterministic code; propose only a bounded base hazard and uncertainty loading.",
    `Framing: ${framing}`,
    "Required JSON shape:",
    JSON.stringify({
      baseHazardPpmPerBlock: "integer",
      uncertaintyLoadingBps: "integer 0..10000",
      confidenceBps: "integer 0..10000",
      hazardFactors: [{ name: "string", severityBps: "integer 0..10000", rationale: "string", evidenceIds: ["corpus-id"] }],
      concerns: ["string"],
      missingFacts: ["string"],
      conclusions: [{ text: "string", evidenceIds: ["corpus-id"] }],
    }),
    `LIVE CHAIN STATE:\n${serialise(state)}`,
    `RETRIEVED EVIDENCE:\n${serialise(evidence)}`,
  ].join("\n\n");
}

function parseResponse(raw: unknown, framing: string, model: string, evidence: Evidence[]): Assessment {
  if (!raw || typeof raw !== "object") throw new AssessmentError("model response was not an object");
  const value = raw as Record<string, unknown>;
  const knownIds = new Set([...evidence.map((item) => item.id), LIVE_STATE_EVIDENCE_ID]);
  const hazardFactorsValue = value.hazardFactors;
  if (!Array.isArray(hazardFactorsValue) || hazardFactorsValue.length === 0) {
    throw new AssessmentError("model returned no hazard factors");
  }
  const hazardFactors = hazardFactorsValue.map((factor, index) => {
    if (!factor || typeof factor !== "object") throw new AssessmentError(`hazardFactors[${index}] is not an object`);
    const item = factor as Record<string, unknown>;
    const evidenceIds = asStringArray(item.evidenceIds, `hazardFactors[${index}].evidenceIds`);
    if (evidenceIds.some((id) => !knownIds.has(id))) throw new AssessmentError(`hazardFactors[${index}] cites unknown evidence`);
    const severityBps = asInteger(item.severityBps, `hazardFactors[${index}].severityBps`);
    if (severityBps > 10_000n) throw new AssessmentError(`hazardFactors[${index}].severityBps is above 10000`);
    return {
      name: asString(item.name, `hazardFactors[${index}].name`),
      severityBps,
      rationale: asString(item.rationale, `hazardFactors[${index}].rationale`),
      evidenceIds,
    };
  });
  const conclusionsValue = value.conclusions;
  if (!Array.isArray(conclusionsValue) || conclusionsValue.length === 0) {
    throw new AssessmentError("model returned no cited conclusions");
  }
  const conclusions = conclusionsValue.map((conclusion, index) => {
    if (!conclusion || typeof conclusion !== "object") throw new AssessmentError(`conclusions[${index}] is not an object`);
    const item = conclusion as Record<string, unknown>;
    const evidenceIds = asStringArray(item.evidenceIds, `conclusions[${index}].evidenceIds`);
    if (evidenceIds.some((id) => !knownIds.has(id))) throw new AssessmentError(`conclusions[${index}] cites unknown evidence`);
    return { text: asString(item.text, `conclusions[${index}].text`), evidenceIds };
  });
  const confidenceBps = asInteger(value.confidenceBps, "confidenceBps");
  const uncertaintyLoadingBps = asInteger(value.uncertaintyLoadingBps, "uncertaintyLoadingBps");
  if (confidenceBps > 10_000n || uncertaintyLoadingBps > 10_000n) {
    throw new AssessmentError("confidence and uncertainty loading must be at most 10000 bp");
  }
  const missingFacts = asStringArray(value.missingFacts, "missingFacts");
  const concerns = asStringArray(value.concerns, "concerns");
  return {
    framing,
    baseHazardPpmPerBlock: asInteger(value.baseHazardPpmPerBlock, "baseHazardPpmPerBlock"),
    uncertaintyLoadingBps,
    confidenceBps,
    hazardFactors,
    concerns,
    missingFacts,
    conclusions,
    model,
  };
}

function extractJson(text: string): unknown {
  const trimmed = text.trim();
  const withoutFence = trimmed.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
  try {
    return JSON.parse(withoutFence);
  } catch (error) {
    throw new AssessmentError(`model did not return valid JSON: ${String(error)}`);
  }
}

export async function assess(
  apiKey: string,
  model: string,
  framing: string,
  state: ChainState,
  evidence: Evidence[],
): Promise<Assessment> {
  const client = new Anthropic({ apiKey, timeout: 300_000, maxRetries: 2 });
  let response: Anthropic.Message;
  try {
    // No `temperature`: the current models reject it. Determinism does not come from sampling
    // here anyway — it comes from the deterministic computation and the gate downstream, and
    // from committing the exact model output to the replayable decision document.
    response = await client.messages.create({
      model,
      max_tokens: 16_000,
      thinking: { type: "adaptive" },
      output_config: { effort: "high" },
      messages: [{ role: "user", content: promptFor(framing, state, evidence) }],
    });
  } catch (error) {
    if (error instanceof Anthropic.APIError) {
      throw new AssessmentError(`Anthropic request failed with HTTP ${error.status}: ${error.message}`);
    }
    throw new AssessmentError(`Anthropic request failed: ${String(error)}`);
  }
  // A safety refusal is not a risk assessment. It must reach the gate as a missing assessment
  // rather than be parsed for a number that is not there.
  if (response.stop_reason === "refusal") {
    throw new AssessmentError(`Anthropic declined the request: ${response.stop_details?.category ?? "unspecified"}`);
  }
  if (response.stop_reason === "max_tokens") {
    throw new AssessmentError("Anthropic response hit the output limit before completing the assessment");
  }
  const text = response.content.find((item) => item.type === "text")?.text;
  if (!text) throw new AssessmentError("Anthropic response contained no text block");
  return parseResponse(extractJson(text), framing, model, evidence);
}

export const __test = { parseResponse, promptFor };
