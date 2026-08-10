import { IssuanceWorkspace } from "@/components/fulfilment/issuance-workspace";
import type { Metadata, Viewport } from "next";

export const metadata: Metadata = {
  title: "Uitgiftescanner | Duindorp SV",
  description: "Online scanner voor gecontroleerde tenue-uitgifte.",
  manifest: "/uitgifte/manifest.webmanifest",
  appleWebApp: {
    capable: true,
    statusBarStyle: "default",
    title: "Uitgifte",
  },
  icons: {
    apple: "/uitgifte/apple-touch-icon.png",
  },
};

export const viewport: Viewport = {
  themeColor: "#0b2e63",
};

export default function UitgiftePage() {
  return <IssuanceWorkspace />;
}
