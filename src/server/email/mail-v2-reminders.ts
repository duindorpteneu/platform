import { unstable_noStore as noStore } from "next/cache";
import {
  mailReminderRuleSchema,
  mailReminderWorkspaceSchema,
  runMailRemindersResponseSchema,
  type MailReminderTemplateKey,
  type MailReminderWorkspace,
  type RunMailRemindersResponse,
} from "@/lib/mail-v2-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { getSupabaseAdminClient } from "@/server/supabase/admin";
import { getSupabaseServerClient } from "@/server/supabase/server";

type AdminClient = NonNullable<ReturnType<typeof getSupabaseAdminClient>>;

export async function getMailReminderWorkspace(): Promise<
  MailReminderWorkspace
> {
  noStore();
  await requireStaffRole(["beheerder"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("MAIL_REMINDER_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc(
    "get_mail_reminder_workspace_v1",
  );
  if (error) {
    if (error.code === "42501") {
      throw new Error("STAFF_AUTHORIZATION_REQUIRED");
    }
    throw new Error("MAIL_REMINDER_WORKSPACE_QUERY_FAILED");
  }
  const parsed = mailReminderWorkspaceSchema.safeParse(data);
  if (!parsed.success) {
    throw new Error("MAIL_REMINDER_WORKSPACE_RESPONSE_INVALID");
  }
  return parsed.data;
}

export async function saveMailReminderRule(
  input: {
    ruleId: string | null;
    seasonId: string;
    templateKey: MailReminderTemplateKey;
    expectedRevision: number | null;
    config: {
      internalName: string;
      firstDelayHours: number;
      frequencyHours: number;
      maximumDispatches: number;
      cooldownHours: number;
      endAt: string | null;
      quietStart: string;
      quietEnd: string;
    };
  },
  correlationId: string | null,
) {
  await requireStaffRole(["beheerder"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("MAIL_REMINDER_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc(
    "save_mail_reminder_rule_v1",
    {
      p_rule_id: input.ruleId,
      p_season_id: input.seasonId,
      p_template_key: input.templateKey,
      p_expected_revision: input.expectedRevision,
      p_config: input.config,
      p_correlation_id: correlationId,
    },
  );
  if (error) return { data: null, error };
  const parsed = mailReminderRuleSchema.safeParse(data);
  if (!parsed.success) {
    throw new Error("MAIL_REMINDER_RULE_RESPONSE_INVALID");
  }
  return { data: parsed.data, error: null };
}

export async function setMailReminderRuleActive(
  input: {
    ruleId: string;
    expectedRevision: number;
    active: boolean;
    reason: string;
  },
  correlationId: string | null,
) {
  await requireStaffRole(["beheerder"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("MAIL_REMINDER_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc(
    "set_mail_reminder_rule_active_v1",
    {
      p_rule_id: input.ruleId,
      p_expected_revision: input.expectedRevision,
      p_active: input.active,
      p_reason: input.reason,
      p_correlation_id: correlationId,
    },
  );
  if (error) return { data: null, error };
  const parsed = mailReminderRuleSchema.safeParse(data);
  if (!parsed.success) {
    throw new Error("MAIL_REMINDER_RULE_RESPONSE_INVALID");
  }
  return { data: parsed.data, error: null };
}

export async function runDueMailReminders(
  admin: AdminClient,
  now: string,
  limit = 500,
): Promise<RunMailRemindersResponse> {
  const { data, error } = await admin.schema("app").rpc(
    "run_due_mail_reminders_v1",
    {
      p_now: now,
      p_limit: limit,
    },
  );
  if (error) throw new Error("MAIL_REMINDER_RUN_FAILED");
  const parsed = runMailRemindersResponseSchema.safeParse(data);
  if (!parsed.success) throw new Error("MAIL_REMINDER_RUN_RESPONSE_INVALID");
  if (parsed.data.failedRuleCount > 0) {
    throw new Error("MAIL_REMINDER_RULE_EXECUTION_FAILED");
  }
  return parsed.data;
}
