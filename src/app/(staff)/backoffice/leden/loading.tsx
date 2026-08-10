export default function MembersLoading() {
  return (
    <div role="status" aria-busy="true" className="mx-auto max-w-[1440px] animate-pulse" aria-label="Ledenoverzicht laden">
      <div className="h-3 w-28 rounded bg-slate-200" />
      <div className="mt-4 h-10 w-48 rounded bg-slate-200" />
      <div className="mt-3 h-4 w-96 max-w-full rounded bg-slate-100" />
      <div className="mt-8 grid gap-6 xl:grid-cols-[minmax(0,1fr)_340px]">
        <div className="h-[620px] rounded-xl border border-line bg-white shadow-card" />
        <div className="space-y-6"><div className="h-28 rounded-xl bg-brand-50" /><div className="h-80 rounded-xl border border-line bg-white shadow-card" /></div>
      </div>
    </div>
  );
}
