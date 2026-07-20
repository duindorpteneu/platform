"use client";

import { AlertTriangle, CalendarPlus, CheckCircle2, Loader2, LockKeyhole, MailPlus, MapPin, Power, Save, ShieldCheck, UserCog, Users } from "lucide-react";
import { type FormEvent, useState } from "react";
import { useRouter } from "next/navigation";
import type { SettingsWorkspace as Workspace, StaffRole } from "@/lib/settings-audit-contract";

type Notice = { tone: "success" | "error"; text: string } | null;
const fieldClass = "mt-2 h-11 w-full rounded-lg border border-line bg-white px-3 text-sm text-ink outline-none transition focus:border-brand-500 focus:ring-2 focus:ring-brand-100 disabled:bg-slate-50 disabled:text-slate-400";
const roleLabels: Record<StaffRole, string> = { beheerder: "Beheerder", kledingcommissie: "Kledingcommissie", uitgifte: "Uitgifte" };

async function postJson(path: string, body: unknown) {
  const response = await fetch(path, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Duindorp-CSRF": "same-origin" },
    body: JSON.stringify(body),
  });
  const payload = await response.json() as { error?: string };
  if (!response.ok) throw new Error(payload.error ?? "De aanvraag kon niet worden verwerkt.");
  return payload;
}

function NoticeBox({ notice }: { notice: Notice }) {
  if (!notice) return null;
  const Icon = notice.tone === "error" ? AlertTriangle : CheckCircle2;
  return <div role={notice.tone === "error" ? "alert" : "status"} className={`mb-5 flex items-start gap-2 rounded-xl border p-4 text-xs ${notice.tone === "error" ? "border-red-100 bg-red-50 text-danger" : "border-emerald-100 bg-emerald-50 text-success"}`}><Icon className="mt-0.5 size-4 shrink-0" />{notice.text}</div>;
}

function euroString(cents: number) {
  return (cents / 100).toFixed(2).replace(".", ",");
}

function parseEuro(value: string) {
  const normalized = value.trim().replace(",", ".");
  if (!/^\d{1,6}(?:\.\d{1,2})?$/.test(normalized)) return null;
  const [euros, decimals = ""] = normalized.split(".");
  return Number(euros) * 100 + Number(decimals.padEnd(2, "0"));
}

