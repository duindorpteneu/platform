import { createHash, randomBytes } from "node:crypto";
import { describe, expect, it } from "vitest";
import {
  decryptImportPayload,
  encryptImportPayload,
  importStagingKeyFingerprint,
} from "@/server/imports/staging-crypto";

describe("versleutelde importstaging", () => {
  it("versleutelt met een batchgebonden HKDF-sleutel en verifieert checksum", () => {
    const key = randomBytes(32).toString("base64url");
    const batchId = "10000000-0000-4000-8000-000000000001";
    const plaintext = new TextEncoder().encode("Relatienummer;Voornaam\nDSV-1;Noa");
    const checksum = createHash("sha256").update(plaintext).digest("hex");
    const encrypted = encryptImportPayload(plaintext, key, batchId, checksum);
    expect(encrypted.ciphertext).not.toContain("Relatienummer");
    expect(encrypted.nonce).toHaveLength(16);
    expect(encrypted.keyFingerprint).toBe(importStagingKeyFingerprint(key));
    expect(encrypted.keyFingerprint).toMatch(/^[0-9a-f]{64}$/);
    expect(decryptImportPayload(
      encrypted,
      key,
      batchId,
      checksum,
    )).toEqual(plaintext);
  });

  it("weigert een andere batch, checksum, sleutel of gewijzigde ciphertext", () => {
    const key = randomBytes(32).toString("base64url");
    const plaintext = new TextEncoder().encode("A,B\n1,2");
    const checksum = createHash("sha256").update(plaintext).digest("hex");
    const encrypted = encryptImportPayload(
      plaintext,
      key,
      "10000000-0000-4000-8000-000000000001",
      checksum,
    );
    expect(() => decryptImportPayload(
      encrypted,
      key,
      "10000000-0000-4000-8000-000000000002",
      checksum,
    )).toThrow("IMPORT_STAGING_DECRYPTION_FAILED");
    expect(() => decryptImportPayload(
      { ...encrypted, keyFingerprint: "0".repeat(64) },
      key,
      "10000000-0000-4000-8000-000000000001",
      checksum,
    )).toThrow("IMPORT_STAGING_KEY_FINGERPRINT_MISMATCH");
    expect(() => decryptImportPayload(
      encrypted,
      randomBytes(32).toString("base64url"),
      "10000000-0000-4000-8000-000000000001",
      checksum,
    )).toThrow("IMPORT_STAGING_KEY_FINGERPRINT_MISMATCH");
    expect(() => decryptImportPayload(
      { ...encrypted, ciphertext: `${encrypted.ciphertext.slice(0, -1)}A` },
      key,
      "10000000-0000-4000-8000-000000000001",
      checksum,
    )).toThrow("IMPORT_STAGING_DECRYPTION_FAILED");
  });

  it("weigert onbekende keyversies en niet-canonieke base64", () => {
    const key = randomBytes(32).toString("base64url");
    const plaintext = new TextEncoder().encode("A,B\n1,2");
    const checksum = createHash("sha256").update(plaintext).digest("hex");
    const encrypted = encryptImportPayload(
      plaintext,
      key,
      "10000000-0000-4000-8000-000000000001",
      checksum,
    );
    expect(() => decryptImportPayload(
      { ...encrypted, keyVersion: 2 },
      key,
      "10000000-0000-4000-8000-000000000001",
      checksum,
    )).toThrow("IMPORT_STAGING_KEY_VERSION_UNSUPPORTED");
    expect(() => decryptImportPayload(
      { ...encrypted, nonce: `${encrypted.nonce}=` },
      key,
      "10000000-0000-4000-8000-000000000001",
      checksum,
    )).toThrow("IMPORT_STAGING_PAYLOAD_INVALID");
  });

  it("accepteert alleen de canonieke 43-teken base64url-rootkey", () => {
    const plaintext = new TextEncoder().encode("A,B\n1,2");
    const checksum = createHash("sha256").update(plaintext).digest("hex");
    expect(() => encryptImportPayload(
      plaintext,
      Buffer.alloc(32).toString("base64"),
      "10000000-0000-4000-8000-000000000001",
      checksum,
    )).toThrow("IMPORT_STAGING_KEY_INVALID");
  });
});
