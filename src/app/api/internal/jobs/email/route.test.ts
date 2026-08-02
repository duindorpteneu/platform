import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  bearer: vi.fn(),
  admin: vi.fn(),
  rpc: vi.fn(),
  feature: vi.fn(),
  send: vi.fn(),
  render: vi.fn(),
  startRun: vi.fn(),
  finishRun: vi.fn(),
}));
vi.mock("@/server/operations/internal-auth", () => ({ hasInternalBearer: mocks.bearer }));
vi.mock("@/server/supabase/admin", () => ({ getSupabaseAdminClient: mocks.admin }));
vi.mock("@/server/operations/feature-flags", () => ({ isOperationalFeatureEnabled: mocks.feature }));
vi.mock("@/server/email/sendgrid", () => ({ sendEmailJob: mocks.send }));
vi.mock("@/server/email/workspace", () => ({ renderClaimedEmailJob: mocks.render }));
vi.mock("@/server/operations/run-ledger", () => ({ startOperationRun: mocks.startRun, finishOperationRun: mocks.finishRun }));

import { POST } from "./route";

const job = {
  id: "71000000-0000-4000-8000-000000000001",
  kind: "transactional",
  contextKind: "order",
  recipientEmail: "ouder@example.invalid",
  templateKey: "payment_received",
  templateVersion: 1,
  subjectSource: "Betaling voor {{volledige_naam}}",
  bodySource: "Betaling van {{bedrag}} ontvangen.",
  allowedShortcodes: ["{{volledige_naam}}", "{{bedrag}}"],
  orderId: "72000000-0000-4000-8000-000000000001",
  parentAccountId: null,
  payload: {
    orderId: "72000000-0000-4000-8000-000000000001",
    memberId: "73000000-0000-4000-8000-000000000001",
    firstName: "Test", fullName: "Test Lid", team: "TEST", relationNumber: "TEST-1", season: "2026/27",
    amountCents: 100, clubName: "Duindorp SV", contactEmail: "test@example.invalid", pickupLocation: "Testlocatie",
    qrVersion: 1, articles: [], articlesReady: [], articlesBackorder: [],
  },
  attempt: 1,
};

const portalJob = {
  id: "71000000-0000-4000-8000-000000000002",
  kind: "transactional",
  contextKind: "portal_access",
  recipientEmail: "ouder@example.invalid",
  templateKey: "portal_access_invite",
  templateVersion: 2,
  subjectSource: "Toegang tot {{clubnaam}}",
  bodySource: "Open zelf {{portaal_url}}.",
  allowedShortcodes: ["{{clubnaam}}", "{{portaal_url}}"],
  orderId: null,
  parentAccountId: "74000000-0000-4000-8000-000000000001",
  payload: {
    parentAccountId: "74000000-0000-4000-8000-000000000001",
    clubName: "Duindorp SV",
    contactEmail: "kleding@duindorpsv.nl",
  },
  attempt: 1,
};

