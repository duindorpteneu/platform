export default function PaymentsLoading() {
  return <div className="mx-auto max-w-[1400px] animate-pulse" aria-label="Betalingen laden"><div className="h-3 w-40 rounded bg-brand-100" /><div className="mt-3 h-10 w-72 rounded bg-slate-200" /><div className="mt-6 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">{Array.from({ length: 4 }, (_, index) => <div key={index} className="h-32 rounded-xl border border-line bg-white" />)}</div><div className="mt-6 h-96 rounded-xl border border-line bg-white" /></div>;
}
