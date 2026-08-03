import { hashParentSecret } from "@/server/auth/parent";

type RateLimitClient = {
  schema: (name: string) => { rpc: (name: string, parameters: Record<string, unknown>) => PromiseLike<{ data: unknown; error: { message?: string } | null }> };
};

export function requestRateKey(request: Request, discriminator: string) {
  const forwarded = request.headers.get("x-forwarded-for")?.split(",", 1)[0]?.trim();
  const address = request.headers.get("x-real-ip")?.trim() || forwarded || "unknown";
  return hashParentSecret(`rate:${discriminator}:${address}`);
}

export function valueRateKey(discriminator: string, value: string) {
  return hashParentSecret(`rate:${discriminator}:${value}`);
}

export async function consumeRateLimit(client: RateLimitClient, input: { scope: "otp_request" | "otp_verify" | "mollie_create" | "export" | "search" | "supplier_login"; keyHash: string; limit: number; windowSeconds: number }) {
  const { data, error } = await client.schema("app").rpc("consume_rate_limit", {
    p_scope: input.scope,
    p_key_hash: input.keyHash,
    p_limit: input.limit,
    p_window_seconds: input.windowSeconds,
  });
  return !error && data === true;
}
