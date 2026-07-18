export type MetricTone = "blue" | "green" | "amber" | "slate";

export type DashboardMetric = {
  label: string;
  value: string;
  detail: string;
  tone: MetricTone;
};

export type MemberRow = {
  name: string;
  team: string;
  relationNumber: string;
  payment: "Betaald" | "Nog te betalen";
  order: "Volledig af te halen" | "Gedeeltelijk af te halen" | "Nalevering";
  progress: string;
  initials: string;
};

export const dashboardMetrics: DashboardMetric[] = [
  { label: "Totaal leden", value: "486", detail: "+12 deze maand", tone: "blue" },
  { label: "Betaald", value: "391", detail: "80,5% van totaal", tone: "green" },
  { label: "Nog niet betaald", value: "95", detail: "Actie vereist", tone: "amber" },
  { label: "Gedeeltelijk af te halen", value: "47", detail: "Meerdere artikelen gereed", tone: "slate" },
  { label: "Volledig af te halen", value: "126", detail: "Klaar voor uitgifte", tone: "green" },
  { label: "Naleveringen", value: "218", detail: "Wacht op voorraad", tone: "amber" },
];

export const memberRows: MemberRow[] = [
  { name: "Liam van der Meer", team: "JO13-1", relationNumber: "DSV-10482", payment: "Betaald", order: "Gedeeltelijk af te halen", progress: "2 van 4", initials: "LM" },
  { name: "Sophie de Jong", team: "MO11-1", relationNumber: "DSV-10479", payment: "Betaald", order: "Volledig af te halen", progress: "3 van 3", initials: "SJ" },
  { name: "Milan Bakker", team: "JO9-2", relationNumber: "DSV-10461", payment: "Nog te betalen", order: "Nalevering", progress: "0 van 3", initials: "MB" },
  { name: "Noa van Dijk", team: "JO15-1", relationNumber: "DSV-10454", payment: "Betaald", order: "Nalevering", progress: "1 van 4", initials: "ND" },
  { name: "Sem Jansen", team: "JO11-1", relationNumber: "DSV-10442", payment: "Betaald", order: "Volledig af te halen", progress: "3 van 3", initials: "SJ" },
];

export const activityItems = [
  { title: "Levering verwerkt", description: "Broekjes maat 152 · 84 stuks", time: "Vandaag, 10:42", icon: "package" },
  { title: "Bulkmail klaargezet", description: "126 ouders met gereedstaande artikelen", time: "Vandaag, 09:18", icon: "mail" },
  { title: "Sportlink-import voltooid", description: "12 nieuwe leden · 474 bijgewerkt", time: "Gisteren, 16:24", icon: "users" },
  { title: "Uitgifte gecorrigeerd", description: "Liam van der Meer · 1 artikel", time: "Gisteren, 15:07", icon: "rotate" },
];
