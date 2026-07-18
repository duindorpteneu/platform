import { describe, expect, it } from "vitest";
import { claimedEmailJobSchema, emailBulkRequestSchema, emailTemplateKeySchema, updateEmailTemplateRequestSchema } from "@/lib/email-contract";

describe("email contracts", () => {
  it("contains exactly the six canonical templates", () => {
    expect(emailTemplateKeySchema.options).toEqual([
      "verification_code", "payment_request", "payment_received", "ready_for_pickup", "payment_reminder", "qr_code_resent",
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
      id, kind: "transactional", recipientEmail: "ouder@example.nl", templateKey: "payment_received",
      templateVersion: 3, subjectSource: "Betaling ontvangen", bodySource: "Uw betaling is veilig ontvangen.",
      allowedShortcodes: ["{{volledige_naam}}"], orderId: id, attempt: 1,
      payload: { orderId: id, memberId: "22222222-2222-4222-8222-222222222222", firstName: "Sophie", fullName: "Sophie de Bruin", team: "JO11-1", relationNumber: "DSV-1", season: "2026/27", amountCents: 12500, clubName: "Duindorp SV", contactEmail: "kleding@duindorpsv.nl", pickupLocation: "Clubhuis", qrVersion: 1, articles: [], articlesReady: [], articlesBackorder: [] },
    };
    expect(claimedEmailJobSchema.safeParse(payload).success).toBe(true);
    expect(claimedEmailJobSchema.safeParse({ ...payload, templateVersion: undefined }).success).toBe(false);
  });
});
