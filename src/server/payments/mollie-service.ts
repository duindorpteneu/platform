import { createHash } from "node:crypto";
import { z } from "zod";
import { getServerEnv } from "@/lib/env";
import {
  mollieReconciliationContextSchema,
  mollieReconciliationResultSchema,
  mollieRefundResponseSchema,
  preparedMolliePaymentSchema,
  preparedMollieRefundSchema,
  type PreparedMolliePayment,
} from "@/lib/mollie-contract";
import {
  createMolliePayment,
  createMollieRefund,
  getMolliePayment,
  MollieRequestError,
  parseMollieMetadata,
  requireHostedCheckoutUrl,
  toLocalMollieStatus,
  type MolliePayment,
} from "@/server/payments/mollie";

type RpcError = { code?: string; message?: string };
type RpcResult = { data: unknown; error: RpcError | null };
type MollieSchemaRpcClient = {
  rpc: (name: string, parameters: Record<string, unknown>) => PromiseLike<RpcResult>;
};

export type MollieRpcClient = {
  rpc: (name: string, parameters: Record<string, unknown>) => PromiseLike<RpcResult>;
  schema: (name: "app") => MollieSchemaRpcClient;
};

export type MollieRuntimeConfig = {
  enabled: boolean;
  apiKey: string | null;
  appBaseUrl: string;
};

export class MollieServiceError extends Error {
  constructor(
    public readonly code:
      | "NOT_CONFIGURED"
      | "INVALID_ORIGIN"
      | "ORDER_ALREADY_PAID"
      | "ORDER_NOT_AVAILABLE"
      | "PACKAGE_SIZES_REQUIRED"
      | "PROVIDER_UNAVAILABLE"
      | "INVALID_PROVIDER_RESPONSE"
      | "RECONCILIATION_REJECTED"
      | "DATABASE_UNAVAILABLE",
    public readonly retryable = false,
  ) {
    super(code);
  }
}

const apiKeySchema = z.string().min(12).max(240).regex(/^(test|live)_/);

export function getMollieRuntimeConfig(): MollieRuntimeConfig {
  const env = getServerEnv();
  const apiKey = apiKeySchema.safeParse(env.MOLLIE_API_KEY);
  return {
    enabled: env.MOLLIE_ENABLED === "true",
    apiKey: apiKey.success ? apiKey.data : null,
    appBaseUrl: env.APP_BASE_URL,
  };
}

export function hasTrustedPaymentOrigin(request: Request, appBaseUrl: string) {
  const origin = request.headers.get("origin");
  if (!origin) return false;
  try {
    return new URL(origin).origin === new URL(appBaseUrl).origin;
  } catch {
    return false;
  }
}

function assertRuntime(config: MollieRuntimeConfig) {
  assertProviderRuntime(config);
  const appUrl = new URL(config.appBaseUrl);
  if (appUrl.protocol !== "https:") throw new MollieServiceError("NOT_CONFIGURED");
  return appUrl;
}

function assertProviderRuntime(config: MollieRuntimeConfig) {
  if (!config.enabled || !config.apiKey) throw new MollieServiceError("NOT_CONFIGURED");
}

function mapPrepareError(error: RpcError) {
  const message = error.message ?? "";
  if (message.includes("ORDER_ALREADY_PAID")) return new MollieServiceError("ORDER_ALREADY_PAID");
  if (message.includes("PARENT_ORDER_ACCESS_DENIED")) return new MollieServiceError("ORDER_NOT_AVAILABLE");
  if (message.includes("PACKAGE_SIZES_REQUIRED")) return new MollieServiceError("PACKAGE_SIZES_REQUIRED");
  return new MollieServiceError("DATABASE_UNAVAILABLE", true);
}

async function preparePayment(
  database: MollieRpcClient,
  input: { tokenHash: string; orderId: string; idempotencyKey: string },
) {
  const { data, error } = await database.rpc("prepare_mollie_payment", {
    p_token_hash: input.tokenHash,
    p_order_id: input.orderId,
    p_idempotency_key: input.idempotencyKey,
  });
  if (error) throw mapPrepareError(error);
  const parsed = preparedMolliePaymentSchema.safeParse(data);
  if (!parsed.success) throw new MollieServiceError("DATABASE_UNAVAILABLE", true);
  return parsed.data;
}

