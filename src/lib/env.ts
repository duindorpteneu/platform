import { z } from "zod";

const serverEnvSchema = z.object({
  NEXT_PUBLIC_SUPABASE_URL: z.string().url().optional(),
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: z.string().min(1).optional(),
  SUPABASE_SECRET_KEY: z.string().min(1).optional(),
  PARENT_TOKEN_PEPPER: z.string().min(32).optional(),
  CRON_SECRET: z.string().min(16).optional(),
  APP_BASE_URL: z.string().url().default("http://localhost:3100"),
  MOLLIE_ENABLED: z.enum(["true", "false"]).default("false"),
  EMAIL_ENABLED: z.enum(["true", "false"]).default("false"),
  SENDGRID_API_KEY: z.string().min(1).optional(),
  SENDGRID_FROM_EMAIL: z.string().email().optional(),
  SENDGRID_PARENT_OTP_TEMPLATE_ID: z.string().min(1).optional(),
});

export function getServerEnv() {
  return serverEnvSchema.parse({
    NEXT_PUBLIC_SUPABASE_URL: process.env.NEXT_PUBLIC_SUPABASE_URL,
    NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
    SUPABASE_SECRET_KEY: process.env.SUPABASE_SECRET_KEY,
    PARENT_TOKEN_PEPPER: process.env.PARENT_TOKEN_PEPPER,
    CRON_SECRET: process.env.CRON_SECRET,
    APP_BASE_URL: process.env.APP_BASE_URL,
    MOLLIE_ENABLED: process.env.MOLLIE_ENABLED,
    EMAIL_ENABLED: process.env.EMAIL_ENABLED,
    SENDGRID_API_KEY: process.env.SENDGRID_API_KEY,
    SENDGRID_FROM_EMAIL: process.env.SENDGRID_FROM_EMAIL,
    SENDGRID_PARENT_OTP_TEMPLATE_ID: process.env.SENDGRID_PARENT_OTP_TEMPLATE_ID,
  });
}
