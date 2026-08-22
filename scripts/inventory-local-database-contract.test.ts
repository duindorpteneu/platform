import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

const repositoryRoot = path.resolve(import.meta.dirname, "..");
const exactLocalDatabase =
  "postgresql://postgres:postgres@127.0.0.1:54339/postgres";

describe("destructieve voorraad-databasetests", () => {
  it.each([
    "test-inventory-concurrency.sh",
    "test-inventory-queue-upgrade.sh",
  ])("bindt %s uitsluitend aan de lokale projectdatabase", (fileName) => {
    const script = readFileSync(
      path.join(repositoryRoot, "scripts", fileName),
      "utf8",
    );

    expect(script).toContain(`database_url="${exactLocalDatabase}"`);
    expect(script).not.toMatch(/database_url=.*\$\{DATABASE_URL/u);
    expect(script).toContain('current_database(),current_user,inet_server_port()');
    expect(script).toContain('"postgres|postgres|5432"');
  });
});
