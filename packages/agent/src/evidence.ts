import { existsSync, readFileSync } from "node:fs";
import type { ChainState, Evidence } from "./types.js";

export type CorpusEntry = Evidence & { text: string };

export function loadCorpus(path: string): CorpusEntry[] {
  if (!existsSync(path)) return [];
  const entries: CorpusEntry[] = [];
  for (const [index, line] of readFileSync(path, "utf8").split(/\r?\n/).entries()) {
    if (!line.trim()) continue;
    let value: Record<string, unknown>;
    try {
      value = JSON.parse(line) as Record<string, unknown>;
    } catch (error) {
      throw new Error(`invalid corpus JSON on line ${index + 1}: ${String(error)}`);
    }
    const requiredFields = ["id", "title", "sourceUrl", "publishedAt", "protocol", "outcome", "text"];
    for (const field of requiredFields) {
      if (typeof value[field] !== "string" || !value[field]) {
        throw new Error(`corpus line ${index + 1} is missing string field ${field}`);
      }
    }
    try {
      new URL(value.sourceUrl as string);
    } catch {
      throw new Error(`corpus line ${index + 1} has an invalid sourceUrl`);
    }
    entries.push({
      id: value.id as string,
      title: value.title as string,
      sourceUrl: value.sourceUrl as string,
      publishedAt: value.publishedAt as string,
      protocol: value.protocol as string,
      outcome: value.outcome as string,
      text: value.text as string,
      excerpt: value.text as string,
    });
  }
  return entries;
}

function termsFor(state: ChainState): string[] {
  const terms = ["aave", "v3", "reserve", "deficit", "oracle", "liquidity", "usdt"];
  if (state.venueName.includes("xlayer")) terms.push("xlayer");
  return terms;
}

/**
 * Deterministic lexical retrieval. It never invents evidence: an empty or absent corpus returns
 * an empty set, which the pricing gate treats as a refusal condition.
 */
export function retrieveEvidence(corpus: CorpusEntry[], state: ChainState, limit = 12): Evidence[] {
  const terms = termsFor(state);
  return corpus
    .map((entry) => {
      const haystack = `${entry.title} ${entry.protocol} ${entry.outcome} ${entry.text}`.toLowerCase();
      const score = terms.reduce((sum, term) => sum + (haystack.includes(term) ? 1 : 0), 0);
      return { entry, score };
    })
    .filter(({ score }) => score > 0)
    .sort((a, b) => b.score - a.score || a.entry.id.localeCompare(b.entry.id))
    .slice(0, limit)
    .map(({ entry }) => ({
      id: entry.id,
      title: entry.title,
      sourceUrl: entry.sourceUrl,
      publishedAt: entry.publishedAt,
      protocol: entry.protocol,
      outcome: entry.outcome,
      excerpt: entry.excerpt,
    }));
}

