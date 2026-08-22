// @vitest-environment jsdom

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { MemberSizeProfile as Profile } from "@/lib/member-overview-contract";
import { MemberSizeProfile } from "./member-size-profile";

const mocks = vi.hoisted(() => ({ refresh: vi.fn() }));

vi.mock("next/navigation", () => ({
  useRouter: () => ({ refresh: mocks.refresh }),
}));

const memberId = "11111111-1111-4111-8111-111111111111";
const importedArticleId = "22222222-2222-4222-8222-222222222222";
const changedArticleId = "33333333-3333-4333-8333-333333333333";
const importedVariantId = "44444444-4444-4444-8444-444444444444";
const originalVariantId = "55555555-5555-4555-8555-555555555555";
const replacementVariantId = "66666666-6666-4666-8666-666666666666";

const importedArticle: Profile["articles"][number] = {
  id: importedArticleId,
  name: "Wedstrijdshirt",
  code: "WEDSTRSHRT",
  active: true,
  selectedVariantId: importedVariantId,
  ordered: false,
  orderLineStatus: null,
  orderLineId: null,
  selectionStatus: "imported_unconfirmed",
  selectionSource: "import",
  rawValue: "152",
  memberNote: null,
  requestedRawValue: null,
  requestedMemberNote: null,
  hasReservation: false,
  issued: false,
  editable: true,
  editBlockReason: null,
  variants: [{ id: importedVariantId, size: "152", active: true }],
};

const profile: Profile = {
  memberSeasonId: "77777777-7777-4777-8777-777777777777",
  seasonId: "88888888-8888-4888-8888-888888888888",
  seasonName: "2026-2027",
  editable: true,
  revision: "a".repeat(64),
  articles: [importedArticle],
};

describe("MemberSizeProfile", () => {
  const roots: Array<ReturnType<typeof createRoot>> = [];

  beforeEach(() => {
    vi.stubGlobal("React", React);
    (globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean })
      .IS_REACT_ACT_ENVIRONMENT = true;
  });

  afterEach(() => {
    for (const root of roots.splice(0)) act(() => root.unmount());
    mocks.refresh.mockReset();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it("bevestigt een ingevulde importmaat zonder dat de maat eerst wijzigt", async () => {
    const requestId = "99999999-9999-4999-8999-999999999999";
    vi.spyOn(globalThis.crypto, "randomUUID").mockReturnValue(requestId);
    const confirmedProfile: Profile = {
      ...profile,
      revision: "b".repeat(64),
      articles: [{
        ...importedArticle,
        selectionStatus: "confirmed",
        selectionSource: "staff",
        rawValue: null,
      }],
    };
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ sizeProfile: confirmedProfile }),
    });
    vi.stubGlobal("fetch", fetchMock);
    const element = document.createElement("div");
    const root = createRoot(element);
    roots.push(root);

    await act(async () => root.render(<MemberSizeProfile memberId={memberId} profile={profile} />));

    const confirmButton = Array.from(element.querySelectorAll("button")).find(
      (button) => button.textContent?.includes("Maten bevestigen"),
    );
    expect(confirmButton).toBeDefined();
    expect(confirmButton?.disabled).toBe(false);
    expect(element.querySelector("textarea")).toBeNull();
    expect(element.textContent).toContain("ongewijzigd bevestigd");

    await act(async () => confirmButton?.click());

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock).toHaveBeenCalledWith("/api/members/sizes", expect.objectContaining({
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Duindorp-CSRF": "same-origin" },
    }));
    const body = JSON.parse(String((fetchMock.mock.calls[0]?.[1] as RequestInit).body));
    expect(body).toMatchObject({
      memberId,
      memberSeasonId: profile.memberSeasonId,
      revision: profile.revision,
      reason: "Geïmporteerde maat bevestigd",
      requestId,
      sizes: [{ articleId: importedArticleId, variantId: importedVariantId, releaseReserved: false }],
    });
    expect(element.textContent).toContain("De geïmporteerde kledingmaten zijn bevestigd en geaudit.");
    expect(mocks.refresh).toHaveBeenCalledTimes(1);
  });

  it("blijft bij een combinatie met een echte maatwijziging een reden eisen", async () => {
    const mixedProfile: Profile = {
      ...profile,
      articles: [
        importedArticle,
        {
          ...importedArticle,
          id: changedArticleId,
          name: "Wedstrijdbroek",
          code: "WEDSTRBRK",
          selectedVariantId: originalVariantId,
          selectionStatus: "confirmed",
          selectionSource: "staff",
          rawValue: null,
          variants: [
            { id: originalVariantId, size: "152", active: true },
            { id: replacementVariantId, size: "164", active: true },
          ],
        },
      ],
    };
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    const element = document.createElement("div");
    const root = createRoot(element);
    roots.push(root);

    await act(async () => root.render(<MemberSizeProfile memberId={memberId} profile={mixedProfile} />));
    const changedSelect = element.querySelector<HTMLSelectElement>("select[aria-label='Maat Wedstrijdbroek']");
    expect(changedSelect).not.toBeNull();
    await act(async () => {
      if (!changedSelect) return;
      changedSelect.value = replacementVariantId;
      changedSelect.dispatchEvent(new Event("change", { bubbles: true }));
    });

    const saveButton = Array.from(element.querySelectorAll("button")).find(
      (button) => button.textContent?.includes("Maten opslaan"),
    );
    expect(saveButton).toBeDefined();
    expect(element.querySelector("textarea")).not.toBeNull();
    expect(element.textContent).toContain("Ongewijzigde geïmporteerde maten worden tegelijk bevestigd.");

    await act(async () => saveButton?.click());

    expect(fetchMock).not.toHaveBeenCalled();
    expect(element.textContent).toContain("Vul een korte reden voor de maatwijziging in.");
  });
});
