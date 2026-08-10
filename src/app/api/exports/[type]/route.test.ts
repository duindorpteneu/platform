import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  getExportPayload: vi.fn(),
}));

vi.mock("@/server/exports/workspace", () => ({
  getExportPayload: mocks.getExportPayload,
}));

import { GET } from "./route";

const seasonId = "10000000-0000-4000-8000-000000000001";

function request(type: string) {
  return new Request(
    `https://tenue.example/api/exports/${type}?format=csv&seasonId=${seasonId}&filter=all`,
  );
}

describe("GET /api/exports/[type]", () => {
  beforeEach(() => {
    mocks.getExportPayload.mockReset().mockResolvedValue({
      type: "package_orders",
      seasonName: "2026 / 2027",
      generatedAt: "2026-08-03T12:00:00.000Z",
      columns: [{ key: "packageName", label: "Pakket" }],
      rows: [{ packageName: "=Onveilige formule" }],
    });
  });

  it("levert first-class pakketorders via het bestaande veilige downloadcontract", async () => {
    const response = await GET(request("package_orders"), {
      params: Promise.resolve({ type: "package_orders" }),
    });

    expect(response.status).toBe(200);
    expect(mocks.getExportPayload).toHaveBeenCalledWith(
      "package_orders",
      seasonId,
      "all",
    );
    expect(response.headers.get("cache-control")).toBe("private, no-store");
    expect(response.headers.get("content-disposition")).toContain(
      "duindorp-sv-pakketorders-2026-2027-2026-08-03.csv",
    );
    expect(await response.text()).toContain("'=Onveilige formule");
  });

  it("weigert onbekende exporttypen voordat de database wordt bevraagd", async () => {
    const response = await GET(request("package_secrets"), {
      params: Promise.resolve({ type: "package_secrets" }),
    });

    expect(response.status).toBe(400);
    expect(mocks.getExportPayload).not.toHaveBeenCalled();
  });

  it("weigert een export zonder expliciet seizoen", async () => {
    const response = await GET(new Request(
      "https://tenue.example/api/exports/package_orders?format=csv&filter=all",
    ), {
      params: Promise.resolve({ type: "package_orders" }),
    });

    expect(response.status).toBe(400);
    expect(mocks.getExportPayload).not.toHaveBeenCalled();
  });
});
