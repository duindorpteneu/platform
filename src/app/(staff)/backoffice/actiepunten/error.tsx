"use client";

export default function ActionItemsError({
  reset,
}: {
  reset: () => void;
}) {
  return (
    <div className="mx-auto max-w-2xl rounded-xl border border-red-200 bg-red-50 p-6">
      <h1 className="text-lg font-bold text-danger">Actiepunten niet beschikbaar</h1>
      <p className="mt-2 text-sm leading-6 text-red-900">
        De beveiligde actiepuntenworkspace kon niet worden geladen. Probeer het
        opnieuw; er is niets gewijzigd.
      </p>
      <button
        type="button"
        onClick={reset}
        className="mt-4 min-h-11 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900"
      >
        Opnieuw proberen
      </button>
    </div>
  );
}
