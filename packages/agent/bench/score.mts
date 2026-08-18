/**
 * Score the labelled corpus so the confidence gate can be derived rather than chosen.
 *
 * One scenario at a time, with its own row removed from the retrievable corpus: the
 * corpus is both the evidence and the answer key, so leaving the row in would measure
 * recall of the answer rather than judgement. The scenario's outcome, label and loss
 * amount are never shown to the model.
 *
 * This run does not apply a threshold. It records what the model said — a loss
 * likelihood, a confidence, an uncertainty loading, and what it reported it could not
 * establish — for every scenario. The operating point is swept over those numbers
 * afterwards, which is what lets the threshold be measured instead of picked.
 */
import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import Anthropic from "@anthropic-ai/sdk";
import { LIVE_STATE_EVIDENCE_ID } from "../src/assess.js";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");

type Row = {
  id: string; title: string; sourceUrl: string; publishedAt: string; protocol: string;
  outcome: string; text: string; label: "loss" | "no_loss"; classification: string;
  technique: string | null;
};

const args = Object.fromEntries(
  process.argv.slice(2).map((a) => a.replace(/^--/, "").split("=") as [string, string]),
);
const limit = Number(args.limit ?? 0);
// Control run: same scenarios, no retrieved evidence. If accuracy survives this, the
// benchmark is reading the label off how the situation is written rather than reasoning
// from evidence, and it must be reported as measuring that instead.
const noEvidence = "noEvidence" in args;
const balanced = "balanced" in args;
const concurrency = Number(args.concurrency ?? 6);
const out = resolve(root, args.out ?? "bench/data/scores.jsonl");
const model = process.env.ANTHROPIC_MODEL!;
const client = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY!, timeout: 300_000, maxRetries: 3 });

const corpus: Row[] = readFileSync(resolve(root, "bench/data/corpus.jsonl"), "utf8")
  .split("\n").filter(Boolean).map((l) => JSON.parse(l) as Row);

const STOP = new Set(["the","and","for","that","was","were","with","from","this","have","has","not","its","are","a","an","of","in","on","to","by"]);
const terms = (text: string) =>
  new Set(text.toLowerCase().split(/[^a-z0-9]+/).filter((t) => t.length > 3 && !STOP.has(t)));

/** Deterministic lexical retrieval over everything except the scenario under test. */
function retrieve(scenario: Row, k = 12) {
  if (noEvidence) return [];
  const want = terms(`${scenario.protocol} ${scenario.classification} ${scenario.title}`);
  return corpus
    .filter((row) => row.id !== scenario.id)
    .map((row) => {
      const have = terms(`${row.title} ${row.protocol} ${row.classification} ${row.text}`);
      let score = 0;
      for (const t of want) if (have.has(t)) score += 1;
      return { row, score };
    })
    .filter(({ score }) => score > 0)
    .sort((a, b) => b.score - a.score || a.row.id.localeCompare(b.row.id))
    .slice(0, k)
    .map(({ row }) => ({
      id: row.id, title: row.title, sourceUrl: row.sourceUrl, publishedAt: row.publishedAt,
      protocol: row.protocol, outcome: row.outcome, excerpt: row.text,
    }));
}

/**
 * How a scenario is shown to the model.
 *
 * The two halves of the corpus arrive in different words, and those words give the answer
 * away: an incident write-up is titled "Balancer - REKT" and an audit finding is classified
 * "Audit finding (high severity)". A model reading either is not judging risk, it is reading
 * a label. Both are stripped here, and both halves are reduced to the same three fields.
 * This narrows the leak; it does not prove it closed, which is what the control run is for.
 */
function situation(scenario: Row) {
  const mechanism = scenario.label === "loss"
    ? (scenario.technique && scenario.technique !== "Unknown" ? scenario.technique : scenario.classification)
    : scenario.title;
  return {
    protocol: scenario.protocol,
    date: scenario.publishedAt,
    mechanism: mechanism.replace(/\s*-\s*REKT\s*$/i, "").trim(),
  };
}

function prompt(framing: string, scenario: Row, evidence: ReturnType<typeof retrieve>) {
  return [
    "You are the risk-assessment component of xCover's pricing agent, judging whether a described",
    "protocol-risk situation resulted in depositor loss. You are not told the outcome.",
    "Return JSON only. Do not use markdown.",
    "You may only make claims supported by the supplied evidence; cite an evidence id on every hazard factor and conclusion.",
    `The only permitted evidence ids are: ${[...evidence.map((e) => e.id), LIVE_STATE_EVIDENCE_ID].join(", ")}.`,
    `Cite "${LIVE_STATE_EVIDENCE_ID}" for a fact taken from the SITUATION block itself. Do not invent an id.`,
    "If a material fact is unavailable, list it in missingFacts instead of guessing.",
    "confidenceBps is how much you would stake on your own answer being right. It is used to decide",
    "whether to price this risk at all, so a confident wrong answer is far more costly than an honest low one.",
    `Framing: ${framing}`,
    "Required JSON shape:",
    JSON.stringify({
      lossLikelihoodBps: "integer 0..10000 — probability the situation caused depositor loss",
      confidenceBps: "integer 0..10000",
      uncertaintyLoadingBps: "integer 0..10000",
      hazardFactors: [{ name: "string", severityBps: "integer 0..10000", rationale: "string", evidenceIds: ["id"] }],
      concerns: ["string"], missingFacts: ["string"],
      conclusions: [{ text: "string", evidenceIds: ["id"] }],
    }),
    `SITUATION:\n${JSON.stringify(situation(scenario))}`,
    evidence.length === 0
      ? "RETRIEVED EVIDENCE:\nNone was retrievable for this scenario."
      : `RETRIEVED EVIDENCE:\n${JSON.stringify(evidence)}`,
  ].join("\n\n");
}

