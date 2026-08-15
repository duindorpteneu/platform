import {
  createHash,
  generateKeyPairSync,
} from "node:crypto";
import { readFileSync } from "node:fs";
import {
  describe,
  expect,
  it,
  vi,
} from "vitest";
// @ts-expect-error The provider acceptance entrypoint is intentionally plain Node.js ESM.
import { cleanupSendGridAcceptanceFixture, runSendGridAcceptance, validateSendGridAcceptanceConfig, waitForInboxMessage, waitForSignedProviderEvent } from "./sendgrid-staging-acceptance.mjs";

const correlation =
  "12345678-1234-4123-8123-123456789abc";
const deliveryId =
  "22345678-1234-4123-8123-123456789abc";
const accountIdentity = {
  username: "duindorp-staging",
  user_id: 12345,
};
const { publicKey } = generateKeyPairSync(
  "ec",
  { namedCurve: "prime256v1" },
);
const publicKeyDer = publicKey.export({
  type: "spki",
  format: "der",
}).toString("base64");
const appKey = "SG.acceptance";
const values = {
  SENDGRID_API_KEY: appKey,
  SENDGRID_ADMIN_API_KEY: "SG.admin-acceptance",
  SENDGRID_API_KEY_FINGERPRINT: createHash("sha256")
    .update(appKey)
    .digest("hex"),
  SENDGRID_API_BASE_URL: "https://api.eu.sendgrid.com",
  SENDGRID_EXPECTED_ACCOUNT_FINGERPRINT: createHash("sha256")
    .update(
      `${accountIdentity.username}:${accountIdentity.user_id}`,
    )
    .digest("hex"),
  SENDGRID_FROM_NAME: "Kledingcommissie Duindorp SV",
  SENDGRID_FROM_EMAIL: "kleding@duindorpsv.nl",
  SENDGRID_REPLY_TO_EMAIL: "kleding@duindorpsv.nl",
  SENDGRID_SMOKE_RECIPIENT:
    "acceptance@example.invalid",
  SENDGRID_WEBHOOK_ID:
    "32345678-1234-4123-8123-123456789abc",
  SENDGRID_WEBHOOK_URL:
    "https://staging-duindorp.dgwebservices.nl/api/webhooks/sendgrid",
  SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY: publicKeyDer,
  STAGING_BASE_URL:
    "https://staging-duindorp.dgwebservices.nl",
  RELEASE_SHA: "a".repeat(40),
  NEXT_PUBLIC_SUPABASE_URL:
    "https://dxbdjtbyghsovlrdcwcr.supabase.co",
  NEXT_PUBLIC_SUPABASE_ANON_KEY: "anon-key".repeat(8),
  SUPABASE_SERVICE_ROLE_KEY: "service-role-key".repeat(4),
  SUPABASE_DB_URL:
    "postgresql://postgres:secret@db.dxbdjtbyghsovlrdcwcr.supabase.co:5432/postgres?sslmode=require",
  SUPABASE_PROJECT_REF: "dxbdjtbyghsovlrdcwcr",
  SENDGRID_ACCEPTANCE_RUN_ID: "123456-1",
  E2E_MAILBOX_IMAP_HOST: "imap.example.invalid",
  E2E_MAILBOX_IMAP_PORT: "993",
  E2E_MAILBOX_IMAP_USER: "acceptance",
  E2E_MAILBOX_IMAP_PASSWORD: "secret",
  E2E_MAILBOX_IMAP_MAILBOX: "INBOX",
};

const webhookSettings = {
  id: values.SENDGRID_WEBHOOK_ID,
  enabled: true,
  url: values.SENDGRID_WEBHOOK_URL,
  delivered: true,
  bounce: true,
  deferred: true,
  dropped: true,
  processed: false,
  spam_report: false,
  unsubscribe: false,
  group_unsubscribe: false,
  group_resubscribe: false,
  open: false,
  click: false,
  account_status_change: false,
};

