import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { Hex } from "viem";

export interface DecisionStore {
  put(hash: Hex, canonicalJson: string): Promise<void>;
  get(hash: Hex): Promise<string | null>;
}

export class FileDecisionStore implements DecisionStore {
  constructor(private readonly directory: string) {}

  private fileFor(hash: Hex): string {
    return join(this.directory, `${hash.slice(2).toLowerCase()}.json`);
  }

  async put(hash: Hex, canonicalJson: string): Promise<void> {
    await mkdir(this.directory, { recursive: true });
    await writeFile(this.fileFor(hash), canonicalJson, { encoding: "utf8", flag: "wx" }).catch(async (error: NodeJS.ErrnoException) => {
      if (error.code !== "EEXIST") throw error;
      // A decision hash is content-addressed. Rewriting an existing path is unnecessary and
      // would make an accidental hash collision harder to notice.
    });
  }

  async get(hash: Hex): Promise<string | null> {
    try {
      return await readFile(this.fileFor(hash), "utf8");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
      throw error;
    }
  }
}

export class MemoryDecisionStore implements DecisionStore {
  private readonly values = new Map<string, string>();

  async put(hash: Hex, canonicalJson: string): Promise<void> {
    this.values.set(hash.toLowerCase(), canonicalJson);
  }

  async get(hash: Hex): Promise<string | null> {
    return this.values.get(hash.toLowerCase()) ?? null;
  }
}

