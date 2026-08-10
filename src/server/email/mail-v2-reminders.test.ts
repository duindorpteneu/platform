import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  requireStaffRole: vi.fn(),
  rpc: vi.fn(),
}));

vi.mock("@/server/auth/staff", () => ({
  requireStaffRole: mocks.requireStaffRole,
}));
vi.mock("@/server/supabase/server", () => ({
  getSupabaseServerClient: vi.fn(async () => ({
    schema: () => ({ rpc: mocks.rpc }),
  })),
}));

import {
  getMailReminderWorkspace,
  runDueMailReminders,
} from "@/server/email/mail-v2-reminders";

const now = "2026-08-03T12:00:00.000Z";

describe("mail-v2 herinneringsservice", () => {
  beforeEach(() => {
    mocks.requireStaffRole.mockReset().mockResolvedValue({
      role: "beheerder",
    });
    mocks.rpc.mockReset();
  });

  it("leest uitsluitend het strikte beheerworkspacecontract", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: {
        timezone: "Europe/Amsterdam",
        newRulesDefaultActive: false,
        rules: [],
        seasons: [{
          id: "78100000-0000-4000-8000-000000000001",
          name: "2026/2027",
          status: "open",
        }],
      },
      error: null,
    });

    await expect(getMailReminderWorkspace()).resolves.toMatchObject({
      timezone: "Europe/Amsterdam",
      newRulesDefaultActive: false,
    });
    expect(mocks.requireStaffRole).toHaveBeenCalledWith(["beheerder"]);
  });

  it("weigert een schedulerantwoord met verborgen regelfouten", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: {
        status: "completed",
        candidateCount: 1,
        dispatchedCount: 0,
        skippedCount: 0,
        failedRuleCount: 1,
      },
      error: null,
    });
    const admin = {
      schema: () => ({ rpc: mocks.rpc }),
    };

    await expect(runDueMailReminders(
      admin as unknown as Parameters<typeof runDueMailReminders>[0],
      now,
    )).rejects.toThrow("MAIL_REMINDER_RULE_EXECUTION_FAILED");
  });

  it("accepteert alleen een volledig valide succesvolle schedulerrun", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: {
        status: "completed",
        candidateCount: 2,
        dispatchedCount: 1,
        skippedCount: 1,
        failedRuleCount: 0,
      },
      error: null,
    });
    const admin = {
      schema: () => ({ rpc: mocks.rpc }),
    };

    await expect(runDueMailReminders(
      admin as unknown as Parameters<typeof runDueMailReminders>[0],
      now,
    )).resolves.toMatchObject({
      status: "completed",
      dispatchedCount: 1,
      failedRuleCount: 0,
    });
  });
});
