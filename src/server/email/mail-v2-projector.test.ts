import { describe, expect, it, vi } from "vitest";
import type {
  FulfilmentMailProjectionGroup,
  MailV2DomainProjectionGroup,
} from "@/lib/mail-v2-contract";
import {
  fulfilmentMailRenderHash,
  projectFulfilmentMail,
  projectMailV2DomainEvents,
  renderFulfilmentProjectionGroup,
  renderMailV2DomainProjectionGroup,
} from "@/server/email/mail-v2-projector";

const branding = {
  id: "69000000-0000-4000-8000-000000000001",
  clubName: "Duindorp SV" as const,
  logoAssetPath: "/duindorp-sv-logo.png" as const,
  fromName: "Kledingcommissie Duindorp SV",
  fromEmail: "kleding@duindorpsv.nl",
  replyToEmail: "kleding@duindorpsv.nl",
  contactEmail: "kleding@duindorpsv.nl",
  clubAddressLine: "Houtrustlaan 1",
  clubPostalCode: "2566 ZW",
  clubCity: "Den Haag",
  pickupName: "Free-Kick Sport",
  pickupAddressLine: "De Savornin Lohmanplein 45",
  pickupPostalCode: "2566 AE",
  pickupCity: "Den Haag",
  privacyUrl: "https://duindorpsv.nl/privacy" as const,
  primaryColor: "#17418B",
  secondaryColor: "#0B2E63",
  accentColor: "#2E69CC",
  footerText: "Kledingcommissie Duindorp SV",
  contrastValidated: true,
  contentHash: "b".repeat(64),
};

function group(
  eventType: "partial_pickup" | "package_complete" = "partial_pickup",
): FulfilmentMailProjectionGroup {
  const protectedKinds = eventType === "partial_pickup"
    ? ["picked_up_items", "remaining_items"] as const
    : ["full_package"] as const;
  return {
    groupId: "69000000-0000-4000-8000-000000000010",
    eligibilityRevision: "c".repeat(64),
    eventType,
    template: {
      id: "69000000-0000-4000-8000-000000000013",
      templateKey: eventType,
      subjectSource: "Uitgifte voor {{member_first_name}}",
      preheaderSource: "Status voor seizoen {{season_name}}",
      bodyTipTap: {
        type: "doc",
        content: [
          {
            type: "paragraph",
            content: [
              { type: "text", text: "Beste ouder van " },
              { type: "shortcode", attrs: { key: "member_first_name" } },
            ],
          },
          ...protectedKinds.map((kind) => ({
            type: "protectedBlock" as const,
            attrs: { kind },
          })),
        ],
      },
      allowedShortcodes: [
        "club_name",
        "recipient_name",
        "member_first_name",
        "member_full_name",
        "team_name",
        "season_name",
        "package_name",
        "portal_url",
        "contact_email",
        "privacy_url",
      ],
      allowedProtectedNodes: [...protectedKinds],
      requiredProtectedNodes: [...protectedKinds],
      contentHash: "a".repeat(64),
    },
    branding,
    events: [
      {
        eventId: "69000000-0000-4000-8000-000000000020",
        memberFirstName: "<Sophie>",
        memberFullName: "<Sophie> de Test",
        teamName: "JO11-1",
        seasonName: "2026/27",
        packageName: "Speler",
        issued: [{ product: "<Shirt>", size: "152", quantity: 1 }],
        remaining: eventType === "partial_pickup"
          ? [{ product: "Broek", size: "152", quantity: 1, status: "backorder" }]
          : [],
        package: [{ product: "<Shirt>", size: "152", quantity: 1, status: "picked_up" }],
      },
      {
        eventId: "69000000-0000-4000-8000-000000000030",
        memberFirstName: "Milan",
        memberFullName: "Milan de Test",
        teamName: "JO13-1",
        seasonName: "2026/27",
        packageName: "Keeper",
        issued: [{ product: "Keepersshirt", size: "164", quantity: 1 }],
        remaining: eventType === "partial_pickup"
          ? [{ product: "Kousen", size: "39-42", quantity: 1, status: "ready_for_pickup" }]
          : [],
        package: [{ product: "Keepersshirt", size: "164", quantity: 1, status: "picked_up" }],
      },
    ],
  };
}

