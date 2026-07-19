import type { Metadata } from "next";
import "./globals.css";
import { getPublicRuntimeConfig, serializePublicRuntimeConfig } from "@/server/config/public-runtime";

export const dynamic = "force-dynamic";

export const metadata: Metadata = {
  title: "Duindorp SV Tenueportaal",
  description: "Operationeel tenuebeheer voor Duindorp SV.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  const runtimeConfig = serializePublicRuntimeConfig(getPublicRuntimeConfig());
  return <html lang="nl"><body><script dangerouslySetInnerHTML={{ __html: `globalThis.__DUINDORP_RUNTIME_CONFIG__=${runtimeConfig}` }} />{children}</body></html>;
}
