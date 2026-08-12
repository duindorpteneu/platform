import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

const source = readFileSync(
  path.join(import.meta.dirname, "test-platform-browser.mjs"),
  "utf8",
);

describe("platform browser Supabase readiness", () => {
  it("pollt de echte Auth-API tot een begrensde 120-seconden-deadline", () => {
    expect(source).toContain(
      'const authReadinessNeedle = "const existing = await admin.auth.admin.listUsers();";',
    );
    expect(source).toContain("const authReadyDeadline = Date.now() + 120_000;");
    expect(source).toContain("while (Date.now() < authReadyDeadline)");
    expect(source).toContain("admin.auth.admin.listUsers({ page: 1, perPage: 1 })");
    expect(source).toContain("existing = probe;");
    expect(source).toContain("Number.isInteger(probe.error.status)");
    expect(source).not.toContain("attempt < 120");
  });

  it("wacht eventgebonden op de Mail-v2-preview zonder retry", () => {
    expect(source).toContain(
      "const mailPreviewFinished = await mailPreviewResponse.finished();",
    );
    expect(source).toContain(
      'for (const key of ["subject", "preheader", "html", "text"])',
    );
    expect(source).toContain(
      'page.getByText("Fictieve preview", { exact: true }).waitFor',
    );
    expect(source).toContain('timeout: 30_000');
    expect(source).toContain(
      'page.getByRole("button", { name: "Desktop", exact: true }).click()',
    );
    expect(source.match(
      /page\.getByRole\("button", \{ name: "Preview", exact: true \}\)\.click\(\)/gu,
    )).toHaveLength(1);
  });
});
