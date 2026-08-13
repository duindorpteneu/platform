import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

const source = readFileSync(
  path.join(import.meta.dirname, "test-platform-browser.mjs"),
  "utf8",
);
const dynamicImportSource = readFileSync(
  path.join(import.meta.dirname, "test-dynamic-import-browser.mjs"),
  "utf8",
);
const parentAccessSource = readFileSync(
  path.join(import.meta.dirname, "test-parent-access-browser.mjs"),
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

  it("herschept de volledige disposable Supabase-stack rond de browsermatrix", () => {
    expect(source).toContain("function recreateLocalSupabaseStack()");
    expect(source).toContain('["stop", "--no-backup"]');
    expect(source).toContain('["start"]');
    expect(source.match(/recreateLocalSupabaseStack\(\)/gu)).toHaveLength(3);
    expect(source).not.toContain('spawnSync("pnpm", ["db:reset"]');
  });

  it("wacht eventgebonden op de Mail-v2-preview zonder retry", () => {
    expect(source).toContain(
      "const mailPreviewFinished = await mailPreviewResponse.finished();",
    );
    expect(source).toContain(
      'for (const key of ["subject", "preheader", "html", "text"])',
    );
    expect(source).toContain(
      'const mailPreviewSection = page.locator("section").filter',
    );
    expect(source).toContain(
      'mailPreviewSection.getByText("Fictieve preview", { exact: true }).waitFor',
    );
    expect(source).toContain('timeout: 30_000');
    expect(source).toContain(
      "'[role=\"group\"][aria-label=\"Previewmodus\"] button[aria-label=\"Desktop\"]'",
    );
    expect(source).toContain(
      'await desktopPreviewMode.getAttribute("aria-pressed") !== "true"',
    );
    expect(source).toContain(
      'await mailPreviewFrame.getAttribute("srcdoc") !== mailPreviewPayload.html',
    );
    expect(source.match(
      /page\.getByRole\("button", \{ name: "Preview", exact: true \}\)\.click\(\)/gu,
    )).toHaveLength(1);
  });

  it("maakt de lokale a11y-flow via echte Supabase AAL2 deterministisch", () => {
    expect(source).toContain("const interactiveStaffLogin");
    expect(source).toContain("const directAal2StaffLogin");
    expect(source).toContain(
      'import { createBrowserClient } from "@supabase/ssr";',
    );
    expect(source).toContain("const localAuthCookies = new Map()");
    expect(source).toContain("createBrowserClient(local.API_URL, local.ANON_KEY");
    expect(source).toContain("localMfaClient.auth.signInWithPassword");
    expect(source).toContain("localMfaClient.auth.mfa.enroll");
    expect(source).toContain("challengeAndVerify");
    expect(source).toContain("await page.context().addCookies(browserAuthCookies)");
    expect(source).toContain('fetch("/api/staff-auth/session"');
    expect(source).toContain(
      "De lokale interactieve MFA-flow kon niet veilig worden vervangen.",
    );
    expect(source).toContain(
      'assertNoAutomatedA11yViolations(page, "deliveries_mobile")',
    );
    expect(source).toContain(
      'assertNoAutomatedA11yViolations(page, "settings_mobile")',
    );
  });

  it("maakt ook de dynamische-importbrowserflow via echte AAL2 deterministisch", () => {
    expect(dynamicImportSource).toContain(
      'import { createBrowserClient } from "@supabase/ssr";',
    );
    expect(dynamicImportSource).toContain("localMfaClient.auth.signInWithPassword");
    expect(dynamicImportSource).toContain("localMfaClient.auth.mfa.enroll");
    expect(dynamicImportSource).toContain("challengeAndVerify");
    expect(dynamicImportSource).toContain("await context.addCookies(browserAuthCookies)");
    expect(dynamicImportSource).toContain('fetch("/api/staff-auth/session"');
    expect(dynamicImportSource).not.toContain(
      'await page.waitForURL(`${baseUrl}/staff/mfa`)',
    );
  });

  it("maakt de portaaltoegang-browserflow via echte AAL2 deterministisch", () => {
    expect(parentAccessSource).toContain(
      'import { createBrowserClient } from "@supabase/ssr";',
    );
    expect(parentAccessSource).toContain("const localAuthCookies = new Map()");
    expect(parentAccessSource).toContain("localMfaClient.auth.signInWithPassword");
    expect(parentAccessSource).toContain("localMfaClient.auth.mfa.enroll");
    expect(parentAccessSource).toContain("challengeAndVerify");
    expect(parentAccessSource).toContain("await context.addCookies(browserAuthCookies)");
    expect(parentAccessSource).toContain('fetch("/api/staff-auth/session"');
    expect(parentAccessSource).not.toContain(
      'await page.waitForURL(`${baseUrl}/staff/mfa`)',
    );
    expect(parentAccessSource).toContain(
      "await page.setViewportSize({ width: 390, height: 844 })",
    );
    expect(parentAccessSource).toContain(
      "parent_access_phase_b_${label}",
    );
  });
});
