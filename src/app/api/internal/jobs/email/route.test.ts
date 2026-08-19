import { createHash } from "node:crypto";
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
  project: vi.fn(),
  projectDomain: vi.fn(),
  reminders: vi.fn(),
}));
vi.mock("@/server/operations/internal-auth", () => ({ hasInternalBearer: mocks.bearer }));
vi.mock("@/server/supabase/admin", () => ({ getSupabaseAdminClient: mocks.admin }));
vi.mock("@/server/operations/feature-flags", () => ({ isOperationalFeatureEnabled: mocks.feature }));
vi.mock("@/server/email/provider", () => ({ sendEmailJob: mocks.send }));
vi.mock("@/server/email/workspace", () => ({ renderClaimedEmailJob: mocks.render }));
vi.mock("@/server/email/mail-v2-projector", () => ({
  projectFulfilmentMail: mocks.project,
  projectMailV2DomainEvents: mocks.projectDomain,
}));
vi.mock("@/server/email/mail-v2-reminders", () => ({
  runDueMailReminders: mocks.reminders,
}));
vi.mock("@/server/operations/run-ledger", () => ({ startOperationRun: mocks.startRun, finishOperationRun: mocks.finishRun }));

import { POST } from "./route";

const job = {
  id: "71000000-0000-4000-8000-000000000001",
  deliveryAttemptId: "71100000-0000-4000-8000-000000000001",
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
  deliveryAttemptId: "71100000-0000-4000-8000-000000000002",
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

const fulfilmentJob = {
  id: "71000000-0000-4000-8000-000000000003",
  deliveryAttemptId: "71100000-0000-4000-8000-000000000003",
  kind: "transactional",
  contextKind: "fulfilment",
  recipientEmail: "ouder@example.invalid",
  templateKey: "partial_pickup",
  templateRevisionId: "75000000-0000-4000-8000-000000000001",
  brandingRevisionId: "75000000-0000-4000-8000-000000000002",
  subject: "Deelafhaling voor Test",
  preheader: "Bekijk wat nog volgt.",
  html: "<p>Immutable HTML</p>",
  text: "Immutable tekst",
  fromName: "Kledingcommissie Duindorp SV",
  fromEmail: "kleding@duindorpsv.nl",
  replyToEmail: "kleding@duindorpsv.nl",
  renderHash: "a".repeat(64),
  parentAccountId: "75000000-0000-4000-8000-000000000003",
  seasonId: "75000000-0000-4000-8000-000000000004",
  eventCount: 2,
  attempt: 1,
};

const domainJob = {
  ...fulfilmentJob,
  id: "71000000-0000-4000-8000-000000000004",
  deliveryAttemptId: "71100000-0000-4000-8000-000000000004",
  kind: "bulk",
  contextKind: "mail_v2",
  templateKey: "payment_reminder",
  subject: "Betalingsherinnering",
  preheader: "Bekijk de afzonderlijke pakketbedragen.",
};

describe("POST /api/internal/jobs/email", () => {
  beforeEach(() => {
    process.env.EMAIL_ENABLED = "true";
    process.env.EMAIL_PROVIDER = "sendgrid";
    process.env.EMAIL_BULK_ENABLED = "true";
    process.env.SENDGRID_FROM_NAME = "Kledingcommissie Duindorp SV";
    process.env.SENDGRID_FROM_EMAIL = "kleding@duindorpsv.nl";
    process.env.SENDGRID_REPLY_TO_EMAIL = "kleding@duindorpsv.nl";
    process.env.SMTP_FROM_NAME = "Verkeerde SMTP-afzender";
    process.env.SMTP_FROM_EMAIL = "smtp@example.invalid";
    process.env.SMTP_REPLY_TO_EMAIL = "smtp-reply@example.invalid";
    process.env.SENDGRID_SMOKE_RECIPIENT = "testinbox@example.invalid";
    process.env.SENDGRID_API_KEY = "SG.test-key";
    process.env.SENDGRID_API_KEY_FINGERPRINT =
      createHash("sha256")
        .update(process.env.SENDGRID_API_KEY)
        .digest("hex");
    process.env.SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY = "test-public-key";
    process.env.CRON_SECRET = "test-cron-secret-1234";
    process.env.APP_BASE_URL = "https://tenue.example";
    mocks.bearer.mockReset().mockReturnValue(true);
    mocks.feature.mockReset().mockResolvedValue(true);
    mocks.startRun.mockReset().mockResolvedValue(true);
    mocks.finishRun.mockReset().mockResolvedValue(true);
    mocks.project.mockReset().mockResolvedValue({
      claimed: 0,
      queued: 0,
      suppressed: 0,
      deferred: 0,
      errors: 0,
    });
    mocks.projectDomain.mockReset().mockResolvedValue({
      claimed: 0,
      queued: 0,
      suppressed: 0,
      deferred: 0,
      errors: 0,
    });
    mocks.reminders.mockReset().mockResolvedValue({
      status: "completed",
      candidateCount: 0,
      dispatchedCount: 0,
      skippedCount: 0,
      failedRuleCount: 0,
    });
    mocks.render.mockReset().mockReturnValue({ subject: "Onderwerp", text: "Bericht", html: "<p>Bericht</p>" });
    mocks.send.mockReset().mockResolvedValue({ delivered: false, reason: "delivery_uncertain", outcome: "delivery_uncertain" });
    mocks.rpc.mockReset().mockImplementation((name: string, args: Record<string, unknown>) => {
      if (name === "get_email_worker_preflight_v2") return Promise.resolve({ data: { ready: true, brandingMatchCount: 1, senderDriftCount: 0, brandingProjectionBlockers: 0 }, error: null });
      if (name === "claim_email_jobs_v5") return Promise.resolve({ data: { claimToken: args.p_claim_token, jobs: [job] }, error: null });
      if (name === "authorize_claimed_email_job_v4") return Promise.resolve({ data: true, error: null });
      if (name === "complete_email_job_v2") return Promise.resolve({ data: { jobId: args.p_job_id, status: args.p_outcome, attempts: 1, availableAt: "2026-07-21T10:00:00.000Z" }, error: null });
      return Promise.resolve({ data: null, error: { code: "PGRST202" } });
    });
    mocks.admin.mockReset().mockReturnValue({ schema: () => ({ rpc: mocks.rpc }) });
  });

  it("parks an uncertain provider result and never turns it into retry", async () => {
    const response = await POST(new Request("https://tenue.example/api/internal/jobs/email", { method: "POST" }));
    expect(response.status).toBe(200);
    expect(mocks.rpc).toHaveBeenCalledWith("complete_email_job_v2", expect.objectContaining({
      p_delivery_attempt_id: job.deliveryAttemptId,
      p_outcome: "delivery_uncertain",
      p_error: "delivery_uncertain",
    }));
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

  it("faalt vóór projectie en claims bij ongeldige runtimeconfiguratie", async () => {
    delete process.env.APP_BASE_URL;

    const response = await POST(
      new Request("https://tenue.example/api/internal/jobs/email", {
        method: "POST",
      }),
    );

    expect(response.status).toBe(503);
    expect(mocks.project).not.toHaveBeenCalled();
    expect(mocks.rpc).not.toHaveBeenCalled();
    expect(mocks.finishRun).toHaveBeenCalledWith(
      expect.anything(),
      "email_worker",
      expect.any(String),
      "failed",
      0,
      "runtime_configuration_invalid",
    );
  });

  it("claimt niets wanneer branding of queued snapshots van de sender afwijken", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: {
        ready: false,
        brandingMatchCount: 0,
        senderDriftCount: 1,
      },
      error: null,
    });

    const response = await POST(
      new Request("https://tenue.example/api/internal/jobs/email", {
        method: "POST",
      }),
    );

    expect(response.status).toBe(503);
    expect(mocks.project).not.toHaveBeenCalled();
    expect(mocks.rpc).not.toHaveBeenCalledWith(
      "claim_email_jobs_v5",
      expect.anything(),
    );
    expect(mocks.finishRun).toHaveBeenCalledWith(
      expect.anything(),
      "email_worker",
      expect.any(String),
      "failed",
      0,
      "sender_contract_drift",
    );
  });

  it("renders, sends and completes a portal invitation through the v2 worker contract", async () => {
    mocks.rpc.mockImplementation((name: string, args: Record<string, unknown>) => {
      if (name === "get_email_worker_preflight_v2") {
        return Promise.resolve({
          data: { ready: true, brandingMatchCount: 1, senderDriftCount: 0 },
          error: null,
        });
      }
      if (name === "claim_email_jobs_v5") {
        return Promise.resolve({
          data: { claimToken: args.p_claim_token, jobs: [portalJob] },
          error: null,
        });
      }
      if (name === "authorize_claimed_email_job_v4") {
        return Promise.resolve({ data: true, error: null });
      }
      if (name === "complete_email_job_v2") {
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
      deliveryAttemptId: portalJob.deliveryAttemptId,
      recipientEmail: portalJob.recipientEmail,
      replyToEmail: "kleding@duindorpsv.nl",
      fromName: "Kledingcommissie Duindorp SV",
      fromEmail: "kleding@duindorpsv.nl",
    }));
    expect(mocks.rpc).toHaveBeenCalledWith(
      "authorize_claimed_email_job_v4",
      expect.objectContaining({
        p_job_id: portalJob.id,
        p_delivery_attempt_id: portalJob.deliveryAttemptId,
      }),
    );
    expect(mocks.rpc).toHaveBeenCalledWith(
      "complete_email_job_v2",
      expect.objectContaining({
        p_job_id: portalJob.id,
        p_delivery_attempt_id: portalJob.deliveryAttemptId,
        p_outcome: "sent",
        p_provider_message_id: "sg-portal-access",
      }),
    );
  });

  it("suppresses a claimed portal invitation when access was revoked before send", async () => {
    mocks.rpc.mockImplementation((name: string, args: Record<string, unknown>) => {
      if (name === "get_email_worker_preflight_v2") {
        return Promise.resolve({
          data: { ready: true, brandingMatchCount: 1, senderDriftCount: 0 },
          error: null,
        });
      }
      if (name === "claim_email_jobs_v5") {
        return Promise.resolve({
          data: { claimToken: args.p_claim_token, jobs: [portalJob] },
          error: null,
        });
      }
      if (name === "authorize_claimed_email_job_v4") {
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
      failed: 0,
      deferred: 1,
      completionErrors: 0,
    });
    expect(mocks.render).not.toHaveBeenCalled();
    expect(mocks.send).not.toHaveBeenCalled();
    expect(mocks.rpc).not.toHaveBeenCalledWith(
      "complete_email_job_v2",
      expect.anything(),
    );
  });

  it("verstuurd een fulfilmentjob uitsluitend uit de immutable render- en sender-snapshot", async () => {
    mocks.rpc.mockImplementation((name: string, args: Record<string, unknown>) => {
      if (name === "get_email_worker_preflight_v2") {
        return Promise.resolve({
          data: { ready: true, brandingMatchCount: 1, senderDriftCount: 0 },
          error: null,
        });
      }
      if (name === "claim_email_jobs_v5") {
        return Promise.resolve({
          data: { claimToken: args.p_claim_token, jobs: [fulfilmentJob] },
          error: null,
        });
      }
      if (name === "authorize_claimed_email_job_v4") {
        return Promise.resolve({ data: true, error: null });
      }
      if (name === "complete_email_job_v2") {
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
      providerMessageId: "sg-fulfilment",
    });

    const response = await POST(new Request(
      "https://tenue.example/api/internal/jobs/email",
      { method: "POST" },
    ));

    expect(response.status).toBe(200);
    expect(mocks.render).not.toHaveBeenCalled();
    expect(mocks.send).toHaveBeenCalledWith({
      jobId: fulfilmentJob.id,
      deliveryAttemptId: fulfilmentJob.deliveryAttemptId,
      recipientEmail: fulfilmentJob.recipientEmail,
      subject: fulfilmentJob.subject,
      html: fulfilmentJob.html,
      text: fulfilmentJob.text,
      fromName: fulfilmentJob.fromName,
      fromEmail: fulfilmentJob.fromEmail,
      replyToEmail: fulfilmentJob.replyToEmail,
    });
  });

  it("verstuurt een generieke v2-job uitsluitend uit de immutable snapshots", async () => {
    mocks.rpc.mockImplementation((name: string, args: Record<string, unknown>) => {
      if (name === "get_email_worker_preflight_v2") {
        return Promise.resolve({
          data: { ready: true, brandingMatchCount: 1, senderDriftCount: 0 },
          error: null,
        });
      }
      if (name === "claim_email_jobs_v5") {
        return Promise.resolve({
          data: { claimToken: args.p_claim_token, jobs: [domainJob] },
          error: null,
        });
      }
      if (name === "authorize_claimed_email_job_v4") {
        return Promise.resolve({ data: true, error: null });
      }
      if (name === "complete_email_job_v2") {
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
      providerMessageId: "sg-domain",
    });

    const response = await POST(new Request(
      "https://tenue.example/api/internal/jobs/email",
      { method: "POST" },
    ));

    expect(response.status).toBe(200);
    expect(mocks.render).not.toHaveBeenCalled();
    expect(mocks.send).toHaveBeenCalledWith({
      jobId: domainJob.id,
      deliveryAttemptId: domainJob.deliveryAttemptId,
      recipientEmail: domainJob.recipientEmail,
      subject: domainJob.subject,
      html: domainJob.html,
      text: domainJob.text,
      fromName: domainJob.fromName,
      fromEmail: domainJob.fromEmail,
      replyToEmail: domainJob.replyToEmail,
    });
  });

  it("verzendt en completeert niets wanneer een domeinjob send-time afvalt", async () => {
    mocks.rpc.mockImplementation((name: string, args: Record<string, unknown>) => {
      if (name === "get_email_worker_preflight_v2") {
        return Promise.resolve({
          data: { ready: true, brandingMatchCount: 1, senderDriftCount: 0 },
          error: null,
        });
      }
      if (name === "claim_email_jobs_v5") {
        return Promise.resolve({
          data: { claimToken: args.p_claim_token, jobs: [domainJob] },
          error: null,
        });
      }
      if (name === "authorize_claimed_email_job_v4") {
        return Promise.resolve({ data: false, error: null });
      }
      return Promise.resolve({ data: null, error: { code: "PGRST202" } });
    });

    const response = await POST(new Request(
      "https://tenue.example/api/internal/jobs/email",
      { method: "POST" },
    ));

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      claimed: 1,
      deferred: 1,
      failed: 0,
      completionErrors: 0,
    });
    expect(mocks.send).not.toHaveBeenCalled();
    expect(mocks.rpc).not.toHaveBeenCalledWith(
      "complete_email_job_v2",
      expect.anything(),
    );
  });

  it("does no work when the runledger cannot be started", async () => {
    mocks.startRun.mockResolvedValueOnce(false);
    const response = await POST(new Request("https://tenue.example/api/internal/jobs/email", { method: "POST" }));
    expect(response.status).toBe(503);
    expect(mocks.rpc).not.toHaveBeenCalledWith("claim_email_jobs_v5", expect.anything());
    expect(mocks.project).not.toHaveBeenCalled();
    expect(mocks.send).not.toHaveBeenCalled();
  });

  it("sluit de operation-run af wanneer de projector onverwacht faalt", async () => {
    mocks.project.mockRejectedValueOnce(new Error("gevoelige providercontext"));

    const response = await POST(new Request(
      "https://tenue.example/api/internal/jobs/email",
      { method: "POST" },
    ));

    expect(response.status).toBe(503);
    expect(await response.text()).not.toContain("gevoelige providercontext");
    expect(mocks.finishRun).toHaveBeenCalledWith(
      expect.anything(),
      "email_worker",
      expect.any(String),
      "failed",
      0,
      "projection_failed",
    );
    expect(mocks.send).not.toHaveBeenCalled();
  });

  it("stopt vóór projectie en claim wanneer de herinneringsplanner faalt", async () => {
    mocks.reminders.mockRejectedValueOnce(new Error("gevoelige plannercontext"));

    const response = await POST(new Request(
      "https://tenue.example/api/internal/jobs/email",
      { method: "POST" },
    ));

    expect(response.status).toBe(503);
    expect(await response.text()).not.toContain("gevoelige plannercontext");
    expect(mocks.project).not.toHaveBeenCalled();
    expect(mocks.rpc).not.toHaveBeenCalledWith(
      "claim_email_jobs_v5",
      expect.anything(),
    );
    expect(mocks.finishRun).toHaveBeenCalledWith(
      expect.anything(),
      "email_worker",
      expect.any(String),
      "failed",
      0,
      "reminder_planner_failed",
    );
  });

  it("sluit de operation-run af wanneer de domeinprojector onverwacht faalt", async () => {
    mocks.projectDomain.mockRejectedValueOnce(
      new Error("gevoelige domeincontext"),
    );

    const response = await POST(new Request(
      "https://tenue.example/api/internal/jobs/email",
      { method: "POST" },
    ));

    expect(response.status).toBe(503);
    expect(await response.text()).not.toContain("gevoelige domeincontext");
    expect(mocks.finishRun).toHaveBeenCalledWith(
      expect.anything(),
      "email_worker",
      expect.any(String),
      "failed",
      0,
      "projection_failed",
    );
    expect(mocks.send).not.toHaveBeenCalled();
  });
});
