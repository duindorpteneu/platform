import { NextResponse } from "next/server";

export type PackageRpcError = {
  code?: string;
  message?: string;
};

export function packageRpcErrorResponse(error: PackageRpcError) {
  if (error.code === "42501") {
    return NextResponse.json({ error: "Alleen beheerders met MFA mogen pakketten beheren." }, { status: 403 });
  }
  if (error.code === "P0002") {
    return NextResponse.json({ error: "Het pakket, de revisie of het seizoen bestaat niet meer." }, { status: 404 });
  }
  if (error.code === "40001") {
    return NextResponse.json({ error: "Het pakket is intussen gewijzigd. Ververs en controleer opnieuw." }, { status: 409 });
  }
  if (error.code === "23505") {
    return NextResponse.json({ error: "Deze pakketcode of een open conceptrevisie bestaat al." }, { status: 409 });
  }
  if (error.code === "23514") {
    if (error.message?.includes("PACKAGE_DEFAULT_REPLACEMENT_REQUIRED")) {
      return NextResponse.json({ error: "Publiceer eerst een andere standaard voor dit seizoen." }, { status: 409 });
    }
    if (error.message?.includes("PACKAGE_PRODUCT_NOT_AVAILABLE")) {
      return NextResponse.json({ error: "Elk pakketproduct moet actief, aan het seizoen gekoppeld en voorzien van een actieve maat zijn." }, { status: 409 });
    }
    return NextResponse.json({ error: "De pakketstatus is intussen gewijzigd. Ververs en controleer opnieuw." }, { status: 409 });
  }
  if (error.code === "22023") {
    return NextResponse.json({ error: "Controleer pakketcode, prijs, inhoud en reden." }, { status: 400 });
  }
  return NextResponse.json({ error: "De pakketwijziging kon niet veilig worden opgeslagen." }, { status: 422 });
}

export function packageMutationExceptionResponse(error: unknown) {
  if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") {
    return NextResponse.json({ error: "Geen toegang tot pakketbeheer." }, { status: 403 });
  }
  if (error instanceof Error && error.message === "PACKAGE_DATABASE_UNAVAILABLE") {
    return NextResponse.json({ error: "Pakketbeheer is tijdelijk niet beschikbaar." }, { status: 503 });
  }
  return NextResponse.json({ error: "De pakketwijziging kon niet worden verwerkt." }, { status: 500 });
}
