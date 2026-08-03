import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

const root = path.resolve(import.meta.dirname, "../../..");
const source = (relative: string) => readFileSync(
  path.join(root, relative),
  "utf8",
);

function pngDimensions(relative: string) {
  const image = readFileSync(path.join(root, relative));
  expect(image.subarray(0, 8)).toEqual(
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
  );
  return {
    width: image.readUInt32BE(16),
    height: image.readUInt32BE(20),
  };
}

describe("uitgiftescanner PWA-contract", () => {
  it("beperkt installatie, start en besturing exact tot /uitgifte", () => {
    const manifest = JSON.parse(
      source("public/uitgifte/manifest.webmanifest"),
    ) as {
      id: string;
      scope: string;
      start_url: string;
      display: string;
      icons: Array<{ sizes: string; src: string }>;
    };
    expect(manifest).toMatchObject({
      id: "/uitgifte",
      scope: "/uitgifte",
      start_url: "/uitgifte",
      display: "standalone",
    });
    expect(manifest.icons.map((icon) => icon.sizes)).toEqual([
      "192x192",
      "512x512",
    ]);
    expect(pngDimensions("public/uitgifte/icon-192.png")).toEqual({
      width: 192,
      height: 192,
    });
    expect(pngDimensions("public/uitgifte/icon-512.png")).toEqual({
      width: 512,
      height: 512,
    });
    expect(
      pngDimensions("public/uitgifte/apple-touch-icon.png"),
    ).toEqual({ width: 180, height: 180 });
  });

  it("is netwerk-only en bewaart geen QR, grant of PII client-side", () => {
    const worker = source("public/uitgifte/scanner-sw.js");
    expect(worker).toContain('fetch(event.request, { cache: "no-store" })');
    expect(worker).toContain("SCANNER_NETWORK_REQUIRED");
    expect(worker).not.toMatch(
      /\bcaches\b|\bindexedDB\b|\blocalStorage\b|backgroundSync|sync\.register/,
    );
    const workspace = source(
      "src/components/fulfilment/issuance-workspace.tsx",
    );
    expect(workspace).toContain('scope: "/uitgifte"');
    expect(workspace).toContain("exchangeAbortRef.current?.abort()");
    expect(workspace).toContain("commitAbortRef.current?.abort()");
    expect(workspace).not.toMatch(
      /\blocalStorage\b|\bsessionStorage\b|\bindexedDB\b|\bcaches\./,
    );
  });

  it("laat uitsluitend de PII-vrije PWA-assets publiek en geeft de SW zijn smalle scope", () => {
    const middleware = source("src/middleware.ts");
    for (const asset of [
      "/uitgifte/apple-touch-icon.png",
      "/uitgifte/icon-192.png",
      "/uitgifte/icon-512.png",
      "/uitgifte/manifest.webmanifest",
      "/uitgifte/scanner-sw.js",
    ]) expect(middleware).toContain(`"${asset}"`);
    const config = source("next.config.ts");
    expect(config).toContain('source: "/uitgifte/scanner-sw.js"');
    expect(config).toContain('key: "Service-Worker-Allowed"');
    expect(config).toContain('value: "/uitgifte"');
    expect(config).toContain('value: "no-store"');
  });
});