function checkoutFromProvider(payment: MolliePayment) {
  const status = toLocalMollieStatus(payment);
  if (status !== "open" && status !== "pending") {
    throw new MollieServiceError("INVALID_PROVIDER_RESPONSE");
  }
  try {
    return { checkoutUrl: requireHostedCheckoutUrl(payment), status };
  } catch {
    throw new MollieServiceError("INVALID_PROVIDER_RESPONSE");
  }
}

async function bindPayment(database: MollieRpcClient, prepared: PreparedMolliePayment, providerPayment: MolliePayment, checkoutUrl: string, status: "open" | "pending") {
  const { error } = await database.schema("app").rpc("bind_mollie_payment", {
    p_payment_id: prepared.paymentId,
    p_provider_id: providerPayment.id,
    p_checkout_url: checkoutUrl,
    p_status: status,
    p_expires_at: providerPayment.expiresAt ?? null,
  });
  if (error) throw new MollieServiceError("DATABASE_UNAVAILABLE", true);
}

export async function startMollieCheckout(
  input: { tokenHash: string; orderId: string; idempotencyKey: string },
  dependencies: {
    database: MollieRpcClient;
    config?: MollieRuntimeConfig;
    createPayment?: typeof createMolliePayment;
  },
) {
  const config = dependencies.config ?? getMollieRuntimeConfig();
  const appUrl = assertRuntime(config);
  const prepared = await preparePayment(dependencies.database, input);

  if (prepared.checkoutUrl) return { checkoutUrl: prepared.checkoutUrl };

  let providerPayment: MolliePayment;
  try {
    providerPayment = await (dependencies.createPayment ?? createMolliePayment)({
      apiKey: config.apiKey!,
      idempotencyKey: prepared.idempotencyKey,
      amountCents: prepared.amountCents,
      description: "Duindorp SV tenuebetaling",
      redirectUrl: new URL("/betaling/terug", appUrl).toString(),
      webhookUrl: new URL("/api/webhooks/mollie", appUrl).toString(),
      metadata: prepared.metadata,
    });
  } catch (error) {
    if (error instanceof MollieServiceError) throw error;
    if (error instanceof MollieRequestError) throw new MollieServiceError("PROVIDER_UNAVAILABLE", error.retryable);
    throw new MollieServiceError("INVALID_PROVIDER_RESPONSE");
  }

  const { checkoutUrl, status } = checkoutFromProvider(providerPayment);
  await bindPayment(dependencies.database, prepared, providerPayment, checkoutUrl, status);
  return { checkoutUrl };
}

const optionalTimestampSchema = z.string().datetime({ offset: true }).nullable().optional();

function timestampFrom(payment: MolliePayment, key: string) {
  const parsed = optionalTimestampSchema.safeParse(payment[key]);
  return parsed.success ? (parsed.data ?? null) : null;
}

function parseProviderAmountCents(value: string) {
  if (!/^\d+\.\d{2}$/.test(value)) throw new MollieServiceError("RECONCILIATION_REJECTED");
  const [euros, cents] = value.split(".");
  const amountCents = Number(euros) * 100 + Number(cents);
  if (!Number.isSafeInteger(amountCents)) throw new MollieServiceError("RECONCILIATION_REJECTED");
  return amountCents;
}

function paymentEventKey(payment: MolliePayment, status: string) {
  const statusMoment = payment.paidAt ?? payment.canceledAt ?? payment.failedAt ?? payment.expiresAt ?? "current";
  const digest = createHash("sha256")
    .update(JSON.stringify({
      id: payment.id,
      status,
      statusMoment,
      amount: payment.amount,
      refunds: [...(payment._embedded?.refunds ?? [])]
        .sort((left, right) => left.id.localeCompare(right.id))
        .map((refund) => ({ id: refund.id, status: refund.status, amount: refund.amount })),
    }))
    .digest("hex");
  return `mollie:${digest}`;
}

