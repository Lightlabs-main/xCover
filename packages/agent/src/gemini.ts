import { ApiError, GoogleGenAI } from "@google/genai";
import {
  AssessmentError,
  assessmentResponseSchema,
  extractJson,
  parseResponse,
  promptFor,
} from "./assess.js";
import type { Assessment, ChainState, Evidence } from "./types.js";

export type GeminiJsonResult = {
  value: unknown;
  inputTokens: number;
  outputTokens: number;
};

/**
 * Call Gemini's server-side structured-output endpoint and return the parsed JSON plus usage.
 * The provider boundary ends here: all semantic validation and citation enforcement remains in
 * assess.ts, shared with the Anthropic path.
 */
export async function generateGeminiJson(
  apiKey: string,
  model: string,
  prompt: string,
  responseJsonSchema: unknown,
): Promise<GeminiJsonResult> {
  const client = new GoogleGenAI({
    apiKey,
    apiVersion: "v1",
    httpOptions: { timeout: 300_000 },
  });

  let response;
  try {
    response = await client.models.generateContent({
      model,
      contents: prompt,
      config: {
        maxOutputTokens: 16_000,
        responseMimeType: "application/json",
        responseJsonSchema,
      },
    });
  } catch (error) {
    if (error instanceof ApiError) {
      throw new AssessmentError(`Gemini request failed with HTTP ${error.status}: ${error.message}`);
    }
    throw new AssessmentError(`Gemini request failed: ${String(error)}`);
  }

  const text = response.text;
  if (!text) {
    const blocked = response.promptFeedback?.blockReason;
    if (blocked) throw new AssessmentError(`Gemini blocked the request: ${blocked}`);
    const finishReason = response.candidates?.[0]?.finishReason;
    if (finishReason === "MAX_TOKENS") {
      throw new AssessmentError("Gemini response hit the output limit before completing the assessment");
    }
    throw new AssessmentError("Gemini response contained no text block");
  }

  return {
    value: extractJson(text),
    inputTokens: response.usageMetadata?.promptTokenCount ?? 0,
    outputTokens: response.usageMetadata?.candidatesTokenCount ?? 0,
  };
}

export async function assessGemini(
  apiKey: string,
  model: string,
  framing: string,
  state: ChainState,
  evidence: Evidence[],
): Promise<Assessment> {
  const result = await generateGeminiJson(apiKey, model, promptFor(framing, state, evidence), assessmentResponseSchema);
  return parseResponse(result.value, framing, model, evidence);
}
