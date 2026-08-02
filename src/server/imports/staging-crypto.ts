import {
  createCipheriv,
  createDecipheriv,
  createHash,
  hkdfSync,
  randomBytes,
} from "node:crypto";

export const IMPORT_STAGING_KEY_VERSION = 1 as const;
const MAX_PLAINTEXT_BYTES = 10 * 1024 * 1024;
const AUTH_TAG_BYTES = 16;

function rootKey(encoded: string) {
  if (!/^[A-Za-z0-9_-]{43}$/u.test(encoded)) throw new Error("IMPORT_STAGING_KEY_INVALID");
  const decoded = Buffer.from(encoded, "base64url");
  if (decoded.byteLength !== 32 || decoded.toString("base64url") !== encoded) {
    throw new Error("IMPORT_STAGING_KEY_INVALID");
  }
  return decoded;
}

export function importStagingKeyFingerprint(encodedRootKey: string) {
  return createHash("sha256").update(rootKey(encodedRootKey)).digest("hex");
}

function derivedKey(encoded: string, batchId: string, checksum: string) {
  if (!/^[0-9a-f]{64}$/u.test(checksum)) throw new Error("IMPORT_STAGING_CHECKSUM_INVALID");
  return Buffer.from(hkdfSync(
    "sha256",
    rootKey(encoded),
    Buffer.from(checksum, "hex"),
    Buffer.from(`duindorp-dynamic-import:${batchId}:v${IMPORT_STAGING_KEY_VERSION}`, "utf8"),
    32,
  ));
}

function aad(batchId: string, checksum: string) {
  return Buffer.from(
    `duindorp-dynamic-import:${batchId}:${checksum}:v${IMPORT_STAGING_KEY_VERSION}`,
    "utf8",
  );
}

function canonicalBase64(value: string, errorCode: string) {
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u.test(value)) {
    throw new Error(errorCode);
  }
  const decoded = Buffer.from(value, "base64");
  if (decoded.toString("base64") !== value) throw new Error(errorCode);
  return decoded;
}

export function encryptImportPayload(
  bytes: Uint8Array,
  encodedRootKey: string,
  batchId: string,
  checksum: string,
) {
  const nonce = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", derivedKey(encodedRootKey, batchId, checksum), nonce);
  cipher.setAAD(aad(batchId, checksum));
  const encrypted = Buffer.concat([cipher.update(bytes), cipher.final()]);
  const ciphertext = Buffer.concat([encrypted, cipher.getAuthTag()]);
  return {
    ciphertext: ciphertext.toString("base64"),
    nonce: nonce.toString("base64"),
    keyVersion: IMPORT_STAGING_KEY_VERSION,
    keyFingerprint: importStagingKeyFingerprint(encodedRootKey),
  };
}

export function decryptImportPayload(
  encrypted: {
    ciphertext: string;
    nonce: string;
    keyVersion: number;
    keyFingerprint: string;
  },
  encodedRootKey: string,
  batchId: string,
  expectedChecksum: string,
) {
  if (encrypted.keyVersion !== IMPORT_STAGING_KEY_VERSION) {
    throw new Error("IMPORT_STAGING_KEY_VERSION_UNSUPPORTED");
  }
  const configuredFingerprint = importStagingKeyFingerprint(encodedRootKey);
  if (encrypted.keyFingerprint !== configuredFingerprint) {
    throw new Error("IMPORT_STAGING_KEY_FINGERPRINT_MISMATCH");
  }
  const ciphertext = canonicalBase64(encrypted.ciphertext, "IMPORT_STAGING_PAYLOAD_INVALID");
  const nonce = canonicalBase64(encrypted.nonce, "IMPORT_STAGING_PAYLOAD_INVALID");
  if (
    ciphertext.byteLength < AUTH_TAG_BYTES + 1
    || ciphertext.byteLength > MAX_PLAINTEXT_BYTES + AUTH_TAG_BYTES
    || nonce.byteLength !== 12
  ) {
    throw new Error("IMPORT_STAGING_PAYLOAD_INVALID");
  }
  const encryptedBytes = ciphertext.subarray(0, -16);
  const tag = ciphertext.subarray(-16);
  try {
    const decipher = createDecipheriv(
      "aes-256-gcm",
      derivedKey(encodedRootKey, batchId, expectedChecksum),
      nonce,
    );
    decipher.setAAD(aad(batchId, expectedChecksum));
    decipher.setAuthTag(tag);
    const plaintext = Buffer.concat([decipher.update(encryptedBytes), decipher.final()]);
    const checksum = createHash("sha256").update(plaintext).digest("hex");
    if (checksum !== expectedChecksum) throw new Error("IMPORT_STAGING_CHECKSUM_MISMATCH");
    return new Uint8Array(plaintext);
  } catch (error) {
    if (error instanceof Error && error.message === "IMPORT_STAGING_CHECKSUM_MISMATCH") throw error;
    throw new Error("IMPORT_STAGING_DECRYPTION_FAILED");
  }
}
