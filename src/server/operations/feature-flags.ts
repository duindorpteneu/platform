export type FeatureFlagClient = {
  schema: (name: string) => { from: (table: string) => { select: (columns: string) => { eq: (column: string, value: boolean) => { maybeSingle: () => PromiseLike<{ data: Record<string, unknown> | null; error: unknown }> } } } };
};

export async function isOperationalFeatureEnabled(client: FeatureFlagClient, flag: "mollie_enabled" | "email_enabled") {
  const { data, error } = await client.schema("app").from("app_settings").select(flag).eq("id", true).maybeSingle();
  return !error && data?.[flag] === true;
}
