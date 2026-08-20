import { assessAnthropic } from "./assess.js";
import { assessGemini } from "./gemini.js";
import { assessRouter } from "./router.js";
import type { Assessment, ChainState, Evidence, ModelProvider } from "./types.js";

export type AssessmentRunner = (
  apiKey: string,
  model: string,
  framing: string,
  state: ChainState,
  evidence: Evidence[],
) => Promise<Assessment>;

export function assessmentRunnerFor(provider: ModelProvider): AssessmentRunner {
  if (provider === "gemini") return assessGemini;
  if (provider === "alibaba") return assessRouter;
  return assessAnthropic;
}
