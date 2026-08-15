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

  it("verifies production state before and after without runtime or database mutation", () => {
    expect(source).toContain("state_before=");
    expect(source).toContain("state_after=");
    expect(source).toContain('[[ "${state_after}" == "${state_before}" ]]');
    expect(source).toContain("container_image_id=");
    expect(source).toContain('capture_source="running_container"');
    expect(source).toContain('capture_source="local_manifest_image"');
    expect(source).toContain(
      'app_container_output="$(',
    );
    expect(source).toContain(
      ')" || die "Productionappcontainerinventaris kon niet worden gelezen."',
    );
    expect(source).toContain(
      'current_app_container_output="$(',
    );
    expect(source).not.toContain(
      "mapfile -t app_containers < <(",
    );
    expect(source).toContain(
      'LEGACY_CAPTURE_SOURCE="${capture_source}"',
    );
    expect(source).toContain(
      '"${loaded_digest}" == "${config_digest}"',
    );
    expect(source).toContain(
      '[[ "${container_image_id}" == "${loaded_digest}" ]]',
    );
    expect(source).toContain('exec 9<>"${runtime_directory}/.deploy.lock"');
    expect(source).not.toContain(
      'exec 9>"${runtime_directory}/.deploy.lock"',
    );
    expect(source.match(/check-legacy-http\.mjs/gu)).toHaveLength(4);
    expect(source.match(/http:\/\/127\.0\.0\.1:24000/gu))
      .toHaveLength(2);
    expect(source).not.toMatch(/\bsupabase db push\b/u);
    expect(source).not.toMatch(/\bdocker compose\b[^\n]*\bup\b/u);
    expect(source).not.toMatch(
      /\bdocker (?:build|pull|load|tag|run|create|start|stop|restart|rm|prune)\b/u,
    );
    expect(source).not.toMatch(
      /\b(?:cp|tar|gzip)\b[^\n]*\.env\.runtime/u,
    );
  });

  it("revalidates OCI and config blobs instead of rebuilding the release", () => {
    expect(source).toContain("docker save");
    expect(source).toContain("archive_manifest_digest");
    expect(source).toContain("archive_config_path");
    expect(source).toContain("image_release_label");
    expect(source).toContain(
      '[[ "${archive_manifest_digest}" == "${image_digest}" ]]',
    );
    expect(source).not.toContain("docker build");
  });
});
