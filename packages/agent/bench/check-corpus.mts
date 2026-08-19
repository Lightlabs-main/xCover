/** Offline preflight for a benchmark corpus. No provider or API key is used. */
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { evidenceId, modelText, retrieve } from "./benchmark.mjs";
import type { Row } from "./benchmark.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const args = Object.fromEntries(
  process.argv.slice(2).map((a) => a.replace(/^--/, "").split("=") as [string, string]),
);
const corpusArg = args.corpus ?? "bench/data/corpus-gemini.jsonl";
const outArg = args.out ?? "bench/data/gemini-corpus-check.md";
const expectedFamily = args.sourceFamily ?? "Code4rena";
const urlPrefix = args.urlPrefix ?? "https://github.com/code-423n4/";
const minRows = Number(args.minRows ?? (expectedFamily === "Code4rena" ? 150 : 40));
const maxRows = Number(args.maxRows ?? 250);
const evidenceK = Number(args.evidenceK ?? 12);
const corpusPath = resolve(root, corpusArg);
const outPath = resolve(root, outArg);

function readCorpus(path: string): Row[] {
  return readFileSync(path, "utf8")
    .split("\n")
    .filter(Boolean)
    .map((line, index) => {
      try {
        return JSON.parse(line) as Row;
      } catch (error) {
        throw new Error(`invalid JSONL at line ${index + 1}: ${String(error)}`);
      }
    });
}

const corpus = readCorpus(corpusPath);
const failures: string[] = [];
const ids = new Set<string>();
const urls = new Set<string>();
const protocolLabels = new Map<string, Set<string>>();
const sourceGroups = new Set<string>();
const labelCounts = { loss: 0, no_loss: 0 };
const modelLeakWords = /\b(?:loss|losses|lost|steal|stolen|drain|drained|exploit|exploited|hack|hacked|theft|funds?|depositor|incident|rekt|no[_ -]?loss|code4rena|github|audit|audited|finding|findings|sponsor|judged?|contest|report|protocol|outcome|label|labels)\b/i;

if (corpus.length < minRows || corpus.length > maxRows) {
  failures.push(`row count ${corpus.length} is outside ${minRows}–${maxRows}`);
}
if (corpus.length === 0) failures.push("corpus is empty");

for (const row of corpus) {
  if (ids.has(row.id)) failures.push(`duplicate id: ${row.id}`);
  ids.add(row.id);
  if (urls.has(row.sourceUrl)) failures.push(`duplicate sourceUrl: ${row.sourceUrl}`);
  urls.add(row.sourceUrl);
  if (row.sourceFamily !== expectedFamily) failures.push(`${row.id} is not ${expectedFamily} sourceFamily`);
  if (!row.sourceGroup && expectedFamily !== "Code4rena") failures.push(`${row.id} is missing sourceGroup`);
  if (row.sourceGroup) sourceGroups.add(row.sourceGroup);
  if (!row.sourceUrl.startsWith(urlPrefix)) {
    failures.push(`${row.id} does not use the expected source URL prefix`);
  }
  if (row.label !== "loss" && row.label !== "no_loss") failures.push(`${row.id} has invalid label`);
  else labelCounts[row.label]++;
  const labels = protocolLabels.get(row.protocol) ?? new Set<string>();
  labels.add(row.label);
  protocolLabels.set(row.protocol, labels);

  try {
    const safe = modelText(row);
    const serialized = JSON.stringify(safe);
    if (serialized.toLowerCase().includes(row.protocol.toLowerCase())) {
      failures.push(`${row.id} model situation contains protocol name`);
    }
    if (modelLeakWords.test(serialized)) failures.push(`${row.id} model situation contains a direct leakage word`);
  } catch (error) {
    failures.push(`${row.id} cannot be converted to model text: ${String(error)}`);
  }
}

if (expectedFamily === "Code4rena") {
  for (const [protocol, labels] of protocolLabels) {
    if (labels.size > 1) failures.push(`protocol has mixed labels: ${protocol}`);
  }
}

