import { NextResponse } from "next/server";
import { getServerEnv } from "@/lib/env";
import {
  BODY_POLICIES,
  readBoundedBody,
  readBoundedJson,
  readBoundedText,
  RequestBodyError,
  validateBodyHeaders,
  validateBrowserMutation,
  type BodyHeaderOptions,
  type BodyReadOptions,
} from "@/server/security/request";

export { BODY_POLICIES };

type BodyResult<T> =
  | { ok: true; data: T }
  | { ok: false; response: NextResponse };

export function guardBrowserMutation(request: Request, options: { appBaseUrl?: string; body?: BodyHeaderOptions | false } = {}) {
  let appBaseUrl = options.appBaseUrl;
  try { appBaseUrl ??= getServerEnv().APP_BASE_URL; }
  catch { return NextResponse.json({ error: "Beveiligingsconfiguratie ontbreekt." }, { status: 503 }); }

  const mutation = validateBrowserMutation(request, appBaseUrl);
  if (!mutation.ok) return NextResponse.json({ error: "Dit verzoek kon niet veilig worden gecontroleerd." }, { status: mutation.status });

  if (options.body !== false) {
    const body = validateBodyHeaders(request, options.body ?? BODY_POLICIES.jsonStandard);
    if (!body.ok) return NextResponse.json({ error: body.status === 413 ? "Het verzoek is te groot." : "Ongeldig inhoudstype." }, { status: body.status });
  }
  return null;
}

export function bodyFailureResponse(error: unknown) {
  if (!(error instanceof RequestBodyError)) {
    return NextResponse.json(
      { error: "De aanvraaginhoud kon niet veilig worden gelezen." },
      { status: 500, headers: { "Cache-Control": "no-store" } },
    );
  }
  if (error.status === 413) {
    return NextResponse.json(
      { error: "Het verzoek is te groot." },
      { status: 413, headers: { "Cache-Control": "no-store" } },
    );
  }
  if (error.status === 408) {
    return NextResponse.json(
      { error: "Het verzoek duurde te lang." },
      { status: 408, headers: { "Cache-Control": "no-store" } },
    );
  }
  return NextResponse.json(
    { error: "Ongeldige aanvraaginhoud." },
    { status: 400, headers: { "Cache-Control": "no-store" } },
  );
}

export async function readBodyRequest(
  request: Request,
  options: BodyReadOptions,
): Promise<BodyResult<Uint8Array>> {
  try {
    return { ok: true, data: await readBoundedBody(request, options) };
  } catch (error) {
    return { ok: false, response: bodyFailureResponse(error) };
  }
}

export async function readJsonRequest(
  request: Request,
  options: BodyReadOptions,
): Promise<BodyResult<unknown>> {
  try {
    return { ok: true, data: await readBoundedJson(request, options) };
  } catch (error) {
    return { ok: false, response: bodyFailureResponse(error) };
  }
}

export async function readTextRequest(
  request: Request,
  options: BodyReadOptions,
): Promise<BodyResult<string>> {
  try {
    return { ok: true, data: await readBoundedText(request, options) };
  } catch (error) {
    return { ok: false, response: bodyFailureResponse(error) };
  }
}

export async function readEmptyRequest(request: Request): Promise<BodyResult<null>> {
  const contentLength = request.headers.get("content-length");
  if (contentLength && (!/^\d+$/.test(contentLength) || Number(contentLength) !== 0)) {
    return { ok: false, response: bodyFailureResponse(new RequestBodyError("body_too_large", 413)) };
  }
  const contentEncoding = request.headers.get("content-encoding")?.trim().toLowerCase();
  if (contentEncoding && contentEncoding !== "identity") {
    return {
      ok: false,
      response: NextResponse.json(
        { error: "Ongeldig inhoudstype." },
        { status: 415, headers: { "Cache-Control": "no-store" } },
      ),
    };
  }
  const result = await readBodyRequest(request, BODY_POLICIES.empty);
  return result.ok ? { ok: true, data: null } : result;
}