function inspectProviderMetadata(value: unknown) {
  try {
    return { metadata: parseMollieMetadata(value), validationIssue: null } as const;
  } catch {
    if (value === null || value === undefined || value === "") {
      return { metadata: null, validationIssue: "MOLLIE_METADATA_MISSING" } as const;
    }
    let candidate = value;
    if (typeof value === "string") {
      try {
        candidate = JSON.parse(value);
      } catch {
        return { metadata: null, validationIssue: "MOLLIE_METADATA_INVALID" } as const;
      }
    }
    if (
      typeof candidate === "object"
      && candidate !== null
      && "schema_version" in candidate
      && candidate.schema_version !== 1
      && candidate.schema_version !== 2
    ) {
      return { metadata: null, validationIssue: "MOLLIE_METADATA_SCHEMA_INVALID" } as const;
    }
    return { metadata: null, validationIssue: "MOLLIE_METADATA_INVALID" } as const;
  }
}

export async function reconcileMollieWebhook(
  providerPaymentId: string,
  dependencies: {
    database: MollieRpcClient;
    config?: MollieRuntimeConfig;
    getPayment?: typeof getMolliePayment;
    receivedAt?: Date;
  },
) {
  const config = dependencies.config ?? getMollieRuntimeConfig();
  assertProviderRuntime(config);

  let providerPayment: MolliePayment;
  try {
    providerPayment = await (dependencies.getPayment ?? getMolliePayment)(config.apiKey!, providerPaymentId);
  } catch (error) {
    if (error instanceof MollieRequestError) throw new MollieServiceError("PROVIDER_UNAVAILABLE", error.retryable);
    throw new MollieServiceError("INVALID_PROVIDER_RESPONSE");
  }
  if (providerPayment.id !== providerPaymentId) throw new MollieServiceError("INVALID_PROVIDER_RESPONSE");

  const appDatabase = dependencies.database.schema("app");
  const { data: contextData, error: contextError } = await appDatabase.rpc("get_mollie_reconciliation_context_v2", {
    p_provider_id: providerPayment.id,
  });
  if (contextError) {
    if ((contextError.message ?? "").includes("PAYMENT_NOT_FOUND")) throw new MollieServiceError("ORDER_NOT_AVAILABLE");
    throw new MollieServiceError("DATABASE_UNAVAILABLE", true);
  }
  const context = mollieReconciliationContextSchema.safeParse(contextData);
  if (!context.success) throw new MollieServiceError("DATABASE_UNAVAILABLE", true);

  let amountCents;
  try {
    amountCents = parseProviderAmountCents(providerPayment.amount.value);
  } catch {
    throw new MollieServiceError("RECONCILIATION_REJECTED");
  }
  const metadataInspection = inspectProviderMetadata(providerPayment.metadata);
  const metadata = metadataInspection.metadata;

  const status = toLocalMollieStatus(providerPayment);
  const receivedAt = (dependencies.receivedAt ?? new Date()).toISOString();
  const { data: resultData, error: resultError } = await appDatabase.rpc("reconcile_mollie_payment_v3", {
    p_event_key: paymentEventKey(providerPayment, status),
    p_provider_id: providerPayment.id,
    p_local_payment_id: context.data.paymentId,
    p_metadata_payment_id: metadata?.payment_id ?? null,
    p_order_id: metadata?.order_id ?? context.data.orderId,
    p_member_id: metadata?.member_id ?? context.data.memberId,
    p_member_season_id: metadata && "member_season_id" in metadata
      ? metadata.member_season_id
      : context.data.memberSeasonId,
    p_season_id: metadata?.season_id ?? context.data.seasonId,
    p_amount_cents: amountCents,
    p_currency: providerPayment.amount.currency,
    p_status: status,
    p_provider_created_at: timestampFrom(providerPayment, "createdAt"),
    p_provider_updated_at: receivedAt,
    p_provider_expires_at: providerPayment.expiresAt ?? null,
    p_paid_at: providerPayment.paidAt ?? null,
    p_refunded_at: null,
    p_validation_issue: metadataInspection.validationIssue,
    p_observation: metadata ? { schema_version: metadata.schema_version } : {},
  });
  if (resultError) {
    const retryable = resultError.code === "40001" || (resultError.message ?? "").includes("QR_VERSION_CONFLICT");
    throw new MollieServiceError(retryable ? "DATABASE_UNAVAILABLE" : "RECONCILIATION_REJECTED", retryable);
  }
  const result = mollieReconciliationResultSchema.safeParse(resultData);
  if (!result.success) throw new MollieServiceError("DATABASE_UNAVAILABLE", true);
  if ((providerPayment._embedded?.refunds?.length ?? 0) > 0) {
    const refundReconciliation = await appDatabase.rpc("reconcile_mollie_refunds_v1", {
      p_provider_payment_id: providerPayment.id,
      p_refunds: providerPayment._embedded?.refunds ?? [],
      p_observed_at: receivedAt,
    });
    if (!refundReconciliation || refundReconciliation.error) {
      throw new MollieServiceError("RECONCILIATION_REJECTED", true);
    }
  }
  return result.data;
}

