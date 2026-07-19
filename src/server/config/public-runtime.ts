import "server-only";

const runtimeValue = (name: string) => process.env[name];

export function getPublicRuntimeConfig() {
  return {
    supabaseUrl: runtimeValue("NEXT_PUBLIC_SUPABASE_URL") ?? "",
    supabasePublishableKey: runtimeValue("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY") ?? "",
  };
}

export function serializePublicRuntimeConfig(config: ReturnType<typeof getPublicRuntimeConfig>) {
  return JSON.stringify(config).replaceAll("<", "\\u003c");
}
