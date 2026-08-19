import { normalizeCorrelationId } from "./correlation";

const SAFE_IDENTIFIER = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const SAFE_ROUTE = /^\/[a-z0-9_./:[\]-]{0,127}$/;
const PROVIDERS = new Set(["mollie", "ses", "sendgrid", "supabase"]);

export type OperationalLogLevel = "info" | "warn" | "error";

export interface OperationalLogFields {
  code?: string;
  correlationId?: string;
  count?: number;
  durationMs?: number;
  provider?: "mollie" | "ses" | "sendgrid" | "supabase";
  operation?: string;
  providerCode?: string;
  retryable?: boolean;
  jobId?: string;
  deliveryAttemptId?: string;
  route?: string;
  status?: number;
}

interface OperationalLoggerOptions {
  now?: () => Date;
  write?: (serialized: string) => void;
}

function boundedInteger(value: unknown, minimum: number, maximum: number) {
  return Number.isSafeInteger(value) && Number(value) >= minimum && Number(value) <= maximum ? Number(value) : undefined;
}

function sanitizeFields(fields: OperationalLogFields & Record<string, unknown>) {
  const safe: Record<string, string | number> = {};
  if (typeof fields.code === "string" && SAFE_IDENTIFIER.test(fields.code)) safe.code = fields.code;
  const correlationId = normalizeCorrelationId(fields.correlationId);
  if (correlationId) safe.correlationId = correlationId;
  const count = boundedInteger(fields.count, 0, 1_000_000_000);
  if (count !== undefined) safe.count = count;
  const durationMs = boundedInteger(fields.durationMs, 0, 86_400_000);
  if (durationMs !== undefined) safe.durationMs = durationMs;
  if (typeof fields.provider === "string" && PROVIDERS.has(fields.provider)) safe.provider = fields.provider;
  if (typeof fields.operation === "string" && SAFE_IDENTIFIER.test(fields.operation)) safe.operation = fields.operation;
  if (typeof fields.providerCode === "string" && SAFE_IDENTIFIER.test(fields.providerCode)) safe.providerCode = fields.providerCode;
  if (typeof fields.retryable === "boolean") safe.retryable = fields.retryable ? 1 : 0;
  if (typeof fields.jobId === "string" && /^[0-9a-f-]{36}$/u.test(fields.jobId)) safe.jobId = fields.jobId;
  if (typeof fields.deliveryAttemptId === "string" && /^[0-9a-f-]{36}$/u.test(fields.deliveryAttemptId)) safe.deliveryAttemptId = fields.deliveryAttemptId;
  if (typeof fields.route === "string" && SAFE_ROUTE.test(fields.route)) safe.route = fields.route;
  const status = boundedInteger(fields.status, 100, 599);
  if (status !== undefined) safe.status = status;
  return safe;
}

export function createOperationalLogger(options: OperationalLoggerOptions = {}) {
  const now = options.now ?? (() => new Date());
  const write = options.write ?? ((serialized: string) => process.stdout.write(`${serialized}\n`));

  function log(level: OperationalLogLevel, event: string, fields: OperationalLogFields & Record<string, unknown> = {}) {
    if (!SAFE_IDENTIFIER.test(event)) throw new TypeError("Operational event must be a stable, non-PII identifier.");
    write(JSON.stringify({ timestamp: now().toISOString(), level, event, ...sanitizeFields(fields) }));
  }

  return {
    info: (event: string, fields?: OperationalLogFields & Record<string, unknown>) => log("info", event, fields),
    warn: (event: string, fields?: OperationalLogFields & Record<string, unknown>) => log("warn", event, fields),
    error: (event: string, fields?: OperationalLogFields & Record<string, unknown>) => log("error", event, fields),
  };
}

export const operationalLogger = createOperationalLogger();
