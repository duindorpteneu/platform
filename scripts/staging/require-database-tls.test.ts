import { describe, expect, it } from "vitest";
// @ts-expect-error The workflow entrypoint is intentionally plain Node.js ESM.
import { requireExplicitDatabaseTls } from "./require-database-tls.mjs";

describe("requireExplicitDatabaseTls", () => {
  it("voegt een ontbrekende afdwingende TLS-modus toe zonder overige queryparameters te verliezen", () => {
    const result = new URL(requireExplicitDatabaseTls(
      "postgresql://postgres:secret@db.example.invalid:5432/postgres?connect_timeout=10",
    ));

    expect(result.searchParams.get("sslmode")).toBe("require");
    expect(result.searchParams.get("connect_timeout")).toBe("10");
  });

  it.each(["require", "verify-ca", "verify-full"])(
    "behoudt de bestaande veilige TLS-modus %s",
    (sslmode) => {
      const source = `postgresql://postgres:secret@db.example.invalid:5432/postgres?sslmode=${sslmode}`;
      expect(requireExplicitDatabaseTls(source)).toBe(source);
    },
  );

  it.each(["disable", "allow", "prefer", "invalid"])(
    "weigert de niet-afdwingende TLS-modus %s",
    (sslmode) => {
      expect(() => requireExplicitDatabaseTls(
        `postgresql://postgres:secret@db.example.invalid:5432/postgres?sslmode=${sslmode}`,
      )).toThrow("geen afdwingende TLS-modus");
    },
  );

  it("weigert dubbele TLS-modi en niet-PostgreSQL-URL's", () => {
    expect(() => requireExplicitDatabaseTls(
      "postgresql://postgres:secret@db.example.invalid/postgres?sslmode=require&sslmode=disable",
    )).toThrow("dubbele databaseparameter");
    expect(() => requireExplicitDatabaseTls("https://example.invalid/postgres"))
      .toThrow("PostgreSQL-protocol");
  });

  it.each([
    "host=db.production.invalid",
    "host=%2Ftmp",
    "hostaddr=203.0.113.10",
    "port=6543",
    "dbname=other",
    "user=other",
    "password=other",
    "service=other",
    "servicefile=%2Ftmp%2Fpg_service.conf",
    "options=-csearch_path%3Dpublic",
  ])("weigert libpq-doel-, credential- en serviceoverride %s", (parameter) => {
    expect(() => requireExplicitDatabaseTls(
      `postgresql://postgres:secret@db.example.invalid:5432/postgres?${parameter}`,
    )).toThrow("niet-toegestane databaseparameter");
  });

  it.each(["0", "121", "abc", "1&connect_timeout=2"])(
    "weigert onveilige of dubbele connect_timeout %s",
    (value) => {
      const expected = value.includes("&")
        ? "dubbele databaseparameter"
        : "ongeldige connectietimeout";
      expect(() => requireExplicitDatabaseTls(
        `postgresql://postgres:secret@db.example.invalid:5432/postgres?connect_timeout=${value}`,
      )).toThrow(expected);
    },
  );

  it.each([
    "evil.invalid,aws-0-eu-central-1.pooler.supabase.com",
    "evil.invalid%2Caws-0-eu-central-1.pooler.supabase.com",
  ])("weigert de libpq multi-host %s", (hostname) => {
    expect(() => requireExplicitDatabaseTls(
      `postgresql://postgres.projectref:secret@${hostname}:5432/postgres`,
    )).toThrow("geen enkele geldige DNS-host");
  });
});
