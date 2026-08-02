import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

function filesBelow(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    return entry.isDirectory() ? filesBelow(path) : [path];
  });
}

const apiRoutes = filesBelow(join(process.cwd(), "src/app/api"))
  .filter((path) => path.endsWith("/route.ts"));

describe("API body-policy architecture", () => {
  it("heeft geen directe, onbegrensde inbound bodyconsumers", () => {
    const offenders = apiRoutes.filter((path) => {
      const source = readFileSync(path, "utf8");
      return /\brequest\.(?:json|text|formData|arrayBuffer|blob)\s*\(/.test(source);
    });
    expect(offenders).toEqual([]);
  });

  it("vereist een expliciete policy bij iedere begrensde JSON- of tekstreader", () => {
    const offenders = apiRoutes.filter((path) => {
      const source = readFileSync(path, "utf8");
      return /\bread(?:Json|Text)Request\s*\(\s*request\s*\)/.test(source);
    });
    expect(offenders).toEqual([]);
  });

  it("koppelt iedere inhoudsloze browsermutatie aan een echte nul-byte reader", () => {
    const offenders = apiRoutes.filter((path) => {
      const source = readFileSync(path, "utf8");
      return /guardBrowserMutation\s*\(\s*request\s*,\s*\{\s*body:\s*false\s*\}/.test(source)
        && !/\breadEmptyRequest\s*\(\s*request\s*\)/.test(source);
    });
    expect(offenders).toEqual([]);
  });

  it("geeft iedere muterende route een expliciete bodydispositie", () => {
    const offenders = apiRoutes.filter((path) => {
      const source = readFileSync(path, "utf8");
      if (!/export async function (?:POST|PATCH|DELETE)\s*\(/.test(source)) return false;
      return !/\bread(?:Json|Text|Body|Empty)Request\s*\(/.test(source)
        && !/\bextractMollieWebhookPaymentId\s*\(/.test(source);
    });
    expect(offenders).toEqual([]);
  });
});
