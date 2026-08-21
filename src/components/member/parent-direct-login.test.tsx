// @vitest-environment jsdom

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { ParentDirectLogin } from "./parent-direct-login";

const mocks = vi.hoisted(() => ({ replace: vi.fn() }));

vi.mock("next/navigation", () => ({
  useRouter: () => ({ replace: mocks.replace }),
}));

describe("ParentDirectLogin", () => {
  const roots: Array<ReturnType<typeof createRoot>> = [];

  beforeAll(() => {
    vi.stubGlobal("React", React);
    (globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean })
      .IS_REACT_ACT_ENVIRONMENT = true;
  });

  afterEach(() => {
    for (const root of roots.splice(0)) act(() => root.unmount());
    mocks.replace.mockReset();
    vi.unstubAllGlobals();
    window.history.replaceState(null, "", "/");
  });

  it("wist het fragment vóór het bewijs same-origin wordt gepost", async () => {
    const events: string[] = [];
    const credential = `v1.11111111-1111-4111-8111-111111111111.${"A".repeat(43)}`;
    window.history.replaceState(null, "", `/login/direct#${credential}`);
    const originalReplaceState = window.history.replaceState.bind(window.history);
    vi.spyOn(window.history, "replaceState").mockImplementation((...args) => {
      events.push("fragment-removed");
      return originalReplaceState(...args);
    });
    vi.stubGlobal("fetch", vi.fn(async (url: string, init?: RequestInit) => {
      events.push("fetch");
      expect(window.location.hash).toBe("");
      expect(url).toBe("/api/parent-auth/verify-direct");
      expect(init).toMatchObject({
        method: "POST",
        cache: "no-store",
        credentials: "same-origin",
      });
      expect(JSON.parse(String(init?.body))).toEqual({ credential });
      return new Response(JSON.stringify({ status: "verified" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }));
    const element = document.createElement("div");
    const root = createRoot(element);
    roots.push(root);

    await act(async () => {
      root.render(<ParentDirectLogin />);
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(events.slice(0, 2)).toEqual(["fragment-removed", "fetch"]);
    expect(mocks.replace).toHaveBeenCalledWith("/mijn-tenue");
  });
});
