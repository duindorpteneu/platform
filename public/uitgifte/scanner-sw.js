/* Scanner PWA: deliberately network-only. No Cache Storage or background sync. */
self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return;
  event.respondWith(
    fetch(event.request, { cache: "no-store" }).catch(() => {
      const acceptsHtml = event.request.headers.get("accept")?.includes("text/html");
      if (acceptsHtml) {
        return new Response(
          "<!doctype html><html lang=\"nl\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>Scanner offline</title><body><main><h1>Geen netwerkverbinding</h1><p>Uitgifte werkt uitsluitend online. Herstel de verbinding en open de scanner opnieuw.</p></main></body></html>",
          {
            status: 503,
            headers: {
              "Cache-Control": "no-store",
              "Content-Type": "text/html; charset=utf-8",
            },
          },
        );
      }
      return new Response(
        JSON.stringify({ error: "SCANNER_NETWORK_REQUIRED" }),
        {
          status: 503,
          headers: {
            "Cache-Control": "no-store",
            "Content-Type": "application/json; charset=utf-8",
          },
        },
      );
    }),
  );
});
