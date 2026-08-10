import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const runner = readFileSync(
  new URL("./run-supabase.mjs", import.meta.url),
  "utf8",
);
const packageJson = JSON.parse(
  readFileSync(new URL("../package.json", import.meta.url), "utf8"),
) as { scripts: Record<string, string> };

describe("Supabase CLI command boundary", () => {
  it("prefers only an absolute existing verified override", () => {
    expect(runner).toContain("SUPABASE_CLI_BINARY_OVERRIDE");
    expect(runner).toContain("path.isAbsolute(configured)");
    expect(runner).toContain("lstatSync(configured");
    expect(runner).not.toContain("shell: true");
  });

  it.each(["supabase:start", "supabase:stop", "db:reset", "test:db"])(
    "routes %s through the command boundary",
    (name) => {
      expect(packageJson.scripts[name]).toMatch(
        /^node scripts\/run-supabase\.mjs /u,
      );
    },
  );
});
