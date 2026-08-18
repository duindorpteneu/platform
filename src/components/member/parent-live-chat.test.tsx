// @vitest-environment jsdom

import { readFileSync } from "node:fs";
import path from "node:path";
import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { ParentLiveChat } from "./parent-live-chat";

const source = readFileSync(
  path.join(import.meta.dirname, "parent-live-chat.tsx"),
  "utf8",
);

describe("ParentLiveChat", () => {
  const roots: Array<ReturnType<typeof createRoot>> = [];

  beforeAll(() => {
    vi.stubGlobal("React", React);
    (globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean })
      .IS_REACT_ACT_ENVIRONMENT = true;
  });

  afterAll(() => {
    vi.unstubAllGlobals();
    (globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean })
      .IS_REACT_ACT_ENVIRONMENT = false;
  });

  afterEach(() => {
    for (const root of roots.splice(0)) act(() => root.unmount());
    document.head.querySelectorAll("script[data-duindorp-livechat]").forEach((script) => script.remove());
    window.sessionStorage.clear();
    delete window.__lc;
    delete window.LiveChatWidget;
  });

  it("laadt de externe provider pas na expliciete toestemming", async () => {
    const element = document.createElement("div");
    const root = createRoot(element);
    roots.push(root);

    await act(async () => root.render(<ParentLiveChat />));
    expect(window.__lc).toBeUndefined();
    expect(element.textContent).toContain("Chat met ons");

    const open = element.querySelector<HTMLButtonElement>("button[aria-expanded]");
    await act(async () => open?.click());
    expect(element.textContent).toContain("functionele cookies");

    const start = [...element.querySelectorAll("button")]
      .find((button) => button.textContent === "Chat starten");
    await act(async () => start?.click());

    expect(window.sessionStorage.getItem("duindorp_livechat_consent")).toBe("accepted");
    expect(window.__lc).toMatchObject({
      asyncInit: true,
      integration_name: "manual_onboarding",
      license: 19904029,
      product_name: "livechat",
    });
    const tracking = document.head.querySelector<HTMLScriptElement>(
      'script[data-duindorp-livechat="tracking"]',
    );
    expect(tracking?.src).toBe("https://cdn.livechatinc.com/tracking.js");
    expect(window.LiveChatWidget).toBeDefined();
  });

  it("geeft geen ouder-, lid- of ordergegevens door aan LiveChat", () => {
    expect(source).not.toMatch(/set_customer_(?:email|name)|session_variables|orderId|memberId/u);
  });
});
