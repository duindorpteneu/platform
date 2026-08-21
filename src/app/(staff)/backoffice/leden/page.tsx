import { MemberOverview } from "@/components/members/member-overview";
import { getMemberOverview } from "@/server/members/overview";

type SearchParams = Promise<Record<string, string | string[] | undefined>>;

export default async function MembersPage({ searchParams }: { searchParams: SearchParams }) {
  const overview = await getMemberOverview(await searchParams);
  return <MemberOverview list={overview.list} detail={overview.detail} otpSupport={overview.otpSupport} query={overview.query} savedViews={overview.savedViews} staffRole={overview.staff.role} packageOptions={overview.packageOptions} />;
}