export function SettingsWorkspace({ workspace }: { workspace: Workspace }) {
  const router = useRouter();
  const [contactEmail, setContactEmail] = useState(workspace.settings.contactEmail ?? "");
  const [pickupLocation, setPickupLocation] = useState(workspace.settings.pickupLocation ?? "");
  const [activeSeasonId, setActiveSeasonId] = useState(workspace.settings.activeSeasonId ?? workspace.seasons.find((season) => season.status === "open")?.id ?? "");
  const [amounts, setAmounts] = useState<Record<string, string>>(Object.fromEntries(workspace.seasons.map((season) => [season.id, euroString(season.defaultAmountCents)])));
  const [mollieEnabled, setMollieEnabled] = useState(workspace.settings.mollieEnabled);
  const [emailEnabled, setEmailEnabled] = useState(workspace.settings.emailEnabled);
  const [notice, setNotice] = useState<Notice>(null);
  const [saving, setSaving] = useState(false);
  const [creatingSeason, setCreatingSeason] = useState(false);
  const [seasonDraft, setSeasonDraft] = useState({ name: "", startsOn: "", endsOn: "", amount: "", makeActive: true });

  async function saveSettings(event: FormEvent) {
    event.preventDefault();
    const seasonAmounts = workspace.seasons.map((season) => ({ seasonId: season.id, amountCents: parseEuro(amounts[season.id] ?? "") }));
    if (seasonAmounts.some((item) => item.amountCents === null)) {
      setNotice({ tone: "error", text: "Gebruik per seizoen een geldig eurobedrag met maximaal twee decimalen." });
      return;
    }
    setSaving(true); setNotice(null);
    try {
      await postJson("/api/settings", {
        contactEmail, pickupLocation, activeSeasonId,
        seasonAmounts: seasonAmounts.map((item) => ({ ...item, amountCents: item.amountCents as number })),
        mollieEnabled, emailEnabled,
      });
      setNotice({ tone: "success", text: "De clubinstellingen zijn server-side gevalideerd, opgeslagen en geaudit." });
      router.refresh();
    } catch (error) {
      setNotice({ tone: "error", text: error instanceof Error ? error.message : "Opslaan mislukt." });
    } finally { setSaving(false); }
  }

  async function createSeason() {
    const defaultAmountCents = parseEuro(seasonDraft.amount);
    if (!seasonDraft.name.trim() || defaultAmountCents === null || (seasonDraft.startsOn && seasonDraft.endsOn && seasonDraft.startsOn > seasonDraft.endsOn)) {
      setNotice({ tone: "error", text: "Controleer de seizoensnaam, datums en het standaardbedrag." });
      return;
    }
    setCreatingSeason(true); setNotice(null);
    try {
      await postJson("/api/settings/seasons", {
        name: seasonDraft.name,
        startsOn: seasonDraft.startsOn,
        endsOn: seasonDraft.endsOn,
        defaultAmountCents,
        makeActive: seasonDraft.makeActive,
      });
      setNotice({ tone: "success", text: `Seizoen ${seasonDraft.name.trim()} is toegevoegd${seasonDraft.makeActive ? " en direct actief gemaakt" : ""}.` });
      setSeasonDraft({ name: "", startsOn: "", endsOn: "", amount: "", makeActive: true });
      router.refresh();
    } catch (error) {
      setNotice({ tone: "error", text: error instanceof Error ? error.message : "Seizoen toevoegen mislukt." });
    } finally { setCreatingSeason(false); }
  }

  return <div className="mx-auto max-w-[1400px]">
    <header className="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
      <div><p className="text-xs font-semibold uppercase tracking-[0.12em] text-brand-500">Beheer en beveiliging</p><h1 className="mt-2 text-[30px] font-bold tracking-[-0.04em] text-brand-900 md:text-[34px]">Instellingen</h1><p className="mt-2 max-w-2xl text-sm leading-6 text-slate-500">Beheer de vaste clubcontext, seizoensbedragen, operationele veiligheidsschakelaars en medewerkers.</p></div>
      <div className="inline-flex h-10 items-center gap-2 self-start rounded-lg border border-emerald-200 bg-emerald-50 px-3 text-xs font-bold text-success"><ShieldCheck className="size-4" />Beheerder · AAL2</div>
    </header>

    <section className="mt-6 grid gap-4 md:grid-cols-3">
      <Summary icon={LockKeyhole} label="Clubidentiteit" value="Duindorp SV" detail="Vast volgens designcanon" />
      <Summary icon={Users} label="Medewerkers" value={String(workspace.staff.filter((staff) => staff.active).length)} detail="Actieve beveiligde accounts" />
      <Summary icon={Power} label="Providers" value={`${mollieEnabled ? "Mollie" : "—"} · ${emailEnabled ? "E-mail" : "—"}`} detail="Operationeel toegestaan" />
    </section>

    <div className="mt-6 grid items-start gap-6 xl:grid-cols-[minmax(0,1fr)_430px]">
      <form onSubmit={saveSettings} className="space-y-6">
        <NoticeBox notice={notice} />
        <section className="rounded-xl border border-line bg-white p-6 shadow-card">
          <div className="border-b border-line pb-5"><p className="text-[10px] font-bold uppercase tracking-[0.12em] text-brand-500">Clubprofiel</p><h2 className="mt-1 text-lg font-bold text-brand-900">Vaste Duindorp SV-context</h2><p className="mt-1 text-xs leading-5 text-slate-500">De clubnaam en het originele logo zijn bindend. Het logo wordt niet geüpload, hertekend of geïnterpreteerd vanuit deze beheerpagina.</p></div>
          <div className="mt-5 grid gap-4 md:grid-cols-2"><label className="text-xs font-semibold text-ink">Clubnaam<input className={fieldClass} value="Duindorp SV" disabled /></label><label className="text-xs font-semibold text-ink">Contactmail<input className={fieldClass} type="email" value={contactEmail} onChange={(event) => setContactEmail(event.target.value)} maxLength={254} placeholder="kleding@duindorpsv.nl" /></label></div>
          <label className="mt-4 block text-xs font-semibold text-ink">Afhaallocatie<span className="relative block"><MapPin className="absolute left-3 top-[22px] size-4 text-slate-400" /><input className={`${fieldClass} pl-9`} value={pickupLocation} onChange={(event) => setPickupLocation(event.target.value)} maxLength={240} placeholder="Clubhuis, Duinlaan 1" /></span></label>
        </section>

        <section className="rounded-xl border border-line bg-white p-6 shadow-card">
          <div className="border-b border-line pb-5"><p className="text-[10px] font-bold uppercase tracking-[0.12em] text-brand-500">Seizoenen</p><h2 className="mt-1 text-lg font-bold text-brand-900">Actief seizoen en standaardbedragen</h2><p className="mt-1 text-xs text-slate-500">Bedragen worden in eurocenten opgeslagen; bestaande bestellingen wijzigen nooit mee.</p></div>
          {workspace.seasons.length === 0 ? <p className="mt-5 rounded-lg bg-amber-50 p-4 text-xs text-amber-800">Er is nog geen seizoen beschikbaar. Voeg hieronder het eerste seizoen toe.</p> : <><label className="mt-5 block text-xs font-semibold text-ink">Actief open seizoen<select className={fieldClass} value={activeSeasonId} onChange={(event) => setActiveSeasonId(event.target.value)} required>{workspace.seasons.filter((season) => season.status === "open").map((season) => <option key={season.id} value={season.id}>{season.name}</option>)}</select></label><div className="mt-5 divide-y divide-line rounded-xl border border-line">{workspace.seasons.map((season) => <div key={season.id} className="flex flex-col gap-3 p-4 sm:flex-row sm:items-center sm:justify-between"><div><p className="text-xs font-bold text-brand-900">{season.name}</p><p className="mt-1 text-[10px] text-slate-400">{season.status === "open" ? "Open" : "Gearchiveerd"}{season.active ? " · Actief" : ""}{season.startsOn ? ` · vanaf ${season.startsOn}` : ""}</p></div><label className="text-xs font-semibold text-ink">Standaardbedrag<div className="relative mt-2"><span className="absolute left-3 top-2.5 text-sm text-slate-400">€</span><input className="h-10 w-40 rounded-lg border border-line pl-8 pr-3 text-right text-sm outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" inputMode="decimal" value={amounts[season.id] ?? ""} onChange={(event) => setAmounts((current) => ({ ...current, [season.id]: event.target.value }))} aria-label={`Standaardbedrag ${season.name}`} /></div></label></div>)}</div></>}
          <div className="mt-5 rounded-xl border border-brand-100 bg-brand-50/50 p-4">
            <div className="flex items-center gap-3"><span className="flex size-9 items-center justify-center rounded-lg bg-white text-brand-700"><CalendarPlus className="size-4" /></span><div><h3 className="text-xs font-bold text-brand-900">Nieuw seizoen toevoegen</h3><p className="mt-0.5 text-[10px] text-slate-500">Het seizoen wordt open aangemaakt. Historische bestellingen blijven ongewijzigd.</p></div></div>
            <div className="mt-4 grid gap-3 sm:grid-cols-2"><label className="text-xs font-semibold text-ink">Naam<input className={fieldClass} value={seasonDraft.name} onChange={(event) => setSeasonDraft((current) => ({ ...current, name: event.target.value }))} maxLength={120} placeholder="2027/2028" /></label><label className="text-xs font-semibold text-ink">Standaardbedrag<div className="relative"><span className="absolute left-3 top-[22px] text-sm text-slate-400">€</span><input className={`${fieldClass} pl-8`} inputMode="decimal" value={seasonDraft.amount} onChange={(event) => setSeasonDraft((current) => ({ ...current, amount: event.target.value }))} placeholder="87,00" /></div></label><label className="text-xs font-semibold text-ink">Startdatum<input className={fieldClass} type="date" value={seasonDraft.startsOn} onChange={(event) => setSeasonDraft((current) => ({ ...current, startsOn: event.target.value }))} /></label><label className="text-xs font-semibold text-ink">Einddatum<input className={fieldClass} type="date" value={seasonDraft.endsOn} min={seasonDraft.startsOn || undefined} onChange={(event) => setSeasonDraft((current) => ({ ...current, endsOn: event.target.value }))} /></label></div>
            <div className="mt-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between"><label className="flex items-center gap-2 text-xs font-semibold text-ink"><input type="checkbox" checked={seasonDraft.makeActive} onChange={(event) => setSeasonDraft((current) => ({ ...current, makeActive: event.target.checked }))} className="size-4 accent-brand-700" /> Direct als actief seizoen instellen</label><button type="button" onClick={() => void createSeason()} disabled={creatingSeason || !seasonDraft.name.trim() || !seasonDraft.amount.trim()} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg border border-brand-200 bg-white px-4 text-xs font-bold text-brand-700 hover:border-brand-500 disabled:opacity-50">{creatingSeason ? <Loader2 className="size-4 animate-spin" /> : <CalendarPlus className="size-4" />}Seizoen toevoegen</button></div>
          </div>
        </section>

        <section className="rounded-xl border border-line bg-white p-6 shadow-card">
          <div className="border-b border-line pb-5"><p className="text-[10px] font-bold uppercase tracking-[0.12em] text-brand-500">Safety switches</p><h2 className="mt-1 text-lg font-bold text-brand-900">Operationele providerstatus</h2><p className="mt-1 text-xs leading-5 text-slate-500">Deze schakelaars blokkeren nieuwe provideracties in de database. Omgevingsconfiguratie en geldige credentials blijven altijd de harde bovengrens.</p></div>
          <div className="mt-5 space-y-3"><Switch checked={mollieEnabled} onChange={setMollieEnabled} title="Mollie-betalingen toestaan" text="Nieuwe online betaalpogingen operationeel vrijgeven." /><Switch checked={emailEnabled} onChange={setEmailEnabled} title="E-mailverzending toestaan" text="De verzendworker mag nieuwe jobs claimen en versturen." /></div>
          <div className="mt-6 flex justify-end"><button type="submit" disabled={saving || !activeSeasonId} className="inline-flex h-11 items-center justify-center gap-2 rounded-lg bg-brand-700 px-5 text-xs font-bold text-white hover:bg-brand-900 disabled:cursor-not-allowed disabled:opacity-50">{saving ? <Loader2 className="size-4 animate-spin" /> : <Save className="size-4" />}Instellingen opslaan</button></div>
        </section>
      </form>

      <StaffPanel workspace={workspace} />
    </div>
  </div>;
}

