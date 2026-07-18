import { BarChart3, ClipboardList, Download, Mail, Package, ScanLine, Settings, WalletCards, HelpCircle } from "lucide-react";
import { notFound } from "next/navigation";
import { SectionPlaceholder } from "@/components/backoffice/section-placeholder";

const modules = {
  bestellingen: { icon: ClipboardList, eyebrow: "Orderbeheer", title: "Bestellingen", description: "Per lid één order met exacte bedragen, artikelregels en afgeleide fulfilmentstatus.", next: "De order- en betalingsmigratie wordt aangesloten op de ledenimport en het gekozen seizoen." },
  betalingen: { icon: WalletCards, eyebrow: "Financieel overzicht", title: "Betalingen", description: "Volg Mollie, kas en pin per lid zonder deel- of gezinsbetalingen toe te staan.", next: "De handmatige betaaltransactie en webhook-first Mollie-adapter volgen na de orderlaag." },
  leveringen: { icon: Package, eyebrow: "Voorraad", title: "Leveringen", description: "Registreer ontvangen varianten en reserveer beschikbare artikelen per orderregel.", next: "De voorraad- en reserveringslaag wordt gebouwd op de orderregels en variantconstraints." },
  uitgifte: { icon: ScanLine, eyebrow: "Operationeel", title: "Uitgiftehistorie", description: "Bekijk uitgiftes en correcties; de beperkte scannerflow blijft beschikbaar via de aparte Uitgifte-werkruimte.", next: "QR lookup en atomaire fulfilment worden na de ouderportal- en voorraadlaag aangesloten." },
  emails: { icon: Mail, eyebrow: "Communicatie", title: "E-mails", description: "Beheer templates, shortcodes en duurzame e-mailjobs voor transactionele clubcommunicatie.", next: "SendGrid-adapters en de jobqueue volgen nadat de order- en gereedmeldingsstaten beschikbaar zijn." },
  export: { icon: Download, eyebrow: "Rapportage", title: "Export", description: "Maak geautoriseerde CSV/XLSX-exports voor leden, orders, betalingen en uitgiftes.", next: "Exports worden pas vrijgegeven met server-side filters en formule-injectiebescherming." },
  instellingen: { icon: Settings, eyebrow: "Beheer", title: "Instellingen", description: "Beheer het actieve seizoen, clubgegevens, medewerkers en operationele safety switches.", next: "Beheerder-only instellingen worden gekoppeld aan Supabase Auth/MFA en de RLS-policies." },
  help: { icon: HelpCircle, eyebrow: "Ondersteuning", title: "Helpcentrum", description: "Operationele uitleg voor importeren, betalingen, leveringen en uitgifte.", next: "Documentatie wordt per afgeronde MVP-flow toegevoegd en blijft in het Nederlands." },
  dashboard: { icon: BarChart3, eyebrow: "Overzicht", title: "Dashboard", description: "Ga terug naar het operationeel overzicht.", next: "Het dashboard is beschikbaar via de hoofdnavigatie." },
} as const;

export default async function BackofficeModulePage({ params }: { params: Promise<{ module: string }> }) {
  const { module } = await params;
  const entry = modules[module as keyof typeof modules];
  if (!entry) notFound();
  return <SectionPlaceholder {...entry} />;
}
