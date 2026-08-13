import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

const repositoryRoot = path.resolve(import.meta.dirname, "../..");
const boundary = readFileSync(
  path.join(repositoryRoot, "scripts/deploy/assert-runner-boundary.sh"),
  "utf8",
);
const file = (relativePath: string) => readFileSync(
  path.join(repositoryRoot, relativePath),
  "utf8",
);

describe("self-hosted runner isolation contract", () => {
  it("binds staging and production to distinct immutable identities", () => {
    for (const value of [
      "duindorp-staging-01",
      "duindorp-production-01",
      "duindorp-staging",
      "duindorp-production",
      "/home/duindorp-staging",
      "/home/duindorp-production",
      "duindorpteneu-staging",
      "duindorpteneu-production",
    ]) expect(boundary).toContain(value);
    expect(boundary).toContain('"${GITHUB_REPOSITORY:-}" == "duindorpteneu/platform"');
    expect(boundary).toContain('$(id -un)');
    expect(boundary).toContain("Rootless Docker-socket");
    expect(boundary).toContain('[[ "${socket_mode}" == 600 ]]');
    expect(boundary).not.toContain(
      '"${socket_mode}" == 600 || "${socket_mode}" == 660',
    );
    expect(boundary).toContain("{{.DockerRootDir}}");
    expect(boundary).toContain("Peer-runtimeboom");
    expect(boundary).toContain("/etc/duindorpteneu-runners/");
  });

  it("makes every mutating shell entrypoint reassert the same boundary", () => {
    for (const [relativePath, environment] of [
      ["scripts/deploy-vps.sh", '"$environment"'],
      ["scripts/staging/cleanup-operational-data.sh", "staging"],
      ["scripts/staging/application-rollback-drill.sh", "staging"],
    ]) {
      const source = file(relativePath);
      expect(source).toContain("source scripts/deploy/assert-runner-boundary.sh");
      expect(source).toContain(`assert_runner_boundary ${environment}`);
      expect(source).not.toContain('"${USER:-}" == "deploy"');
      expect(source).not.toContain('"${USER:-}" == deploy');
    }
  });

  it("checks the boundary in every self-hosted workflow before secret-backed operations", () => {
    for (const relativePath of [
      ".github/workflows/deploy.yml",
      ".github/workflows/promote-production.yml",
      ".github/workflows/staging-domain-cleanup.yml",
      ".github/workflows/staging-operations.yml",
      ".github/workflows/staging-rollback-drill.yml",
    ]) {
      const source = file(relativePath);
      expect(source).toContain("- deploy");
      const boundaryIndex = source.indexOf(
        "bash scripts/deploy/assert-runner-boundary.sh",
      );
      expect(boundaryIndex).toBeGreaterThan(0);
      const secretIndex = source.indexOf("secrets.", boundaryIndex);
      if (secretIndex >= 0) expect(boundaryIndex).toBeLessThan(secretIndex);
    }
  });

  it("installs pinned Node after the boundary and before staging runner scripts", () => {
    for (const [relativePath, protectedCommand] of [
      [
        ".github/workflows/staging-operations.yml",
        "node scripts/deploy/check-http.mjs",
      ],
      [
        ".github/workflows/staging-rollback-drill.yml",
        "run: bash scripts/staging/application-rollback-drill.sh",
      ],
    ]) {
      const source = file(relativePath);
      const boundaryIndex = source.indexOf(
        "bash scripts/deploy/assert-runner-boundary.sh staging",
      );
      const nodeIndex = source.indexOf(
        "actions/setup-node@820762786026740c76f36085b0efc47a31fe5020",
      );
      const commandIndex = source.indexOf(protectedCommand);
      expect(boundaryIndex).toBeGreaterThan(0);
      expect(nodeIndex).toBeGreaterThan(boundaryIndex);
      expect(commandIndex).toBeGreaterThan(nodeIndex);
      expect(source).toContain("node-version: 22");
    }
  });
});
