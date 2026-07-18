import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Duindorp SV Tenueportaal",
  description: "Operationeel tenuebeheer voor Duindorp SV.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="nl"><body>{children}</body></html>;
}