function domainGroup(): MailV2DomainProjectionGroup {
  return {
    groupId: "68000000-0000-4000-8000-000000000010",
    eligibilityRevision: "d".repeat(64),
    templateKey: "payment_request",
    template: {
      id: "68000000-0000-4000-8000-000000000011",
      templateKey: "payment_request",
      subjectSource: "Betaalverzoek voor {{member_first_name}}",
      preheaderSource: "Bekijk de afzonderlijke pakketbedragen.",
      bodyTipTap: {
        type: "doc",
        content: [
          {
            type: "paragraph",
            content: [{
              type: "text",
              text: "Betaal ieder pakket afzonderlijk.",
            }],
          },
          { type: "protectedBlock", attrs: { kind: "payment_summary" } },
          { type: "protectedBlock", attrs: { kind: "payment_action" } },
        ],
      },
      allowedShortcodes: [
        "club_name",
        "member_first_name",
        "package_amount",
        "payment_url",
        "portal_url",
        "contact_email",
        "privacy_url",
      ],
      allowedProtectedNodes: ["payment_summary", "payment_action"],
      requiredProtectedNodes: ["payment_summary", "payment_action"],
      contentHash: "e".repeat(64),
    },
    branding,
    events: [
      {
        eventId: "68000000-0000-4000-8000-000000000020",
        payload: {
          memberSeasonId: "68000000-0000-4000-8000-000000000021",
          memberFirstName: "<Sophie>",
          memberFullName: "<Sophie> de Test",
          teamName: "JO11-1",
          seasonName: "2026/27",
          orderId: "68000000-0000-4000-8000-000000000022",
          packageName: "Speler",
          amountCents: 12_500,
          currency: "EUR",
          lines: [],
        },
      },
      {
        eventId: "68000000-0000-4000-8000-000000000030",
        payload: {
          memberSeasonId: "68000000-0000-4000-8000-000000000031",
          memberFirstName: "Milan",
          memberFullName: "Milan de Test",
          teamName: "JO13-1",
          seasonName: "2026/27",
          orderId: "68000000-0000-4000-8000-000000000032",
          packageName: "Keeper",
          amountCents: 10_000,
          currency: "EUR",
          lines: [],
        },
      },
    ],
  };
}

function internalFailureGroup(): MailV2DomainProjectionGroup {
  return {
    groupId: "67000000-0000-4000-8000-000000000010",
    eligibilityRevision: "f".repeat(64),
    templateKey: "internal_email_failure",
    template: {
      id: "67000000-0000-4000-8000-000000000011",
      templateKey: "internal_email_failure",
      subjectSource: "Definitieve e-mailfout",
      preheaderSource: "Een mailjob vereist beheeractie.",
      bodyTipTap: {
        type: "doc",
        content: [
          {
            type: "paragraph",
            content: [{ type: "text", text: "Controleer de mailjob." }],
          },
          { type: "protectedBlock", attrs: { kind: "failure_reference" } },
        ],
      },
      allowedShortcodes: ["club_name", "contact_email"],
      allowedProtectedNodes: ["failure_reference"],
      requiredProtectedNodes: ["failure_reference"],
      contentHash: "1".repeat(64),
    },
    branding,
    events: [{
      eventId: "67000000-0000-4000-8000-000000000020",
      payload: {
        jobId: "67000000-0000-4000-8000-000000000021",
        reason: "provider_bounced",
      },
    }],
  };
}

function pickupDomainGroup(): MailV2DomainProjectionGroup {
  const base = domainGroup();
  return {
    ...base,
    templateKey: "pickup_ready",
    template: {
      ...base.template,
      templateKey: "pickup_ready",
      subjectSource: "Afhalen voor {{member_first_name}}",
      preheaderSource: "Uw gereserveerde pakketregels liggen klaar.",
      bodyTipTap: {
        type: "doc",
        content: [
          { type: "protectedBlock", attrs: { kind: "ready_items" } },
          { type: "protectedBlock", attrs: { kind: "pickup_location" } },
          { type: "protectedBlock", attrs: { kind: "pickup_qr" } },
        ],
      },
      allowedProtectedNodes: [
        "ready_items",
        "pickup_location",
        "pickup_qr",
      ],
      requiredProtectedNodes: [
        "ready_items",
        "pickup_location",
        "pickup_qr",
      ],
    },
    events: base.events.map((event, index) => ({
      ...event,
      payload: {
        ...event.payload,
        lines: [{
          product: index === 0 ? "<Shirt>" : "Keepersshirt",
          size: index === 0 ? "152" : "164",
          quantity: 1,
          status: "ready_for_pickup",
        }],
      },
    })),
  };
}

