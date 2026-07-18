import type { NextConfig } from "next";
import { buildSecurityHeaders } from "./src/server/security/headers";

const nextConfig: NextConfig = {
  poweredByHeader: false,
  reactStrictMode: true,
  async headers() {
    return [{
      source: "/(.*)",
      headers: buildSecurityHeaders(process.env.NODE_ENV === "production", process.env.NEXT_PUBLIC_SUPABASE_URL),
    }];
  },
};

export default nextConfig;
