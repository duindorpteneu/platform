import { timingSafeEqual } from "node:crypto";

export function hasInternalBearer(request: Request) {
  const secret = process.env.CRON_SECRET;
  const header = request.headers.get("authorization");
  if (!secret || !header?.startsWith("Bearer ")) return false;
  const provided = Buffer.from(header.slice(7), "utf8");
  const expected = Buffer.from(secret, "utf8");
  return provided.length === expected.length && timingSafeEqual(provided, expected);
}

