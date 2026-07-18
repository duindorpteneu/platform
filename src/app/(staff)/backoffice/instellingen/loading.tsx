export default function SettingsLoading() {
  return <div className="mx-auto max-w-[1400px] animate-pulse" aria-busy="true" aria-label="Instellingen laden"><div className="h-4 w-32 rounded bg-slate-200" /><div className="mt-3 h-10 w-64 rounded bg-slate-200" /><div className="mt-6 grid gap-4 md:grid-cols-3">{Array.from({ length: 3 }, (_, index) => <div key={index} className="h-28 rounded-xl border border-line bg-white" />)}</div><div className="mt-6 grid gap-6 xl:grid-cols-[minmax(0,1fr)_430px]"><div className="h-[620px] rounded-xl border border-line bg-white" /><div className="h-[520px] rounded-xl border border-line bg-white" /></div></div>;
}

