export default function ActionItemsLoading() {
  return (
    <div role="status" className="mx-auto max-w-[1440px]" aria-busy="true" aria-label="Actiepunten laden">
      <div className="h-8 w-52 animate-pulse rounded bg-slate-200" />
      <div className="mt-3 h-4 w-full max-w-2xl animate-pulse rounded bg-slate-100" />
      <div className="mt-7 grid gap-3 sm:grid-cols-3">
        {[0, 1, 2].map((key) => (
          <div key={key} className="h-24 animate-pulse rounded-xl border border-line bg-white" />
        ))}
      </div>
      <div className="mt-5 h-24 animate-pulse rounded-xl border border-line bg-white" />
      <div className="mt-5 h-64 animate-pulse rounded-xl border border-line bg-white" />
    </div>
  );
}
