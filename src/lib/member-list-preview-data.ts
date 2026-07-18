export type MemberListPreviewRow = {
  name: string;
  team: string;
  relationNumber: string;
  payment: "Betaald" | "Nog te betalen";
  order: "Volledig af te halen" | "Gedeeltelijk af te halen" | "Nalevering";
};

export const memberListPreviewRows: MemberListPreviewRow[] = [
  { name: "Liam van der Meer", team: "JO13-1", relationNumber: "DSV-10482", payment: "Betaald", order: "Gedeeltelijk af te halen" },
  { name: "Sophie de Jong", team: "MO11-1", relationNumber: "DSV-10479", payment: "Betaald", order: "Volledig af te halen" },
  { name: "Milan Bakker", team: "JO9-2", relationNumber: "DSV-10461", payment: "Nog te betalen", order: "Nalevering" },
  { name: "Noa van Dijk", team: "JO15-1", relationNumber: "DSV-10454", payment: "Betaald", order: "Nalevering" },
  { name: "Sem Jansen", team: "JO11-1", relationNumber: "DSV-10442", payment: "Betaald", order: "Volledig af te halen" },
];
