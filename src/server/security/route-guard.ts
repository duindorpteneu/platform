import { NextResponse } from "next/server";
import { getServerEnv } from "@/lib/env";
import { validateBodyHeaders, validateBrowserMutation, type BodyHeaderOptions } from "@/server/security/request";

export function guardBrowserMutation(request: Request, options: { appBaseUrl?: string; body?: BodyHeaderOptions | false } = {}) {
  let appBaseUrl = options.appBaseUrl;
  try { appBaseUrl ??= getServerEnv().APP_BASE_URL; }
  catch { return NextResponse.json({ error: "Beveiligingsconfiguratie ontbreekt." }, { status: 503 }); }

  const mutation = validateBrowserMutation(request, appBaseUrl);
  if (!mutation.ok) return NextResponse.json({ error: "Dit verzoek kon niet veilig worden gecontroleerd." }, { status: mutation.status });

  if (options.body !== false) {
    const body = validateBodyHeaders(request, options.body ?? { allowedContentTypes: ["application/json"], maxBytes: 64 * 1024 });
    if (!body.ok) return NextResponse.json({ error: body.status === 413 ? "Het verzoek is te groot." : "Ongeldig inhoudstype." }, { status: body.status });
  }
  return null;
}
