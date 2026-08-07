import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const installer = readFileSync(
  new URL("./install-supabase-cli.sh", import.meta.url),
  "utf8",
);

describe("pinned Supabase CLI installer", () => {
  it("downloads only a pinned HTTPS release and verifies before extraction", () => {
    const download = installer.indexOf("curl --fail");
    const verify = installer.indexOf("sha256sum --check --status");
    const extract = installer.indexOf("tar --extract");
    expect(installer).toContain('readonly version="2.109.1"');
    expect(installer).toContain(
      'readonly archive_sha256="36d87b7fe6b4bcfe89ac47a4354e526cff22480224de426d7b370f6934556976"',
    );
    expect(installer).toContain("--proto '=https' --tlsv1.2");
    expect(verify).toBeGreaterThan(download);
    expect(extract).toBeGreaterThan(verify);
    expect(installer).not.toContain("curl |");
    expect(installer).not.toContain("sudo");
    expect(installer).toContain("supabase supabase-go");
    expect(installer).toContain("for binary in supabase supabase-go");
    expect(installer).toContain(
      "SUPABASE_CLI_BINARY_OVERRIDE=%s",
    );
    expect(installer).toContain('>> "${GITHUB_ENV}"');
  });
});
