"use client";

import { MessageCircle, ShieldCheck, X } from "lucide-react";
import { useEffect, useRef, useState } from "react";

const CONSENT_KEY = "duindorp_livechat_consent";
const LIVECHAT_SCRIPT_URL = "https://cdn.livechatinc.com/tracking.js";

type LiveChatWidgetApi = {
  _h?: ((...args: unknown[]) => unknown) | null;
  _q?: unknown[][];
  _v?: string;
  call(method: string, payload?: unknown): unknown;
  get(...args: unknown[]): unknown;
  init(): void;
  off(...args: unknown[]): unknown;
  on(...args: unknown[]): unknown;
  once(event: string, callback: () => void): unknown;
};

declare global {
  interface Window {
    __lc?: {
      asyncInit?: boolean;
      integration_name?: string;
      license?: number;
      product_name?: string;
    };
    LiveChatWidget?: LiveChatWidgetApi;
  }
}

function installLiveChatWidget() {
  window.__lc = {
    ...window.__lc,
    asyncInit: true,
    integration_name: "manual_onboarding",
    license: 19904029,
    product_name: "livechat",
  };
  if (window.LiveChatWidget) return window.LiveChatWidget;

  const queue: unknown[][] = [];
  const widget = {} as LiveChatWidgetApi;
  const invoke = (args: unknown[]) => widget._h
    ? widget._h.apply(null, args)
    : queue.push(args);
  widget._q = queue;
  widget._h = null;
  widget._v = "2.0";
  widget.on = (...args) => invoke(["on", args]);
  widget.once = (...args) => invoke(["once", args]);
  widget.off = (...args) => invoke(["off", args]);
  widget.get = (...args) => {
    if (!widget._h) {
      throw new Error("[LiveChatWidget] You can't use getters before load.");
    }
    return invoke(["get", args]);
  };
  widget.call = (...args) => invoke(["call", args]);
  widget.init = () => {
    if (document.querySelector('script[data-duindorp-livechat="tracking"]')) {
      return;
    }
    const script = document.createElement("script");
    script.async = true;
    script.type = "text/javascript";
    script.src = LIVECHAT_SCRIPT_URL;
    script.dataset.duindorpLivechat = "tracking";
    document.head.appendChild(script);
  };
  window.LiveChatWidget = widget;
  return widget;
}

export function ParentLiveChat() {
  const [consentPromptOpen, setConsentPromptOpen] = useState(false);
  const [enabled, setEnabled] = useState(false);
  const [widgetReady, setWidgetReady] = useState(false);
  const maximizeAfterLoad = useRef(false);

  useEffect(() => {
    setEnabled(window.sessionStorage.getItem(CONSENT_KEY) === "accepted");
    return () => {
      window.LiveChatWidget?.call("hide");
    };
  }, []);

  useEffect(() => {
    if (!enabled) return;
    let active = true;
    const widget = installLiveChatWidget();
    widget.once("ready", () => {
      if (!active) return;
      setWidgetReady(true);
      widget.call(maximizeAfterLoad.current ? "maximize" : "minimize");
      maximizeAfterLoad.current = false;
    });
    widget.init();
    return () => {
      active = false;
    };
  }, [enabled]);

  function startChat() {
    window.sessionStorage.setItem(CONSENT_KEY, "accepted");
    maximizeAfterLoad.current = true;
    setConsentPromptOpen(false);
    setEnabled(true);
  }

  return (
    <>
      {!widgetReady && (
        <div className="fixed bottom-4 right-4 z-[100] flex max-w-[calc(100vw-2rem)] flex-col items-end gap-3 sm:bottom-6 sm:right-6">
          {consentPromptOpen && (
            <section
              aria-label="LiveChat starten"
              className="w-[min(22rem,calc(100vw-2rem))] rounded-2xl border border-line bg-white p-5 text-left shadow-2xl"
              role="dialog"
            >
              <div className="flex items-start justify-between gap-4">
                <div className="flex size-10 shrink-0 items-center justify-center rounded-xl bg-brand-50 text-brand-700">
                  <ShieldCheck aria-hidden="true" className="size-5" />
                </div>
                <button
                  aria-label="Chatvenster sluiten"
                  className="rounded-lg p-2 text-slate-400 hover:bg-slate-50 hover:text-slate-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500"
                  onClick={() => setConsentPromptOpen(false)}
                  type="button"
                >
                  <X aria-hidden="true" className="size-4" />
                </button>
              </div>
              <h2 className="mt-4 text-sm font-bold text-brand-900">Chat met de kledingcommissie</h2>
              <p className="mt-2 text-xs leading-5 text-slate-500">
                Als je de chat start, laden we LiveChat. Deze dienst gebruikt
                functionele cookies om het gesprek te laten werken en te
                onthouden.
              </p>
              <a
                className="mt-2 inline-block text-xs font-semibold text-brand-700 underline hover:text-brand-900"
                href="https://duindorpsv.nl/privacy"
                rel="noopener noreferrer"
                target="_blank"
              >
                Lees de privacyverklaring
              </a>
              <button
                className="mt-4 inline-flex h-10 w-full items-center justify-center rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-2"
                onClick={startChat}
                type="button"
              >
                Chat starten
              </button>
            </section>
          )}

          <button
            aria-expanded={consentPromptOpen}
            className="inline-flex h-12 items-center gap-2 rounded-full bg-brand-700 px-5 text-sm font-bold text-white shadow-xl hover:bg-brand-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-2 disabled:cursor-wait disabled:opacity-80"
            disabled={enabled}
            onClick={() => setConsentPromptOpen((open) => !open)}
            type="button"
          >
            <MessageCircle aria-hidden="true" className="size-5" />
            {enabled ? "Chat wordt geopend…" : "Chat met ons"}
          </button>
        </div>
      )}

      <noscript>
        <a href="https://www.livechat.com/chat-with/19904029/" rel="nofollow">
          Chat met ons
        </a>
        , mogelijk gemaakt door{" "}
        <a
          href="https://www.livechat.com/?welcome"
          rel="noopener nofollow"
          target="_blank"
        >
          LiveChat
        </a>
      </noscript>
    </>
  );
}
