import { NextResponse } from "next/server";
import type { ActionItemRpcError } from "./workspace";

const privateHeaders = {
  "Cache-Control": "private, no-store, max-age=0",
};

export function actionItemError(message: string, status: number) {
  return NextResponse.json({ error: message }, {
    status,
    headers: privateHeaders,
  });
}

export function actionItemRpcErrorResponse(error: ActionItemRpcError) {
  if (error.code === "42501") {
    return actionItemError(
      "Je hebt geen toegang tot dit actiepunt of deze handeling.",
      403,
    );
  }
  if (error.code === "P0002") {
    return actionItemError(
      "Het actiepunt of seizoen bestaat niet meer.",
      404,
    );
  }
  if (error.code === "40001") {
    return actionItemError(
      "Het actiepunt is intussen gewijzigd. Vernieuw de lijst.",
      409,
    );
  }
  if (error.code === "23514") {
    return actionItemError(
      "Deze eigenaar of statusovergang is niet toegestaan.",
      409,
    );
  }
  if (error.code === "22023") {
    return actionItemError("Controleer de handeling en reden.", 400);
  }
  return actionItemError(
    "Actiepunten zijn tijdelijk niet beschikbaar.",
    503,
  );
}

export function actionItemExceptionResponse(error: unknown) {
  const code = error instanceof Error ? error.message : "";
  if (code === "STAFF_AUTHORIZATION_REQUIRED") {
    return actionItemError("Je hebt geen toegang tot actiepunten.", 403);
  }
  if (code === "ACTION_ITEM_DATABASE_UNAVAILABLE") {
    return actionItemError(
      "Actiepunten zijn tijdelijk niet beschikbaar.",
      503,
    );
  }
  return actionItemError(
    "De actiepunthandeling kon niet veilig worden verwerkt.",
    500,
  );
}
