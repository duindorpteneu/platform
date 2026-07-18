import { z } from "zod";

const serverEnvSchema = z.object({
  NODE_ENV: z.enum(["development", "test", "production"]).default("development"),
  NEXT_PUBLIC_SUPABASE_URL: z.string().url().optional(),
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: z.string().min(1).optional(),
  SUPABASE_SECRET_KEY: z.string().min(1).optional(),
  PARENT_TOKEN_PEPPER: z.string().min(32).optional(),
  CRON_SECRET: z.string().min(16).optional(),
  APP_BASE_URL: z.string().url().default("http://localhost:3100"),
  MOLLIE_ENABLED: z.enum(["true", "false"]).default("false"),
  MOLLIE_API_KEY: z.string().min(1).optional(),
  EMAIL_ENABLED: z.enum(["true", "false"]).default("false"),
  SENDGRID_API_KEY: z.string().min(1).optional(),
  SENDGRID_FROM_EMAIL: z.string().email().optional(),
  SENDGRID_REPLY_TO_EMAIL: z.string().email().optional(),
  SENDGRID_PARENT_OTP_TEMPLATE_ID: z.string().min(1).optional(),
  SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY: z.string().min(1).optional(),
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
    const required = ["SENDGRID_API_KEY", "SENDGRID_FROM_EMAIL", "SENDGRID_REPLY_TO_EMAIL", "SENDGRID_PARENT_OTP_TEMPLATE_ID", "SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY", "CRON_SECRET"] as const;
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
    SENDGRID_PARENT_OTP_TEMPLATE_ID: process.env.SENDGRID_PARENT_OTP_TEMPLATE_ID,
    SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY: process.env.SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY,
  });
}
