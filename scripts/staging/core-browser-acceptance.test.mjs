import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  databaseTargetFromEnvironment,
  safeA11yFailureSummary,
  stablePhaseBFailureCode,
  targetFromEnvironment,
  verifyIssuanceBackofficeBoundary,
  verifyIssuanceLanding,
} from "./core-browser-acceptance.mjs";

const valid = {
  STAGING_BASE_URL: "https://staging-duindorp.dgwebservices.nl",
  SUPABASE_PROJECT_REF: "dxbdjtbyghsovlrdcwcr",
  RELEASE_SHA: "a".repeat(40),
  ARTIFACT_DIGEST: `sha256:${"b".repeat(64)}`,
  CONFIRMATION: "STAGING-CORE",
};
const STAGING_REF = "dxbdjtbyghsovlrdcwcr";

describe("staging core target", () => {
  it("accepts only the canonical staging identity", () => {
    expect(targetFromEnvironment(valid).projectRef).toBe("dxbdjtbyghsovlrdcwcr");
    expect(() => targetFromEnvironment({ ...valid, STAGING_BASE_URL: "https://duindorp.dgwebservices.nl" })).toThrow("STAGING_TARGET_INVALID");
    expect(() => targetFromEnvironment({ ...valid, SUPABASE_PROJECT_REF: "wobcbufmmputydtzemyu" })).toThrow("STAGING_TARGET_INVALID");
  });

  it("requires an exact release and confirmation", () => {
    expect(() => targetFromEnvironment({ ...valid, RELEASE_SHA: "main" })).toThrow("RELEASE_SHA_INVALID");
    expect(() => targetFromEnvironment({ ...valid, ARTIFACT_DIGEST: "sha256:short" })).toThrow("ARTIFACT_DIGEST_INVALID");
    expect(() => targetFromEnvironment({ ...valid, CONFIRMATION: "yes" })).toThrow("CONFIRMATION_INVALID");
    expect(targetFromEnvironment({
      ...valid,
      CONFIRMATION: "STAGING-PHASE-B",
      VERIFY_PHASE_B_SURFACES: "1",
    }).verifyPhaseBSurfaces).toBe(true);
    expect(() => targetFromEnvironment({
      ...valid,
      VERIFY_PHASE_B_SURFACES: "1",
    })).toThrow("CONFIRMATION_INVALID");
  });

  it("accepts only a PostgreSQL URL bound to the staging project", () => {
    expect(databaseTargetFromEnvironment({
      SUPABASE_DB_URL: `postgresql://postgres.${STAGING_REF}:secret@aws-0-eu-central-1.pooler.supabase.com:6543/postgres?sslmode=require`,
    })).toContain(STAGING_REF);
    for (const databaseUrl of [
      "postgresql://postgres.production:secret@aws-0-eu-central-1.pooler.supabase.com:6543/postgres?sslmode=require",
      `postgresql://postgres.${STAGING_REF}:secret@pooler.supabase.com:6543/postgres?sslmode=require`,
      `postgresql://postgres.${STAGING_REF}:secret@aws-0-eu-central-1.pooler.supabase.com:6543/postgres?sslmode=disable`,
      `postgresql://postgres.${STAGING_REF}:secret@aws-0-eu-central-1.pooler.supabase.com:6543/postgres?sslmode=require&host=evil.invalid`,
      `postgresql://postgres.${STAGING_REF}:secret@aws-0-eu-central-1.pooler.supabase.com:6543/postgres?sslmode=require&sslmode=verify-full`,
      "https://dxbdjtbyghsovlrdcwcr.supabase.co",
    ]) {
      expect(() => databaseTargetFromEnvironment({
        SUPABASE_DB_URL: databaseUrl,
      })).toThrow();
    }
  });

  it("beperkt de databasecredential tot core en Phase-B fixturestappen", () => {
    for (const workflowName of [
      "staging-core-acceptance.yml",
      "staging-phase-b-acceptance.yml",
    ]) {
      const workflow = readFileSync(
        new URL(`../../.github/workflows/${workflowName}`, import.meta.url),
        "utf8",
      );
      const fixture = workflow.indexOf(
        "node scripts/staging/core-browser-acceptance.mjs",
      );
      expect(fixture).toBeGreaterThan(0);
      expect(workflow).not.toContain(
        "node scripts/staging/require-database-tls.mjs",
      );
      expect(workflow.match(
        /SUPABASE_DB_URL: \$\{\{ secrets\.SUPABASE_DB_URL \}\}/gu,
      )).toHaveLength(2);
    }
  });

  it("houdt container-stdin open zodat psql de profielmutatie werkelijk uitvoert", () => {
    const source = readFileSync(new URL("./core-browser-acceptance.mjs", import.meta.url), "utf8");
    expect(source).toContain('"run", "--rm", "--interactive"');
    expect(source).toContain("input: statement");
  });

  it("controleert de echte instellingenpagina zonder op het document-load-event te blokkeren", () => {
    const source = readFileSync(new URL("./core-browser-acceptance.mjs", import.meta.url), "utf8");
    expect(source).toContain("window.location.assign(url)");
    expect(source).toContain("ADMIN_SETTINGS_WORKSPACE_UNAVAILABLE");
    expect(source).toContain("ADMIN_SETTINGS_RENDER_TIMEOUT");
  });

  it("controleert het settings-RPC met hetzelfde echte AAL2-token zonder het token te loggen", () => {
    const source = readFileSync(new URL("./core-browser-acceptance.mjs", import.meta.url), "utf8");
    expect(source).toContain("get_settings_workspace_v3");
    expect(source).toContain("settingsWorkspaceSchema.safeParse(payload)");
    expect(source).toContain("syncResponse.request().postDataJSON()");
    expect(source).toContain("ADMIN_SETTINGS_RPC_");
    expect(source).not.toContain("process.stdout.write(accessToken");
  });

  it("loopt de gedeployde Phase-B-oppervlakken en supplier-privacycopy na", () => {
    const source = readFileSync(
      new URL("./core-browser-acceptance.mjs", import.meta.url),
      "utf8",
    );
    for (const path of [
      "/backoffice/pakketten",
      "/backoffice/actiepunten",
      "/backoffice/leden",
      "/backoffice/leveringen",
      "/backoffice/emails",
      "/backoffice/instellingen",
      "/leverancier/login",
    ]) {
      expect(source).toContain(path);
    }
    expect(source).toContain(
      "assertNoAutomatedA11yViolations",
    );
    expect(source).toContain(
      "uitsluitend geaggregeerde aantallen",
    );
    for (const codeTemplate of [
      "PHASE_B_${surface.code}_NAVIGATION_FAILED",
      "PHASE_B_${surface.code}_HTTP_FAILED",
      "PHASE_B_${surface.code}_HEADING_FAILED",
      "PHASE_B_${surface.code}_A11Y_FAILED",
      "PHASE_B_${surface.code}_A11Y_EXECUTION_FAILED",
    ]) {
      expect(source).toContain(codeTemplate);
    }
    for (const code of [
      "PHASE_B_RELEASE_CONTROLS_FAILED",
      "PHASE_B_SUPPLIER_PRIVACY_FAILED",
      "PHASE_B_DASHBOARD_RETURN_FAILED",
    ]) {
      expect(source).toContain(code);
    }
    expect(source).toContain(
      'await page.waitForURL(`${target.baseUrl}/backoffice`',
    );
    expect(source).toContain(
      'await page.getByText("Operationeel dashboard"',
    );
    expect(source).toContain(
      'await page.getByRole("heading", { level: 1 }).waitFor();',
    );
  });

  it("reduceert een a11y-fout tot een PII-vrije regel, impact en telling", () => {
    expect(safeA11yFailureSummary(new Error(
      "A11Y_STAGING_PAKKETTEN_color-contrast:serious:2:div:implicit:no-aria:fixture-member-name",
    ))).toBe("color-contrast:serious:2");
    expect(safeA11yFailureSummary(new Error("persoonlijke inhoud"))).toBeNull();
    expect(safeA11yFailureSummary("geen error-object")).toBeNull();
  });

  it("behoudt een bekende Phase-B-foutcode en maskeert overige fouten", () => {
    expect(stablePhaseBFailureCode(
      new Error("PHASE_B_SUPPLIER_PRIVACY_COPY_INVALID"),
      "PHASE_B_SUPPLIER_PRIVACY_FAILED",
    )).toBe("PHASE_B_SUPPLIER_PRIVACY_COPY_INVALID");
    expect(stablePhaseBFailureCode(
      new Error("mogelijke persoonlijke inhoud"),
      "PHASE_B_SUPPLIER_PRIVACY_FAILED",
    )).toBe("PHASE_B_SUPPLIER_PRIVACY_FAILED");
  });

  it("laat de MFA-scannerlanding aflopen voordat de backoffice-rolgrens wordt beproefd", async () => {
    const events = [];
    const page = {
      waitForURL: async (url) => { events.push(`wait:${url}`); },
      getByRole: () => ({
        waitFor: async () => { events.push("heading:Uitgifte"); },
      }),
      goto: async (url) => {
        events.push(`goto:${url}`);
        return { ok: () => true };
      },
    };
    const target = { baseUrl: valid.STAGING_BASE_URL };

    await verifyIssuanceLanding(page, target);
    await verifyIssuanceBackofficeBoundary(page, target);

    expect(events).toEqual([
      `wait:${valid.STAGING_BASE_URL}/uitgifte`,
      "heading:Uitgifte",
      `goto:${valid.STAGING_BASE_URL}/backoffice`,
      `wait:${valid.STAGING_BASE_URL}/uitgifte`,
      "heading:Uitgifte",
    ]);
  });

  it("geeft PII-vrije stabiele foutcodes voor scannerlanding en rolgrens", async () => {
    const failingLanding = {
      waitForURL: async () => { throw new Error("persoonlijke browserfout"); },
    };
    await expect(verifyIssuanceLanding(
      failingLanding,
      { baseUrl: valid.STAGING_BASE_URL },
    )).rejects.toThrow("ISSUANCE_LANDING_FAILED");

    const rejectedBoundary = {
      goto: async () => ({ ok: () => false }),
    };
    await expect(verifyIssuanceBackofficeBoundary(
      rejectedBoundary,
      { baseUrl: valid.STAGING_BASE_URL },
    )).rejects.toThrow("ISSUANCE_BOUNDARY_HTTP_FAILED");
  });
});
