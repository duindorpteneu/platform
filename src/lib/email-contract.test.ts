import { describe, expect, it } from "vitest";
import {
  claimedEmailJobSchema,
  emailBulkRequestSchema,
  emailTemplateKeySchema,
  emailWorkspaceSchema,
  updateEmailTemplateRequestSchema,
} from "@/lib/email-contract";

describe("email contracts", () => {
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
      id, kind: "transactional", contextKind: "order", recipientEmail: "ouder@example.nl", templateKey: "payment_received",
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

    expect(emailWorkspaceSchema.safeParse(workspace).success).toBe(true);
    expect(emailWorkspaceSchema.safeParse({
      ...workspace,
      jobs: [{ ...workspace.jobs[0], recipientEmail: "ouder@example.invalid" }],
    }).success).toBe(false);
  });
});