describe("POST /api/internal/jobs/email", () => {
  beforeEach(() => {
    process.env.EMAIL_ENABLED = "true";
    mocks.bearer.mockReset().mockReturnValue(true);
    mocks.feature.mockReset().mockResolvedValue(true);
    mocks.startRun.mockReset().mockResolvedValue(true);
    mocks.finishRun.mockReset().mockResolvedValue(true);
    mocks.render.mockReset().mockReturnValue({ subject: "Onderwerp", text: "Bericht", html: "<p>Bericht</p>" });
    mocks.send.mockReset().mockResolvedValue({ delivered: false, reason: "delivery_uncertain", outcome: "delivery_uncertain" });
    mocks.rpc.mockReset().mockImplementation((name: string, args: Record<string, unknown>) => {
      if (name === "claim_email_jobs_v2") return Promise.resolve({ data: { claimToken: args.p_claim_token, jobs: [job] }, error: null });
      if (name === "authorize_claimed_email_job") return Promise.resolve({ data: true, error: null });
      if (name === "complete_email_job") return Promise.resolve({ data: { jobId: args.p_job_id, status: args.p_outcome, attempts: 1, availableAt: "2026-07-21T10:00:00.000Z" }, error: null });
      return Promise.resolve({ data: null, error: { code: "PGRST202" } });
    });
    mocks.admin.mockReset().mockReturnValue({ schema: () => ({ rpc: mocks.rpc }) });
  });

  it("parks an uncertain provider result and never turns it into retry", async () => {
    const response = await POST(new Request("https://tenue.example/api/internal/jobs/email", { method: "POST" }));
    expect(response.status).toBe(200);
    expect(mocks.rpc).toHaveBeenCalledWith("complete_email_job", expect.objectContaining({ p_outcome: "delivery_uncertain", p_error: "delivery_uncertain" }));
    expect(await response.json()).toMatchObject({ status: "processed", claimed: 1, retry: 0, deliveryUncertain: 1 });
    expect(mocks.finishRun).toHaveBeenCalledWith(expect.anything(), "email_worker", expect.any(String), "succeeded", 1, null);
  });

  it("keeps the explicit paused scheduler contract when e-mail is disabled", async () => {
    process.env.EMAIL_ENABLED = "false";
    const response = await POST(new Request("https://tenue.example/api/internal/jobs/email", { method: "POST" }));
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ status: "paused", claimed: 0, deliveryUncertain: 0 });
    expect(mocks.finishRun).toHaveBeenCalledWith(expect.anything(), "email_worker", expect.any(String), "paused", 0);
    expect(mocks.send).not.toHaveBeenCalled();
  });

  it("renders, sends and completes a portal invitation through the v2 worker contract", async () => {
    mocks.rpc.mockImplementation((name: string, args: Record<string, unknown>) => {
      if (name === "claim_email_jobs_v2") {
        return Promise.resolve({
          data: { claimToken: args.p_claim_token, jobs: [portalJob] },
          error: null,
        });
      }
      if (name === "authorize_claimed_email_job") {
        return Promise.resolve({ data: true, error: null });
      }
      if (name === "complete_email_job") {
        return Promise.resolve({
          data: {
            jobId: args.p_job_id,
            status: args.p_outcome,
            attempts: 1,
            availableAt: "2026-07-21T10:00:00.000Z",
          },
          error: null,
        });
      }
      return Promise.resolve({ data: null, error: { code: "PGRST202" } });
    });
    mocks.send.mockResolvedValueOnce({
      delivered: true,
      providerMessageId: "sg-portal-access",
    });

    const response = await POST(
      new Request("https://tenue.example/api/internal/jobs/email", {
        method: "POST",
      }),
    );

    expect(response.status).toBe(200);
    expect(mocks.render).toHaveBeenCalledWith(
      portalJob,
      expect.any(String),
    );
    expect(mocks.send).toHaveBeenCalledWith(expect.objectContaining({
      jobId: portalJob.id,
      recipientEmail: portalJob.recipientEmail,
      replyToEmail: "kleding@duindorpsv.nl",
    }));
    expect(mocks.rpc).toHaveBeenCalledWith(
      "authorize_claimed_email_job",
      expect.objectContaining({
        p_job_id: portalJob.id,
      }),
    );
    expect(mocks.rpc).toHaveBeenCalledWith(
      "complete_email_job",
      expect.objectContaining({
        p_job_id: portalJob.id,
        p_outcome: "sent",
        p_provider_message_id: "sg-portal-access",
      }),
    );
  });

  it("suppresses a claimed portal invitation when access was revoked before send", async () => {
    mocks.rpc.mockImplementation((name: string, args: Record<string, unknown>) => {
      if (name === "claim_email_jobs_v2") {
        return Promise.resolve({
          data: { claimToken: args.p_claim_token, jobs: [portalJob] },
          error: null,
        });
      }
      if (name === "authorize_claimed_email_job") {
        return Promise.resolve({ data: false, error: null });
      }
      return Promise.resolve({ data: null, error: { code: "PGRST202" } });
    });

    const response = await POST(
      new Request("https://tenue.example/api/internal/jobs/email", {
        method: "POST",
      }),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      claimed: 1,
      sent: 0,
      failed: 1,
      completionErrors: 0,
    });
    expect(mocks.render).not.toHaveBeenCalled();
    expect(mocks.send).not.toHaveBeenCalled();
    expect(mocks.rpc).not.toHaveBeenCalledWith(
      "complete_email_job",
      expect.anything(),
    );
  });

  it("does no work when the runledger cannot be started", async () => {
    mocks.startRun.mockResolvedValueOnce(false);
    const response = await POST(new Request("https://tenue.example/api/internal/jobs/email", { method: "POST" }));
    expect(response.status).toBe(503);
    expect(mocks.rpc).not.toHaveBeenCalledWith("claim_email_jobs_v2", expect.anything());
    expect(mocks.send).not.toHaveBeenCalled();
  });
});
