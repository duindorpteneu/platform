import Image from "next/image";

export function BrandMark({ compact = false }: { compact?: boolean }) {
  return (
    <div className="flex items-center gap-3">
      <div className="flex size-10 shrink-0 items-center justify-center rounded-xl bg-white p-1.5 shadow-sm">
        <Image src="/duindorp-sv-logo.png" alt="Duindorp SV" width={36} height={36} className="size-full object-contain" priority />
      </div>
      {!compact && (
        <div className="min-w-0">
          <p className="truncate text-sm font-bold tracking-tight text-white">Duindorp SV</p>
          <p className="truncate text-[11px] font-medium text-blue-100">Tenueportaal</p>
        </div>
      )}
    </div>
  );
}
