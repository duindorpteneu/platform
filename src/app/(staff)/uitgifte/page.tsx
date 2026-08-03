import { IssuanceWorkspace } from "@/components/fulfilment/issuance-workspace";
import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Uitgiftescanner | Duindorp SV",
  description: "Online scanner voor gecontroleerde tenue-uitgifte.",
  manifest: "/uitgifte/manifest.webmanifest",
  themeColor: "#0b2e63",
  appleWebApp: {
    capable: true,
    statusBarStyle: "default",
    title: "Uitgifte",
  },
  icons: {
    apple: "/uitgifte/apple-touch-icon.png",
  },
};

export default function UitgiftePage() {
  return <IssuanceWorkspace />;
}
