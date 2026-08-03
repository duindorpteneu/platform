import { describe, expect, it, vi } from "vitest";
import type { FulfilmentMailProjectionGroup } from "@/lib/mail-v2-contract";
import {
  fulfilmentMailRenderHash,
  projectFulfilmentMail,
  renderFulfilmentProjectionGroup,
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