describe("mail-v2 fulfilmentprojector", () => {
  it("consolideert gezinsregels en escapet lid- en productwaarden", () => {
    const rendered = renderFulfilmentProjectionGroup(
      group(),
      "https://tenue.duindorpsv.nl",
    );

    expect(rendered.subject).toBe("Uitgifte voor <Sophie> en Milan");
    expect(rendered.html).toContain("&lt;Sophie&gt;");
    expect(rendered.html).toContain("&lt;Shirt&gt;");
    expect(rendered.html).not.toContain("<Sophie>");
    expect(rendered.text).toContain("Nalevering");
    expect(rendered.text).toContain("Af te halen");
    expect(rendered.fromEmail).toBe("kleding@duindorpsv.nl");
  });

  it("rendert een eindbevestiging uitsluitend uit het volledige pakketsnapshot", () => {
    const rendered = renderFulfilmentProjectionGroup(
      group("package_complete"),
      "https://tenue.duindorpsv.nl",
    );

    expect(rendered.text).toContain("Volledig pakket");
    expect(rendered.text).not.toContain("Nog te leveren");
  });

  it("berekent dezelfde renderhash deterministisch en inhoudsgevoelig", () => {
    const rendered = renderFulfilmentProjectionGroup(
      group(),
      "https://tenue.duindorpsv.nl",
    );
    const input = {
      groupId: group().groupId,
      eligibilityRevision: group().eligibilityRevision,
      templateRevisionId: rendered.templateRevisionId,
      brandingRevisionId: rendered.brandingRevisionId,
      subject: rendered.subject,
      preheader: rendered.preheader,
      html: rendered.html,
      text: rendered.text,
    };
    const first = fulfilmentMailRenderHash(input);
    expect(first).toMatch(/^[0-9a-f]{64}$/u);
    expect(fulfilmentMailRenderHash(input)).toBe(first);
    expect(fulfilmentMailRenderHash({
      ...input,
      text: `${input.text}.`,
    })).not.toBe(first);
  });

  it("weigert gerenderde headers die na tokenvervanging de providergrens overschrijden", () => {
    const oversized = group();
    oversized.events[0]!.memberFirstName = "A".repeat(160);
    oversized.events[1]!.memberFirstName = "B".repeat(160);

    expect(() => renderFulfilmentProjectionGroup(
      oversized,
      "https://tenue.duindorpsv.nl",
    )).toThrow();
  });

  it("claimt, rendert en finaliseert één geconsolideerde job", async () => {
    const calls: string[] = [];
    const rpc = vi.fn(async (name: string, args: Record<string, unknown>) => {
      calls.push(name);
      if (name === "claim_fulfilment_mail_projections_v1") {
        return {
          data: {
            leaseToken: args.p_lease_token,
            groups: [group()],
          },
          error: null,
        };
      }
      if (name === "finalize_fulfilment_mail_projection_v1") {
        return {
          data: {
            groupId: group().groupId,
            jobId: "69000000-0000-4000-8000-000000000099",
            status: "queued",
            eventCount: 2,
            reused: false,
          },
          error: null,
        };
      }
      return { data: null, error: { code: "PGRST202" } };
    });
    const admin = { schema: () => ({ rpc }) };

    await expect(projectFulfilmentMail(
      admin as never,
      "https://tenue.duindorpsv.nl",
    )).resolves.toEqual({
      claimed: 1,
      queued: 1,
      suppressed: 0,
      deferred: 0,
      errors: 0,
    });
    expect(calls).toEqual([
      "claim_fulfilment_mail_projections_v1",
      "finalize_fulfilment_mail_projection_v1",
    ]);
    expect(rpc).toHaveBeenLastCalledWith(
      "finalize_fulfilment_mail_projection_v1",
      expect.objectContaining({
        p_projection_batch_id: group().groupId,
        p_eligibility_revision: group().eligibilityRevision,
        p_render_hash: expect.stringMatching(/^[0-9a-f]{64}$/u),
      }),
    );
  });

  it("isoleert een ongeldige groep en verwerkt overige leases wel", async () => {
    const invalidGroup = {
      ...group(),
      groupId: "69000000-0000-4000-8000-000000000040",
      events: [{
        ...group().events[0],
        memberFullName: "X".repeat(321),
      }],
    };
    const rpc = vi.fn(async (name: string, args: Record<string, unknown>) => {
      if (name === "claim_fulfilment_mail_projections_v1") {
        return {
          data: {
            leaseToken: args.p_lease_token,
            groups: [invalidGroup, group()],
          },
          error: null,
        };
      }
      if (name === "fail_fulfilment_mail_projection_v1") {
        return {
          data: {
            groupId: args.p_projection_batch_id,
            status: "suppressed",
            reused: false,
          },
          error: null,
        };
      }
      if (name === "finalize_fulfilment_mail_projection_v1") {
        return {
          data: {
            groupId: group().groupId,
            jobId: "69000000-0000-4000-8000-000000000099",
            status: "queued",
            eventCount: 2,
            reused: false,
          },
          error: null,
        };
      }
      return { data: null, error: { code: "PGRST202" } };
    });
    const admin = { schema: () => ({ rpc }) };

    await expect(projectFulfilmentMail(
      admin as never,
      "https://tenue.duindorpsv.nl",
    )).resolves.toEqual({
      claimed: 2,
      queued: 1,
      suppressed: 1,
      deferred: 0,
      errors: 0,
    });
    expect(rpc).toHaveBeenCalledWith(
      "fail_fulfilment_mail_projection_v1",
      expect.objectContaining({
        p_projection_batch_id: invalidGroup.groupId,
        p_reason: "projection_response_invalid",
      }),
    );
  });

  it("onderdrukt een deterministisch door de database geweigerde render", async () => {
    const rpc = vi.fn(async (name: string, args: Record<string, unknown>) => {
      if (name === "claim_fulfilment_mail_projections_v1") {
        return {
          data: { leaseToken: args.p_lease_token, groups: [group()] },
          error: null,
        };
      }
      if (name === "finalize_fulfilment_mail_projection_v1") {
        return { data: null, error: { code: "23514" } };
      }
      if (name === "fail_fulfilment_mail_projection_v1") {
        return {
          data: {
            groupId: group().groupId,
            status: "suppressed",
            reused: false,
          },
          error: null,
        };
      }
      return { data: null, error: { code: "PGRST202" } };
    });
    const admin = { schema: () => ({ rpc }) };

    await expect(projectFulfilmentMail(
      admin as never,
      "https://tenue.duindorpsv.nl",
    )).resolves.toEqual({
      claimed: 1,
      queued: 0,
      suppressed: 1,
      deferred: 0,
      errors: 0,
    });
    expect(rpc).toHaveBeenLastCalledWith(
      "fail_fulfilment_mail_projection_v1",
      expect.objectContaining({ p_reason: "projection_finalize_invalid" }),
    );
  });
});

