import { AuditWorkspace } from "@/components/audit/audit-workspace";
import { auditFiltersSchema } from "@/lib/settings-audit-contract";
import { getAuditWorkspace } from "@/server/audit/workspace";

export const dynamic = "force-dynamic";

type SearchParams = Promise<Record<string, string | string[] | undefined>>;

export default async function AuditPage({ searchParams }: { searchParams: SearchParams }) {
  const raw = await searchParams;
  const candidate = {
    ...(typeof raw.category === "string" && raw.category ? { category: raw.category } : {}),
    ...(typeof raw.action === "string" && raw.action ? { action: raw.action } : {}),
    ...(typeof raw.actorUserId === "string" && raw.actorUserId ? { actorUserId: raw.actorUserId } : {}),
    ...(typeof raw.before === "string" && raw.before ? { before: raw.before } : {}),
    limit: typeof raw.limit === "string" ? raw.limit : "50",
  };
  const parsed = auditFiltersSchema.safeParse(candidate);
  const filters = parsed.success ? parsed.data : auditFiltersSchema.parse({ limit: 50 });
  const workspace = await getAuditWorkspace(filters);
  return <AuditWorkspace workspace={workspace} filters={filters} />;
}

