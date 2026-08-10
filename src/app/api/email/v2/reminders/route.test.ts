import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  save: vi.fn(),
  toggle: vi.fn(),
}));

vi.mock("@/server/email/mail-v2-reminders", () => ({
  saveMailReminderRule: mocks.save,
  setMailReminderRuleActive: mocks.toggle,
}));

import { POST } from "./route";

const correlationId = "78000000-0000-4000-8000-000000000001";
const seasonId = "78000000-0000-4000-8000-000000000002";
const ruleId = "78000000-0000-4000-8000-000000000003";
const now = "2026-08-03T20:00:00.000Z";
const savedRule = {
  id: ruleId,
  seasonId,
  templateKey: "payment_reminder",
  internalName: "Wekelijkse betaalherinnering",
  firstDelayHours: 72,
  frequencyHours: 168,
  maximumDispatches: 4,
  cooldownHours: 24,
  endAt: null,
  quietStart: "21:00",
  quietEnd: "08:00",
  timezone: "Europe/Amsterdam",
  active: false,
  revision: 1,
  dueNow: 0,
  nextDueAt: null,
  lastRunAt: null,
  lastRunStatus: null,
  createdAt: now,
  updatedAt: now,
};

function request(body: unknown) {
  return new Request("https://tenue.example/api/email/v2/reminders", {
    method: "POST",
    headers: {
      origin: "https://tenue.example",
      host: "tenue.example",
      "sec-fetch-site": "same-origin",
      "x-duindorp-csrf": "same-origin",
      "x-correlation-id": correlationId,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

const createInput = {
  action: "save" as const,
  ruleId: null,
  seasonId,
  templateKey: "payment_reminder" as const,
  expectedRevision: null,
  config: {
    internalName: "Wekelijkse betaalherinnering",
    firstDelayHours: 72,
    frequencyHours: 168,
    maximumDispatches: 4,
    cooldownHours: 24,
    endAt: null,
    quietStart: "21:00",
    quietEnd: "08:00",
  },
};

describe("POST /api/email/v2/reminders", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    mocks.save.mockReset().mockResolvedValue({
      data: savedRule,
      error: null,
    });
    mocks.toggle.mockReset().mockResolvedValue({
      data: { ...savedRule, active: true, revision: 2 },
      error: null,
    });
  });

  it("maakt een regel altijd eerst inactief aan", async () => {
    const response = await POST(request(createInput));

    expect(response.status).toBe(201);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(mocks.save).toHaveBeenCalledWith(createInput, correlationId);
    expect(await response.json()).toMatchObject({
      active: false,
      revision: 1,
    });
  });

  it("activeert alleen expliciet met reden en verwachte revisie", async () => {
    const input = {
      action: "toggle" as const,
      ruleId,
      expectedRevision: 1,
      active: true,
      reason: "Schema gecontroleerd voor dit seizoen",
    };
    const response = await POST(request(input));

    expect(response.status).toBe(200);
    expect(mocks.toggle).toHaveBeenCalledWith(input, correlationId);
  });

  it("weigert gelijke stille uren vóór de service", async () => {
    const response = await POST(request({
      ...createInput,
      config: {
        ...createInput.config,
        quietStart: "22:00",
        quietEnd: "22:00",
      },
    }));

    expect(response.status).toBe(400);
    expect(mocks.save).not.toHaveBeenCalled();
  });

  it("vertaalt revisiedrift en MFA-blokkade zonder databasecontext", async () => {
    mocks.save.mockResolvedValueOnce({
      data: null,
      error: {
        code: "40001",
        message: "MAIL_REMINDER_RULE_CONFLICT",
      },
    });
    const conflict = await POST(request(createInput));
    expect(conflict.status).toBe(409);
    expect(await conflict.text()).not.toContain("MAIL_REMINDER_RULE_CONFLICT");

    mocks.toggle.mockRejectedValueOnce(
      new Error("STAFF_AUTHORIZATION_REQUIRED"),
    );
    const denied = await POST(request({
      action: "toggle",
      ruleId,
      expectedRevision: 1,
      active: true,
      reason: "Veilige activering",
    }));
    expect(denied.status).toBe(403);
  });
});
