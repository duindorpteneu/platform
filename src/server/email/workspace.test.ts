import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ rpc: vi.fn() }));

vi.mock("next/cache", () => ({ unstable_noStore: vi.fn() }));
vi.mock("@/server/auth/staff", () => ({
  requireStaffRole: vi.fn(async () => ({
    userId: "99999999-9999-4999-8999-999999999999",
    role: "kledingcommissie",
  })),
}));
vi.mock("@/server/email/provider", () => ({
  emailProviderCapabilities: () => ({
    provider: "smtp",
    providerName: "VoetbalAssist SMTP",
    runtimeEnabled: true,
    providerConfigured: true,
    senderName: "Kledingcommissie Duindorp SV",
    feedbackCapability: "smtp_sync_only",
  }),
}));
vi.mock("@/server/supabase/server", () => ({
  getSupabaseServerClient: vi.fn(async () => ({
    schema: () => ({ rpc: mocks.rpc }),
  })),
}));

import { getEmailWorkspace } from "@/server/email/workspace";

const timestamp = "2026-08-21T12:00:00.000Z";
const templateKeys = [
  "verification_code",
  "portal_access_invite",
  "payment_request",
  "payment_received",
  "ready_for_pickup",
  "payment_reminder",
  "qr_code_resent",
] as const;
const databaseWorkspace = {
  recoveryAllowed: false,
  templateKeys,
  templates: templateKeys.map((key, index) => ({
    id: `11111111-1111-4111-8111-11111111111${index}`,
    key,
    subjectSource: `Onderwerp ${key}`,
    bodySource: `Veilige inhoud voor ${key}.`,
    allowedShortcodes: ["{{clubnaam}}"],
    active: true,
    version: 1,
    updatedAt: timestamp,
  })),
  batches: [],
  jobs: [],
  orders: [],
};
const controlCenter = {
  feedbackCapability: "smtp_sync_only",
  recipients: [{
    id: "22222222-2222-4222-8222-222222222222",
    email: null,
    emailMasked: "o***@example.nl",
    healthState: "accepted",
    suspiciousDomain: false,
    suppressionReason: null,
    lastSendAt: timestamp,
    lastProviderAcceptanceAt: timestamp,
    lastProvenDeliveryAt: null,
    lastFailureAt: null,
    lastProviderFeedbackAt: timestamp,
    temporaryFailureCount: 0,
    permanentRejectionCount: 0,
    hardBounceCount: 0,
    dropCount: 0,
    deliveryUncertainCount: 0,
    lastOtpRequestedAt: null,
    lastOtpOutcome: null,
    otpExpiresAt: null,
    linkedChildren: [],
  }],
};

describe("email control center workspace", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.rpc.mockImplementation(async (name: string) => (
      name === "get_email_workspace_v4"
        ? { data: databaseWorkspace, error: null }
        : { data: controlCenter, error: null }
    ));
  });

  it("combineert de bestaande mailwerkruimte met provider- en recipientprojectie", async () => {
    const result = await getEmailWorkspace();
    expect(mocks.rpc).toHaveBeenCalledWith("get_email_control_center_v1");
    expect(result.workspace.provider.feedbackCapability).toBe("smtp_sync_only");
    expect(result.workspace.controlCenter.recipients[0]).toMatchObject({
      email: null,
      emailMasked: "o***@example.nl",
      healthState: "accepted",
    });
  });

  it("projecteert de werkelijke runtimefeedbackcapaciteit boven een oude databasehint", async () => {
    mocks.rpc.mockImplementation(async (name: string) => (
      name === "get_email_workspace_v4"
        ? { data: databaseWorkspace, error: null }
        : {
            data: { ...controlCenter, feedbackCapability: "sendgrid_webhook" },
            error: null,
          }
    ));
    const result = await getEmailWorkspace();
    expect(result.workspace.controlCenter.feedbackCapability).toBe(
      "smtp_sync_only",
    );
  });

  it("faalt gesloten op een ongeldige recipientprojectie", async () => {
    mocks.rpc.mockImplementation(async (name: string) => (
      name === "get_email_workspace_v4"
        ? { data: databaseWorkspace, error: null }
        : { data: { ...controlCenter, recipients: [{ email: "leak" }] }, error: null }
    ));
    await expect(getEmailWorkspace()).rejects.toThrow(
      "EMAIL_CONTROL_CENTER_RESPONSE_INVALID",
    );
  });
});
