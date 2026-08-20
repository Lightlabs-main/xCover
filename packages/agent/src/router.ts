import {
  AssessmentError,
  extractJson,
  parseResponse,
  promptFor,
} from "./assess.js";
import type { Assessment, ChainState, Evidence } from "./types.js";

export type RouterJsonResult = {
  value: unknown;
  inputTokens: number;
  outputTokens: number;
};

const ROUTER_URL = "https://router.bynara.id/v1/chat/completions";

/**
 * Call NaraRouter's OpenAI-compatible chat endpoint. The router does not need a provider SDK:
 * the prompt requests JSON and the common xCover parser remains responsible for validating the
 * assessment and its evidence citations.
 */
export async function generateRouterJson(
  apiKey: string,
  model: string,
  prompt: string,
  reasoningEffort: "low" | "medium" | "high" = "high",
): Promise<RouterJsonResult> {
  let response: Response;
  try {
    response = await fetch(ROUTER_URL, {
      method: "POST",
      headers: {
        authorization: `Bearer ${apiKey}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model,
        messages: [{ role: "user", content: prompt }],
        // Qwen's reasoning tokens count toward this budget. Keep enough room for reasoning
        // while preventing the free gateway from spending several minutes on an unbounded answer.
        max_tokens: 8_192,
        reasoning_effort: reasoningEffort,
      }),
      signal: AbortSignal.timeout(300_000),
    });
  } catch (error) {
    throw new AssessmentError(`NaraRouter request failed: ${String(error)}`);
  }

  const body = await response.text();
  let payload: Record<string, unknown>;
  try {
    payload = JSON.parse(body) as Record<string, unknown>;
  } catch {
    throw new AssessmentError(`NaraRouter request failed with HTTP ${response.status}`);
  }
  if (!response.ok) {
    const error = payload.error;
    const message = error && typeof error === "object" && "message" in error
      ? String((error as { message: unknown }).message)
      : `HTTP ${response.status}`;
    throw new AssessmentError(`NaraRouter request failed with HTTP ${response.status}: ${message}`);
  }

  const choices = payload.choices;
  const first = Array.isArray(choices) ? choices[0] : null;
  const message = first && typeof first === "object" && "message" in first
    ? (first as { message: unknown }).message
    : null;
  const text = message && typeof message === "object" && "content" in message
    ? (message as { content: unknown }).content
    : null;
  if (typeof text !== "string" || !text.trim()) {
    throw new AssessmentError("NaraRouter response contained no text block");
  }

  const usage = payload.usage && typeof payload.usage === "object"
    ? payload.usage as Record<string, unknown>
    : {};
  return {
    value: extractJson(text),
    inputTokens: typeof usage.prompt_tokens === "number" ? usage.prompt_tokens : 0,
    outputTokens: typeof usage.completion_tokens === "number" ? usage.completion_tokens : 0,
  };
}

export async function assessRouter(
  apiKey: string,
  model: string,
  framing: string,
  state: ChainState,
  evidence: Evidence[],
): Promise<Assessment> {
  const result = await generateRouterJson(apiKey, model, promptFor(framing, state, evidence));
  return parseResponse(result.value, framing, model, evidence);
}
