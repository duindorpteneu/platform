import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

const root = path.resolve(import.meta.dirname, "../..");

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

describe("browserbranding", () => {
  it("gebruikt het canonieke logo als geldig root- en Apple-icoon", () => {
    const layout = readFileSync(path.join(root, "src/app/layout.tsx"), "utf8");
    expect(layout).toContain('url: "/uitgifte/icon-192.png"');
    expect(layout).toContain('sizes: "192x192"');
    expect(layout).toContain('url: "/uitgifte/apple-touch-icon.png"');
    expect(layout).toContain('sizes: "180x180"');
    expect(layout).toContain("getPublishedBrandCssVariables");
    expect(pngDimensions("public/uitgifte/icon-192.png")).toEqual({
      width: 192,
      height: 192,
    });
    expect(pngDimensions("public/uitgifte/apple-touch-icon.png")).toEqual({
      width: 180,
      height: 180,
    });
  });
});
