import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const source = readFileSync(
  new URL("./capture-legacy-release.sh", import.meta.url),
  "utf8",
);

describe("read-only legacy production capture", () => {
  it("is hard-bound to the single known production identity", () => {
    expect(source).toContain(
      'legacy_sha="a79c8d843d75e90810ccceb228538c6368d2198b"',
    );
    expect(source).toContain(
      'assert_runner_boundary production',
    );
    expect(source).toContain(
      'PRODUCTION_BASE_URL}" == "https://duindorp.dgwebservices.nl"',
    );
  });

  it("verifies live state before and after without runtime or database mutation", () => {
    expect(source).toContain("state_before=");
    expect(source).toContain("state_after=");
    expect(source).toContain('[[ "${state_after}" == "${state_before}" ]]');
    expect(source).toContain("container_image_id=");
    expect(source).toContain(
      '[[ "${loaded_digest}" == "${config_digest}"',
    );
    expect(source).toContain(
      '&& "${container_image_id}" == "${loaded_digest}"',
    );
    expect(source).toContain('exec 9<>"${runtime_directory}/.deploy.lock"');
    expect(source).not.toContain(
      'exec 9>"${runtime_directory}/.deploy.lock"',
    );
    expect(source).toContain("check-legacy-http.mjs");
    expect(source).not.toMatch(/\bsupabase db push\b/u);
    expect(source).not.toMatch(/\bdocker compose\b[^\n]*\bup\b/u);
    expect(source).not.toMatch(
      /\b(?:cp|tar|gzip)\b[^\n]*\.env\.runtime/u,
    );
  });

  it("revalidates OCI and config blobs instead of rebuilding the release", () => {
    expect(source).toContain("docker save");
    expect(source).toContain("archive_manifest_digest");
    expect(source).toContain("archive_config_path");
    expect(source).not.toContain("docker build");
  });
});
