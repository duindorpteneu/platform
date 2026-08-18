const BASE_HEADERS = [
  { key: "Cross-Origin-Opener-Policy", value: "same-origin" },
  { key: "Cross-Origin-Resource-Policy", value: "same-origin" },
  { key: "Referrer-Policy", value: "no-referrer" },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "X-Frame-Options", value: "DENY" },
] as const;

function supabaseConnections(rawUrl: string | undefined) {
  if (!rawUrl) return ["https://*.supabase.co", "wss://*.supabase.co"];
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

const LIVECHAT_SOURCES = {
  connect: [
    "https://api.livechatinc.com",
    "https://cdn.livechatinc.com",
    "https://secure.livechatinc.com",
    "https://api.text.com",
  ],
  font: ["https://cdn.livechatinc.com", "https://secure.livechatinc.com"],
  frame: [
    "https://api.livechatinc.com",
    "https://cdn.livechatinc.com",
    "https://secure.livechatinc.com",
  ],
  image: [
    "https://cdn.livechatinc.com",
    "https://secure.livechatinc.com",
    "https://cdn.livechat-static.com",
    "https://cdn.livechat-files.com",
    "https://cdn.files-text.com",
  ],
  media: [
    "https://cdn.livechatinc.com",
    "https://secure.livechatinc.com",
    "https://cdn.livechat-static.com",
  ],
  script: [
    "https://api.livechatinc.com",
    "https://cdn.livechatinc.com",
    "https://secure.livechatinc.com",
    "https://cdn.livechat-static.com",
  ],
} as const;

function sources(values: readonly string[], enabled: boolean) {
  return enabled ? ` ${values.join(" ")}` : "";
}

export function buildContentSecurityPolicy(
  production: boolean,
  supabaseUrl?: string,
  liveChatAllowed = false,
) {
  const directives = [
    "default-src 'self'",
    "base-uri 'self'",
    `connect-src 'self' ${supabaseConnections(supabaseUrl).join(" ")}${sources(LIVECHAT_SOURCES.connect, liveChatAllowed)}`.trim(),
    `font-src 'self' data:${sources(LIVECHAT_SOURCES.font, liveChatAllowed)}`,
    "form-action 'self'",
    "frame-ancestors 'none'",
    liveChatAllowed
      ? `frame-src${sources(LIVECHAT_SOURCES.frame, true)}`
      : "frame-src 'none'",
    `img-src 'self' data: blob:${sources(LIVECHAT_SOURCES.image, liveChatAllowed)}`,
    "manifest-src 'self'",
    `media-src 'self'${sources(LIVECHAT_SOURCES.media, liveChatAllowed)}`,
    "object-src 'none'",
    `script-src 'self' 'unsafe-inline'${production ? "" : " 'unsafe-eval'"}${sources(LIVECHAT_SOURCES.script, liveChatAllowed)}`,
    "style-src 'self' 'unsafe-inline'",
    "worker-src 'self' blob:",
  ];
  if (production) directives.push("upgrade-insecure-requests");
  return directives.join("; ");
}

export function buildSecurityHeaders(
  production: boolean,
  supabaseUrl?: string,
  cameraAllowed = false,
  liveChatAllowed = false,
) {
  const headers: Array<{ key: string; value: string }> = [
    {
      key: "Content-Security-Policy",
      value: buildContentSecurityPolicy(production, supabaseUrl, liveChatAllowed),
    },
    {
      key: "Permissions-Policy",
      value: `camera=${cameraAllowed ? "(self)" : "()"}, geolocation=(), microphone=(), payment=(), usb=()`,
    },
    ...BASE_HEADERS,
  ];
  if (production) headers.push({ key: "Strict-Transport-Security", value: "max-age=31536000; includeSubDomains" });
  return headers;
}
