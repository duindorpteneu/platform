"use client";

import { ArrowLeft, ExternalLink, Loader2, LockKeyhole, RefreshCw } from "lucide-react";
import Image from "next/image";
import Link from "next/link";
import { useParams } from "next/navigation";
import { useCallback, useEffect, useRef, useState } from "react";

type State = "starting" | "error";

export default function PaymentStartPage() {
  const params = useParams<{ orderId: string }>();
  const started = useRef(false);
  const [state, setState] = useState<State>("starting");
  const [message, setMessage] = useState("Je beveiligde betaalomgeving wordt klaargezet.");

  const startPayment = useCallback(async () => {
    setState("starting");
    setMessage("Je beveiligde betaalomgeving wordt klaargezet.");
    try {
      const response = await fetch("/api/payments/mollie/create", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ orderId: params.orderId }),
      });
      const payload = await response.json() as { checkoutUrl?: unknown; error?: unknown };
      if (!response.ok) throw new Error(typeof payload.error === "string" ? payload.error : "De betaling kon niet worden gestart.");
      if (typeof payload.checkoutUrl !== "string") throw new Error("De beveiligde betaalomgeving kon niet worden geopend.");
      const checkoutUrl = new URL(payload.checkoutUrl);
      if (checkoutUrl.protocol !== "https:" || (checkoutUrl.hostname !== "mollie.com" && !checkoutUrl.hostname.endsWith(".mollie.com"))) throw new Error("De beveiligde betaalomgeving kon niet worden geopend.");
      window.location.assign(checkoutUrl.toString());
    } catch (error) {
      setState("error");
      setMessage(error instanceof Error ? error.message : "De betaling kon niet worden gestart.");
    }
  }, [params.orderId]);

  useEffect(() => {
    if (started.current) return;
    started.current = true;
    void startPayment();
  }, [startPayment]);

  return (
    <main className="min-h-screen bg-canvas px-5 py-12">
      <div className="mx-auto flex min-h-[calc(100vh-96px)] max-w-[520px] flex-col justify-center">
        <div className="rounded-2xl border border-line bg-white p-7 text-center shadow-card sm:p-9">
          <div className="mx-auto size-16 rounded-2xl border border-brand-100 bg-white p-1.5">
            <Image src="/duindorp-sv-logo.png" alt="Duindorp SV" width={52} height={52} className="size-full object-contain" priority />
          </div>
          <p className="mt-6 text-xs font-bold uppercase tracking-[0.14em] text-brand-500">Veilig betalen</p>
          <h1 className="mt-2 text-2xl font-bold tracking-tight text-brand-900">
            {state === "starting" ? "Door naar Mollie" : "Betalen lukt nu niet"}
          </h1>
          <p className="mx-auto mt-3 max-w-sm text-sm leading-6 text-slate-500" aria-live="polite">{message}</p>

          {state === "starting" ? (
            <div className="mt-7 inline-flex items-center gap-2 rounded-lg bg-brand-50 px-4 py-3 text-xs font-semibold text-brand-700">
              <Loader2 className="size-4 animate-spin" aria-hidden="true" /> Even geduld
            </div>
          ) : (
            <button onClick={() => void startPayment()} className="mt-7 inline-flex items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 py-2.5 text-xs font-semibold text-white hover:bg-brand-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-2">
              <RefreshCw className="size-4" aria-hidden="true" /> Opnieuw proberen
            </button>
          )}

          <div className="mt-7 flex items-center justify-center gap-2 border-t border-line pt-5 text-[11px] text-slate-400">
            <LockKeyhole className="size-3.5" aria-hidden="true" /> Bedrag en bestelling worden opnieuw op de server gecontroleerd.
          </div>
          <p className="mt-2 inline-flex items-center gap-1 text-[10px] text-slate-400"><ExternalLink className="size-3" aria-hidden="true" /> Je verlaat tijdelijk het tenueportaal.</p>
        </div>
        <Link href="/mijn-tenue" className="mx-auto mt-6 inline-flex items-center gap-2 text-xs font-semibold text-brand-700 hover:text-brand-900">
          <ArrowLeft className="size-4" aria-hidden="true" /> Terug naar mijn tenue
        </Link>
      </div>
    </main>
  );
}
