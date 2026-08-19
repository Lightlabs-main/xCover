/**
 * Shared, model-facing benchmark policy.
 *
 * The corpus retains provenance and labels for auditability, but this module is the
 * only path by which a benchmark row becomes prompt content.  In particular, it
 * never reads label, outcome, protocol, sourceUrl, lossUsd, or raw text.
 */

export type Label = "loss" | "no_loss";

export type Row = {
  id: string;
  title: string;
  sourceUrl: string;
  publishedAt: string;
  protocol: string;
  outcome: string;
  text: string;
  label: Label;
  classification: string;
  technique: string | null;
  sourceFamily?: string;
  /** A model-safe mechanism title, separated from the auditable source title. */
  modelTitle?: string;
  /** Source/article group held out during retrieval. */
  sourceGroup?: string;
};

export type ModelText = {
  era: string;
  riskBand: "high" | "medium";
  mechanism: string;
};

export type Evidence = {
  id: string;
  era: string;
  excerpt: string;
};

const STOP = new Set([
  "the", "and", "for", "that", "was", "were", "with", "from", "this", "have", "has",
  "not", "its", "are", "a", "an", "of", "in", "on", "to", "by", "can", "will", "does",
  "into", "when", "than", "then", "their", "they", "should", "could",
]);

const OUTCOME_WORDS = /\b(?:loss|losses|lost|steal|steals|stolen|drain|drains|drained|exploit|exploits|exploited|exploitation|hack|hacks|hacked|hacking|theft|funds?|depositor|depositors|incident|incidents|rekt|no[_ -]?loss)\b/gi;
const SOURCE_WORDS = /\b(?:code4rena|github|audit|audited|auditor|auditors|finding|findings|sponsor|judge|judged|contest|report|reports|protocol|outcome|label|labels)\b/gi;

const words = (text: string) =>
  new Set(text.toLowerCase().split(/[^a-z0-9]+/).filter((term) => term.length > 3 && !STOP.has(term)));

function eraFor(date: string): string {
  const match = /^(\d{4})-(\d{2})-\d{2}$/.exec(date);
  if (!match) throw new Error(`publishedAt must be YYYY-MM-DD: ${date}`);
  return `${match[1]}-H${Number(match[2]) <= 6 ? 1 : 2}`;
}

function riskBandFor(classification: string): ModelText["riskBand"] {
  if (/\bhigh\b/i.test(classification)) return "high";
  if (/\bmedium\b/i.test(classification)) return "medium";
  throw new Error(`classification must contain high or medium: ${classification}`);
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function redactMechanism(title: string, protocol: string): string {
  const protocolPattern = new RegExp(escapeRegExp(protocol), "gi");
  const mechanism = title
    .replace(/https?:\/\/\S+/gi, " ")
    .replace(/`/g, "")
    .replace(protocolPattern, " ")
    .replace(OUTCOME_WORDS, " ")
    .replace(SOURCE_WORDS, " ")
    .replace(/\s+/g, " ")
    .replace(/^[\s:;,.\-]+|[\s:;,.\-]+$/g, "")
    .trim();
  return mechanism || "unspecified mechanism";
}

/** The complete model-facing representation of one row. */
export function modelText(row: Row): ModelText {
  return {
    era: eraFor(row.publishedAt),
    riskBand: riskBandFor(row.classification),
    mechanism: redactMechanism(row.modelTitle ?? row.title, row.protocol),
  };
}

export function evidenceId(index: number): string {
  return `e${String(index + 1).padStart(4, "0")}`;
}

/**
 * Deterministic lexical retrieval. The scenario's complete protocol and source/article
 * groups are held out, and the returned evidence is rebuilt from modelText rather than
 * copied from the corpus row.
 */
export function retrieve(corpus: Row[], scenario: Row, noEvidence = false, k = 12): Evidence[] {
  if (noEvidence) return [];
  const scenarioText = modelText(scenario);
  const want = words(`${scenarioText.riskBand} ${scenarioText.mechanism}`);
  return corpus
    .map((row, index) => ({ row, index }))
    .filter(({ row }) => row.protocol !== scenario.protocol &&
      !(scenario.sourceGroup && row.sourceGroup === scenario.sourceGroup))
    .map(({ row, index }) => {
      const safe = modelText(row);
      let score = 0;
      for (const term of want) if (words(`${safe.riskBand} ${safe.mechanism}`).has(term)) score++;
      return { row, index, safe, score };
    })
    .filter(({ score }) => score > 0)
    .sort((a, b) => b.score - a.score || a.row.id.localeCompare(b.row.id))
    .slice(0, k)
    .map(({ index, safe }) => ({ id: evidenceId(index), era: safe.era, excerpt: safe.mechanism }));
}

export function promptSituation(scenario: Row): ModelText {
  return modelText(scenario);
}
