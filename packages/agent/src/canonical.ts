import { keccak256, stringToHex, type Hex } from "viem";

/**
 * Canonical JSON for the decision commitment.
 *
 * Decision documents intentionally encode every chain-sized integer as a decimal string, so
 * this implementation only has to handle the RFC 8785 JSON value types and never risks a
 * JavaScript number changing the committed value. Object keys are ASCII schema keys and are
 * sorted by JavaScript's UTF-16 code-unit ordering, which is the ordering used by JCS.
 */
export function canonicalJson(value: unknown): string {
  if (value === null) return "null";
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new TypeError("canonical JSON cannot contain a non-finite number");
    return JSON.stringify(value);
  }
  if (typeof value === "bigint") {
    throw new TypeError("canonical JSON cannot contain a bigint; encode it as a decimal string");
  }
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>)
      .filter(([, item]) => item !== undefined)
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
    return `{${entries.map(([key, item]) => `${JSON.stringify(key)}:${canonicalJson(item)}`).join(",")}}`;
  }
  throw new TypeError(`unsupported canonical JSON value: ${typeof value}`);
}

export function hashCanonicalJson(value: unknown): Hex {
  return keccak256(stringToHex(canonicalJson(value)));
}

