import { z } from "zod";

const emptyStringToUndefined = (value: unknown) => (
  typeof value === "string" && value.trim() === "" ? undefined : value
);
const optionalText = (minimum = 1) => z.preprocess(
  emptyStringToUndefined,
  z.string().min(minimum).optional(),
);
const optionalUrl = z.preprocess(emptyStringToUndefined, z.string().url().optional());
const optionalEmail = z.preprocess(emptyStringToUndefined, z.string().email().optional());

const serverEnvSchema = z.object({
  NODE_ENV: z.enum(["development", "test", "production"]).default("development"),
  NEXT_PUBLIC_SUPABASE_URL: optionalUrl,
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: optionalText(),
  SUPABASE_SECRET_KEY: optionalText(),
  SUPABASE_JWKS: optionalText(),
  PARENT_TOKEN_PEPPER: optionalText(32),
  QR_TOKEN_PEPPER: optionalText(43),
  QR_TOKEN_PEPPER_VERSION: z.string().regex(/^[1-9][0-9]{0,3}$/).default("1").transform(Number),
  QR_TOKEN_PREVIOUS_PEPPER: optionalText(43),
  QR_TOKEN_PREVIOUS_PEPPER_VERSION: z.preprocess(
    emptyStringToUndefined,
    z.string().regex(/^[1-9][0-9]{0,3}$/).transform(Number).optional(),
  ),
  CRON_SECRET: optionalText(16),
  DYNAMIC_IMPORT_ENABLED: z.enum(["true", "false"]).default("false"),
  IMPORT_STAGING_ENCRYPTION_KEY: optionalText(43),
  IMPORT_RAW_RETENTION_HOURS: z.string().regex(/^(?:[1-9]|[1-6][0-9]|7[0-2])$/).default("24").transform(Number),
  APP_BASE_URL: z.string().url().default("http://localhost:3100"),
  MOLLIE_ENABLED: z.enum(["true", "false"]).default("false"),
  MOLLIE_API_KEY: optionalText(),
  EMAIL_ENABLED: z.enum(["true", "false"]).default("false"),
  EMAIL_PROVIDER: z.enum(["ses", "sendgrid"]).optional(),
  AWS_REGION: optionalText(),
  AWS_ACCESS_KEY_ID: optionalText(),
  AWS_SECRET_ACCESS_KEY: optionalText(),
  SES_FROM_NAME: optionalText(3),
  SES_FROM_EMAIL: optionalEmail,
  SES_REPLY_TO_EMAIL: optionalEmail,
  SES_CONFIGURATION_SET: optionalText(),
  SES_SMOKE_RECIPIENT: optionalEmail,
  SES_SNS_TOPIC_ARN: optionalText(),
  SES_SNS_AUTO_CONFIRM: z.enum(["true", "false"]).default("false"),
  SENDGRID_API_KEY: optionalText(),
  SENDGRID_API_KEY_FINGERPRINT: z.preprocess(
    emptyStringToUndefined,
    z.string().regex(/^[a-f0-9]{64}$/).optional(),
  ),
  SENDGRID_API_BASE_URL: z.enum(["https://api.sendgrid.com", "https://api.eu.sendgrid.com"]).default("https://api.sendgrid.com"),
  SENDGRID_FROM_NAME: optionalText(3),
  SENDGRID_FROM_EMAIL: optionalEmail,
  SENDGRID_REPLY_TO_EMAIL: optionalEmail,
  SENDGRID_SMOKE_RECIPIENT: optionalEmail,
  SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY: optionalText(),
}).superRefine((env, context) => {
  const canonicalSecret = (value: string | undefined) => {
    if (!value || !/^[A-Za-z0-9_-]{43}$/u.test(value)) return false;
    const decoded = Buffer.from(value, "base64url");
    return decoded.byteLength === 32
      && decoded.toString("base64url") === value;
  };
  if (env.QR_TOKEN_PEPPER && !canonicalSecret(env.QR_TOKEN_PEPPER)) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["QR_TOKEN_PEPPER"],
      message: "QR-tokenpepper vereist een canonieke 32-byte base64url-sleutel.",
    });
  }
  if (
    Boolean(env.QR_TOKEN_PREVIOUS_PEPPER)
      !== Boolean(env.QR_TOKEN_PREVIOUS_PEPPER_VERSION)
  ) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["QR_TOKEN_PREVIOUS_PEPPER"],
      message: "Een vorige QR-sleutel vereist zowel pepper als versie.",
    });
  }
  if (
    env.QR_TOKEN_PREVIOUS_PEPPER
    && !canonicalSecret(env.QR_TOKEN_PREVIOUS_PEPPER)
  ) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["QR_TOKEN_PREVIOUS_PEPPER"],
      message: "Vorige QR-tokenpepper vereist een canonieke 32-byte base64url-sleutel.",
    });
  }
  if (
    env.QR_TOKEN_PREVIOUS_PEPPER_VERSION
    && env.QR_TOKEN_PREVIOUS_PEPPER_VERSION === env.QR_TOKEN_PEPPER_VERSION
  ) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["QR_TOKEN_PREVIOUS_PEPPER_VERSION"],
      message: "Huidige en vorige QR-sleutelversie moeten verschillen.",
    });
  }
  if (env.IMPORT_STAGING_ENCRYPTION_KEY) {
    const key = env.IMPORT_STAGING_ENCRYPTION_KEY;
    const decoded = Buffer.from(key, "base64url");
    if (!/^[A-Za-z0-9_-]{43}$/u.test(key) || decoded.byteLength !== 32 || decoded.toString("base64url") !== key) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ["IMPORT_STAGING_ENCRYPTION_KEY"], message: "Importstaging vereist een canonieke 32-byte base64url-sleutel." });
    }
  }
  if (env.DYNAMIC_IMPORT_ENABLED === "true" && !env.IMPORT_STAGING_ENCRYPTION_KEY) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ["IMPORT_STAGING_ENCRYPTION_KEY"], message: "Importstaging-sleutel is verplicht wanneer dynamische import actief is." });
  }
  if (env.MOLLIE_ENABLED === "true") {
    if (!env.MOLLIE_API_KEY) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ["MOLLIE_API_KEY"], message: "Mollie API-key is verplicht wanneer Mollie actief is." });
    }
    if (!env.APP_BASE_URL.startsWith("https://")) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ["APP_BASE_URL"], message: "Mollie vereist een publieke HTTPS-basis-URL." });
    }
    if (env.MOLLIE_API_KEY?.startsWith("live_") && env.NODE_ENV !== "production") {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ["MOLLIE_API_KEY"], message: "Een live Mollie-key is buiten productie niet toegestaan." });
    }
    if (!env.PARENT_TOKEN_PEPPER) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ["PARENT_TOKEN_PEPPER"], message: "Ouderportaal-tokenpepper is verplicht wanneer Mollie actief is." });
    }
  }
  if (env.EMAIL_ENABLED === "true") {
    if (!env.APP_BASE_URL.startsWith("https://")) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ["APP_BASE_URL"], message: "E-mailverzending vereist een publieke HTTPS-basis-URL." });
    }
    if (!env.EMAIL_PROVIDER) context.addIssue({ code: z.ZodIssueCode.custom, path: ["EMAIL_PROVIDER"], message: "EMAIL_PROVIDER is verplicht wanneer e-mail actief is." });
    const required = env.EMAIL_PROVIDER === "ses"
      ? ["AWS_REGION", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "SES_FROM_NAME", "SES_FROM_EMAIL", "SES_REPLY_TO_EMAIL", "SES_CONFIGURATION_SET", "SES_SNS_TOPIC_ARN", "CRON_SECRET"] as const
      : ["SENDGRID_API_KEY", "SENDGRID_API_KEY_FINGERPRINT", "SENDGRID_FROM_NAME", "SENDGRID_FROM_EMAIL", "SENDGRID_REPLY_TO_EMAIL", "SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY", "CRON_SECRET"] as const;
    for (const key of required) {
      if (!env[key]) context.addIssue({ code: z.ZodIssueCode.custom, path: [key], message: `${key} is verplicht wanneer e-mail actief is.` });
    }
  }
});

