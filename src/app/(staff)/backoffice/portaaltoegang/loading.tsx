export default function PortalAccessLoading() {
  return (
    <div role="status" aria-busy="true" className="mx-auto max-w-[1440px] animate-pulse" aria-label="Portaaltoegang laden">
      <div className="h-8 w-64 rounded bg-slate-200" />
      <div className="mt-7 h-24 rounded-xl bg-white" />
      <div className="mt-6 grid gap-6 xl:grid-cols-[minmax(0,1fr)_430px]">
        <div className="h-[560px] rounded-xl bg-white" />
        <div className="h-72 rounded-xl bg-white" />
      </div>
    </div>
  );
}
