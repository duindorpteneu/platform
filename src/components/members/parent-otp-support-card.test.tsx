// @vitest-environment jsdom

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { ParentOtpSupportCard } from "./parent-otp-support-card";

const mocks = vi.hoisted(() => ({ refresh: vi.fn() }));

vi.mock("next/navigation", () => ({
  useRouter: () => ({ refresh: mocks.refresh }),
}));

const support = {
  parentAccountId: "11111111-1111-4111-8111-111111111111",
  status: "active" as const,
  loginEmailMasked: "o****@example.nl",
  lastCodeRequestedAt: "2026-08-21T15:00:00.000Z",
  lastDeliveryAttemptAt: "2026-08-21T15:00:02.000Z",
  lastDeliveryStatus: "provider_accepted" as const,
  codeExpiresAt: "2026-08-21T15:10:00.000Z",
  lastSuccessfulLoginAt: null,
  linkedChildren: [{
    memberId: "22222222-2222-4222-8222-222222222222",
    memberSeasonId: "33333333-3333-4333-8333-333333333333",
    memberName: "Voorbeeld Lid",
    team: "JO11-1",
  }],
};

describe("ParentOtpSupportCard", () => {
  const roots: Array<ReturnType<typeof createRoot>> = [];

  beforeAll(() => {
    vi.stubGlobal("React", React);
    (globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean })
      .IS_REACT_ACT_ENVIRONMENT = true;
  });

  afterEach(() => {
    for (const root of roots.splice(0)) act(() => root.unmount());
    mocks.refresh.mockReset();
  });

  it("toont alleen het gemaskeerde adres en waarschuwt vóór intrekken", async () => {
    const element = document.createElement("div");
    const root = createRoot(element);
    roots.push(root);

    await act(async () => root.render(<ParentOtpSupportCard support={support} />));

    expect(element.textContent).toContain("o****@example.nl");
    expect(element.textContent).not.toContain("ouder@example.nl");
    expect(element.textContent).toContain("Geaccepteerd door mailserver");
    expect(element.textContent).toContain("Gekoppelde kinderen1");
    expect(element.textContent).not.toContain("vervalt de huidige verificatiecode");

    const resetButton = Array.from(element.querySelectorAll("button")).find(
      (button) => button.textContent?.includes("Alle codes intrekken"),
    );
    await act(async () => resetButton?.click());

    expect(element.textContent).toContain(
      "Hiermee vervalt de huidige verificatiecode op alle apparaten.",
    );
    expect(element.textContent).toContain("Intrekken en sturen");
  });
});
