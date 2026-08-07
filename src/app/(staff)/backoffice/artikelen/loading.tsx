export default function ArticlesLoading() {
  return <div role="status" aria-busy="true" className="mx-auto max-w-[1400px] animate-pulse" aria-label="Catalogus laden"><div className="h-3 w-28 rounded bg-slate-200" /><div className="mt-4 h-10 w-72 rounded bg-slate-200" /><div className="mt-8 grid gap-6 xl:grid-cols-[340px_minmax(0,1fr)]"><div className="h-[620px] rounded-xl border border-line bg-white shadow-card" /><div className="h-[620px] rounded-xl border border-line bg-white shadow-card" /></div></div>;
}
