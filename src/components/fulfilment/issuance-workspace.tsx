"use client";

import { AlertTriangle, Camera, CheckCircle2, Loader2, PackageCheck, RefreshCw, ScanLine, ShieldCheck, Shirt, X } from "lucide-react";
import { FormEvent, useEffect, useMemo, useRef, useState } from "react";
import { extractQrBearerToken } from "@/lib/qr-payload";

type FulfilmentLine = { id: string; article: string; size: string; status: "backorder" | "ready_for_pickup" | "picked_up" | "cancelled" };
type LookupResult = {
  status: "found";
  orderId: string;
  paid: boolean;
  member: { name: string; team: string; relationNumberSuffix: string };
  lines: FulfilmentLine[];
};
type BarcodeDetectorLike = { detect(source: HTMLVideoElement): Promise<Array<{ rawValue: string }>> };
type BarcodeDetectorConstructor = new (options: { formats: string[] }) => BarcodeDetectorLike;

const lineLabel: Record<FulfilmentLine["status"], string> = {
  backorder: "Nalevering",
  ready_for_pickup: "Af te halen",
  picked_up: "Afgehaald",
  cancelled: "Geannuleerd",
};

export function IssuanceWorkspace() {
  const [tokenInput, setTokenInput] = useState("");
  const [activeToken, setActiveToken] = useState<string | null>(null);
  const [result, setResult] = useState<LookupResult | null>(null);
  const [selected, setSelected] = useState<string[]>([]);
  const [location, setLocation] = useState("Clubhuis Duindorp SV");
  const [message, setMessage] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [cameraActive, setCameraActive] = useState(false);
  const [success, setSuccess] = useState<{ count: number; completedAt: string } | null>(null);
  const videoRef = useRef<HTMLVideoElement>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const frameRef = useRef<number | null>(null);

  function stopCamera() {
    if (frameRef.current !== null) cancelAnimationFrame(frameRef.current);
    frameRef.current = null;
    streamRef.current?.getTracks().forEach((track) => track.stop());
    streamRef.current = null;
    setCameraActive(false);
  }

  useEffect(() => () => stopCamera(), []);

  async function lookupToken(token: string) {
    setBusy(true);
    setMessage(null);
    setResult(null);
    setSelected([]);
    setSuccess(null);
    try {
      const response = await fetch("/api/fulfilment/lookup", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ token }),
      });
      const payload = await response.json() as LookupResult | { status?: string; error?: string };
      if (!response.ok) throw new Error("error" in payload && payload.error ? payload.error : "De QR-code kon niet worden gecontroleerd.");
      if (payload.status !== "found") {
        setMessage("Deze QR-code is ongeldig of ingetrokken.");
        return;
      }
      setActiveToken(token);
      setResult(payload as LookupResult);
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "De QR-code kon niet worden gecontroleerd.");
    } finally {
      setBusy(false);
    }
  }

  async function submitToken(event: FormEvent) {
    event.preventDefault();
    const token = extractQrBearerToken(tokenInput);
    if (!token) {
      setMessage("Voer een geldige Duindorp SV QR-code in.");
      return;
    }
    await lookupToken(token);
  }

  async function startCamera() {
    setMessage(null);
    const Detector = (window as unknown as { BarcodeDetector?: BarcodeDetectorConstructor }).BarcodeDetector;
    if (!navigator.mediaDevices?.getUserMedia || !Detector) {
      setMessage("Scannen wordt in deze browser niet ondersteund. Vul de QR-code hieronder in.");
      return;
    }
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: "environment" } }, audio: false });
      streamRef.current = stream;
      setCameraActive(true);
      await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
      if (!videoRef.current) throw new Error("Camera niet beschikbaar.");
      videoRef.current.srcObject = stream;
      await videoRef.current.play();
      const detector = new Detector({ formats: ["qr_code"] });
      const scan = async () => {
        if (!videoRef.current || !streamRef.current) return;
        try {
          const codes = await detector.detect(videoRef.current);
          const token = codes[0] ? extractQrBearerToken(codes[0].rawValue) : null;
          if (token) {
            stopCamera();
            setTokenInput(token);
            await lookupToken(token);
            return;
          }
        } catch {
          setMessage("De camera kon de code niet lezen. Probeer opnieuw of vul de code in.");
          stopCamera();
          return;
        }
        frameRef.current = requestAnimationFrame(() => { void scan(); });
      };
      void scan();
    } catch {
      stopCamera();
      setMessage("Cameratoegang is niet beschikbaar. Controleer de browsertoestemming of vul de code in.");
    }
  }

  async function commitFulfilment() {
    if (!result || !activeToken || selected.length === 0) return;
    setBusy(true);
    setMessage(null);
    try {
      const response = await fetch("/api/fulfilment/commit", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ orderId: result.orderId, orderLineIds: selected, location, token: activeToken }),
      });
      const payload = await response.json() as { issuedLines?: number; completedAt?: string; error?: string };
      if (!response.ok || !payload.issuedLines || !payload.completedAt) throw new Error(payload.error ?? "De uitgifte kon niet worden voltooid.");
      setSuccess({ count: payload.issuedLines, completedAt: payload.completedAt });
      await lookupToken(activeToken);
      setSuccess({ count: payload.issuedLines, completedAt: payload.completedAt });
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "De uitgifte kon niet worden voltooid.");
    } finally {
      setBusy(false);
    }
  }

  function reset() {
    stopCamera();
    setTokenInput("");
    setActiveToken(null);
    setResult(null);
    setSelected([]);
    setMessage(null);
    setSuccess(null);
  }

  const groups = useMemo(() => ({
    ready: result?.lines.filter((line) => line.status === "ready_for_pickup") ?? [],
    backorder: result?.lines.filter((line) => line.status === "backorder") ?? [],
    pickedUp: result?.lines.filter((line) => line.status === "picked_up") ?? [],
  }), [result]);

  return (
    <div className="mx-auto max-w-[1120px]">
      <div className="flex flex-col justify-between gap-4 sm:flex-row sm:items-end">
        <div><p className="text-xs font-bold uppercase tracking-[0.14em] text-brand-500">Operationele werkruimte</p><h1 className="mt-2 text-3xl font-bold tracking-tight text-brand-900">Uitgifte</h1><p className="mt-2 text-sm text-slate-500">Scan live, controleer de actuele status en geef alleen geselecteerde artikelen uit.</p></div>
        <div className="inline-flex items-center gap-2 text-xs font-semibold text-success"><ShieldCheck className="size-4" /> Beveiligde medewerkerssessie</div>
      </div>

      <div className="mt-7 grid gap-6 xl:grid-cols-[380px_1fr]">
        <section className="rounded-2xl border border-line bg-white p-6 shadow-card">
          <div className="flex items-center justify-between"><div><p className="text-[10px] font-bold uppercase tracking-[0.14em] text-slate-400">Stap 1</p><h2 className="mt-1 text-base font-bold text-brand-900">Bestelling identificeren</h2></div><ScanLine className="size-5 text-brand-500" /></div>
          {cameraActive ? <div className="relative mt-5 overflow-hidden rounded-xl bg-slate-950"><video ref={videoRef} muted playsInline className="aspect-square w-full object-cover" /><div className="pointer-events-none absolute inset-[18%] rounded-2xl border-2 border-white/80" /><button type="button" onClick={stopCamera} aria-label="Camera sluiten" className="absolute right-3 top-3 flex size-9 items-center justify-center rounded-lg bg-slate-950/80 text-white"><X className="size-4" /></button><p className="absolute inset-x-0 bottom-4 text-center text-xs font-semibold text-white">Houd de QR-code binnen het kader</p></div> : <button type="button" onClick={() => void startCamera()} className="mt-5 flex min-h-40 w-full flex-col items-center justify-center rounded-xl border border-dashed border-brand-200 bg-brand-50/60 px-5 text-brand-700 transition-colors hover:border-brand-500 hover:bg-brand-50"><span className="flex size-12 items-center justify-center rounded-xl bg-brand-700 text-white"><Camera className="size-5" /></span><span className="mt-3 text-sm font-bold">Scan QR-code</span><span className="mt-1 text-[11px] text-slate-500">Camera start pas na deze klik</span></button>}
          <div className="my-5 flex items-center gap-3"><div className="h-px flex-1 bg-line" /><span className="text-[10px] font-bold uppercase tracking-[0.12em] text-slate-400">of code invoeren</span><div className="h-px flex-1 bg-line" /></div>
          <form onSubmit={(event) => void submitToken(event)}><label htmlFor="qr-token" className="text-xs font-semibold text-ink">QR-code of beveiligde QR-link</label><input id="qr-token" value={tokenInput} onChange={(event) => setTokenInput(event.target.value)} autoComplete="off" spellCheck={false} placeholder="v1.••••••••••••" className="mt-2 h-11 w-full rounded-lg border border-line bg-white px-3 text-xs text-ink outline-none transition focus:border-brand-500 focus:ring-2 focus:ring-brand-100" /><button disabled={busy} className="mt-3 flex h-11 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 text-sm font-semibold text-white hover:bg-brand-900 disabled:cursor-not-allowed disabled:opacity-60">{busy ? <Loader2 className="size-4 animate-spin" /> : <PackageCheck className="size-4" />} Bestelling controleren</button></form>
          {message && <div role="alert" className="mt-4 flex gap-2 rounded-lg border border-red-100 bg-red-50 p-3 text-xs leading-5 text-danger"><AlertTriangle className="mt-0.5 size-4 shrink-0" />{message}</div>}
        </section>

        <section className="rounded-2xl border border-line bg-white shadow-card">
          {!result ? <div className="flex min-h-[560px] flex-col items-center justify-center px-8 text-center"><div className="flex size-14 items-center justify-center rounded-2xl bg-slate-100 text-slate-400"><Shirt className="size-6" /></div><h2 className="mt-5 text-lg font-bold text-brand-900">Wacht op een QR-code</h2><p className="mt-2 max-w-sm text-sm leading-6 text-slate-500">Lidgegevens verschijnen pas nadat een ingelogde medewerker een geldige code heeft gecontroleerd.</p></div> : <div>
            <div className="flex flex-col justify-between gap-4 border-b border-line p-6 sm:flex-row sm:items-start"><div><div className="flex items-center gap-2"><h2 className="text-xl font-bold text-brand-900">{result.member.name}</h2><span className={`rounded-full px-2.5 py-1 text-[10px] font-bold ${result.paid ? "bg-emerald-50 text-success" : "bg-red-50 text-danger"}`}>{result.paid ? "Betaald" : "Niet betaald"}</span></div><p className="mt-2 text-xs text-slate-500">{result.member.team} · relatienummer eindigt op {result.member.relationNumberSuffix}</p></div><button onClick={reset} className="inline-flex h-9 items-center justify-center gap-2 rounded-lg border border-line px-3 text-xs font-semibold text-slate-600 hover:border-brand-500"><RefreshCw className="size-3.5" /> Nieuwe scan</button></div>
            {success && <div className="mx-6 mt-5 flex items-start gap-3 rounded-xl border border-emerald-100 bg-emerald-50 p-4 text-success"><CheckCircle2 className="mt-0.5 size-5 shrink-0" /><div><p className="text-sm font-bold">Uitgifte voltooid</p><p className="mt-1 text-xs">{success.count} {success.count === 1 ? "artikel" : "artikelen"} geregistreerd om {new Date(success.completedAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit" })}.</p></div></div>}
            {!result.paid && <div className="mx-6 mt-5 flex gap-3 rounded-xl border border-red-100 bg-red-50 p-4 text-danger"><AlertTriangle className="size-5 shrink-0" /><div><p className="text-sm font-bold">Uitgifte geblokkeerd</p><p className="mt-1 text-xs leading-5">De exacte betaling is nog niet ontvangen. Er is geen override beschikbaar.</p></div></div>}
            <div className="grid gap-5 p-6 lg:grid-cols-3">{([{ key: "ready", title: "Nu af te halen", lines: groups.ready }, { key: "backorder", title: "Nalevering", lines: groups.backorder }, { key: "picked", title: "Eerder afgehaald", lines: groups.pickedUp }] as const).map((group) => <div key={group.key}><div className="flex items-center justify-between"><h3 className="text-xs font-bold uppercase tracking-[0.1em] text-slate-500">{group.title}</h3><span className="rounded-full bg-slate-100 px-2 py-0.5 text-[10px] font-bold text-slate-500">{group.lines.length}</span></div><div className="mt-3 space-y-2">{group.lines.length === 0 ? <div className="rounded-lg border border-dashed border-line px-3 py-4 text-center text-[11px] text-slate-400">Geen artikelen</div> : group.lines.map((line) => { const selectable = result.paid && line.status === "ready_for_pickup"; const checked = selected.includes(line.id); return <label key={line.id} className={`flex min-h-14 items-center gap-3 rounded-lg border px-3 py-2.5 ${selectable ? "cursor-pointer border-line hover:border-brand-500" : "border-transparent bg-slate-50"}`}><input type="checkbox" disabled={!selectable} checked={checked} onChange={() => setSelected((current) => checked ? current.filter((id) => id !== line.id) : [...current, line.id])} className="size-4 rounded border-slate-300 text-brand-700 focus:ring-brand-500 disabled:hidden" /><span className="min-w-0 flex-1"><span className="block truncate text-xs font-semibold text-ink">{line.article}</span><span className="mt-1 block text-[10px] text-slate-400">Maat {line.size} · {lineLabel[line.status]}</span></span>{line.status === "picked_up" && <CheckCircle2 className="size-4 text-success" />}</label>; })}</div></div>)}</div>
            <div className="border-t border-line bg-slate-50/70 p-6"><div className="flex flex-col gap-4 sm:flex-row sm:items-end"><div className="flex-1"><label htmlFor="pickup-location" className="text-xs font-semibold text-ink">Uitgiftelocatie</label><input id="pickup-location" value={location} onChange={(event) => setLocation(event.target.value)} maxLength={160} className="mt-2 h-11 w-full rounded-lg border border-line bg-white px-3 text-xs outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" /></div><button onClick={() => void commitFulfilment()} disabled={busy || !result.paid || selected.length === 0 || location.trim().length === 0} className="flex h-11 min-w-64 items-center justify-center gap-2 rounded-lg bg-brand-700 px-5 text-sm font-semibold text-white hover:bg-brand-900 disabled:cursor-not-allowed disabled:bg-slate-300">{busy ? <Loader2 className="size-4 animate-spin" /> : <PackageCheck className="size-4" />} Geselecteerde artikelen uitgeven ({selected.length})</button></div></div>
          </div>}
        </section>
      </div>
    </div>
  );
}
