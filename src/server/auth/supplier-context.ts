import { getServerEnv } from "@/lib/env";
import {
  supplierContextSchema,
  supplierSessionTokenSchema,
  type SupplierContext,
} from "@/lib/supplier-contract";
import { z } from "zod";

const SUPPLIER_CONTEXT_TIMEOUT_MS = 10_000;
export const SUPPLIER_SESSION_COOKIE = "duindorp_supplier_session";

function bytesToHex(bytes: ArrayBuffer) {
  return Array.from(new Uint8Array(bytes))
    .map((value) => value.toString(16).padStart(2, "0"))
    .join("");
}

export async function hashSupplierSecret(value: string) {
  return bytesToHex(await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  ));
}

export async function keyedSupplierRequestDigest(value: string) {
  const secret = getServerEnv().SUPABASE_SECRET_KEY;
  if (!secret) throw new Error("SUPPLIER_AUTH_UNAVAILABLE");
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return bytesToHex(await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`supplier-request-v1:${value}`),
  ));
}

function randomOpaqueToken() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/u, "");
}

export function generateSupplierAccessToken() {
  return `dsv_supplier_${randomOpaqueToken()}`;
}

export function generateSupplierSessionToken() {
  return randomOpaqueToken();
}

async function callSupplierRpc(
  name: string,
  body: Record<string, unknown>,
  throwOnTransportFailure = false,
) {
  const env = getServerEnv();
  if (!env.NEXT_PUBLIC_SUPABASE_URL || !env.SUPABASE_SECRET_KEY) return null;
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    timer = setTimeout(() => controller.abort(), SUPPLIER_CONTEXT_TIMEOUT_MS);
    const response = await fetch(
      new URL(`/rest/v1/rpc/${name}`, env.NEXT_PUBLIC_SUPABASE_URL),
      {
        method: "POST",
        headers: {
          Accept: "application/json",
          "Accept-Profile": "app",
          apikey: env.SUPABASE_SECRET_KEY,
          Authorization: `Bearer ${env.SUPABASE_SECRET_KEY}`,
          "Content-Profile": "app",
          "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
        cache: "no-store",
        signal: controller.signal,
      },
    );
    if (!response.ok) return null;
    return response.json();
  } catch {
    if (throwOnTransportFailure) throw new Error("SUPPLIER_AUTH_UNAVAILABLE");
    return null;
  } finally {
    if (timer) clearTimeout(timer);
  }
}

export async function fetchSupplierContext(
  sessionToken: string,
): Promise<SupplierContext | null> {
  if (!supplierSessionTokenSchema.safeParse(sessionToken).success) return null;
  const parsed = supplierContextSchema.safeParse(await callSupplierRpc(
    "get_supplier_planner_context_v1",
    { p_session_token_hash: await hashSupplierSecret(sessionToken) },
  ));
  return parsed.success ? parsed.data : null;
}

export async function createSupplierSession(
  accessToken: string,
  requestKey: string,
) {
  const sessionToken = generateSupplierSessionToken();
  const context = await callSupplierRpc(
    "create_supplier_planner_session_v1",
    {
      p_access_token_hash: await hashSupplierSecret(accessToken),
      p_ip_key_hash: await keyedSupplierRequestDigest(requestKey),
      p_session_token_hash: await hashSupplierSecret(sessionToken),
    },
    true,
  );
  const parsed = z.object({
    principalId: z.string().uuid(),
    displayName: z.string().min(2).max(120),
    expiresAt: z.string().datetime({ offset: true }),
  }).strict().safeParse(context);
  return parsed.success ? { sessionToken, context: parsed.data } : null;
}

export async function revokeSupplierSession(sessionToken: string) {
  if (!supplierSessionTokenSchema.safeParse(sessionToken).success) return false;
  const result = await callSupplierRpc(
    "revoke_supplier_planner_session_v1",
    { p_session_token_hash: await hashSupplierSecret(sessionToken) },
  );
  return typeof result === "number" && result > 0;
}
