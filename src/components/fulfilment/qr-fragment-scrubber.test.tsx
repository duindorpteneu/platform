// @vitest-environment jsdom

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { QrFragmentScrubber } from "./qr-fragment-scrubber";

describe("QrFragmentScrubber", () => {
  const roots: Array<ReturnType<typeof createRoot>> = [];

  beforeAll(() => {
    (globalThis as typeof globalThis & {
      IS_REACT_ACT_ENVIRONMENT: boolean;
    }).IS_REACT_ACT_ENVIRONMENT = true;
  });

  afterAll(() => {
    (globalThis as typeof globalThis & {
      IS_REACT_ACT_ENVIRONMENT: boolean;
    }).IS_REACT_ACT_ENVIRONMENT = false;
  });

  afterEach(() => {
    for (const root of roots.splice(0)) {
      act(() => root.unmount());
    }
    window.history.replaceState(null, "", "/");
  });

  it("verwijdert locatorfragment en query uit de huidige history-entry", () => {
    window.history.replaceState(
      { source: "test" },
      "",
      `/qr?legacy=verboden#q2.k1.${"a".repeat(43)}`,
    );
    const element = document.createElement("div");
    const root = createRoot(element);
    roots.push(root);
    act(() => root.render(<QrFragmentScrubber />));
    expect(window.location.pathname).toBe("/qr");
    expect(window.location.search).toBe("");
    expect(window.location.hash).toBe("");
    expect(window.history.state).toEqual({ source: "test" });
  });
});