export async function startMollieRefund(
  input: {
    refundId: string;
    requestId: string;
    actorUserId: string;
    staffSessionHash: string;
    correlationId?: string | null;
  },
  dependencies: {
    database: MollieRpcClient;
    config?: MollieRuntimeConfig;
    createRefund?: typeof createMollieRefund;
    now?: Date;
  },
) {
  const config = dependencies.config ?? getMollieRuntimeConfig();
  assertProviderRuntime(config);
  const appDatabase = dependencies.database.schema("app");
  const { data, error } = await appDatabase.rpc("prepare_mollie_refund_v1", {
    p_refund_id: input.refundId,
    p_operation_request_id: input.requestId,
    p_actor_user_id: input.actorUserId,
    p_staff_session_hash: input.staffSessionHash,
    p_correlation_id: input.correlationId ?? null,
  });
  if (error) throw new MollieServiceError("DATABASE_UNAVAILABLE", true);
  const prepared = preparedMollieRefundSchema.safeParse(data);
  if (!prepared.success) throw new MollieServiceError("DATABASE_UNAVAILABLE", true);
  if (prepared.data.providerRefundId) {
    return {
      refundId: prepared.data.refundId,
      providerRefundId: prepared.data.providerRefundId,
      status: prepared.data.status,
      reused: true,
    };
  }
  const observedAt = (dependencies.now ?? new Date()).toISOString();
  try {
    const providerRefund = await (dependencies.createRefund ?? createMollieRefund)({
      apiKey: config.apiKey!,
      providerPaymentId: prepared.data.providerPaymentId,
      idempotencyKey: prepared.data.idempotencyKey,
      amountCents: prepared.data.amountCents,
      description: "Duindorp SV pakketcorrectie",
      metadata: { package_refund_id: prepared.data.refundId, schema_version: 1 },
    });
    const { data: bound, error: bindError } = await appDatabase.rpc("bind_mollie_refund_v1", {
      p_refund_id: prepared.data.refundId,
      p_provider_refund_id: providerRefund.id,
      p_provider_status: providerRefund.status,
      p_observed_at: observedAt,
    });
    if (bindError) throw new MollieServiceError("DATABASE_UNAVAILABLE", true);
    const parsed = mollieRefundResponseSchema.safeParse(bound);
    if (!parsed.success) throw new MollieServiceError("DATABASE_UNAVAILABLE", true);
    return { ...parsed.data, reused: false };
  } catch (cause) {
    // Once the provider call has started, a timeout, unreadable success body,
    // response mismatch or local bind failure has an uncertain outcome. The
    // durable Mollie idempotency key makes retrying that same refund safe.
    const retryable = cause instanceof MollieRequestError
      ? cause.retryable
      : true;
    await appDatabase.rpc("fail_mollie_refund_v1", {
      p_refund_id: prepared.data.refundId,
      p_failure_code: cause instanceof MollieServiceError
        ? "MOLLIE_REFUND_BIND_UNAVAILABLE"
        : retryable
          ? "MOLLIE_PROVIDER_UNAVAILABLE"
          : "MOLLIE_REFUND_RESPONSE_INVALID",
      p_retryable: retryable,
      p_observed_at: observedAt,
    });
    if (cause instanceof MollieServiceError) throw cause;
    if (cause instanceof MollieRequestError) {
      throw new MollieServiceError("PROVIDER_UNAVAILABLE", cause.retryable);
    }
    throw new MollieServiceError("INVALID_PROVIDER_RESPONSE", true);
  }
}