export function parseServerEnv(input: Record<string, string | undefined>) {
  return serverEnvSchema.parse(input);
}

export function getServerEnv() {
  return parseServerEnv({
    NODE_ENV: process.env.NODE_ENV,
    NEXT_PUBLIC_SUPABASE_URL: process.env.NEXT_PUBLIC_SUPABASE_URL,
    NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
    SUPABASE_SECRET_KEY: process.env.SUPABASE_SECRET_KEY,
    SUPABASE_JWKS: process.env.SUPABASE_JWKS,
    PARENT_TOKEN_PEPPER: process.env.PARENT_TOKEN_PEPPER,
    QR_TOKEN_PEPPER: process.env.QR_TOKEN_PEPPER,
    QR_TOKEN_PEPPER_VERSION: process.env.QR_TOKEN_PEPPER_VERSION,
    QR_TOKEN_PREVIOUS_PEPPER: process.env.QR_TOKEN_PREVIOUS_PEPPER,
    QR_TOKEN_PREVIOUS_PEPPER_VERSION: process.env.QR_TOKEN_PREVIOUS_PEPPER_VERSION,
    CRON_SECRET: process.env.CRON_SECRET,
    DYNAMIC_IMPORT_ENABLED: process.env.DYNAMIC_IMPORT_ENABLED,
    IMPORT_STAGING_ENCRYPTION_KEY: process.env.IMPORT_STAGING_ENCRYPTION_KEY,
    IMPORT_RAW_RETENTION_HOURS: process.env.IMPORT_RAW_RETENTION_HOURS,
    APP_BASE_URL: process.env.APP_BASE_URL,
    MOLLIE_ENABLED: process.env.MOLLIE_ENABLED,
    MOLLIE_API_KEY: process.env.MOLLIE_API_KEY,
    EMAIL_ENABLED: process.env.EMAIL_ENABLED,
    EMAIL_PROVIDER: process.env.EMAIL_PROVIDER,
    AWS_REGION: process.env.AWS_REGION,
    AWS_ACCESS_KEY_ID: process.env.AWS_ACCESS_KEY_ID,
    AWS_SECRET_ACCESS_KEY: process.env.AWS_SECRET_ACCESS_KEY,
    SES_FROM_NAME: process.env.SES_FROM_NAME,
    SES_FROM_EMAIL: process.env.SES_FROM_EMAIL,
    SES_REPLY_TO_EMAIL: process.env.SES_REPLY_TO_EMAIL,
    SES_CONFIGURATION_SET: process.env.SES_CONFIGURATION_SET,
    SES_SMOKE_RECIPIENT: process.env.SES_SMOKE_RECIPIENT,
    SES_SNS_TOPIC_ARN: process.env.SES_SNS_TOPIC_ARN,
    SES_SNS_AUTO_CONFIRM: process.env.SES_SNS_AUTO_CONFIRM,
    SENDGRID_API_KEY: process.env.SENDGRID_API_KEY,
    SENDGRID_API_KEY_FINGERPRINT:
      process.env.SENDGRID_API_KEY_FINGERPRINT,
    SENDGRID_API_BASE_URL: process.env.SENDGRID_API_BASE_URL,
    SENDGRID_FROM_NAME: process.env.SENDGRID_FROM_NAME,
    SENDGRID_FROM_EMAIL: process.env.SENDGRID_FROM_EMAIL,
    SENDGRID_REPLY_TO_EMAIL: process.env.SENDGRID_REPLY_TO_EMAIL,
    SENDGRID_SMOKE_RECIPIENT: process.env.SENDGRID_SMOKE_RECIPIENT,
    SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY: process.env.SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY,
  });
}
