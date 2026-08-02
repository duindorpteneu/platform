import {
  createCipheriv,
  createDecipheriv,
  createHash,
  hkdfSync,
  randomBytes,
} from "node:crypto";

const KEY_VERSION = 1;

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
    Buffer.from(`duindorp-dynamic-import:${batchId}:v${KEY_VERSION}`, "utf8"),
    32,
  ));
}

function aad(batchId: string, checksum: string) {
  return Buffer.from(`duindorp-dynamic-import:${batchId}:${checksum}:v${KEY_VERSION}`, "utf8");
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
    keyVersion: KEY_VERSION,
    keyFingerprint: importStagingKeyFingerprint(encodedRootKey),
  };
}

export function decryptImportPayload(
  ciphertextBase64: string,
  nonceBase64: string,
  encodedRootKey: string,
  batchId: string,
  expectedChecksum: string,
) {
  const ciphertext = Buffer.from(ciphertextBase64, "base64");
  const nonce = Buffer.from(nonceBase64, "base64");
  if (ciphertext.byteLength < 17 || nonce.byteLength !== 12) throw new Error("IMPORT_STAGING_PAYLOAD_INVALID");
  const encrypted = ciphertext.subarray(0, -16);
  const tag = ciphertext.subarray(-16);
  try {
    const decipher = createDecipheriv(
      "aes-256-gcm",
      derivedKey(encodedRootKey, batchId, expectedChecksum),
      nonce,
    );
    decipher.setAAD(aad(batchId, expectedChecksum));
    decipher.setAuthTag(tag);
    const plaintext = Buffer.concat([decipher.update(encrypted), decipher.final()]);
    const checksum = createHash("sha256").update(plaintext).digest("hex");
    if (checksum !== expectedChecksum) throw new Error("IMPORT_STAGING_CHECKSUM_MISMATCH");
    return new Uint8Array(plaintext);
  } catch (error) {
    if (error instanceof Error && error.message === "IMPORT_STAGING_CHECKSUM_MISMATCH") throw error;
    throw new Error("IMPORT_STAGING_DECRYPTION_FAILED");
  }
}
