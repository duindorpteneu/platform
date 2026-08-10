import { NextResponse } from "next/server";
import type { PortalAccessRpcError } from "@/server/portal-access/workspace";

export function portalAccessRpcErrorResponse(error: PortalAccessRpcError) {
  if (error.code === "42501") {
    return NextResponse.json({ error: "Alleen een beheerder met MFA kan portaaltoegang beheren." }, { status: 403 });
  }
  if (error.code === "P0002") {
    return NextResponse.json({ error: "De geselecteerde toegang of het seizoen bestaat niet meer." }, { status: 404 });
  }
  if (error.code === "40001") {
    return NextResponse.json({ error: "De toegangssituatie is gewijzigd. Voer de controle opnieuw uit." }, { status: 409 });
  }
  if (error.code === "23505") {
    return NextResponse.json({ error: "Deze bevestigingssleutel hoort bij een andere toegangshandeling." }, { status: 409 });
  }
  if (error.code === "23514") {
    return NextResponse.json({ error: "De selectie is niet meer veilig uitvoerbaar. Controleer de blokkades opnieuw." }, { status: 409 });
  }
  if (error.code === "22023") {
    return NextResponse.json({ error: "De toegangshandeling is ongeldig." }, { status: 400 });
  }
  return NextResponse.json({ error: "Portaaltoegang is tijdelijk niet beschikbaar." }, { status: 503 });
}

export function portalAccessExceptionResponse(error: unknown) {
  const code = error instanceof Error ? error.message : "";
  if (code === "STAFF_AUTHORIZATION_REQUIRED") {
    return NextResponse.json({ error: "Alleen een beheerder kan portaaltoegang beheren." }, { status: 403 });
  }
  if (
    code === "PORTAL_ACCESS_PREVIEW_TOKEN_INVALID"
    || code === "PORTAL_ACCESS_PREVIEW_TOKEN_MISMATCH"
    || code === "PORTAL_ACCESS_PREVIEW_TOKEN_EXPIRED"
  ) {
    return NextResponse.json({ error: "De controle is ongeldig of verlopen. Voer de controle opnieuw uit." }, { status: 409 });
  }
  if (code === "PORTAL_ACCESS_PREVIEW_PEPPER_MISSING") {
    return NextResponse.json({ error: "Portaaltoegang is nog niet veilig geconfigureerd." }, { status: 503 });
  }
  return NextResponse.json({ error: "Portaaltoegang is tijdelijk niet beschikbaar." }, { status: 503 });
}
