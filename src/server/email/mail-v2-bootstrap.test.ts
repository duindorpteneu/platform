import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  getWorkspace: vi.fn(),
  source: vi.fn(),
  branding: vi.fn(),
  preview: vi.fn(),
  render: vi.fn(),
  rpc: vi.fn(),
}));

vi.mock("@/server/email/mail-v2-workspace", () => ({
  getMailV2Workspace: mocks.getWorkspace,
  mailV2SourceForTemplate: mocks.source,
  mailV2BrandingValues: mocks.branding,
}));
vi.mock("@/server/email/mail-v2", () => ({
  mailV2PreviewData: mocks.preview,
  renderMailV2Body: mocks.render,
}));
vi.mock("@/server/supabase/server", () => ({
  getSupabaseServerClient: vi.fn(async () => ({
    schema: () => ({ rpc: mocks.rpc }),
  })),
}));

import { prepareAndActivateMailV2 } from "@/server/email/mail-v2-bootstrap";

const revisionId = "75000000-0000-4000-8000-000000000001";
const correlationId = "75000000-0000-4000-8000-000000000002";
const initialHash = "a".repeat(64);
const renderedHash = "b".repeat(64);
const cutoverRevision = "c".repeat(64);
const draft = {
  id: revisionId,
  revision: 1,
  status: "draft",
  internalName: "Afhaalklaar",
  subjectSource: "Afhalen voor {{member_first_name}}",
  preheaderSource: "Je kleding ligt klaar.",
  bodyTipTap: {
    type: "doc",
    content: [{ type: "protectedBlock", attrs: { kind: "ready_items" } }],
  },
  sanitizedHtmlSource: null,
  textFallbackSource: "Je kleding ligt klaar.",
  schemaVersion: 1,
  contentHash: initialHash,
};
const snapshot = {
  enabled: false,
  cutoverAt: null,
  catalogCount: 19,
  publishedCount: 19,
  brandingCount: 1,
  producerCount: 19,
  legacyPendingCount: 0,
  projectionFailureCount: 0,
  unresolvedConfirmationCount: 0,
  brandingProjectionBlockers: 0,
  projectionFailures: [],
  ready: true,
  revision: cutoverRevision,
  reused: false,
};

describe("Mail-v2 veilig gereedmaken", () => {
  beforeEach(() => {
    mocks.getWorkspace.mockReset().mockResolvedValue({
      templates: [{
        key: "pickup_ready",
        published: null,
        draft,
      }],
      branding: { published: { id: revisionId } },
    });
    mocks.source.mockReset().mockReturnValue({ templateKey: "pickup_ready" });
    mocks.branding.mockReset().mockReturnValue({ clubName: "Duindorp SV" });
    mocks.preview.mockReset().mockReturnValue({ shortcodes: {}, protectedValues: {} });
    mocks.render.mockReset().mockReturnValue({ html: "<p>Veilig</p>", text: "Veilig" });
    mocks.rpc.mockReset().mockImplementation(async (name: string) => {
      if (name === "save_mail_template_draft_v1") {
        return {
          data: {
            revisionId,
            templateKey: "pickup_ready",
            revision: 1,
            status: "draft",
            contentHash: renderedHash,
          },
          error: null,
        };
      }
      if (name === "publish_mail_template_revision_v1") {
        return {
          data: {
            revisionId,
            templateKey: "pickup_ready",
            revision: 1,
            status: "published",
            contentHash: renderedHash,
            publishedAt: "2026-08-16T12:00:00.000Z",
          },
          error: null,
        };
      }
      if (name === "get_mail_v2_cutover_snapshot_v2") {
        return { data: snapshot, error: null };
      }
      return {
        data: {
          ...snapshot,
          enabled: true,
          cutoverAt: "2026-08-16T12:01:00.000Z",
        },
        error: null,
      };
    });
  });

  it("rendert, publiceert en activeert pas na een verse groene preflight", async () => {
    const result = await prepareAndActivateMailV2(
      { reason: "Veilige systeemtemplates gecontroleerd" },
      correlationId,
    );

    expect(mocks.rpc.mock.calls.map(([name]) => name)).toEqual([
      "save_mail_template_draft_v1",
      "publish_mail_template_revision_v1",
      "get_mail_v2_cutover_snapshot_v2",
      "activate_mail_templates_v2",
    ]);
    expect(mocks.rpc).toHaveBeenLastCalledWith(
      "activate_mail_templates_v2",
      expect.objectContaining({
        p_expected_revision: cutoverRevision,
        p_reason: "Veilige systeemtemplates gecontroleerd",
      }),
    );
    expect(result).toMatchObject({
      data: { enabled: true, preparedCount: 1 },
      error: null,
    });
  });

  it("activeert nooit wanneer een publicatie stale raakt", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: { code: "40001", message: "stale" },
    });

    const result = await prepareAndActivateMailV2(
      { reason: "Veilige systeemtemplates gecontroleerd" },
      correlationId,
    );

    expect(result).toMatchObject({ error: { code: "40001" } });
    expect(mocks.rpc).toHaveBeenCalledTimes(1);
  });
});
