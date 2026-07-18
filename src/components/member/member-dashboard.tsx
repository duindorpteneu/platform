"use client";

import { ArrowRight, CheckCircle2, Link2, Loader2, LockKeyhole, RefreshCw, Shirt, UserRound } from "lucide-react";
import Image from "next/image";
import Link from "next/link";
import { useEffect, useState } from "react";

type Member = {
  member_id: string;
  relation_number: string;
  first_name: string;
  insertion: string | null;
  last_name: string;
  team: string;
  order_id: string | null;
  amount_due_cents: number | null;
  payment_status: string | null;
  order_status: string | null;
  qr_data_url: string | null;
  article_lines: Array<{ id: string; article: string; size: string; quantity: number; status: string }>;
};

type Candidate = {
  member_id: string;
  relation_number: string;
  first_name: string;
  insertion: string | null;
  last_name: string;
  team: string;
};

const amount = new Intl.NumberFormat("nl-NL", { style: "currency", currency: "EUR" });
const statusLabel: Record<string, string> = {
  backorder: "Nalevering",
  ready_for_pickup: "Af te halen",
  picked_up: "Afgehaald",
};

function fullName(member: { first_name: string; insertion: string | null; last_name: string }) {
  return [member.first_name, member.insertion, member.last_name].filter(Boolean).join(" ");
}

function QrPanel({ member }: { member: Member }) {
  if (member.payment_status === "paid" && member.qr_data_url) {
    return (
      <div className="flex flex-col items-center justify-center rounded-xl border border-brand-100 bg-white p-2 text-center">
        <Image src={member.qr_data_url} alt={`QR-code voor ${fullName(member)}`} width={112} height={112} unoptimized className="size-24" />
        <p className="mt-1 text-[9px] font-semibold text-brand-700">Toon bij uitgifte</p>
      </div>
    );
  }

  return (
    <div className="flex flex-col items-center justify-center rounded-xl border border-dashed border-line bg-canvas p-3 text-center">
      <LockKeyhole className="size-5 text-slate-400" />
      <p className="mt-2 text-[10px] font-semibold text-slate-500">QR vergrendeld</p>
      <p className="mt-1 text-[9px] leading-4 text-slate-400">
        {member.payment_status === "paid" ? "QR wordt klaargezet" : "Beschikbaar na betaling"}
      </p>
    </div>
  );
}

