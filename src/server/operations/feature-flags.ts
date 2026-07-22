export type FeatureFlagClient = {
  rpc: (name: string, parameters: Record<string, unknown>) => PromiseLike<{ data: unknown; error: unknown }>;
};

export async function isOperationalFeatureEnabled(client: FeatureFlagClient, flag: "mollie_enabled" | "email_enabled") {
  const { data, error } = await client.rpc("is_operational_feature_enabled", { p_flag: flag });
  return !error && data === true;
}
