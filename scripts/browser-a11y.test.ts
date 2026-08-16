import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

const source = readFileSync(
  path.join(import.meta.dirname, "browser-a11y.mjs"),
  "utf8",
);
const globalStyles = readFileSync(
  path.join(import.meta.dirname, "../src/app/globals.css"),
  "utf8",
);
const emailSurfaceSources = [
  "../src/components/email/email-workspace.tsx",
  "../src/components/email/mail-v2-editor.tsx",
  "../src/components/email/mail-v2-reminders-panel.tsx",
  "../src/components/email/mail-v2-workspace.tsx",
].map((relativePath) => readFileSync(
  path.join(import.meta.dirname, relativePath),
  "utf8",
));

describe("browser accessibility gate", () => {
  it("uses WCAG 2.2 AA without exclusions or raw DOM output", () => {
    for (const tag of [
      "wcag2a",
      "wcag2aa",
      "wcag21a",
      "wcag21aa",
      "wcag22aa",
    ]) {
      expect(source).toContain(`"${tag}"`);
    }
    expect(source).not.toContain(".setLegacyMode(true)");
    expect(source).not.toContain(".exclude(");
    expect(source).not.toContain("violation.nodes.map");
    expect(source).not.toContain(".html");
    expect(source).not.toContain("textContent");
  });

  it("enforces and probes the reduced-motion operating-system preference", () => {
    expect(globalStyles).toContain(
      "@media (prefers-reduced-motion: reduce)",
    );
    expect(globalStyles).toContain(
      "animation-duration: 0.01ms !important",
    );
    expect(globalStyles).toContain(
      "transition-duration: 0.01ms !important",
    );
    expect(source).toContain(
      'page.emulateMedia({ reducedMotion: "reduce" })',
    );
    expect(source).toContain(
      'page.emulateMedia({ reducedMotion: "no-preference" })',
    );
  });

  it("checks the e-mail center while that route is still rendered", () => {
    const platformHarness = readFileSync(
      path.join(import.meta.dirname, "test-platform-browser.mjs"),
      "utf8",
    );
    expect(platformHarness).toContain(
      'assertNoAutomatedA11yViolations(page, "email_center")',
    );
    expect(platformHarness).toMatch(
      /assertNoAutomatedA11yViolations\(page, "email_center"\);'[\s\S]{0,200}const emailDimensions/u,
    );
  });

  it("does not animate simultaneous foreground and background state changes in the e-mail center", () => {
    for (const emailSource of emailSurfaceSources) {
      expect(emailSource).not.toMatch(/\btransition(?=\s)/u);
    }
    expect(emailSurfaceSources.join("\n")).toContain("transition-[width]");
  });

  it("keeps completed mail-cutover success states above the normal-text contrast threshold", () => {
    expect(emailSurfaceSources.join("\n")).not.toContain(
      "bg-emerald-100 text-success",
    );
    expect(emailSurfaceSources.join("\n")).toContain(
      "bg-emerald-50 text-success",
    );
  });
});
