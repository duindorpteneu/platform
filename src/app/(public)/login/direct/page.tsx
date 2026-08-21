import type { Metadata } from "next";
import { ShieldCheck } from "lucide-react";
import { ParentDirectLogin } from "@/components/member/parent-direct-login";

export const dynamic = "force-dynamic";
export const metadata: Metadata = {
  referrer: "no-referrer",
  robots: { index: false, follow: false },
};

export default function ParentDirectLoginPage() {
  return (
    <main className="min-h-screen bg-canvas px-5 py-12">
      <div className="mx-auto flex min-h-[calc(100vh-96px)] max-w-[520px] flex-col justify-center text-center">
        <div className="mx-auto flex size-14 items-center justify-center rounded-2xl bg-brand-700 text-white">
          <ShieldCheck aria-hidden="true" className="size-6" />
        </div>
        <p className="mt-6 text-xs font-bold uppercase tracking-[0.14em] text-brand-500">
          Beveiligd inloggen
        </p>
        <h1 className="mt-2 text-3xl font-bold tracking-tight text-brand-900">
          Direct inloggen
        </h1>
        <div className="mt-8"><ParentDirectLogin /></div>
      </div>
    </main>
  );
}
