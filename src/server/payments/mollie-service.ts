import { createHash } from "node:crypto";
import { z } from "zod";
import { getServerEnv } from "@/lib/env";
import {
  mollieReconciliationContextSchema,
  mollieReconciliationResultSchema,
  preparedMolliePaymentSchema,
  type PreparedMolliePayment,
} from "@/lib/mollie-contract";
import {
  createMolliePayment,
  getMolliePayment,
  MollieRequestError,
  parseMollieMetadata,
  requireHostedCheckoutUrl,
  toLocalMollieStatus,
  type MolliePayment,
} from "@/server/payments/mollie";
import { deriveQrBearerToken, hashQrBearerToken } from "@/server/qr/tokens";

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
    .update(`${payment.id}:${status}:${statusMoment}:${payment.amount.value}:${payment.amount.currency}`)
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
    if (typeof candidate === "object" && candidate !== null && "schema_version" in candidate && candidate.schema_version !== 1) {
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
  const { data: contextData, error: contextError } = await appDatabase.rpc("get_mollie_reconciliation_context", {
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

  let status;
  try {
    status = toLocalMollieStatus(providerPayment);
  } catch {
    // Een refundveld dat niet exact kan worden geïnterpreteerd mag nooit als paid doorstromen.
    const embeddedRefund = providerPayment._embedded?.refunds?.some((refund) => {
      return refund.status === "processing" || refund.status === "refunded";
    });
    status = providerPayment.amountRefunded || embeddedRefund
      ? "refunded"
      : providerPayment.status === "authorized" ? "pending" : providerPayment.status;
  }
  const nextQrVersion = context.data.qrVersion + 1;
  const tokenHash = hashQrBearerToken(deriveQrBearerToken(context.data.orderId, nextQrVersion));
  const receivedAt = (dependencies.receivedAt ?? new Date()).toISOString();
  const { data: resultData, error: resultError } = await appDatabase.rpc("reconcile_mollie_payment", {
    p_event_key: paymentEventKey(providerPayment, status),
    p_provider_id: providerPayment.id,
    p_local_payment_id: context.data.paymentId,
    p_metadata_payment_id: metadata?.payment_id ?? null,
    p_order_id: metadata?.order_id ?? context.data.orderId,
    p_member_id: metadata?.member_id ?? context.data.memberId,
    p_season_id: metadata?.season_id ?? context.data.seasonId,
    p_amount_cents: amountCents,
    p_currency: providerPayment.amount.currency,
    p_status: status,
    p_provider_created_at: timestampFrom(providerPayment, "createdAt"),
    p_provider_updated_at: receivedAt,
    p_provider_expires_at: providerPayment.expiresAt ?? null,
    p_paid_at: providerPayment.paidAt ?? null,
    p_refunded_at: status === "refunded" ? receivedAt : null,
    p_expected_qr_version: context.data.qrVersion,
    p_token_hash: tokenHash,
    p_validation_issue: metadataInspection.validationIssue,
    p_observation: metadata ? { schema_version: metadata.schema_version } : {},
  });
  if (resultError) {
    const retryable = resultError.code === "40001" || (resultError.message ?? "").includes("QR_VERSION_CONFLICT");
    throw new MollieServiceError(retryable ? "DATABASE_UNAVAILABLE" : "RECONCILIATION_REJECTED", retryable);
  }
  const result = mollieReconciliationResultSchema.safeParse(resultData);
  if (!result.success) throw new MollieServiceError("DATABASE_UNAVAILABLE", true);
  return result.data;
}