const int = (v: unknown, field: string): number => {
  if (typeof v === "number" && Number.isSafeInteger(v)) return v;
  if (typeof v === "string" && /^\d+$/.test(v)) return Number(v);
  throw new Error(`${field} must be a non-negative integer`);
};

async function pass(framing: string, scenario: Row, evidence: ReturnType<typeof retrieve>) {
  const response = await client.messages.create({
    model, max_tokens: 16_000, thinking: { type: "adaptive" },
    output_config: { effort: "high" },
    messages: [{ role: "user", content: prompt(framing, scenario, evidence) }],
  });
  if (response.stop_reason === "refusal") throw new Error("model declined");
  if (response.stop_reason === "max_tokens") throw new Error("truncated before completing");
  const text = response.content.find((b) => b.type === "text")?.text;
  if (!text) throw new Error("no text block");
  const raw = JSON.parse(text.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "")) as Record<string, unknown>;
  const known = new Set([...evidence.map((e) => e.id), LIVE_STATE_EVIDENCE_ID]);
  const cited = evidence.length === 0 ? [LIVE_STATE_EVIDENCE_ID] : [
    ...(raw.hazardFactors as Array<{ evidenceIds: string[] }> ?? []),
    ...(raw.conclusions as Array<{ evidenceIds: string[] }> ?? []),
  ].flatMap((x: { evidenceIds?: string[] }) => x.evidenceIds ?? []);
  if (cited.length === 0) throw new Error("no citations");
  if (cited.some((id) => !known.has(id))) throw new Error("cites unknown evidence");
  return {
    lossLikelihoodBps: int(raw.lossLikelihoodBps, "lossLikelihoodBps"),
    confidenceBps: int(raw.confidenceBps, "confidenceBps"),
    uncertaintyLoadingBps: int(raw.uncertaintyLoadingBps, "uncertaintyLoadingBps"),
    missingFacts: (raw.missingFacts as string[]) ?? [],
  };
}

const FRAMINGS = [
  "Analyse the historical hazard first; be conservative about extrapolating across deployments.",
  "Stress-test the first framing; search for missing facts and reasons not to commit capital.",
];

async function scoreOne(scenario: Row) {
  const evidence = retrieve(scenario);
  const [a, b] = await Promise.all(FRAMINGS.map((f: string) => pass(f, scenario, evidence)));
  return {
    id: scenario.id, label: scenario.label, protocol: scenario.protocol,
    classification: scenario.classification, evidenceCount: evidence.length,
    lossLikelihoodBps: Math.round((a.lossLikelihoodBps + b.lossLikelihoodBps) / 2),
    // Confidence is the lower of the two framings, and disagreement is a measured signal,
    // not noise to be averaged away (SPEC 5.2 step 3).
    confidenceBps: Math.min(a.confidenceBps, b.confidenceBps),
    disagreementBps: Math.max(
      Math.abs(a.lossLikelihoodBps - b.lossLikelihoodBps),
      Math.abs(a.confidenceBps - b.confidenceBps),
      Math.abs(a.uncertaintyLoadingBps - b.uncertaintyLoadingBps),
    ),
    uncertaintyLoadingBps: Math.round((a.uncertaintyLoadingBps + b.uncertaintyLoadingBps) / 2),
    missingFactCount: new Set([...a.missingFacts, ...b.missingFacts]).size,
    passes: [a, b],
  };
}

// Resume only over scenarios that actually produced a score. A row recorded with an error
// is a scenario still owed an answer — a run stopped by a credit limit or a rate limit must
// pick those up again, not treat "we failed once" as "we are done".
const previous = existsSync(out)
  ? readFileSync(out, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l) as { id: string; error?: string })
  : [];
const done = new Set(previous.filter((r) => !r.error).map((r) => r.id));
const retryable = previous.filter((r) => r.error).length;
if (retryable > 0) console.error(`${retryable} previously failed scenarios will be retried`);
let pending = corpus.filter((r) => !done.has(r.id));
if (balanced) {
  // Sampling in file order takes the earliest rows, which are all incidents; a run that
  // never sees a negative cannot tell discrimination from a constant answer.
  const loss = pending.filter((r) => r.label === "loss");
  const noLoss = pending.filter((r) => r.label === "no_loss");
  const half = Math.floor((limit || pending.length) / 2);
  pending = [...loss.slice(0, half), ...noLoss.slice(0, half)];
}
const queue = pending.slice(0, limit || undefined);
console.error(`${done.size} already scored; scoring ${queue.length} of ${corpus.length} at concurrency ${concurrency}`);

let index = 0, ok = 0, failed = 0;
await Promise.all(Array.from({ length: concurrency }, async () => {
  while (index < queue.length) {
    const scenario = queue[index++];
    try {
      appendFileSync(out, `${JSON.stringify(await scoreOne(scenario))}\n`);
      ok++;
    } catch (error) {
      // A scenario the harness could not score is recorded as unscored, never as a guess.
      appendFileSync(out, `${JSON.stringify({ id: scenario.id, label: scenario.label, error: String(error) })}\n`);
      failed++;
    }
    if ((ok + failed) % 10 === 0) console.error(`  ${ok + failed}/${queue.length} (${failed} failed)`);
  }
}));
console.error(`scored ${ok}, failed ${failed}`);
