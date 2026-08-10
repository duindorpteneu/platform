import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ preview: vi.fn() }));
vi.mock("@/server/email/mail-v2-workspace", () => ({
  previewMailV2Template: mocks.preview,
}));

import { POST } from "./route";

function request(body: unknown) {
  return new Request("https://tenue.example/api/email/v2/templates/preview", {
    method: "POST",
    headers: {
      origin: "https://tenue.example",
      host: "tenue.example",
      "sec-fetch-site": "same-origin",
      "x-duindorp-csrf": "same-origin",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

const body = {
  templateKey: "package_complete",
  internalName: "Pakket compleet",
  subjectSource: "Pakket compleet voor {{member_first_name}}",
  preheaderSource: "Alle pakketregels zijn afgehaald.",
  bodyTipTap: {
    type: "doc",
    content: [{ type: "protectedBlock", attrs: { kind: "full_package" } }],
  },
};

describe("POST /api/email/v2/templates/preview", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    mocks.preview.mockReset().mockResolvedValue({
      subject: "Pakket compleet voor Sophie",
      preheader: "Alle pakketregels zijn afgehaald.",
      html: "<p>Veilige preview</p>",
      text: "Veilige preview",
    });
  });

  it("rendert alleen met fictieve serverdata", async () => {
    const response = await POST(request(body));
    expect(response.status).toBe(200);
    expect(mocks.preview).toHaveBeenCalledWith(body, "https://tenue.example");
    expect(await response.json()).toEqual({
      subject: "Pakket compleet voor Sophie",
      preheader: "Alle pakketregels zijn afgehaald.",
      html: "<p>Veilige preview</p>",
      text: "Veilige preview",
    });
  });

  it("geeft rolweigering als generieke 403 terug", async () => {
    mocks.preview.mockRejectedValueOnce(new Error("STAFF_AUTHORIZATION_REQUIRED"));
    const response = await POST(request(body));
    expect(response.status).toBe(403);
  });
});