function Summary({ icon: Icon, label, value, detail }: { icon: typeof ShieldCheck; label: string; value: string; detail: string }) {
  return <div className="rounded-xl border border-line bg-white p-5 shadow-card"><div className="flex items-center justify-between"><p className="text-[10px] font-bold uppercase tracking-[0.1em] text-slate-400">{label}</p><span className="flex size-8 items-center justify-center rounded-lg bg-brand-50 text-brand-700"><Icon className="size-4" /></span></div><p className="mt-3 text-lg font-bold text-brand-900">{value}</p><p className="mt-1 text-[11px] text-slate-400">{detail}</p></div>;
}

function Switch({ checked, onChange, title, text }: { checked: boolean; onChange: (checked: boolean) => void; title: string; text: string }) {
  return <label className="flex cursor-pointer items-center gap-4 rounded-xl border border-line p-4 hover:bg-slate-50"><input type="checkbox" checked={checked} onChange={(event) => onChange(event.target.checked)} className="peer sr-only" /><span className="relative h-6 w-11 shrink-0 rounded-full bg-slate-300 transition peer-checked:bg-brand-700 peer-focus-visible:ring-2 peer-focus-visible:ring-brand-300 peer-focus-visible:ring-offset-2 after:absolute after:left-1 after:top-1 after:size-4 after:rounded-full after:bg-white after:transition peer-checked:after:translate-x-5" /><span><span className="block text-xs font-bold text-brand-900">{title}</span><span className="mt-1 block text-[11px] leading-5 text-slate-500">{text}</span></span></label>;
}

