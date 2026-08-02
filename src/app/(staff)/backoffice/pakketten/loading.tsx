export default function PackagesLoading() {
  return (
    <div className="mx-auto max-w-[1400px]" aria-busy="true" aria-label="Pakketbeheer laden">
      <div className="h-4 w-36 animate-pulse rounded bg-slate-200" />
      <div className="mt-3 h-10 w-72 animate-pulse rounded bg-slate-200" />
      <div className="mt-8 grid gap-6 xl:grid-cols-[340px_minmax(0,1fr)]">
        <div className="h-[480px] animate-pulse rounded-xl border border-line bg-white" />
        <div className="h-[560px] animate-pulse rounded-xl border border-line bg-white" />
      </div>
    </div>
  );
}
