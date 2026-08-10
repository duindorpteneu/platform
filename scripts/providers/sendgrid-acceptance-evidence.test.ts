import { describe, expect, it } from "vitest";
// @ts-expect-error Provider evidence entrypoint is intentionally plain Node.js ESM.
import { buildSendGridAcceptanceEvidence, validatePostDeliveryHealth, validateSendGridObservation } from "./sendgrid-acceptance-evidence.mjs";

const releaseSha = "a".repeat(40);
const observation = {
  schema_version: 1,
  release_sha: releaseSha,
  checks: {
    account_identity: true,
    app_request_idempotency: true,
    inbox_delivery: true,
    mail_send_scope: true,
    signed_delivery_event: true,
    webhook_configuration: true,
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
};
const health = {
  status: "healthy",
  emailControl: {
    gateMatches: true,
    providerConfigured: true,
    keyFingerprintMatches: true,
    testEventQuarantined: 0,
  },
};

describe("SendGrid acceptance evidence", () => {
  it("bindt privacyveilige tellingen en post-delivery health aan de SHA", () => {
    const evidence = buildSendGridAcceptanceEvidence(
      observation,
      health,
      releaseSha,
    );
    expect(evidence).toMatchObject({
      release_sha: releaseSha,
      checks: {
        post_delivery_operational_health: true,
      },
      delivery: {
        delivered_events: 1,
        deferred_events: 1,
      },
    });
    expect(JSON.stringify(evidence)).not.toMatch(
      /@|recipient|message[_-]?id|delivery[_-]?id/i,
    );
  });

  it.each([
    { release_sha: "b".repeat(40) },
    { extra: true },
    {
      delivery: {
        ...observation.delivery,
        delivered_events: true,
      },
    },
    {
      delivery: {
        ...observation.delivery,
        failure_events: 1,
        provider_events: 3,
      },
    },
  ])("weigert observatiedrift of onveilige typecoercie", (patch) => {
    expect(() => validateSendGridObservation(
      { ...observation, ...patch },
      releaseSha,
    )).toThrow("SENDGRID_ACCEPTANCE_OBSERVATION_INVALID");
  });

  it("weigert gedegradeerde of onvolledige finale health", () => {
    expect(() => validatePostDeliveryHealth({
      ...health,
      status: "degraded",
    })).toThrow("SENDGRID_POST_DELIVERY_HEALTH_INVALID");
    expect(() => validatePostDeliveryHealth({
      status: "healthy",
      emailControl: {
        ...health.emailControl,
        testEventQuarantined: 1,
      },
    })).toThrow("SENDGRID_POST_DELIVERY_HEALTH_INVALID");
  });
});
