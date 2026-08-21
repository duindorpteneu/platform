import { describe, expect, it } from "vitest";
import {
  claimedEmailJobSchema,
  emailBulkRequestSchema,
  emailControlCenterProjectionSchema,
  emailJobOperationalState,
  emailTemplateKeySchema,
  emailWorkspaceSchema,
  updateEmailTemplateRequestSchema,
} from "@/lib/email-contract";

describe("email contracts", () => {
  it("valideert recipient-health zonder een volledig adres voor kledingcommissie", () => {
    const recipient = {
      id: "11111111-1111-4111-8111-111111111111",
      email: null,
      emailMasked: "o***@example.nl",
      healthState: "accepted",
      suspiciousDomain: false,
      suppressionReason: null,
      lastSendAt: "2026-08-21T12:00:00.000Z",
      lastProviderAcceptanceAt: "2026-08-21T12:00:01.000Z",
      lastProvenDeliveryAt: null,
      lastFailureAt: null,
      lastProviderFeedbackAt: "2026-08-21T12:00:01.000Z",
      temporaryFailureCount: 0,
      permanentRejectionCount: 0,
      hardBounceCount: 0,
      dropCount: 0,
      deliveryUncertainCount: 0,
      lastOtpRequestedAt: "2026-08-21T11:59:55.000Z",
      lastOtpOutcome: "accepted",
      otpExpiresAt: "2026-08-21T12:09:55.000Z",
      linkedChildren: [{
        memberId: "22222222-2222-4222-8222-222222222222",
        memberName: "Sophie de Bruin",
        team: "JO11-1",
      }],
    };
    expect(emailControlCenterProjectionSchema.safeParse({
      feedbackCapability: "smtp_sync_only",
      recipients: [recipient],
    }).success).toBe(true);
    expect(emailControlCenterProjectionSchema.safeParse({
      feedbackCapability: "smtp_sync_only",
      recipients: [{
        ...recipient,
        healthState: "suppressed",
        suppressionReason: null,
      }],
    }).success).toBe(false);
    expect(emailControlCenterProjectionSchema.safeParse({
      feedbackCapability: "smtp_sync_only",
      recipients: [{
        ...recipient,
        email: "not-an-email",
      }],
    }).success).toBe(false);
  });

  it("contains the durable portal invitation beside the six legacy templates", () => {
    expect(emailTemplateKeySchema.options).toEqual([
      "verification_code", "portal_access_invite", "payment_request", "payment_received", "ready_for_pickup", "payment_reminder", "qr_code_resent",
    ]);
  });

  it("allows bulk only for manual reminders and ready notifications", () => {
    const orderId = "11111111-1111-4111-8111-111111111111";
    expect(emailBulkRequestSchema.safeParse({ action: "preview", templateKey: "payment_reminder", orderIds: [orderId] }).success).toBe(true);
    expect(emailBulkRequestSchema.safeParse({ action: "preview", templateKey: "payment_received", orderIds: [orderId] }).success).toBe(false);
    expect(emailBulkRequestSchema.safeParse({ action: "preview", templateKey: "payment_reminder", orderIds: [orderId, orderId] }).success).toBe(false);
  });

  it("rejects HTML at the template route boundary", () => {
    expect(updateEmailTemplateRequestSchema.safeParse({
      templateId: "11111111-1111-4111-8111-111111111111",
      subjectSource: "Betalingsherinnering",
      bodySource: "Beste ouder <script>alert(1)</script>",
      expectedVersion: 1,
    }).success).toBe(false);
  });

  it("requires immutable template snapshots on claimed jobs", () => {
    const id = "11111111-1111-4111-8111-111111111111";
    const payload = {
      id, deliveryAttemptId: "11111111-1111-4111-8111-111111111112", kind: "transactional", contextKind: "order", recipientEmail: "ouder@example.nl", templateKey: "payment_received",
      templateVersion: 3, subjectSource: "Betaling ontvangen", bodySource: "Uw betaling is veilig ontvangen.",
      allowedShortcodes: ["{{volledige_naam}}"], orderId: id, parentAccountId: null, attempt: 1,
      payload: { orderId: id, memberId: "22222222-2222-4222-8222-222222222222", firstName: "Sophie", fullName: "Sophie de Bruin", team: "JO11-1", relationNumber: "DSV-1", season: "2026/27", amountCents: 12500, clubName: "Duindorp SV", contactEmail: "kleding@duindorpsv.nl", pickupLocation: "Clubhuis", qrVersion: 1, articles: [], articlesReady: [], articlesBackorder: [] },
    };
    expect(claimedEmailJobSchema.safeParse(payload).success).toBe(true);
    expect(claimedEmailJobSchema.safeParse({ ...payload, templateVersion: undefined }).success).toBe(false);
  });

  it("accepts only a minimal PII-free portal-access payload", () => {
    const parentAccountId = "22222222-2222-4222-8222-222222222222";
    const payload = {
      id: "11111111-1111-4111-8111-111111111111",
      deliveryAttemptId: "11111111-1111-4111-8111-111111111112",
      kind: "transactional",
      contextKind: "portal_access",
      recipientEmail: "ouder@example.nl",
      templateKey: "portal_access_invite",
      templateVersion: 1,
      subjectSource: "Toegang tot {{clubnaam}}",
      bodySource: "Open het portaal via {{portaal_url}}.",
      allowedShortcodes: ["{{clubnaam}}", "{{portaal_url}}"],
      orderId: null,
      parentAccountId,
      payload: {
        parentAccountId,
        clubName: "Duindorp SV",
        contactEmail: "kleding@duindorpsv.nl",
      },
      attempt: 1,
    };
    expect(claimedEmailJobSchema.safeParse(payload).success).toBe(true);
    expect(claimedEmailJobSchema.safeParse({
      ...payload,
      payload: { ...payload.payload, children: ["Anna"] },
    }).success).toBe(false);
  });

  it("accepteert fulfilment uitsluitend als immutable render- en sender-snapshot", () => {
    const payload = {
      id: "11111111-1111-4111-8111-111111111111",
      deliveryAttemptId: "11111111-1111-4111-8111-111111111112",
      kind: "transactional",
      contextKind: "fulfilment",
      recipientEmail: "ouder@example.nl",
      templateKey: "partial_pickup",
      templateRevisionId: "22222222-2222-4222-8222-222222222222",
      brandingRevisionId: "33333333-3333-4333-8333-333333333333",
      subject: "Deelafhaling voor Sophie",
      preheader: "Bekijk wat nog volgt.",
      html: "<p>Immutable HTML</p>",
      text: "Immutable tekst",
      fromName: "Kledingcommissie Duindorp SV",
      fromEmail: "kleding@duindorpsv.nl",
      replyToEmail: "kleding@duindorpsv.nl",
      renderHash: "a".repeat(64),
      parentAccountId: "44444444-4444-4444-8444-444444444444",
      seasonId: "55555555-5555-4555-8555-555555555555",
      eventCount: 2,
      attempt: 1,
    };
    expect(claimedEmailJobSchema.safeParse(payload).success).toBe(true);
    expect(claimedEmailJobSchema.safeParse({
      ...payload,
      payload: { memberName: "Sophie" },
    }).success).toBe(false);
    expect(claimedEmailJobSchema.safeParse({
      ...payload,
      fromName: undefined,
    }).success).toBe(false);
  });

  it("accepteert generieke v2-jobs alleen met passende immutable doelgroepcontext", () => {
    const payload = {
      id: "11111111-1111-4111-8111-111111111111",
      deliveryAttemptId: "11111111-1111-4111-8111-111111111112",
      kind: "bulk",
      contextKind: "mail_v2",
      recipientEmail: "ouder@example.nl",
      templateKey: "payment_reminder",
      templateRevisionId: "22222222-2222-4222-8222-222222222222",
      brandingRevisionId: "33333333-3333-4333-8333-333333333333",
      subject: "Betalingsherinnering",
      preheader: "Bekijk de afzonderlijke pakketbedragen.",
      html: "<p>Immutable HTML</p>",
      text: "Immutable tekst",
      fromName: "Kledingcommissie Duindorp SV",
      fromEmail: "kleding@duindorpsv.nl",
      replyToEmail: "kleding@duindorpsv.nl",
      renderHash: "a".repeat(64),
      parentAccountId: "44444444-4444-4444-8444-444444444444",
      seasonId: "55555555-5555-4555-8555-555555555555",
      eventCount: 2,
      attempt: 1,
    };
    expect(claimedEmailJobSchema.safeParse(payload).success).toBe(true);
    expect(claimedEmailJobSchema.safeParse({
      ...payload,
      templateKey: "login_otp",
    }).success).toBe(false);
    expect(claimedEmailJobSchema.safeParse({
      ...payload,
      parentAccountId: null,
    }).success).toBe(false);
    expect(claimedEmailJobSchema.safeParse({
      ...payload,
      templateKey: "internal_email_failure",
      parentAccountId: null,
      kind: "transactional",
    }).success).toBe(true);
    expect(claimedEmailJobSchema.safeParse({
      ...payload,
      templateKey: "internal_email_failure",
      parentAccountId: null,
      kind: "bulk",
    }).success).toBe(false);
  });

  it("accepts an administrator workspace with a redacted portal job", () => {
    const timestamp = "2026-08-02T12:00:00.000Z";
    const templateId = "11111111-1111-4111-8111-111111111111";
    const jobId = "22222222-2222-4222-8222-222222222222";
    const workspace = {
      recoveryAllowed: true,
      templateKeys: emailTemplateKeySchema.options,
      templates: emailTemplateKeySchema.options.map((key) => ({
        id: templateId,
        key,
        subjectSource: `Onderwerp ${key}`,
        bodySource: `Veilige template-inhoud voor ${key}.`,
        allowedShortcodes: ["{{clubnaam}}"],
        active: true,
        version: 1,
        updatedAt: timestamp,
      })),
      batches: [],
      jobs: [{
        id: jobId,
        contextKind: "portal_access",
        orderId: null,
        templateKey: "portal_access_invite",
        status: "failed",
        attempts: 1,
        deliveryStatus: null,
        availableAt: timestamp,
        sentAt: null,
        createdAt: timestamp,
        updatedAt: timestamp,
        claimedAt: null,
        recoverable: false,
      }],
      orders: [],
    };

    const parsed = emailWorkspaceSchema.safeParse(workspace);
    expect(parsed.success).toBe(true);
    if (!parsed.success) throw new Error("workspace fixture invalid");
    expect(emailJobOperationalState(parsed.data.jobs[0])).toBe(
      "permanent_rejection",
    );
    expect(emailJobOperationalState({
      ...parsed.data.jobs[0],
      status: "sent",
    })).toBe("provider_accepted");
    expect(emailJobOperationalState({
      ...parsed.data.jobs[0],
      status: "sent",
      deliveryStatus: "delivered",
    })).toBe("delivered");
    expect(emailWorkspaceSchema.safeParse({
      ...workspace,
      jobs: [{ ...workspace.jobs[0], recipientEmail: "ouder@example.invalid" }],
    }).success).toBe(false);
    expect(emailWorkspaceSchema.safeParse({
      ...workspace,
      jobs: [{
        ...workspace.jobs[0],
        contextKind: "fulfilment",
        templateKey: "package_complete",
      }],
    }).success).toBe(true);
    expect(emailWorkspaceSchema.safeParse({
      ...workspace,
      jobs: [{
        ...workspace.jobs[0],
        contextKind: "mail_v2",
        templateKey: "payment_reminder",
      }],
    }).success).toBe(true);
  });
});
