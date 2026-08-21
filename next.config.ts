import type { NextConfig } from "next";
import { buildSecurityHeaders } from "./src/server/security/headers";

const nextConfig: NextConfig = {
  output: "standalone",
  poweredByHeader: false,
  reactStrictMode: true,
  experimental: {
    // Middleware clones request bodies before route handlers. This exact ceiling
    // preserves the largest signed edge probe; the immutable runtime gateway,
    // optional host Caddy and route policies keep their lower limits.
    middlewareClientMaxBodySize: 12_000_001,
  },
  async headers() {
    const production = process.env.NODE_ENV === "production";
    const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
    const parentPortalHeaders = buildSecurityHeaders(
      production,
      supabaseUrl,
      false,
      true,
    );
    return [
      {
        source: "/(.*)",
        headers: buildSecurityHeaders(production, supabaseUrl),
      },
      {
        source: "/uitgifte/:path*",
        headers: buildSecurityHeaders(production, supabaseUrl, true),
      },
      {
        source: "/",
        headers: parentPortalHeaders,
      },
      {
        source: "/login/:path*",
        headers: parentPortalHeaders,
      },
      {
        source: "/login/direct",
        headers: [
          { key: "Cache-Control", value: "no-store" },
          { key: "Referrer-Policy", value: "no-referrer" },
        ],
      },
      {
        source: "/mijn-tenue/:path*",
        headers: parentPortalHeaders,
      },
      {
        source: "/uitgifte/scanner-sw.js",
        headers: [
          {
            key: "Service-Worker-Allowed",
            value: "/uitgifte",
          },
          {
            key: "Cache-Control",
            value: "no-store",
          },
        ],
      },
    ];
  },
};

export default nextConfig;
