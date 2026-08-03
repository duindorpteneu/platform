"use client";

import {
  AlertTriangle,
  Camera,
  CheckCircle2,
  Download,
  Loader2,
  PackageCheck,
  RefreshCw,
  ScanLine,
  ShieldCheck,
  Shirt,
  Wifi,
  WifiOff,
  X,
} from "lucide-react";
import {
  FormEvent,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import {
  formatIssuanceGender,
  fulfilmentCommitResponseSchema,
  fulfilmentExchangeResponseSchema,
  type FulfilmentExchangeFound,
} from "@/lib/fulfilment-contract";
import { extractQrLocator } from "@/lib/qr-payload";

type FulfilmentLine = FulfilmentExchangeFound["lines"][number];
type BarcodeDetectorLike = {
  detect(source: HTMLVideoElement): Promise<Array<{ rawValue: string }>>;
};
type BarcodeDetectorConstructor = new (
  options: { formats: string[] },
) => BarcodeDetectorLike;
type InstallPromptEvent = Event & {
  prompt(): Promise<void>;
  userChoice: Promise<{ outcome: "accepted" | "dismissed" }>;
};
type ScannerControls = { stop(): void };

const lineLabel: Record<FulfilmentLine["status"], string> = {
  backorder: "Nalevering",
  ready_for_pickup: "Af te halen",
  picked_up: "Afgehaald",
};

export function IssuanceWorkspace() {
  const [locatorInput, setLocatorInput] = useState("");
  const [result, setResult] = useState<FulfilmentExchangeFound | null>(null);
  const [selected, setSelected] = useState<string[]>([]);
  const [message, setMessage] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [cameraActive, setCameraActive] = useState(false);
  const [online, setOnline] = useState(true);
  const [installPrompt, setInstallPrompt] =
    useState<InstallPromptEvent | null>(null);
  const [commitRequestId, setCommitRequestId] = useState<string | null>(null);
  const [success, setSuccess] = useState<{
    count: number;
    completedAt: string;
    outcome: "partial_pickup" | "package_complete";
  } | null>(null);
  const videoRef = useRef<HTMLVideoElement>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const frameRef = useRef<number | null>(null);
  const fallbackControlsRef = useRef<ScannerControls | null>(null);
  const cameraGenerationRef = useRef(0);
  const cameraAcceptingRef = useRef(false);
  const exchangeAbortRef = useRef<AbortController | null>(null);
  const exchangeGenerationRef = useRef(0);
  const commitAbortRef = useRef<AbortController | null>(null);
  const commitGenerationRef = useRef(0);

  function stopCamera() {
    cameraGenerationRef.current += 1;
    cameraAcceptingRef.current = false;
    if (frameRef.current !== null) cancelAnimationFrame(frameRef.current);
    frameRef.current = null;
    fallbackControlsRef.current?.stop();
    fallbackControlsRef.current = null;
    streamRef.current?.getTracks().forEach((track) => track.stop());
    streamRef.current = null;
    if (videoRef.current) videoRef.current.srcObject = null;
    setCameraActive(false);
  }

  function clearScan() {
    exchangeGenerationRef.current += 1;
    exchangeAbortRef.current?.abort();
    exchangeAbortRef.current = null;
    commitGenerationRef.current += 1;
    commitAbortRef.current?.abort();
    commitAbortRef.current = null;
    setLocatorInput("");
    setResult(null);
    setSelected([]);
    setCommitRequestId(null);
    setBusy(false);
  }

  useEffect(() => {
    setOnline(navigator.onLine);
    const onlineHandler = () => setOnline(true);
    const offlineHandler = () => {
      setOnline(false);
      stopCamera();
      clearScan();
      setMessage("Uitgifte werkt uitsluitend online. Scan opnieuw zodra de verbinding hersteld is.");
    };
    const promptHandler = (event: Event) => {
      event.preventDefault();
      setInstallPrompt(event as InstallPromptEvent);
    };
    const visibilityHandler = () => {
      if (document.visibilityState === "hidden") {
        stopCamera();
        clearScan();
      }
    };
    window.addEventListener("online", onlineHandler);
    window.addEventListener("offline", offlineHandler);
    window.addEventListener("beforeinstallprompt", promptHandler);
    document.addEventListener("visibilitychange", visibilityHandler);
    if ("serviceWorker" in navigator) {
      void navigator.serviceWorker.register(
        "/uitgifte/scanner-sw.js",
        { scope: "/uitgifte" },
      );
    }
    return () => {
      stopCamera();
      exchangeGenerationRef.current += 1;
      exchangeAbortRef.current?.abort();
      commitGenerationRef.current += 1;
      commitAbortRef.current?.abort();
      window.removeEventListener("online", onlineHandler);
      window.removeEventListener("offline", offlineHandler);
      window.removeEventListener("beforeinstallprompt", promptHandler);
      document.removeEventListener("visibilitychange", visibilityHandler);
    };
  }, []);

  useEffect(() => {
    if (!result) return;
    const remaining = new Date(result.grantExpiresAt).getTime() - Date.now();
    if (remaining <= 0) {
      clearScan();
      setMessage("De scan is verlopen. Scan de QR-code opnieuw.");
      return;
    }
    const timer = window.setTimeout(() => {
      clearScan();
      setMessage("De scan is verlopen. Scan de QR-code opnieuw.");
    }, remaining);
    return () => window.clearTimeout(timer);
  }, [result]);

  async function exchangeLocator(locator: string) {
    if (!online) {
      setMessage("Uitgifte werkt uitsluitend online.");
      return;
    }
    exchangeGenerationRef.current += 1;
    const exchangeGeneration = exchangeGenerationRef.current;
    exchangeAbortRef.current?.abort();
    const controller = new AbortController();
    exchangeAbortRef.current = controller;
    setBusy(true);
    setMessage(null);
    setLocatorInput("");
    setResult(null);
    setSelected([]);
    setCommitRequestId(null);
    setSuccess(null);
    try {
      const response = await fetch("/api/fulfilment/exchange", {
        method: "POST",
        cache: "no-store",
        signal: controller.signal,
        headers: {
          "Content-Type": "application/json",
          "X-Duindorp-CSRF": "same-origin",
        },
        body: JSON.stringify({
          locator,
          requestId: crypto.randomUUID(),
        }),
      });
      const payload: unknown = await response.json();
      if (exchangeGeneration !== exchangeGenerationRef.current) return;
      if (!response.ok) {
        const errorMessage = payload
          && typeof payload === "object"
          && "error" in payload
          && typeof payload.error === "string"
          ? payload.error
          : "De QR-code kon niet worden gecontroleerd.";
        throw new Error(errorMessage);
      }
      const parsed = fulfilmentExchangeResponseSchema.safeParse(payload);
      if (!parsed.success) {
        throw new Error("De QR-code gaf een ongeldig serverantwoord.");
      }
      if (parsed.data.status !== "found") {
        setMessage("Deze QR-code is ongeldig, ingetrokken of nog niet afhaalklaar.");
        return;
      }
      setResult(parsed.data);
    } catch (error) {
      if (exchangeGeneration !== exchangeGenerationRef.current) return;
      setResult(null);
      setSelected([]);
      setCommitRequestId(null);
      setMessage(
        error instanceof DOMException && error.name === "AbortError"
          ? null
          : error instanceof Error
          ? error.message
          : "De QR-code kon niet worden gecontroleerd.",
      );
    } finally {
      if (exchangeGeneration === exchangeGenerationRef.current) {
        exchangeAbortRef.current = null;
        setBusy(false);
      }
    }
  }

  async function submitLocator(event: FormEvent) {
    event.preventDefault();
    const locator = extractQrLocator(locatorInput);
    if (!locator) {
      setLocatorInput("");
      setMessage("Voer een geldige Duindorp SV QR-code in.");
      return;
    }
    await exchangeLocator(locator);
  }

  async function acceptCameraValue(value: string) {
    if (cameraAcceptingRef.current) return false;
    const locator = extractQrLocator(value);
    if (!locator) return false;
    cameraAcceptingRef.current = true;
    stopCamera();
    await exchangeLocator(locator);
    return true;
  }

  async function startFallbackCamera() {
    if (!videoRef.current) throw new Error("Camera niet beschikbaar.");
    const { BrowserQRCodeReader } = await import("@zxing/browser");
    const reader = new BrowserQRCodeReader();
    const cameraGeneration = cameraGenerationRef.current;
    const controls = await reader.decodeFromConstraints(
      {
        audio: false,
        video: { facingMode: { ideal: "environment" } },
      },
      videoRef.current,
      (decoded) => {
        if (
          !decoded
          || cameraGeneration !== cameraGenerationRef.current
          || cameraAcceptingRef.current
        ) return;
        void acceptCameraValue(decoded.getText());
      },
    );
    fallbackControlsRef.current = controls;
  }

  async function startNativeCamera(Detector: BarcodeDetectorConstructor) {
    const cameraGeneration = cameraGenerationRef.current;
    const stream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: { ideal: "environment" } },
      audio: false,
    });
    streamRef.current = stream;
    if (!videoRef.current) throw new Error("Camera niet beschikbaar.");
    videoRef.current.srcObject = stream;
    await videoRef.current.play();
    const detector = new Detector({ formats: ["qr_code"] });
    const scan = async () => {
      if (
        !videoRef.current
        || !streamRef.current
        || cameraGeneration !== cameraGenerationRef.current
        || cameraAcceptingRef.current
      ) return;
      try {
        const codes = await detector.detect(videoRef.current);
        if (codes[0] && await acceptCameraValue(codes[0].rawValue)) return;
      } catch {
        stopCamera();
        setMessage("De camera kon de code niet lezen. Probeer opnieuw of vul de code in.");
        return;
      }
      frameRef.current = requestAnimationFrame(() => {
        void scan();
      });
    };
    void scan();
  }

  async function startCamera() {
    setMessage(null);
    if (!online) {
      setMessage("Uitgifte werkt uitsluitend online.");
      return;
    }
    if (!navigator.mediaDevices?.getUserMedia) {
      setMessage("Cameratoegang wordt in deze browser niet ondersteund.");
      return;
    }
    try {
      cameraGenerationRef.current += 1;
      cameraAcceptingRef.current = false;
      setCameraActive(true);
      await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
      const Detector = (
        window as unknown as { BarcodeDetector?: BarcodeDetectorConstructor }
      ).BarcodeDetector;
      if (Detector) await startNativeCamera(Detector);
      else await startFallbackCamera();
    } catch {
      stopCamera();
      setMessage("Cameratoegang is niet beschikbaar. Controleer de browsertoestemming.");
    }
  }

  async function commitFulfilment() {
    if (!result || selected.length === 0 || !online) return;
    commitGenerationRef.current += 1;
    const commitGeneration = commitGenerationRef.current;
    commitAbortRef.current?.abort();
    const controller = new AbortController();
    commitAbortRef.current = controller;
    const requestId = commitRequestId ?? crypto.randomUUID();
    setCommitRequestId(requestId);
    setBusy(true);
    setMessage(null);
    try {
      const response = await fetch("/api/fulfilment/commit", {
        method: "POST",
        cache: "no-store",
        signal: controller.signal,
        headers: {
          "Content-Type": "application/json",
          "X-Duindorp-CSRF": "same-origin",
        },
        body: JSON.stringify({
          orderLineIds: selected,
          requestId,
          scanGrant: result.scanGrant,
        }),
      });
      const payload: unknown = await response.json();
      if (commitGeneration !== commitGenerationRef.current) return;
      if (!response.ok) {
        const errorMessage = payload
          && typeof payload === "object"
          && "error" in payload
          && typeof payload.error === "string"
          ? payload.error
          : "De uitgifte kon niet worden voltooid.";
        if (response.status < 500) {
          clearScan();
          setMessage(errorMessage);
          return;
        }
        throw new Error(errorMessage);
      }
      const parsed = fulfilmentCommitResponseSchema.safeParse(payload);
      if (!parsed.success) {
        clearScan();
        throw new Error("De uitgifte gaf een ongeldig serverantwoord.");
      }
      if (parsed.data.status !== "completed") {
        clearScan();
        setMessage(
          parsed.data.status === "stale"
            ? "De scan is niet meer actueel. Scan de QR-code opnieuw."
            : "Uitgifte is nu geblokkeerd. Controleer betaling en reservering.",
        );
        return;
      }
      setSuccess({
        count: parsed.data.issuedLines,
        completedAt: parsed.data.completedAt,
        outcome: parsed.data.outcome,
      });
      clearScan();
    } catch (error) {
      if (commitGeneration !== commitGenerationRef.current) return;
      setMessage(
        error instanceof DOMException && error.name === "AbortError"
          ? null
          : error instanceof Error
          ? error.message
          : "De uitgifte kon niet worden voltooid.",
      );
    } finally {
      if (commitGeneration === commitGenerationRef.current) {
        commitAbortRef.current = null;
        setBusy(false);
      }
    }
  }

  function reset() {
    stopCamera();
    setLocatorInput("");
    clearScan();
    setMessage(null);
    setSuccess(null);
  }

  async function installScanner() {
    if (!installPrompt) return;
    await installPrompt.prompt();
    await installPrompt.userChoice;
    setInstallPrompt(null);
  }

  const groups = useMemo(() => ({
    ready: result?.lines.filter(
      (line) => line.status === "ready_for_pickup",
    ) ?? [],
    backorder: result?.lines.filter((line) => line.status === "backorder") ?? [],
    pickedUp: result?.lines.filter((line) => line.status === "picked_up") ?? [],
  }), [result]);

  function toggleLine(lineId: string, checked: boolean) {
    setCommitRequestId(null);
    setSelected((current) => (
      checked
        ? current.filter((id) => id !== lineId)
        : [...current, lineId]
    ));
  }

  return (
    <div className="mx-auto max-w-[1120px]">
      <div className="flex flex-col justify-between gap-4 sm:flex-row sm:items-end">
        <div>
          <p className="text-xs font-bold uppercase tracking-[0.14em] text-brand-500">Operationele scanner</p>
          <h1 className="mt-2 text-3xl font-bold tracking-tight text-brand-900">Uitgifte</h1>
          <p className="mt-2 text-sm text-slate-500">Scan live en geef uitsluitend concrete, betaalde reserveringen uit.</p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <span className={`inline-flex items-center gap-2 rounded-lg px-3 py-2 text-xs font-semibold ${online ? "bg-emerald-50 text-success" : "bg-red-50 text-danger"}`}>
            {online ? <Wifi className="size-4" /> : <WifiOff className="size-4" />}
            {online ? "Online" : "Offline geblokkeerd"}
          </span>
          {installPrompt && (
            <button type="button" onClick={() => void installScanner()} className="inline-flex min-h-10 items-center gap-2 rounded-lg border border-line bg-white px-3 text-xs font-semibold text-brand-900 hover:border-brand-500">
              <Download className="size-4" /> Scanner installeren
            </button>
          )}
          <span className="inline-flex items-center gap-2 text-xs font-semibold text-success">
            <ShieldCheck className="size-4" /> Beveiligde medewerkerssessie
          </span>
        </div>
      </div>

      <div className="mt-7 grid gap-6 xl:grid-cols-[380px_1fr]">
        <section className="rounded-2xl border border-line bg-white p-6 shadow-card">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-[10px] font-bold uppercase tracking-[0.14em] text-slate-400">Stap 1</p>
              <h2 className="mt-1 text-base font-bold text-brand-900">Pakket identificeren</h2>
            </div>
            <ScanLine className="size-5 text-brand-500" />
          </div>
          {cameraActive ? (
            <div className="relative mt-5 overflow-hidden rounded-xl bg-slate-950">
              <video ref={videoRef} muted playsInline className="aspect-square w-full object-cover" />
              <div className="pointer-events-none absolute inset-[18%] rounded-2xl border-2 border-white/80" />
              <button type="button" onClick={stopCamera} aria-label="Camera sluiten" className="absolute right-3 top-3 flex size-11 items-center justify-center rounded-lg bg-slate-950/80 text-white">
                <X className="size-4" />
              </button>
              <p className="absolute inset-x-0 bottom-4 text-center text-xs font-semibold text-white">Houd de QR-code binnen het kader</p>
            </div>
          ) : (
            <button type="button" disabled={!online || busy} onClick={() => void startCamera()} className="mt-5 flex min-h-40 w-full flex-col items-center justify-center rounded-xl border border-dashed border-brand-200 bg-brand-50/60 px-5 text-brand-700 transition-colors hover:border-brand-500 hover:bg-brand-50 disabled:cursor-not-allowed disabled:opacity-50">
              <span className="flex size-12 items-center justify-center rounded-xl bg-brand-700 text-white">
                <Camera className="size-5" />
              </span>
              <span className="mt-3 text-sm font-bold">Scan QR-code</span>
              <span className="mt-1 text-[11px] text-slate-500">Camera start pas na deze klik</span>
            </button>
          )}
          <div className="my-5 flex items-center gap-3">
            <div className="h-px flex-1 bg-line" />
            <span className="text-[10px] font-bold uppercase tracking-[0.12em] text-slate-400">of code invoeren</span>
            <div className="h-px flex-1 bg-line" />
          </div>
          <form onSubmit={(event) => void submitLocator(event)}>
            <label htmlFor="qr-locator" className="text-xs font-semibold text-ink">QR-code of beveiligde fragmentlink</label>
            <input id="qr-locator" value={locatorInput} onChange={(event) => setLocatorInput(event.target.value)} autoComplete="off" spellCheck={false} placeholder="q2.k1.••••••••••••" className="mt-2 h-11 w-full rounded-lg border border-line bg-white px-3 text-xs text-ink outline-none transition focus:border-brand-500 focus:ring-2 focus:ring-brand-100" />
            <button disabled={busy || !online} className="mt-3 flex h-11 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 text-sm font-semibold text-white hover:bg-brand-900 disabled:cursor-not-allowed disabled:opacity-60">
              {busy ? <Loader2 className="size-4 animate-spin" /> : <PackageCheck className="size-4" />}
              Pakket controleren
            </button>
          </form>
          {message && (
            <div role="alert" className="mt-4 flex gap-2 rounded-lg border border-red-100 bg-red-50 p-3 text-xs leading-5 text-danger">
              <AlertTriangle className="mt-0.5 size-4 shrink-0" />{message}
            </div>
          )}
        </section>

        <section className="rounded-2xl border border-line bg-white shadow-card">
          {!result ? (
            <div className="flex min-h-[560px] flex-col items-center justify-center px-8 text-center">
              {success ? (
                <>
                  <div className="flex size-14 items-center justify-center rounded-2xl bg-emerald-50 text-success">
                    <CheckCircle2 className="size-7" />
                  </div>
                  <h2 className="mt-5 text-lg font-bold text-brand-900">
                    {success.outcome === "package_complete" ? "Pakket volledig uitgegeven" : "Deeluitgifte voltooid"}
                  </h2>
                  <p className="mt-2 max-w-sm text-sm leading-6 text-slate-500">
                    {success.count} {success.count === 1 ? "regel" : "regels"} geregistreerd om {new Date(success.completedAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit" })}. De uitgifte is één keer transactioneel geregistreerd.
                  </p>
                  <button type="button" onClick={reset} className="mt-6 inline-flex min-h-11 items-center gap-2 rounded-lg bg-brand-700 px-5 text-sm font-semibold text-white hover:bg-brand-900">
                    <RefreshCw className="size-4" /> Nieuwe scan
                  </button>
                </>
              ) : (
                <>
                  <div className="flex size-14 items-center justify-center rounded-2xl bg-slate-100 text-slate-400">
                    <Shirt className="size-6" />
                  </div>
                  <h2 className="mt-5 text-lg font-bold text-brand-900">Wacht op een QR-code</h2>
                  <p className="mt-2 max-w-sm text-sm leading-6 text-slate-500">Alleen na een geldige, online scan verschijnen voornaam, geslacht en de actuele pakketregels.</p>
                </>
              )}
            </div>
          ) : (
            <div>
              <div className="flex flex-col justify-between gap-4 border-b border-line p-6 sm:flex-row sm:items-start">
                <div>
                  <div className="flex flex-wrap items-center gap-2">
                    <h2 className="text-xl font-bold text-brand-900">{result.member.firstName}</h2>
                    <span className="rounded-full bg-blue-50 px-2.5 py-1 text-[10px] font-bold text-brand-700">{formatIssuanceGender(result.member.gender)}</span>
                    <span className="rounded-full bg-emerald-50 px-2.5 py-1 text-[10px] font-bold text-success">Betaling en reservering herbevestigd</span>
                  </div>
                  <p className="mt-2 text-xs text-slate-500">De scanbevoegdheid verloopt automatisch; er worden geen verdere lidgegevens getoond.</p>
                </div>
                <button onClick={reset} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-lg border border-line px-3 text-xs font-semibold text-slate-600 hover:border-brand-500">
                  <RefreshCw className="size-3.5" /> Nieuwe scan
                </button>
              </div>
              <div className="grid gap-5 p-6 lg:grid-cols-3">
                {([
                  { key: "ready", title: "Nu af te halen", lines: groups.ready },
                  { key: "backorder", title: "Nalevering", lines: groups.backorder },
                  { key: "picked", title: "Eerder afgehaald", lines: groups.pickedUp },
                ] as const).map((group) => (
                  <div key={group.key}>
                    <div className="flex items-center justify-between">
                      <h3 className="text-xs font-bold uppercase tracking-[0.1em] text-slate-500">{group.title}</h3>
                      <span className="rounded-full bg-slate-100 px-2 py-0.5 text-[10px] font-bold text-slate-500">{group.lines.length}</span>
                    </div>
                    <div className="mt-3 space-y-2">
                      {group.lines.length === 0 ? (
                        <div className="rounded-lg border border-dashed border-line px-3 py-4 text-center text-[11px] text-slate-400">Geen artikelen</div>
                      ) : group.lines.map((line) => {
                        const selectable = line.status === "ready_for_pickup";
                        const checked = selected.includes(line.id);
                        return (
                          <label key={line.id} className={`flex min-h-14 items-center gap-3 rounded-lg border px-3 py-2.5 ${selectable ? "cursor-pointer border-line hover:border-brand-500" : "border-transparent bg-slate-50"}`}>
                            <input type="checkbox" disabled={!selectable} checked={checked} onChange={() => toggleLine(line.id, checked)} className="size-4 rounded border-slate-300 text-brand-700 focus:ring-brand-500 disabled:hidden" />
                            <span className="min-w-0 flex-1">
                              <span className="block truncate text-xs font-semibold text-ink">{line.article}</span>
                              <span className="mt-1 block text-[10px] text-slate-400">Maat {line.size} · {line.quantity}× · {lineLabel[line.status]}</span>
                            </span>
                            {line.status === "picked_up" && <CheckCircle2 className="size-4 text-success" />}
                          </label>
                        );
                      })}
                    </div>
                  </div>
                ))}
              </div>
              <div className="border-t border-line bg-slate-50/70 p-6">
                <div className="flex flex-col justify-between gap-4 sm:flex-row sm:items-center">
                  <p className="max-w-xl text-xs leading-5 text-slate-500">De uitgiftelocatie komt uit de beheerde clubconfiguratie. Offline uitgifte, betaaloverride en voorraadoverride zijn niet beschikbaar.</p>
                  <button onClick={() => void commitFulfilment()} disabled={busy || !online || selected.length === 0} className="flex min-h-11 min-w-64 items-center justify-center gap-2 rounded-lg bg-brand-700 px-5 text-sm font-semibold text-white hover:bg-brand-900 disabled:cursor-not-allowed disabled:bg-slate-300">
                    {busy ? <Loader2 className="size-4 animate-spin" /> : <PackageCheck className="size-4" />}
                    Geselecteerde artikelen uitgeven ({selected.length})
                  </button>
                </div>
              </div>
            </div>
          )}
        </section>
      </div>
    </div>
  );
}