const purityRows: Array<{ id: string; label: string; evidence: number; same: number }> = [];
for (const scenario of corpus) {
  const evidence = retrieve(corpus, scenario, false, evidenceK);
  const evidenceRows = evidence.map((item) => corpus[Number(item.id.slice(1)) - 1]);
  if (evidenceRows.some((row) => !row || row.protocol === scenario.protocol || (scenario.sourceGroup && row.sourceGroup === scenario.sourceGroup))) {
    failures.push(`${scenario.id} retrieval crossed the held-out protocol or source boundary`);
  }
  for (const item of evidence) {
    const keys = Object.keys(item).sort().join(",");
    if (keys !== "era,excerpt,id") failures.push(`${scenario.id} evidence has unsafe fields: ${keys}`);
    if (/https?:\/\//i.test(JSON.stringify(item)) || /protocol|outcome|label|sourceUrl/i.test(JSON.stringify(item))) {
      failures.push(`${scenario.id} evidence contains provenance or label data`);
    }
  }
  const same = evidenceRows.filter((row) => row?.label === scenario.label).length;
  purityRows.push({ id: scenario.id, label: scenario.label, evidence: evidence.length, same });
}

const withEvidence = purityRows.filter((row) => row.evidence > 0);
const totalEvidence = purityRows.reduce((sum, row) => sum + row.evidence, 0);
const totalSame = purityRows.reduce((sum, row) => sum + row.same, 0);
const meanPurity = totalEvidence === 0 ? 0 : totalSame / totalEvidence;
const maxPurity = withEvidence.length === 0
  ? 0
  : Math.max(...withEvidence.map((row) => row.same / row.evidence));
const coverage = corpus.length === 0 ? 0 : withEvidence.length / corpus.length;
const retrievalGate = 0.75;
if (meanPurity > retrievalGate) {
  failures.push(`retrieved neighbours are too label-pure: ${(meanPurity * 100).toFixed(1)}% > ${(retrievalGate * 100).toFixed(0)}% gate`);
}

const dateValues = corpus.map((row) => row.publishedAt).sort();
const status = failures.length === 0 ? "PASS" : "FAIL";
const report = [
  "# Gemini corpus preflight",
  "",
  `Status: **${status}**` + (failures.length ? ` (${failures.length} failure${failures.length === 1 ? "" : "s"})` : ""),
  "",
  `- Corpus: \`${corpusArg}\``,
  `- Rows: ${corpus.length}`,
  `- Labels: ${labelCounts.loss} loss / ${labelCounts.no_loss} no-loss`,
  `- Protocol groups: ${protocolLabels.size} (${[...protocolLabels.values()].filter((labels) => labels.size > 1).length} mixed-label protocol groups allowed)`,
  `- Source/article groups: ${sourceGroups.size}`,
  `- Date range: ${dateValues[0] ?? "n/a"} through ${dateValues.at(-1) ?? "n/a"}`,
  `- Source family: ${expectedFamily}`,
  `- Retrieval coverage: ${(coverage * 100).toFixed(1)}% of rows have at least one neighbour`,
  `- Retrieval neighbours per scenario: ${evidenceK}`,
  `- Retrieval label purity: ${(meanPurity * 100).toFixed(1)}% weighted mean; ${(maxPurity * 100).toFixed(1)}% maximum`,
  `- Retrieval gate: weighted mean must be at most ${(retrievalGate * 100).toFixed(0)}%`,
  "",
  expectedFamily === "Code4rena"
    ? "The loss label is protocol-level: a protocol appears in the checked incident snapshot. It does not assert that the individual finding caused that incident."
    : "Each label is taken from the outcome described by the same Immunefi article as the scenario: realized loss versus a reported/fixed or mitigated case. No cross-source incident join is used.",
  "The prompt path exposes only redacted mechanism text, risk band, era, and opaque evidence IDs; provenance and labels remain evaluation-only.",
  "",
  ...(failures.length ? ["## Failures", "", ...failures.map((failure) => `- ${failure}`)] : ["No offline leakage, schema, source-family, or retrieval-purity failures."]),
  "",
];
writeFileSync(outPath, report.join("\n"));
console.log(JSON.stringify({ status, rows: corpus.length, labels: labelCounts, protocols: protocolLabels.size, retrieval: { coverage, meanPurity, maxPurity }, failures }));
if (failures.length) process.exitCode = 1;
