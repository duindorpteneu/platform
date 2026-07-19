import { createBrowserClient } from "@supabase/ssr";

let browserClient: ReturnType<typeof createBrowserClient> | null = null;

declare global {
  // Public project data only; never add server-side secrets here.
  var __DUINDORP_RUNTIME_CONFIG__: { supabaseUrl?: string; supabasePublishableKey?: string } | undefined;
}

export function getSupabaseBrowserClient() {
  const url = globalThis.__DUINDORP_RUNTIME_CONFIG__?.supabaseUrl;
  const publishableKey = globalThis.__DUINDORP_RUNTIME_CONFIG__?.supabasePublishableKey;
  if (!url || !publishableKey) return null;

  browserClient ??= createBrowserClient(url, publishableKey);
  return browserClient;
}