function StaffPanel({ workspace }: { workspace: Workspace }) {
  const router = useRouter();
  const [notice, setNotice] = useState<Notice>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [invite, setInvite] = useState({ email: "", displayName: "", role: "kledingcommissie" as StaffRole });

  async function updateStaff(staff: Workspace["staff"][number], form: HTMLFormElement) {
    const data = new FormData(form);
    setBusy(staff.authUserId); setNotice(null);
    try {
      await postJson("/api/settings/staff", { authUserId: staff.authUserId, displayName: String(data.get("displayName")), role: String(data.get("role")), active: data.get("active") === "on" });
      setNotice({ tone: "success", text: `${staff.displayName} is bijgewerkt en geaudit.` }); router.refresh();
    } catch (error) { setNotice({ tone: "error", text: error instanceof Error ? error.message : "Bijwerken mislukt." }); }
    finally { setBusy(null); }
  }

  async function submitInvite(event: FormEvent) {
    event.preventDefault(); setBusy("invite"); setNotice(null);
    try {
      await postJson("/api/settings/staff/invite", invite);
      setNotice({ tone: "success", text: "De uitnodiging is verstuurd en het staff-profiel is veilig geregistreerd." });
      setInvite({ email: "", displayName: "", role: "kledingcommissie" }); router.refresh();
    } catch (error) { setNotice({ tone: "error", text: error instanceof Error ? error.message : "Uitnodigen mislukt." }); }
    finally { setBusy(null); }
  }

  return <aside className="space-y-6 xl:sticky xl:top-[106px]">
    <NoticeBox notice={notice} />
    <section className="rounded-xl border border-line bg-white p-6 shadow-card"><div className="flex items-center gap-3 border-b border-line pb-5"><span className="flex size-10 items-center justify-center rounded-xl bg-brand-50 text-brand-700"><MailPlus className="size-5" /></span><div><h2 className="text-sm font-bold text-brand-900">Medewerker uitnodigen</h2><p className="mt-1 text-[11px] text-slate-400">Supabase Auth · MFA verplicht na login</p></div></div><form onSubmit={submitInvite} className="mt-5 space-y-4"><label className="block text-xs font-semibold text-ink">Naam<input className={fieldClass} value={invite.displayName} onChange={(event) => setInvite((current) => ({ ...current, displayName: event.target.value }))} minLength={2} maxLength={100} required /></label><label className="block text-xs font-semibold text-ink">E-mailadres<input className={fieldClass} type="email" value={invite.email} onChange={(event) => setInvite((current) => ({ ...current, email: event.target.value }))} maxLength={254} required /></label><label className="block text-xs font-semibold text-ink">Rol<select className={fieldClass} value={invite.role} onChange={(event) => setInvite((current) => ({ ...current, role: event.target.value as StaffRole }))}>{workspace.roles.map((role) => <option key={role} value={role}>{roleLabels[role]}</option>)}</select></label><button type="submit" disabled={Boolean(busy)} className="inline-flex h-10 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-bold text-white hover:bg-brand-900 disabled:opacity-50">{busy === "invite" ? <Loader2 className="size-4 animate-spin" /> : <MailPlus className="size-4" />}Uitnodiging versturen</button></form></section>
    <section className="overflow-hidden rounded-xl border border-line bg-white shadow-card"><div className="border-b border-line px-6 py-5"><h2 className="text-sm font-bold text-brand-900">Medewerkers</h2><p className="mt-1 text-[11px] text-slate-400">Exact drie rollen; laatste beheerder beschermd</p></div><div className="max-h-[620px] divide-y divide-line overflow-y-auto">{workspace.staff.map((staff) => <form key={staff.authUserId} onSubmit={(event) => { event.preventDefault(); void updateStaff(staff, event.currentTarget); }} className="p-5"><div className="flex items-start justify-between gap-3"><div className="flex min-w-0 items-center gap-3"><span className="flex size-9 shrink-0 items-center justify-center rounded-full bg-brand-50 text-brand-700"><UserCog className="size-4" /></span><div className="min-w-0"><input name="displayName" defaultValue={staff.displayName} aria-label={`Naam ${staff.displayName}`} className="w-full rounded border border-transparent bg-transparent px-1 text-xs font-bold text-brand-900 outline-none hover:border-line focus:border-brand-500" maxLength={100} required /><p className="mt-1 px-1 text-[10px] text-slate-400">{staff.isCurrentUser ? "Huidige gebruiker · " : ""}{staff.lastLoginAt ? `Laatst actief ${new Date(staff.lastLoginAt).toLocaleDateString("nl-NL")}` : "Nog niet ingelogd"}</p></div></div><label className="flex items-center gap-2 text-[10px] font-bold text-slate-500"><input name="active" type="checkbox" defaultChecked={staff.active} disabled={staff.isCurrentUser} className="size-4 accent-brand-700" />Actief</label></div><div className="mt-3 flex gap-2"><select name="role" defaultValue={staff.role} disabled={staff.isCurrentUser} aria-label={`Rol ${staff.displayName}`} className="h-9 min-w-0 flex-1 rounded-lg border border-line bg-white px-2 text-[11px] font-semibold text-ink outline-none focus:border-brand-500">{workspace.roles.map((role) => <option key={role} value={role}>{roleLabels[role]}</option>)}</select><button type="submit" disabled={busy === staff.authUserId} className="inline-flex h-9 items-center justify-center gap-1.5 rounded-lg border border-brand-200 px-3 text-[11px] font-bold text-brand-700 hover:bg-brand-50 disabled:opacity-50">{busy === staff.authUserId ? <Loader2 className="size-3.5 animate-spin" /> : <Save className="size-3.5" />}Opslaan</button></div></form>)}</div></section>
  </aside>;
}
