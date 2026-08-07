import {
  readdirSync,
  readFileSync,
} from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

const sourceRoot = path.resolve("src");
const centralLogger = path.resolve(
  "src/server/security/logger.ts",
);

function sourceFiles(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const candidate = path.join(directory, entry.name);
    if (entry.isDirectory()) return sourceFiles(candidate);
    if (
      !entry.isFile()
      || !/\.(?:ts|tsx|js|jsx|mjs)$/u.test(entry.name)
      || /\.(?:test|spec)\.[^.]+$/u.test(entry.name)
    ) {
      return [];
    }
    return [candidate];
  });
}

describe("application logging architecture", () => {
  it("keeps free-text process output behind the allowlist logger", () => {
    const violations = sourceFiles(sourceRoot).filter((file) => {
      if (path.resolve(file) === centralLogger) return false;
      const source = readFileSync(file, "utf8");
      return /\bconsole\.(?:debug|error|info|log|warn)\s*\(/u.test(source)
        || /\bprocess\.(?:stdout|stderr)\.write\s*\(/u.test(source);
    });
    expect(violations).toEqual([]);
  });

  it("keeps the central logger field allowlist free of raw request material", () => {
    const logger = readFileSync(centralLogger, "utf8");
    expect(logger).toContain("sanitizeFields");
    expect(logger).not.toMatch(
      /\b(?:body|cookie|email|headers|memberName|payload|stack|token)\??:\s*/u,
    );
    expect(logger).not.toContain("error.message");
  });
});
