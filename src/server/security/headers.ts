const BASE_HEADERS = [
  { key: "Cross-Origin-Opener-Policy", value: "same-origin" },
  { key: "Cross-Origin-Resource-Policy", value: "same-origin" },
  { key: "Permissions-Policy", value: "camera=(self), geolocation=(), microphone=(), payment=(), usb=()" },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "X-Frame-Options", value: "DENY" },
] as const;

function supabaseConnections(rawUrl: string | undefined) {
  if (!rawUrl) return [];
  try {
    const url = new URL(rawUrl);
    if (url.protocol !== "https:" && url.protocol !== "http:") return [];
    const websocket = new URL(url.origin);
    websocket.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    return [url.origin, websocket.origin];
  } catch {
    return [];
  }
}

export function buildContentSecurityPolicy(production: boolean, supabaseUrl?: string) {
  const directives = [
    "default-src 'self'",
    "base-uri 'self'",
    `connect-src 'self' ${supabaseConnections(supabaseUrl).join(" ")}`.trim(),
    "font-src 'self' data:",
    "form-action 'self'",
    "frame-ancestors 'none'",
    "frame-src 'none'",
    "img-src 'self' data: blob:",
    "manifest-src 'self'",
    "media-src 'self'",
    "object-src 'none'",
    `script-src 'self' 'unsafe-inline'${production ? "" : " 'unsafe-eval'"}`,
    "style-src 'self' 'unsafe-inline'",
    "worker-src 'self' blob:",
  ];
  if (production) directives.push("upgrade-insecure-requests");
  return directives.join("; ");
}

export function buildSecurityHeaders(production: boolean, supabaseUrl?: string) {
  const headers: Array<{ key: string; value: string }> = [
    { key: "Content-Security-Policy", value: buildContentSecurityPolicy(production, supabaseUrl) },
    ...BASE_HEADERS,
  ];
  if (production) headers.push({ key: "Strict-Transport-Security", value: "max-age=31536000; includeSubDomains" });
  return headers;
}
