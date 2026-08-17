import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const installer = readFileSync(
  new URL("./install-github-cli.sh", import.meta.url),
  "utf8",
);

describe("pinned GitHub CLI installer", () => {
  it("downloads only the pinned HTTPS archive and verifies it before extraction", () => {
    const download = installer.indexOf("curl --fail");
    const verify = installer.indexOf("sha256sum --check --status");
    const extract = installer.indexOf("tar --extract");

    expect(installer).toContain('readonly version="2.97.0"');
    expect(installer).toContain(
      'readonly archive_sha256="a2c9b8497e1f85b1ad0dfcb78b5a622e098801b8e461e459e88e1ee12f018112"',
    );
    expect(installer).toContain(
      'https://github.com/cli/cli/releases/download/v${version}/${archive_name}',
    );
    expect(installer).toContain("--proto '=https' --tlsv1.2");
    expect(verify).toBeGreaterThan(download);
    expect(extract).toBeGreaterThan(verify);
    expect(installer).not.toContain("curl |");
    expect(installer).not.toContain("sudo");
    expect(installer).toContain('>> "${GITHUB_PATH}"');
  });
});