export function MemberDashboard() {
  const [members, setMembers] = useState<Member[]>([]);
  const [candidates, setCandidates] = useState<Candidate[]>([]);
  const [loading, setLoading] = useState(true);
  const [unauthorized, setUnauthorized] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [linking, setLinking] = useState<string | null>(null);

  async function load() {
    setLoading(true);
    setError(null);
    try {
      const response = await fetch("/api/parent/members", { cache: "no-store" });
      if (response.status === 401) {
        setUnauthorized(true);
        return;
      }
      if (!response.ok) throw new Error();
      const payload = await response.json() as { members: Member[] };
      setMembers(payload.members);

      const candidateResponse = await fetch("/api/parent/candidates", { cache: "no-store" });
      if (candidateResponse.ok) {
        setCandidates((await candidateResponse.json() as { candidates: Candidate[] }).candidates);
      }
    } catch {
      setError("De leden konden niet worden geladen.");
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => { void load(); }, []);

  async function linkMember(memberId: string) {
    setLinking(memberId);
    try {
      const response = await fetch("/api/parent/member-links", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ memberId }),
      });
      if (!response.ok) throw new Error();
      await load();
    } catch {
      setError("Dit lid kon niet worden gekoppeld.");
    } finally {
      setLinking(null);
    }
  }

  if (loading) {
    return <div className="mx-auto max-w-[900px] animate-pulse"><div className="h-8 w-56 rounded bg-slate-200" /><div className="mt-8 h-72 rounded-2xl bg-white" /></div>;
  }

  if (unauthorized) {
    return (
      <div className="mx-auto max-w-[560px] text-center">
        <div className="mx-auto flex size-14 items-center justify-center rounded-2xl bg-brand-700 text-white"><LockKeyhole className="size-6" /></div>
        <h1 className="mt-6 text-3xl font-bold tracking-tight text-brand-900">Log in om je tenue te bekijken</h1>
        <p className="mt-3 text-sm leading-6 text-slate-500">Je ouderaccount is niet actief in deze browser.</p>
        <Link href="/login" className="mt-7 inline-flex items-center gap-2 rounded-lg bg-brand-700 px-4 py-2.5 text-xs font-semibold text-white hover:bg-brand-900">Naar ouderlogin <ArrowRight className="size-4" /></Link>
      </div>
    );
  }

  if (error) {
    return (
      <div className="mx-auto max-w-[560px] text-center">
        <div className="mx-auto flex size-14 items-center justify-center rounded-2xl bg-red-50 text-danger"><RefreshCw className="size-6" /></div>
        <h1 className="mt-6 text-2xl font-bold text-brand-900">Tijdelijk niet beschikbaar</h1>
        <p className="mt-3 text-sm text-slate-500">{error}</p>
        <button onClick={() => void load()} className="mt-6 rounded-lg bg-brand-700 px-4 py-2.5 text-xs font-semibold text-white">Opnieuw proberen</button>
      </div>
    );
  }

  return (
    <div className="mx-auto max-w-[980px]">
      <div className="flex flex-col justify-between gap-4 sm:flex-row sm:items-end">
        <div><p className="text-xs font-bold uppercase tracking-[0.14em] text-brand-500">Mijn Duindorp SV tenue</p><h1 className="mt-2 text-3xl font-bold tracking-tight text-brand-900">Jouw tenue-overzicht</h1><p className="mt-2 text-sm text-slate-500">Ieder lid heeft een eigen bestelling, betaling en QR-code.</p></div>
        <button onClick={() => void load()} className="inline-flex items-center justify-center gap-2 rounded-lg border border-line bg-white px-3.5 py-2.5 text-xs font-semibold text-slate-600 hover:border-brand-500"><RefreshCw className="size-3.5" /> Vernieuwen</button>
      </div>

      {members.length === 0 ? (
        <div className="mt-8 rounded-2xl border border-line bg-white p-8 text-center shadow-card"><UserRound className="mx-auto size-7 text-brand-500" /><h2 className="mt-4 text-base font-bold text-brand-900">Nog geen gekoppeld lid</h2><p className="mt-2 text-sm text-slate-500">Koppel hieronder een actief lid dat bij hetzelfde e-mailadres hoort.</p></div>
      ) : (
        <div className="mt-8 grid gap-5 lg:grid-cols-2">
          {members.map((member) => (
            <article key={member.member_id} className="rounded-2xl border border-line bg-white p-6 shadow-card">
              <div className="flex items-start justify-between gap-4">
                <div className="flex items-center gap-3"><div className="flex size-11 items-center justify-center rounded-full bg-brand-50 text-sm font-bold text-brand-700">{member.first_name.slice(0, 1)}{member.last_name.slice(0, 1)}</div><div><h2 className="text-base font-bold text-brand-900">{fullName(member)}</h2><p className="mt-1 text-xs text-slate-500">{member.team} · {member.relation_number}</p></div></div>
                <span className={`rounded-full px-2.5 py-1 text-[10px] font-semibold ${member.payment_status === "paid" ? "bg-emerald-50 text-success" : "bg-amber-50 text-warning"}`}>{member.payment_status === "paid" ? "Betaald" : "Nog te betalen"}</span>
              </div>
              <div className="mt-6 grid grid-cols-[1fr_118px] gap-4">
                <div><p className="text-[10px] font-bold uppercase tracking-[0.1em] text-slate-400">Artikelregels</p><div className="mt-3 space-y-2">{member.article_lines.length === 0 ? <p className="text-xs text-slate-400">Nog geen artikelen gekoppeld.</p> : member.article_lines.map((line) => <div key={line.id} className="flex items-center justify-between rounded-lg bg-slate-50 px-3 py-2"><span className="flex items-center gap-2 text-xs font-medium text-ink"><Shirt className="size-3.5 text-brand-500" />{line.article} · {line.size}</span><span className={`text-[10px] font-semibold ${line.status === "picked_up" ? "text-success" : line.status === "ready_for_pickup" ? "text-brand-700" : "text-warning"}`}>{statusLabel[line.status] ?? line.status}</span></div>)}</div></div>
                <QrPanel member={member} />
              </div>
              <div className="mt-5 flex items-center justify-between border-t border-line pt-4"><div><p className="text-[10px] text-slate-400">Verschuldigd bedrag</p><p className="mt-1 text-sm font-bold text-ink">{member.amount_due_cents === null ? "Nog niet samengesteld" : amount.format(member.amount_due_cents / 100)}</p></div>{member.payment_status === "paid" && <span className="inline-flex items-center gap-1.5 text-[11px] font-semibold text-success"><CheckCircle2 className="size-4" /> Betaling ontvangen</span>}</div>
            </article>
          ))}
        </div>
      )}

      {candidates.length > 0 && (
        <section className="mt-8 rounded-2xl border border-line bg-white p-6 shadow-card">
          <div className="flex items-start gap-3"><div className="flex size-9 items-center justify-center rounded-lg bg-brand-50 text-brand-700"><Link2 className="size-4" /></div><div><h2 className="text-base font-bold text-brand-900">Nog een lid koppelen</h2><p className="mt-1 text-xs text-slate-500">Deze leden gebruiken hetzelfde e-mailadres. Koppelen is altijd een bewuste keuze.</p></div></div>
          <div className="mt-5 grid gap-3 sm:grid-cols-2">{candidates.map((candidate) => <button key={candidate.member_id} onClick={() => void linkMember(candidate.member_id)} disabled={linking === candidate.member_id} className="flex items-center justify-between rounded-lg border border-line px-4 py-3 text-left hover:border-brand-500 disabled:opacity-60"><span><span className="block text-xs font-semibold text-ink">{fullName(candidate)}</span><span className="mt-1 block text-[10px] text-slate-400">{candidate.team} · {candidate.relation_number}</span></span>{linking === candidate.member_id ? <Loader2 className="size-4 animate-spin text-brand-500" /> : <Link2 className="size-4 text-brand-500" />}</button>)}</div>
        </section>
      )}
    </div>
  );
}
