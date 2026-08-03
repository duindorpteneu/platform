import type { NextConfig } from "next";
import { buildSecurityHeaders } from "./src/server/security/headers";

const nextConfig: NextConfig = {
  output: "standalone",
  poweredByHeader: false,
  reactStrictMode: true,
  async headers() {
    const production = process.env.NODE_ENV === "production";
    const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
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
