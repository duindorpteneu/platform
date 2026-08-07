import type { Metadata } from "next";
import type { CSSProperties } from "react";
import "./globals.css";
import { getPublicRuntimeConfig, serializePublicRuntimeConfig } from "@/server/config/public-runtime";
import { getPublishedBrandCssVariables } from "@/server/branding/public-tokens";

export const dynamic = "force-dynamic";

export const metadata: Metadata = {
  title: "Duindorp SV Tenueportaal",
  description: "Operationeel tenuebeheer voor Duindorp SV.",
  icons: {
    icon: [{
      url: "/uitgifte/icon-192.png",
      type: "image/png",
      sizes: "192x192",
    }],
    apple: [{
      url: "/uitgifte/apple-touch-icon.png",
      type: "image/png",
      sizes: "180x180",
    }],
  },
};

export default async function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  const runtimeConfig = serializePublicRuntimeConfig(getPublicRuntimeConfig());
  const brandStyle = await getPublishedBrandCssVariables();
  return <html lang="nl" style={brandStyle as CSSProperties}><body><script dangerouslySetInnerHTML={{ __html: `globalThis.__DUINDORP_RUNTIME_CONFIG__=${runtimeConfig}` }} />{children}</body></html>;
}
