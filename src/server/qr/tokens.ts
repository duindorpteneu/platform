import { createHash, createHmac, randomBytes } from "node:crypto";
import { z } from "zod";
import { getServerEnv } from "@/lib/env";
import {
  QR_LOCATOR_PATTERN,
  QR_SCAN_GRANT_PATTERN,
} from "@/lib/qr-payload";

const qrLocatorSchema = z.string().regex(QR_LOCATOR_PATTERN);
const qrScanGrantSchema = z.string().regex(QR_SCAN_GRANT_PATTERN);
const qrNonceSchema = z.string().regex(/^[A-Za-z0-9_-]{43}$/);
const uuid = z.string().uuid();

export const fulfilmentExchangeRequestSchema = z.object({
  locator: qrLocatorSchema,
  requestId: uuid,
}).strict();

export const fulfilmentCommitRequestSchema = z.object({
  orderLineIds: z.array(uuid).min(1).max(25),
  requestId: uuid,
  scanGrant: qrScanGrantSchema,
}).strict().superRefine((value, context) => {
  if (new Set(value.orderLineIds).size !== value.orderLineIds.length) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      message: "Een artikelregel mag maar één keer worden uitgegeven.",
      path: ["orderLineIds"],
    });
  }
});

function qrPepperForVersion(version: number) {
  const env = getServerEnv();
  if (
    version === env.QR_TOKEN_PEPPER_VERSION
    && env.QR_TOKEN_PEPPER
  ) {
    return Buffer.from(env.QR_TOKEN_PEPPER, "base64url");
  }
  if (
    version === env.QR_TOKEN_PREVIOUS_PEPPER_VERSION
    && env.QR_TOKEN_PREVIOUS_PEPPER
  ) {
    return Buffer.from(env.QR_TOKEN_PREVIOUS_PEPPER, "base64url");
  }
  throw new Error("QR_TOKEN_KEY_VERSION_UNAVAILABLE");
}

function versionFromToken(value: string, prefix: "q2" | "sg2") {
  const match = new RegExp(`^${prefix}\\.k([1-9]\\d{0,3})\\.`).exec(value);
  if (!match) throw new Error("QR_TOKEN_VERSION_INVALID");
  return Number(match[1]);
}

export function qrKeyVersion() {
  return getServerEnv().QR_TOKEN_PEPPER_VERSION;
}

export function qrPepperFingerprint(version = qrKeyVersion()) {
  return createHash("sha256")
    .update("duindorp-qr-pepper:v2:", "utf8")
    .update(qrPepperForVersion(version))
    .digest("hex");
}

export function qrAcceptedKeyMetadata() {
  const env = getServerEnv();
  return {
    current: {
      fingerprint: qrPepperFingerprint(env.QR_TOKEN_PEPPER_VERSION),
      version: env.QR_TOKEN_PEPPER_VERSION,
    },
    previous: env.QR_TOKEN_PREVIOUS_PEPPER
      && env.QR_TOKEN_PREVIOUS_PEPPER_VERSION
      ? {
          fingerprint: qrPepperFingerprint(
            env.QR_TOKEN_PREVIOUS_PEPPER_VERSION,
          ),
          version: env.QR_TOKEN_PREVIOUS_PEPPER_VERSION,
        }
      : null,
  };
}

export function generateQrDerivationNonce() {
  return randomBytes(32).toString("base64url");
}

export function deriveQrLocator(input: {
  generation: number;
  keyVersion: number;
  nonce: string;
  orderId: string;
}) {
  const nonce = qrNonceSchema.parse(input.nonce);
  const opaque = createHmac(
    "sha256",
    qrPepperForVersion(input.keyVersion),
  )
    .update(
      [
        "duindorp-qr-locator:v2",
        `k${input.keyVersion}`,
        input.orderId,
        input.generation,
        nonce,
      ].join(":"),
      "utf8",
    )
    .digest("base64url");
  return `q2.k${input.keyVersion}.${opaque}`;
}

export function hashQrLocator(locator: string) {
  const parsed = qrLocatorSchema.parse(locator);
  const version = versionFromToken(parsed, "q2");
  return createHmac("sha256", qrPepperForVersion(version))
    .update(`duindorp-qr-lookup:v2:${parsed}`, "utf8")
    .digest("hex");
}

export function deriveQrScanGrant(input: {
  actorId: string;
  locator: string;
  requestId: string;
  staffSessionHash: string;
}) {
  const keyVersion = qrKeyVersion();
  const opaque = createHmac("sha256", qrPepperForVersion(keyVersion))
    .update(
      [
        "duindorp-qr-scan-grant:v2",
        input.actorId,
        input.staffSessionHash,
        input.requestId,
        input.locator,
      ].join(":"),
      "utf8",
    )
    .digest("base64url");
  return `sg2.k${keyVersion}.${opaque}`;
}

export function hashQrScanGrant(grant: string) {
  const parsed = qrScanGrantSchema.parse(grant);
  const version = versionFromToken(parsed, "sg2");
  return createHmac("sha256", qrPepperForVersion(version))
    .update(`duindorp-qr-scan-grant-lookup:v2:${parsed}`, "utf8")
    .digest("hex");
}

export function buildQrFragmentUrl(baseUrl: string, locator: string) {
  const parsed = qrLocatorSchema.parse(locator);
  const url = new URL("/qr", baseUrl);
  url.hash = parsed;
  return url.toString();
}
