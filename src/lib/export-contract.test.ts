import { describe, expect, it } from "vitest";
import { EXPORT_TYPES, exportPayloadSchema, exportWorkspaceSchema } from "@/lib/export-contract";

describe("export contract", () => {
  it("accepts only the six canonical export types", () => {
    expect(EXPORT_TYPES).toEqual(["members", "orders", "payments", "deliveries", "fulfilments", "outstanding"]);
    expect(exportPayloadSchema.safeParse({ type: "families" }).success).toBe(false);
  });

  it("rejects non-primitive row values and unknown workspace fields", () => {
    const base = { type: "members", seasonName: null, generatedAt: "2026-07-18T10:00:00+02:00", columns: [{ key: "name", label: "Naam" }] };
    expect(exportPayloadSchema.safeParse({ ...base, rows: [{ name: { unsafe: true } }] }).success).toBe(false);
    expect(exportWorkspaceSchema.safeParse({ types: EXPORT_TYPES, seasons: [], filters: Object.fromEntries(EXPORT_TYPES.map((type) => [type, []])), extra: true }).success).toBe(false);
  });
});

