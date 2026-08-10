import { createHash, randomUUID } from "node:crypto";
import { z } from "zod";
import {
  fulfilmentMailProjectionClaimEnvelopeSchema,
  fulfilmentMailProjectionFinalizeSchema,
  fulfilmentMailProjectionGroupSchema,
  mailV2DomainProjectionClaimEnvelopeSchema,
  mailV2DomainProjectionFinalizeSchema,
  mailV2DomainProjectionGroupSchema,
  type FulfilmentMailProjectionGroup,
  type MailLine,
  type MailProtectedValues,
  type MailShortcodeKey,
  type MailV2DomainProjectionGroup,
} from "@/lib/mail-v2-contract";
import { renderMailV2 } from "@/server/email/mail-v2";
import { getSupabaseAdminClient } from "@/server/supabase/admin";

type AdminClient = NonNullable<ReturnType<typeof getSupabaseAdminClient>>;

const utf8Length = (value: string) => new TextEncoder().encode(value).byteLength;
const renderedProjectionSchema = z.object({
  templateRevisionId: z.string().uuid(),
  brandingRevisionId: z.string().uuid(),
  subject: z.string().trim().min(1).max(200).refine(
    (value) => !/[\r\n]/u.test(value),
  ),
  preheader: z.string().trim().min(1).max(240).refine(
    (value) => !/[\r\n]/u.test(value),
  ),
  html: z.string().trim().min(1).refine(
    (value) => utf8Length(value) <= 50_000,
  ).refine(
    (value) => !/<\s*(?:script|iframe|form|object|embed|style|link|meta|base|svg|math)\b/iu.test(value)
      && !/\son[a-z]+\s*=/iu.test(value)
      && !/(?:href|src)\s*=\s*["']\s*(?:javascript|vbscript|data)\s*:/iu.test(value),
  ),
  text: z.string().trim().min(1).refine(
    (value) => utf8Length(value) <= 20_000,
  ),
  fromName: z.string().trim().min(3).max(120),
  fromEmail: z.string().trim().email().max(254),
  replyToEmail: z.string().trim().email().max(254),
}).strict();

export type FulfilmentProjectionResult = {
  claimed: number;
  queued: number;
  suppressed: number;
  deferred: number;
  errors: number;
};
export type MailProjectionResult = FulfilmentProjectionResult;

function compactList(values: string[]) {
  const unique = [...new Set(values.map((value) => value.trim()).filter(Boolean))];
  if (unique.length <= 3) {
    if (unique.length <= 1) return unique[0] ?? "";
    return `${unique.slice(0, -1).join(", ")} en ${unique.at(-1)}`;
  }
  return `${unique.slice(0, 3).join(", ")} en ${unique.length - 3} andere`;
}

function statusLabel(status: string | undefined) {
  const labels: Record<string, string> = {
    backorder: "Nalevering",
    ready_for_pickup: "Af te halen",
    picked_up: "Afgehaald",
  };
  return status ? labels[status] ?? status : undefined;
}

function formatMoney(amountCents: number) {
  return new Intl.NumberFormat("nl-NL", {
    style: "currency",
    currency: "EUR",
  }).format(amountCents / 100);
}

function projectionRows(
  group: FulfilmentMailProjectionGroup,
  field: "issued" | "remaining" | "package",
): MailLine[] {
  return group.events.flatMap((event) => event[field].map((line) => ({
    memberFirstName: event.memberFirstName,
    product: line.product,
    size: line.size,
    quantity: line.quantity,
    ...(line.status ? { status: statusLabel(line.status) } : {}),
  })));
}

function shortcodeValues(
  group: FulfilmentMailProjectionGroup,
  appBaseUrl: string,
): Record<MailShortcodeKey, string | number> {
  const portalUrl = new URL("/mijn-tenue", appBaseUrl).toString();
  const paymentUrl = new URL("/mijn-tenue", appBaseUrl).toString();
  const pickupAddress = [
    group.branding.pickupAddressLine,
    group.branding.pickupPostalCode,
    group.branding.pickupCity,
  ].join(", ");
  return {
    club_name: group.branding.clubName,
    recipient_name: "ouder/verzorger",
    member_first_name: compactList(
      group.events.map((event) => event.memberFirstName),
    ),
    member_full_name: compactList(
      group.events.map((event) => event.memberFullName),
    ),
    team_name: compactList(group.events.map((event) => event.teamName)),
    season_name: compactList(group.events.map((event) => event.seasonName)),
    package_name: compactList(group.events.map((event) => event.packageName)),
    package_amount: "Niet van toepassing",
    payment_url: paymentUrl,
    portal_url: portalUrl,
    size_confirm_url: portalUrl,
    pickup_name: group.branding.pickupName,
    pickup_address: pickupAddress,
    contact_email: group.branding.contactEmail,
    privacy_url: group.branding.privacyUrl,
    otp_expiry_minutes: 10,
  };
}

export function renderFulfilmentProjectionGroup(
  group: FulfilmentMailProjectionGroup,
  appBaseUrl: string,
) {
  const { id: templateRevisionId, contentHash: _templateHash, ...source } = group.template;
  const { id: brandingRevisionId, contentHash: _brandingHash, ...branding } = group.branding;
  void _templateHash;
  void _brandingHash;
  const portalUrl = new URL("/mijn-tenue", appBaseUrl).toString();
  const protectedValues: MailProtectedValues = group.eventType === "partial_pickup"
    ? {
      picked_up_items: { rows: projectionRows(group, "issued") },
      remaining_items: { rows: projectionRows(group, "remaining") },
    }
    : {
      full_package: { rows: projectionRows(group, "package") },
    };
  const rendered = renderMailV2({
    source,
    branding,
    shortcodes: shortcodeValues(group, appBaseUrl),
    protectedValues: {
      ...protectedValues,
      pickup_qr: { portalUrl },
    },
    appBaseUrl,
  });
  return renderedProjectionSchema.parse({
    templateRevisionId,
    brandingRevisionId,
    ...rendered,
  });
}

export function fulfilmentMailRenderHash(input: {
  groupId: string;
  eligibilityRevision: string;
  templateRevisionId: string;
  brandingRevisionId: string;
  subject: string;
  preheader: string;
  html: string;
  text: string;
}) {
  return createHash("sha256").update([
    input.groupId,
    input.eligibilityRevision,
    input.templateRevisionId,
    input.brandingRevisionId,
    input.subject,
    input.preheader,
    input.html,
    input.text,
  ].join("\n"), "utf8").digest("hex");
}

type DomainPayload =
  MailV2DomainProjectionGroup["events"][number]["payload"];
type DomainMemberPayload = Extract<
  DomainPayload,
  { memberSeasonId: string }
>;

function domainMemberEvents(group: MailV2DomainProjectionGroup) {
  return group.events.filter(
    (event): event is typeof event & { payload: DomainMemberPayload } =>
      "memberSeasonId" in event.payload,
  );
}

function domainRows(group: MailV2DomainProjectionGroup): MailLine[] {
  return domainMemberEvents(group).flatMap((event) =>
    event.payload.lines.map((line) => ({
      memberFirstName: event.payload.memberFirstName,
      product: line.product,
      size: line.size,
      quantity: line.quantity,
      ...(line.status ? { status: statusLabel(line.status) } : {}),
    })));
}

function domainShortcodeValues(
  group: MailV2DomainProjectionGroup,
  appBaseUrl: string,
): Record<MailShortcodeKey, string | number> {
  const events = domainMemberEvents(group);
  const portalUrl = new URL("/mijn-tenue", appBaseUrl).toString();
  const values = <K extends keyof DomainMemberPayload>(
    key: K,
  ) => events.map((event) => event.payload[key]);
  const amounts = values("amountCents").filter(
    (amount): amount is number => typeof amount === "number",
  );
  const paymentAmounts = events
    .filter((event) => typeof event.payload.amountCents === "number")
    .map((event) =>
      `${event.payload.memberFirstName}: ${formatMoney(event.payload.amountCents ?? 0)}`);
  const pickupAddress = [
    group.branding.pickupAddressLine,
    group.branding.pickupPostalCode,
    group.branding.pickupCity,
  ].join(", ");
  return {
    club_name: group.branding.clubName,
    recipient_name: "ouder/verzorger",
    member_first_name: compactList(values("memberFirstName")) || "Lid",
    member_full_name: compactList(values("memberFullName")) || "Lid",
    team_name: compactList(values("teamName")) || "Niet opgegeven",
    season_name: compactList(values("seasonName")) || "Actief seizoen",
    package_name: compactList(values("packageName")) || "Kledingpakket",
    package_amount: amounts.length === 1
      ? formatMoney(amounts[0] ?? 0)
      : paymentAmounts.length > 1
        ? paymentAmounts.join("; ")
      : "Niet van toepassing",
    payment_url: portalUrl,
    portal_url: portalUrl,
    size_confirm_url: portalUrl,
    pickup_name: group.branding.pickupName,
    pickup_address: pickupAddress,
    contact_email: group.branding.contactEmail,
    privacy_url: group.branding.privacyUrl,
    otp_expiry_minutes: 10,
  };
}

function domainProtectedValues(
  group: MailV2DomainProjectionGroup,
  appBaseUrl: string,
): MailProtectedValues {
  const events = domainMemberEvents(group);
  const portalUrl = new URL("/mijn-tenue", appBaseUrl).toString();
  const loginUrl = new URL("/login", appBaseUrl).toString();
  const rows = domainRows(group);
  const pickupAddress = [
    group.branding.pickupAddressLine,
    group.branding.pickupPostalCode,
    group.branding.pickupCity,
  ].join(", ");
  switch (group.templateKey) {
    case "portal_access_invite":
    case "portal_access_reminder":
      return {
        portal_route: {
          url: loginUrl,
          label: "Open het tenueportaal",
        },
      };
    case "size_fill_request":
    case "size_fill_reminder":
    case "size_review_request":
    case "size_review_reminder":
      return {
        size_table: { rows },
        size_action: {
          url: portalUrl,
          label: "Maten controleren",
        },
      };
    case "size_confirmed":
      return { size_table: { rows } };
    case "payment_request":
    case "payment_reminder":
      return {
        payment_summary: {
          orders: events.map((event) => ({
            memberFirstName: event.payload.memberFirstName,
            packageName: event.payload.packageName,
            amountCents: event.payload.amountCents ?? 0,
            currency: "EUR" as const,
          })),
        },
        payment_action: {
          url: portalUrl,
          label: "Naar het betaaloverzicht",
        },
      };
    case "payment_received_waiting_stock":
      return {
        payment_summary: {
          orders: events.map((event) => ({
            memberFirstName: event.payload.memberFirstName,
            packageName: event.payload.packageName,
            amountCents: event.payload.amountCents ?? 0,
            currency: "EUR" as const,
          })),
        },
        stock_items: { rows },
      };
    case "available_payment_required":
      return {
        stock_items: { rows },
        payment_action: {
          url: portalUrl,
          label: "Naar het betaaloverzicht",
        },
      };
    case "pickup_ready":
    case "pickup_reminder":
      return {
        ready_items: { rows },
        pickup_location: {
          name: group.branding.pickupName,
          address: pickupAddress,
        },
        pickup_qr: { portalUrl },
      };
    case "out_of_stock":
      return { stock_items: { rows } };
    case "back_in_stock":
      return {
        ready_items: { rows },
        pickup_location: {
          name: group.branding.pickupName,
          address: pickupAddress,
        },
      };
    case "internal_email_failure": {
      const event = group.events[0];
      if (!event || !("jobId" in event.payload)) {
        throw new Error("MAIL_V2_FAILURE_REFERENCE_MISSING");
      }
      return {
        failure_reference: {
          jobId: event.payload.jobId,
          reason: event.payload.reason,
        },
      };
    }
  }
}

export function renderMailV2DomainProjectionGroup(
  group: MailV2DomainProjectionGroup,
  appBaseUrl: string,
) {
  const { id: templateRevisionId, contentHash: _templateHash, ...source } =
    group.template;
  const { id: brandingRevisionId, contentHash: _brandingHash, ...branding } =
    group.branding;
  void _templateHash;
  void _brandingHash;
  const rendered = renderMailV2({
    source,
    branding,
    shortcodes: domainShortcodeValues(group, appBaseUrl),
    protectedValues: domainProtectedValues(group, appBaseUrl),
    appBaseUrl,
  });
  return renderedProjectionSchema.parse({
    templateRevisionId,
    brandingRevisionId,
    ...rendered,
  });
}

async function suppressProjection(
  admin: AdminClient,
  groupId: string,
  leaseToken: string,
  reason:
    | "render_invalid"
    | "projection_response_invalid"
    | "projection_finalize_invalid",
) {
  return admin.schema("app").rpc("fail_fulfilment_mail_projection_v1", {
    p_projection_batch_id: groupId,
    p_lease_token: leaseToken,
    p_reason: reason,
  });
}

export async function projectFulfilmentMail(
  admin: AdminClient,
  appBaseUrl: string,
): Promise<FulfilmentProjectionResult> {
  const leaseToken = randomUUID();
  const claimResult = await admin.schema("app").rpc(
    "claim_fulfilment_mail_projections_v1",
    { p_lease_token: leaseToken, p_limit: 10 },
  );
  const claim = fulfilmentMailProjectionClaimEnvelopeSchema.safeParse(
    claimResult.data,
  );
  if (claimResult.error || !claim.success || claim.data.leaseToken !== leaseToken) {
    return {
      claimed: 0,
      queued: 0,
      suppressed: 0,
      deferred: 0,
      errors: 1,
    };
  }

  const result: FulfilmentProjectionResult = {
    claimed: claim.data.groups.length,
    queued: 0,
    suppressed: 0,
    deferred: 0,
    errors: 0,
  };
  const groups: FulfilmentMailProjectionGroup[] = [];
  for (const rawGroup of claim.data.groups) {
    const parsed = fulfilmentMailProjectionGroupSchema.safeParse(rawGroup);
    if (parsed.success) {
      groups.push(parsed.data);
      continue;
    }
    const identity = z.object({ groupId: z.string().uuid() })
      .passthrough()
      .safeParse(rawGroup);
    if (!identity.success) {
      result.errors += 1;
      continue;
    }
    const suppressed = await suppressProjection(
      admin,
      identity.data.groupId,
      leaseToken,
      "projection_response_invalid",
    );
    if (suppressed.error) result.errors += 1;
    else result.suppressed += 1;
  }

  for (let offset = 0; offset < groups.length; offset += 5) {
    await Promise.all(groups.slice(offset, offset + 5).map(
      async (group) => {
        let rendered: ReturnType<typeof renderFulfilmentProjectionGroup>;
        try {
          rendered = renderFulfilmentProjectionGroup(group, appBaseUrl);
        } catch {
          const suppressed = await suppressProjection(
            admin,
            group.groupId,
            leaseToken,
            "render_invalid",
          );
          if (suppressed.error) result.errors += 1;
          else result.suppressed += 1;
          return;
        }
        const renderHash = fulfilmentMailRenderHash({
          groupId: group.groupId,
          eligibilityRevision: group.eligibilityRevision,
          templateRevisionId: rendered.templateRevisionId,
          brandingRevisionId: rendered.brandingRevisionId,
          subject: rendered.subject,
          preheader: rendered.preheader,
          html: rendered.html,
          text: rendered.text,
        });
        const finalized = await admin.schema("app").rpc(
          "finalize_fulfilment_mail_projection_v1",
          {
            p_projection_batch_id: group.groupId,
            p_lease_token: leaseToken,
            p_eligibility_revision: group.eligibilityRevision,
            p_subject: rendered.subject,
            p_preheader: rendered.preheader,
            p_html: rendered.html,
            p_text: rendered.text,
            p_render_hash: renderHash,
          },
        );
        if (finalized.error) {
          if (["22023", "23514"].includes(finalized.error.code ?? "")) {
            const suppressed = await suppressProjection(
              admin,
              group.groupId,
              leaseToken,
              "projection_finalize_invalid",
            );
            if (suppressed.error) result.errors += 1;
            else result.suppressed += 1;
          } else {
            result.errors += 1;
          }
          return;
        }
        const parsed = fulfilmentMailProjectionFinalizeSchema.safeParse(
          finalized.data,
        );
        if (!parsed.success || parsed.data.groupId !== group.groupId) {
          const suppressed = await suppressProjection(
            admin,
            group.groupId,
            leaseToken,
            "projection_response_invalid",
          );
          if (suppressed.error) result.errors += 1;
          else result.suppressed += 1;
          return;
        }
        if (parsed.data.status === "queued") result.queued += 1;
        else if (parsed.data.status === "suppressed") result.suppressed += 1;
        else result.deferred += 1;
      },
    ));
  }
  return result;
}

async function suppressDomainProjection(
  admin: AdminClient,
  groupId: string,
  leaseToken: string,
  reason:
    | "render_invalid"
    | "projection_response_invalid"
    | "projection_finalize_invalid",
) {
  return admin.schema("app").rpc("fail_mail_v2_domain_projection_v1", {
    p_projection_batch_id: groupId,
    p_lease_token: leaseToken,
    p_reason: reason,
  });
}

export async function projectMailV2DomainEvents(
  admin: AdminClient,
  appBaseUrl: string,
): Promise<MailProjectionResult> {
  const leaseToken = randomUUID();
  const claimResult = await admin.schema("app").rpc(
    "claim_mail_v2_domain_projections_v1",
    { p_lease_token: leaseToken, p_limit: 10 },
  );
  const claim = mailV2DomainProjectionClaimEnvelopeSchema.safeParse(
    claimResult.data,
  );
  if (
    claimResult.error
    || !claim.success
    || claim.data.leaseToken !== leaseToken
  ) {
    return {
      claimed: 0,
      queued: 0,
      suppressed: 0,
      deferred: 0,
      errors: 1,
    };
  }

  const result: MailProjectionResult = {
    claimed: claim.data.groups.length,
    queued: 0,
    suppressed: 0,
    deferred: 0,
    errors: 0,
  };
  const groups: MailV2DomainProjectionGroup[] = [];
  for (const rawGroup of claim.data.groups) {
    const parsed = mailV2DomainProjectionGroupSchema.safeParse(rawGroup);
    if (parsed.success) {
      groups.push(parsed.data);
      continue;
    }
    const identity = z.object({ groupId: z.string().uuid() })
      .passthrough()
      .safeParse(rawGroup);
    if (!identity.success) {
      result.errors += 1;
      continue;
    }
    const suppressed = await suppressDomainProjection(
      admin,
      identity.data.groupId,
      leaseToken,
      "projection_response_invalid",
    );
    if (suppressed.error) result.errors += 1;
    else result.suppressed += 1;
  }

  for (let offset = 0; offset < groups.length; offset += 5) {
    await Promise.all(groups.slice(offset, offset + 5).map(async (group) => {
      let rendered: ReturnType<typeof renderMailV2DomainProjectionGroup>;
      try {
        rendered = renderMailV2DomainProjectionGroup(group, appBaseUrl);
      } catch {
        const suppressed = await suppressDomainProjection(
          admin,
          group.groupId,
          leaseToken,
          "render_invalid",
        );
        if (suppressed.error) result.errors += 1;
        else result.suppressed += 1;
        return;
      }
      const renderHash = fulfilmentMailRenderHash({
        groupId: group.groupId,
        eligibilityRevision: group.eligibilityRevision,
        templateRevisionId: rendered.templateRevisionId,
        brandingRevisionId: rendered.brandingRevisionId,
        subject: rendered.subject,
        preheader: rendered.preheader,
        html: rendered.html,
        text: rendered.text,
      });
      const finalized = await admin.schema("app").rpc(
        "finalize_mail_v2_domain_projection_v1",
        {
          p_projection_batch_id: group.groupId,
          p_lease_token: leaseToken,
          p_eligibility_revision: group.eligibilityRevision,
          p_subject: rendered.subject,
          p_preheader: rendered.preheader,
          p_html: rendered.html,
          p_text: rendered.text,
          p_render_hash: renderHash,
        },
      );
      if (finalized.error) {
        if (["22023", "23514"].includes(finalized.error.code ?? "")) {
          const suppressed = await suppressDomainProjection(
            admin,
            group.groupId,
            leaseToken,
            "projection_finalize_invalid",
          );
          if (suppressed.error) result.errors += 1;
          else result.suppressed += 1;
        } else {
          result.errors += 1;
        }
        return;
      }
      const parsed = mailV2DomainProjectionFinalizeSchema.safeParse(
        finalized.data,
      );
      if (!parsed.success || parsed.data.groupId !== group.groupId) {
        const suppressed = await suppressDomainProjection(
          admin,
          group.groupId,
          leaseToken,
          "projection_response_invalid",
        );
        if (suppressed.error) result.errors += 1;
        else result.suppressed += 1;
        return;
      }
      if (parsed.data.status === "queued") result.queued += 1;
      else if (parsed.data.status === "suppressed") result.suppressed += 1;
      else result.deferred += 1;
    }));
  }
  return result;
}
