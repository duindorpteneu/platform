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
  PARENT_TOKEN_PEPPER: optionalText(32),
  CRON_SECRET: optionalText(16),
  APP_BASE_URL: z.string().url().default("http://localhost:3100"),
  MOLLIE_ENABLED: z.enum(["true", "false"]).default("false"),
  MOLLIE_API_KEY: optionalText(),
  EMAIL_ENABLED: z.enum(["true", "false"]).default("false"),
  SENDGRID_API_KEY: optionalText(),
  SENDGRID_FROM_EMAIL: optionalEmail,
  SENDGRID_REPLY_TO_EMAIL: optionalEmail,
  SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY: optionalText(),
}).superRefine((env, context) => {
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
      context.addIssue({ code: z.ZodIssueCode.custom, path: ["PARENT_TOKEN_PEPPER"], message: "QR-tokenpepper is verplicht wanneer Mollie actief is." });
    }
  }
  if (env.EMAIL_ENABLED === "true") {
    if (!env.APP_BASE_URL.startsWith("https://")) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ["APP_BASE_URL"], message: "E-mailverzending vereist een publieke HTTPS-basis-URL." });
    }
    const required = ["SENDGRID_API_KEY", "SENDGRID_FROM_EMAIL", "SENDGRID_REPLY_TO_EMAIL", "SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY", "CRON_SECRET"] as const;
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
    PARENT_TOKEN_PEPPER: process.env.PARENT_TOKEN_PEPPER,
    CRON_SECRET: process.env.CRON_SECRET,
    APP_BASE_URL: process.env.APP_BASE_URL,
    MOLLIE_ENABLED: process.env.MOLLIE_ENABLED,
    MOLLIE_API_KEY: process.env.MOLLIE_API_KEY,
    EMAIL_ENABLED: process.env.EMAIL_ENABLED,
    SENDGRID_API_KEY: process.env.SENDGRID_API_KEY,
    SENDGRID_FROM_EMAIL: process.env.SENDGRID_FROM_EMAIL,
    SENDGRID_REPLY_TO_EMAIL: process.env.SENDGRID_REPLY_TO_EMAIL,
    SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY: process.env.SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY,
  });
}
