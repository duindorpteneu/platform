import { unstable_noStore as noStore } from "next/cache";
import {
  memberDetailResponseSchema,
  memberListQuerySchema,
  memberListResponseSchema,
  type MemberListQuery,
} from "@/lib/member-overview-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { getMemberSavedViews } from "@/server/members/saved-views";
import { getSupabaseServerClient } from "@/server/supabase/server";

export const MEMBER_LIST_PAGE_SIZE = 50;
type RawSearchParams = Record<string, string | string[] | undefined>;

function scalar(params: RawSearchParams, key: string) {
  return typeof params[key] === "string" ? params[key] : undefined;
}

export function parseMemberListQuery(params: RawSearchParams): MemberListQuery {
  const parsed = memberListQuerySchema.safeParse({
    search: scalar(params, "search"),
    team: scalar(params, "team"),
    payment: scalar(params, "payment"),
    orderStatus: scalar(params, "orderStatus"),
    articleId: scalar(params, "articleId"),
    size: scalar(params, "size"),
    lineStatus: scalar(params, "lineStatus"),
    member: scalar(params, "member"),
    page: scalar(params, "page"),
  });
  if (!parsed.success) throw new Error("MEMBER_LIST_QUERY_INVALID");
  return parsed.data;
}

export async function getMemberOverview(rawParams: RawSearchParams) {
  noStore();
  const query = parseMemberListQuery(rawParams);
  const staff = await requireStaffRole(["beheerder", "kledingcommissie"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("MEMBER_DATABASE_UNAVAILABLE");
  if (query.search) {
    const { data: allowed, error: rateError } = await supabase.schema("app").rpc("consume_staff_search_rate");
    if (rateError?.code === "42501") throw new Error("STAFF_AUTHORIZATION_REQUIRED");
    if (rateError || allowed !== true) throw new Error("MEMBER_SEARCH_RATE_LIMITED");
  }

  const { data: listData, error: listError } = await supabase.schema("app").rpc("get_member_list", {
    p_search: query.search ?? null,
    p_team: query.team ?? null,
    p_payment_filter: query.payment ?? null,
    p_order_status: query.orderStatus ?? null,
    p_article_id: query.articleId ?? null,
    p_size: query.size ?? null,
    p_line_status: query.lineStatus ?? null,
    p_limit: MEMBER_LIST_PAGE_SIZE,
    p_offset: (query.page - 1) * MEMBER_LIST_PAGE_SIZE,
  });
  if (listError) {
    if (listError.code === "42501") throw new Error("STAFF_AUTHORIZATION_REQUIRED");
    throw new Error("MEMBER_LIST_QUERY_FAILED");
  }
  const list = memberListResponseSchema.safeParse(listData);
  if (!list.success) throw new Error("MEMBER_LIST_RESPONSE_INVALID");
  let savedViews = null;
  if (list.data.activeSeason) {
    const savedViewResult = await getMemberSavedViews(list.data.activeSeason.id);
    if (savedViewResult.error) {
      if (savedViewResult.error.code === "42501") {
        throw new Error("STAFF_AUTHORIZATION_REQUIRED");
      }
      throw new Error("MEMBER_SAVED_VIEWS_QUERY_FAILED");
    }
    savedViews = savedViewResult.data;
  }

  let detail = null;
  if (query.member) {
    const { data: detailData, error: detailError } = await supabase.schema("app").rpc("get_member_detail_v3", {
      p_member_id: query.member,
    });
    if (detailError) {
      if (detailError.code === "42501") throw new Error("STAFF_AUTHORIZATION_REQUIRED");
      if (detailError.code !== "P0002") throw new Error("MEMBER_DETAIL_QUERY_FAILED");
    } else {
      const parsedDetail = memberDetailResponseSchema.safeParse(detailData);
      if (!parsedDetail.success) throw new Error("MEMBER_DETAIL_RESPONSE_INVALID");
      detail = parsedDetail.data;
    }
  }

  return { list: list.data, detail, query, savedViews, staff };
}