describe("mail-v2 domeinprojector", () => {
  it("consolideert per gezin zonder gezinssom of gezinsbetaling", () => {
    const rendered = renderMailV2DomainProjectionGroup(
      domainGroup(),
      "https://tenue.duindorpsv.nl",
    );

    expect(rendered.subject).toBe("Betaalverzoek voor <Sophie> en Milan");
    expect(rendered.html).toContain("&lt;Sophie&gt;");
    expect(rendered.text).toContain("<Sophie> · Speler");
    expect(rendered.text).toContain("Milan · Keeper");
    expect(rendered.text).toContain("125,00");
    expect(rendered.text).toContain("100,00");
    expect(rendered.text).not.toContain("225,00");
    expect(rendered.text).toContain("Ieder pakket wordt afzonderlijk");
    expect(rendered.text).not.toMatch(/totaal/iu);
    expect(rendered.html).not.toContain("/betaling/");
  });

  it("rendert voorraad, afhaallocatie en portaal-QR zonder geheim", () => {
    const rendered = renderMailV2DomainProjectionGroup(
      pickupDomainGroup(),
      "https://tenue.duindorpsv.nl",
    );

    expect(rendered.html).toContain("Afhaalklaar");
    expect(rendered.html).toContain("&lt;Shirt&gt;");
    expect(rendered.text).toContain("Free-Kick Sport");
    expect(rendered.text).toContain("https://tenue.duindorpsv.nl/mijn-tenue");
    expect(rendered.text).not.toMatch(/token|secret|bearer/iu);
  });

  it("rendert een interne fout uitsluitend met veilige referentie", () => {
    const rendered = renderMailV2DomainProjectionGroup(
      internalFailureGroup(),
      "https://tenue.duindorpsv.nl",
    );

    expect(rendered.text).toContain(
      "67000000-0000-4000-8000-000000000021",
    );
    expect(rendered.text).toContain("provider_bounced");
    expect(rendered.text).not.toContain("ouder/verzorger");
  });

  it("claimt, rendert en finaliseert één generieke immutable job", async () => {
    const calls: string[] = [];
    const rpc = vi.fn(async (name: string, args: Record<string, unknown>) => {
      calls.push(name);
      if (name === "claim_mail_v2_domain_projections_v1") {
        return {
          data: {
            leaseToken: args.p_lease_token,
            groups: [domainGroup()],
          },
          error: null,
        };
      }
      if (name === "finalize_mail_v2_domain_projection_v1") {
        return {
          data: {
            groupId: domainGroup().groupId,
            jobId: "68000000-0000-4000-8000-000000000099",
            status: "queued",
            eventCount: 2,
            reused: false,
          },
          error: null,
        };
      }
      return { data: null, error: { code: "PGRST202" } };
    });
    const admin = { schema: () => ({ rpc }) };

    await expect(projectMailV2DomainEvents(
      admin as never,
      "https://tenue.duindorpsv.nl",
    )).resolves.toEqual({
      claimed: 1,
      queued: 1,
      suppressed: 0,
      deferred: 0,
      errors: 0,
    });
    expect(calls).toEqual([
      "claim_mail_v2_domain_projections_v1",
      "finalize_mail_v2_domain_projection_v1",
    ]);
    expect(rpc).toHaveBeenLastCalledWith(
      "finalize_mail_v2_domain_projection_v1",
      expect.objectContaining({
        p_projection_batch_id: domainGroup().groupId,
        p_eligibility_revision: domainGroup().eligibilityRevision,
        p_render_hash: expect.stringMatching(/^[0-9a-f]{64}$/u),
      }),
    );
  });

  it("isoleert een ongeldige generieke groep en verwerkt de rest", async () => {
    const invalid = {
      ...domainGroup(),
      groupId: "68000000-0000-4000-8000-000000000040",
      events: [{
        ...domainGroup().events[0],
        payload: {
          ...domainGroup().events[0]!.payload,
          memberFullName: "X".repeat(321),
        },
      }],
    };
    const rpc = vi.fn(async (name: string, args: Record<string, unknown>) => {
      if (name === "claim_mail_v2_domain_projections_v1") {
        return {
          data: {
            leaseToken: args.p_lease_token,
            groups: [invalid, domainGroup()],
          },
          error: null,
        };
      }
      if (name === "fail_mail_v2_domain_projection_v1") {
        return {
          data: {
            groupId: args.p_projection_batch_id,
            status: "suppressed",
            reused: false,
          },
          error: null,
        };
      }
      if (name === "finalize_mail_v2_domain_projection_v1") {
        return {
          data: {
            groupId: domainGroup().groupId,
            jobId: "68000000-0000-4000-8000-000000000099",
            status: "queued",
            eventCount: 2,
            reused: false,
          },
          error: null,
        };
      }
      return { data: null, error: { code: "PGRST202" } };
    });
    const admin = { schema: () => ({ rpc }) };

    await expect(projectMailV2DomainEvents(
      admin as never,
      "https://tenue.duindorpsv.nl",
    )).resolves.toEqual({
      claimed: 2,
      queued: 1,
      suppressed: 1,
      deferred: 0,
      errors: 0,
    });
    expect(rpc).toHaveBeenCalledWith(
      "fail_mail_v2_domain_projection_v1",
      expect.objectContaining({
        p_projection_batch_id: invalid.groupId,
        p_reason: "projection_response_invalid",
      }),
    );
  });
});