function acceptanceUserId(runMarker = "123456-1") {
  const bytes = createHash("sha256")
    .update(`duindorp-sendgrid-acceptance:${runMarker}`)
    .digest()
    .subarray(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function response(
  status: number,
  body?: unknown,
  headers?: Record<string, string>,
) {
  return new Response(
    body === undefined ? null : JSON.stringify(body),
    { status, headers },
  );
}

function acceptanceClient() {
  const rpc = vi.fn(async (name: string) => {
    if (name === "get_mail_workspace_v1") {
      return {
        data: {
          featureEnabled: true,
          templates: [{
            key: "package_complete",
            published: {
              contentHash: "b".repeat(64),
            },
          }],
          branding: {
            published: {
              fromName:
                "Kledingcommissie Duindorp SV",
              fromEmail: "kleding@duindorpsv.nl",
              replyToEmail: "kleding@duindorpsv.nl",
            },
          },
        },
        error: null,
      };
    }
    return {
      data: {
        deliveryId,
        accepted: true,
        eventCount: 2,
        deliveredEventCount: 1,
        deferredEventCount: 1,
        failureEventCount: 0,
        quarantinedEventCount: 0,
      },
      error: null,
    };
  });
  return {
    auth: {
      signOut: vi.fn().mockResolvedValue({
        error: null,
      }),
      signInWithPassword: vi.fn().mockResolvedValue({
        data: {
          session: { access_token: "aal1-token" },
        },
        error: null,
      }),
      mfa: {
        getAuthenticatorAssuranceLevel: vi.fn()
          .mockResolvedValue({
            data: {
              currentLevel: "aal2",
              nextLevel: "aal2",
            },
            error: null,
          }),
        listFactors: vi.fn().mockResolvedValue({
          data: { totp: [] },
          error: null,
        }),
        enroll: vi.fn().mockResolvedValue({
          data: {
            id: "factor-1",
            totp: { secret: "JBSWY3DPEHPK3PXP" },
          },
          error: null,
        }),
        challengeAndVerify: vi.fn().mockResolvedValue({
          data: {},
          error: null,
        }),
      },
      getSession: vi.fn().mockResolvedValue({
        data: {
          session: { access_token: "aal2-token" },
        },
        error: null,
      }),
    },
    schema: vi.fn(() => ({ rpc })),
    rpc,
  };
}

function acceptanceAdmin(runMarker = "123456-1") {
  const fixtureUser = {
    id: acceptanceUserId(runMarker),
    email: `staging-sendgrid-${runMarker}@example.invalid`,
    app_metadata: {
      duindorp_acceptance:
        "duindorp-sendgrid-acceptance-v1",
    },
  };
  const getUserById = vi.fn()
    .mockResolvedValueOnce({
      data: { user: null },
      error: { status: 404 },
    })
    .mockResolvedValue({
      data: { user: fixtureUser },
      error: null,
    });
  const listUsers = vi.fn()
    .mockResolvedValueOnce({
      data: { users: [] },
      error: null,
    })
    .mockResolvedValue({
      data: { users: [fixtureUser] },
      error: null,
    });
  return {
    auth: {
      admin: {
        getUserById,
        listUsers,
        createUser: vi.fn().mockResolvedValue({
          data: { user: fixtureUser },
          error: null,
        }),
        signOut: vi.fn().mockResolvedValue({
          data: null,
          error: null,
        }),
        deleteUser: vi.fn().mockResolvedValue({
          data: {},
          error: null,
        }),
      },
    },
  };
}

describe("SendGrid staging acceptance", () => {
  it("verifieert de gebonden staging-key read-only op mail.send", () => {
    const workflow = readFileSync(
      new URL("../../.github/workflows/sendgrid-fingerprints.yml", import.meta.url),
      "utf8",
    );

    expect(workflow).toContain("VERIFY-STAGING-MAIL-SEND");
    expect(workflow).toContain("/v3/scopes");
    expect(workflow).toContain(".scopes | index(\"mail.send\") != null");
    expect(workflow).not.toContain("--request PUT");
    expect(workflow).not.toContain("/v3/api_keys/${api_key_id}");
    expect(workflow).toContain("SENDGRID_API_KEY_FINGERPRINT");
    expect(workflow).toContain("SENDGRID_EXPECTED_ACCOUNT_FINGERPRINT");
    expect(workflow).not.toContain("echo \"$SENDGRID_API_KEY\"");
    expect(workflow).not.toContain("echo \"$SENDGRID_ADMIN_API_KEY\"");
  });

  it("vereist keyseparatie, exacte clubafzender en het vaste stagingorigin", () => {
    expect(validateSendGridAcceptanceConfig(values))
      .toMatchObject({
        fromEmail: "kleding@duindorpsv.nl",
        imapPort: 993,
        releaseSha: "a".repeat(40),
      });
    expect(validateSendGridAcceptanceConfig({
      ...values,
      SUPABASE_DB_URL: values.SUPABASE_DB_URL.replace(
        "?sslmode=require",
        "",
      ),
    }).databaseUrl).toContain("sslmode=require");
    for (const override of [
      {
        SENDGRID_ADMIN_API_KEY:
          values.SENDGRID_API_KEY,
      },
      {
        SENDGRID_API_KEY_FINGERPRINT:
          "0".repeat(64),
      },
      {
        SENDGRID_FROM_EMAIL:
          "other@example.invalid",
      },
      {
        STAGING_BASE_URL:
          "https://duindorp.dgwebservices.nl",
      },
      {
        SENDGRID_WEBHOOK_URL:
          "https://staging-duindorp.dgwebservices.nl/api/webhooks/sendgrid?token=leak",
      },
      {
        E2E_MAILBOX_IMAP_HOST: "127.0.0.1",
      },
      {
        SUPABASE_DB_URL:
          "postgresql://postgres:secret@db.wobcbufmmputydtzemyu.supabase.co:5432/postgres?sslmode=require",
      },
    ]) {
      expect(() => validateSendGridAcceptanceConfig({
        ...values,
        ...override,
      })).toThrow();
    }
  });

  it("bewijst mail.send met extra providerscopes, read-only webhookconfig, MFA, appdelivery, inbox en gekoppeld event", async () => {
    const fetchImpl = vi.fn()
      .mockResolvedValueOnce(
        response(200, accountIdentity),
      )
      .mockResolvedValueOnce(
        response(200, {
          scopes: ["mail.send", "user.profile.read"],
        }),
      )
      .mockResolvedValueOnce(
        response(200, webhookSettings),
      )
      .mockResolvedValueOnce(response(200, {
        id: values.SENDGRID_WEBHOOK_ID,
        public_key: publicKeyDer,
      }))
      .mockResolvedValueOnce(response(
        200,
        { landingPath: "/backoffice" },
        {
          "set-cookie":
            "duindorp_staff_session=session-token; Path=/; HttpOnly",
        },
      ))
      .mockResolvedValueOnce(response(200, {
        deliveryId,
        status: "accepted",
        reused: false,
      }))
      .mockResolvedValueOnce(response(200, {
        deliveryId,
        status: "accepted",
        reused: true,
      }));
    const release = vi.fn();
    const logout = vi.fn().mockResolvedValue(undefined);
    const imap = {
      connect: vi.fn().mockResolvedValue(undefined),
      getMailboxLock: vi.fn().mockResolvedValue({
        release,
      }),
      search: vi.fn().mockResolvedValue([42]),
      fetchOne: vi.fn().mockResolvedValue({
        envelope: {
          subject: "Voorbeeldpakket compleet voor Sophie",
          from: [{
            address: "kleding@duindorpsv.nl",
          }],
          to: [{
            address: "acceptance@example.invalid",
          }],
        },
      }),
      logout,
    };
    const client = acceptanceClient();
    const admin = acceptanceAdmin();
    const spawnSync = vi.fn().mockReturnValue({ status: 0 });

    await expect(runSendGridAcceptance(values, {
      randomUUID: () => correlation,
      fetchImpl,
      createClient: () => client,
      createAdminClient: () => admin,
      createImapClient: () => imap,
      spawnSync,
      randomBytes: () => Buffer.alloc(32, 7),
      attempts: 1,
      now: () => 1_785_680_000_000,
    })).resolves.toMatchObject({
      release_sha: "a".repeat(40),
      checks: {
        app_request_idempotency: true,
        ephemeral_admin_cleanup: true,
        ephemeral_admin_mfa: true,
        inbox_delivery: true,
        signed_delivery_event: true,
      },
      delivery: {
        application_requests: 2,
        inbox_messages: 1,
        provider_events: 2,
        delivered_events: 1,
        deferred_events: 1,
        failure_events: 0,
        quarantined_events: 0,
      },
    });

    expect(fetchImpl).toHaveBeenCalledTimes(7);
    expect(fetchImpl.mock.calls.slice(0, 4).every(
      (call) => !call[1]?.method,
    )).toBe(true);
    expect(fetchImpl.mock.calls[4]?.[1]).toMatchObject({
      method: "POST",
      headers: expect.objectContaining({
        Accept: "application/json",
        Origin:
          "https://staging-duindorp.dgwebservices.nl",
        "Sec-Fetch-Site": "same-origin",
        "X-Duindorp-CSRF": "same-origin",
      }),
    });
    expect(
      client.auth.mfa.challengeAndVerify,
    ).toHaveBeenCalledWith({
      factorId: "factor-1",
      code: expect.stringMatching(/^\d{6}$/),
    });
    expect(client.auth.mfa.enroll).toHaveBeenCalledWith({
      factorType: "totp",
      friendlyName: "SendGrid staging acceptance",
    });
    expect(spawnSync).toHaveBeenCalledTimes(3);
    expect(admin.auth.admin.deleteUser).toHaveBeenCalledWith(
      acceptanceUserId(),
      false,
    );
    expect(admin.auth.admin.signOut).toHaveBeenCalledWith(
      "aal2-token",
      "global",
    );
    expect(client.auth.signOut).not.toHaveBeenCalled();
    expect(client.rpc).toHaveBeenCalledWith(
      "get_mail_test_delivery_status_v2",
      { p_delivery_id: deliveryId },
    );
    expect(imap.search).toHaveBeenCalledWith({
      header: {
        "x-duindorp-acceptance": deliveryId,
      },
    }, { uid: true });
    expect(release).toHaveBeenCalledOnce();
    expect(logout).toHaveBeenCalledOnce();
    const testDeliveryCalls = fetchImpl.mock.calls.filter(
      (call) => String(call[0]).endsWith(
        "/api/email/v2/test-delivery",
      ),
    );
    expect(testDeliveryCalls).toHaveLength(2);
    for (const call of testDeliveryCalls) {
      expect(call[1]?.headers).toEqual(
        expect.objectContaining({
          Accept: "application/json",
          Origin:
            "https://staging-duindorp.dgwebservices.nl",
          "Sec-Fetch-Site": "same-origin",
          "X-Duindorp-CSRF": "same-origin",
        }),
      );
    }
    expect(testDeliveryCalls[0]?.[1]?.body).toBe(
      testDeliveryCalls[1]?.[1]?.body,
    );
  });

  it("weigert een runtimekey zonder mail.send", async () => {
    const fetchImpl = vi.fn()
      .mockResolvedValueOnce(
        response(200, accountIdentity),
      )
      .mockResolvedValueOnce(response(200, {
        scopes: ["user.profile.read"],
      }));
    await expect(runSendGridAcceptance(values, {
      randomUUID: () => correlation,
      fetchImpl,
    })).rejects.toThrow(
      "SENDGRID_MAIL_SEND_SCOPE_MISSING",
    );
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });

  it("deactiveert fail-closed en weigert een authfixture zonder marker", async () => {
    const admin = acceptanceAdmin();
    admin.auth.admin.listUsers = vi.fn().mockResolvedValue({
      data: { users: [] },
      error: null,
    });
    admin.auth.admin.getUserById = vi.fn()
      .mockResolvedValue({
        data: {
          user: {
            id: acceptanceUserId(),
            email: "human@example.invalid",
            app_metadata: {},
          },
        },
        error: null,
      });
    const spawnSync = vi.fn().mockReturnValue({ status: 0 });
    await expect(cleanupSendGridAcceptanceFixture(values, {
      createAdminClient: () => admin,
      spawnSync,
    })).rejects.toThrow(
      "SENDGRID_ACCEPTANCE_FIXTURE_CLEANUP_FAILED",
    );
    expect(spawnSync).toHaveBeenCalledOnce();
    expect(spawnSync.mock.calls[0]?.[2]?.input).toContain(
      "profile.automation_kind = 'sendgrid_acceptance'",
    );
    expect(admin.auth.admin.deleteUser).not.toHaveBeenCalled();
  });

  it("schoont databaseprofielen ook wanneer Auth tijdelijk onbereikbaar is", async () => {
    const admin = acceptanceAdmin();
    admin.auth.admin.listUsers = vi.fn().mockResolvedValue({
      data: { users: [] },
      error: { status: 503 },
    });
    admin.auth.admin.getUserById = vi.fn().mockResolvedValue({
      data: { user: null },
      error: { status: 503 },
    });
    const spawnSync = vi.fn().mockReturnValue({ status: 0 });

    await expect(cleanupSendGridAcceptanceFixture(values, {
      createAdminClient: () => admin,
      spawnSync,
    })).rejects.toThrow(
      "SENDGRID_ACCEPTANCE_FIXTURE_CLEANUP_FAILED",
    );

    expect(spawnSync).toHaveBeenCalledOnce();
    const cleanupSql = spawnSync.mock.calls[0]?.[2]?.input;
    expect(cleanupSql).toContain(
      "profile.automation_kind = 'sendgrid_acceptance'",
    );
    expect(cleanupSql).toContain("and active;");
    expect(cleanupSql).toContain("do $assertion$");
    expect(cleanupSql.indexOf("for target in")).toBeLessThan(
      cleanupSql.indexOf("do $assertion$"),
    );
    expect(cleanupSql).not.toContain(
      "and profile.active\n    for update",
    );
    expect(admin.auth.admin.deleteUser).not.toHaveBeenCalled();
  });

  it("verwijdert Auth best-effort wanneer databasecleanup of global sign-out faalt", async () => {
    const admin = acceptanceAdmin();
    admin.auth.admin.listUsers = vi.fn().mockResolvedValue({
      data: {
        users: [{
          id: acceptanceUserId(),
          email: "staging-sendgrid-123456-1@example.invalid",
          app_metadata: {
            duindorp_acceptance:
              "duindorp-sendgrid-acceptance-v1",
          },
        }],
      },
      error: null,
    });
    admin.auth.admin.signOut.mockResolvedValue({
      data: null,
      error: { status: 500 },
    });
    await expect(cleanupSendGridAcceptanceFixture(values, {
      accessToken: "ephemeral-aal2-token",
      createAdminClient: () => admin,
      spawnSync: vi.fn().mockReturnValue({ status: 1 }),
    })).rejects.toThrow(
      "SENDGRID_ACCEPTANCE_FIXTURE_CLEANUP_FAILED",
    );
    expect(admin.auth.admin.signOut).toHaveBeenCalledOnce();
    expect(admin.auth.admin.deleteUser).toHaveBeenCalledWith(
      acceptanceUserId(),
      false,
    );
  });

  it("gebruikt per run een andere Auth-identiteit", () => {
    expect(acceptanceUserId("123456-1"))
      .not.toBe(acceptanceUserId("123456-2"));
  });

  it("faalt gesloten bij dubbele inboxcorrelatie of timeout", async () => {
    const config =
      validateSendGridAcceptanceConfig(values);
    const makeClient = (matches: number[]) => ({
      connect: vi.fn().mockResolvedValue(undefined),
      getMailboxLock: vi.fn().mockResolvedValue({
        release: vi.fn(),
      }),
      search: vi.fn().mockResolvedValue(matches),
      fetchOne: vi.fn(),
      logout: vi.fn().mockResolvedValue(undefined),
    });
    await expect(waitForInboxMessage(
      config,
      deliveryId,
      {
        createImapClient: () => makeClient([1, 2]),
        attempts: 1,
      },
    )).rejects.toThrow(
      "E2E_MAILBOX_CORRELATION_NOT_UNIQUE",
    );
    await expect(waitForInboxMessage(
      config,
      deliveryId,
      {
        createImapClient: () => makeClient([]),
        attempts: 1,
      },
    )).rejects.toThrow(
      "E2E_MAILBOX_DELIVERY_TIMEOUT",
    );
  });

  it("faalt direct op een testevent in quarantaine of een definitieve fout", async () => {
    const makeSession = (data: Record<string, unknown>) => ({
      client: {
        schema: () => ({
          rpc: vi.fn().mockResolvedValue({
            data,
            error: null,
          }),
        }),
      },
    });
    await expect(waitForSignedProviderEvent(
      makeSession({
        deliveryId,
        accepted: true,
        eventCount: 0,
        deliveredEventCount: 0,
        deferredEventCount: 0,
        failureEventCount: 0,
        quarantinedEventCount: 1,
      }),
      deliveryId,
      { attempts: 1 },
    )).rejects.toThrow(
      "E2E_PROVIDER_EVENT_QUARANTINED",
    );
    await expect(waitForSignedProviderEvent(
      makeSession({
        deliveryId,
        accepted: true,
        eventCount: 1,
        deliveredEventCount: 0,
        deferredEventCount: 0,
        failureEventCount: 1,
        quarantinedEventCount: 0,
      }),
      deliveryId,
      { attempts: 1 },
    )).rejects.toThrow(
      "E2E_PROVIDER_DELIVERY_FAILED",
    );
  });

  it("accepteert geen typecoercie of inconsistente providertellers", async () => {
    const session = {
      client: {
        schema: () => ({
          rpc: vi.fn().mockResolvedValue({
            data: {
              deliveryId,
              accepted: true,
              eventCount: 1,
              deliveredEventCount: true,
              deferredEventCount: 0,
              failureEventCount: 0,
              quarantinedEventCount: 0,
            },
            error: null,
          }),
        }),
      },
    };
    await expect(waitForSignedProviderEvent(
      session,
      deliveryId,
      { attempts: 1 },
    )).rejects.toThrow(
      "E2E_PROVIDER_EVENT_STATUS_INVALID",
    );
  });
});
