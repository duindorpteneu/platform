import { z } from "zod";

export const parentMemberLinkSchema = z.object({ memberId: z.string().uuid() }).strict();

export type ParentMember = {
  member_id: string;
  member_season_id: string;
  relation_number: string | null;
  first_name: string;
  insertion: string | null;
  last_name: string;
  date_of_birth: string | null;
  gender: "male" | "female" | "other" | "unknown";
  team: string;
  order_id: string | null;
  amount_due_cents: number | null;
  payment_status: string | null;
  order_status: string | null;
  article_lines: Array<{ id: string; article: string; size: string; quantity: number; status: string }>;
};
