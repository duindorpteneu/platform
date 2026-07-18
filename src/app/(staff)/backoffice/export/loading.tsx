export default function ExportLoading() {
  return <div className="mx-auto max-w-[1400px] animate-pulse" aria-label="Exports laden"><div className="h-3 w-52 rounded bg-slate-200" /><div className="mt-4 h-10 w-52 rounded bg-slate-200" /><div className="mt-8 grid gap-3 sm:grid-cols-2 xl:grid-cols-3">{Array.from({ length: 6 }, (_, index) => <div key={index} className="h-32 rounded-xl border border-line bg-white shadow-card" />)}</div><div className="mt-6 h-72 rounded-xl border border-line bg-white shadow-card" /></div>;
}

