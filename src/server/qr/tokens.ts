import { createHash, createHmac } from "node:crypto";
import { z } from "zod";
import { getServerEnv } from "@/lib/env";
import { QR_TOKEN_PATTERN } from "@/lib/qr-payload";

const qrTokenSchema = z.string().regex(QR_TOKEN_PATTERN);

export const fulfilmentLookupRequestSchema = z.object({ token: qrTokenSchema }).strict();

export const fulfilmentCommitRequestSchema = z.object({
  orderId: z.string().uuid(),
  orderLineIds: z.array(z.string().uuid()).min(1).max(25),
  location: z.string().trim().min(1).max(160),
  token: qrTokenSchema,
}).strict().superRefine((value, context) => {
  if (new Set(value.orderLineIds).size !== value.orderLineIds.length) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: "Een artikelregel mag maar één keer worden uitgegeven.", path: ["orderLineIds"] });
  }
});

function qrPepper() {
  const value = getServerEnv().PARENT_TOKEN_PEPPER;
  if (!value) throw new Error("PARENT_TOKEN_PEPPER_MISSING");
  return value;
}

export function deriveQrBearerToken(orderId: string, version = 1) {
  const token = createHmac("sha256", qrPepper()).update(`duindorp-qr:${version}:${orderId}`).digest("base64url");
  return `v${version}.${token}`;
}

export function hashQrBearerToken(token: string) {
  return createHash("sha256").update(token, "utf8").digest("hex");
}
