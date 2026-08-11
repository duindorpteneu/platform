import { describe, expect, it } from "vitest";
import {
  classifyPostgrestProbeError,
  createPostgrestHttpError,
  PostgrestProbeError,
  safeRemoteCode,
} from "./postgrest-diagnostics.mjs";

describe("PostgREST deploydiagnostiek", () => {
  it.each([
    ["AbortError", undefined, "REQUEST_TIMEOUT"],
    ["Error", "UND_ERR_CONNECT_TIMEOUT", "REQUEST_TIMEOUT"],
    ["Error", "ENOTFOUND", "REQUEST_DNS_FAILED"],
    ["Error", "ERR_TLS_CERT_ALTNAME_INVALID", "REQUEST_TLS_FAILED"],
    ["Error", "ECONNRESET", "REQUEST_CONNECT_FAILED"],
  ])("classificeert %s/%s zonder foutdetails te loggen", (name, code, expected) => {
    const cause = Object.assign(new Error("NIET_LOGGEN"), { code, name });
    const error = new TypeError("fetch failed", { cause });
    expect(classifyPostgrestProbeError(error)).toBe(expected);
  });

  it("doorzoekt geneste en geaggregeerde oorzaken met vaste prioriteit", () => {
    const aggregate = new AggregateError([
      Object.assign(new Error("connect"), { code: "ECONNREFUSED" }),
      Object.assign(new Error("dns"), { code: "EAI_AGAIN" }),
      Object.assign(new Error("timeout"), { code: "ETIMEDOUT" }),
    ]);
    expect(classifyPostgrestProbeError(new Error("outer", { cause: aggregate })))
      .toBe("REQUEST_TIMEOUT");
  });

  it.each([404, 429, 502])("behoudt veilige HTTP-status %s en bekende remote code", (status) => {
    const error = createPostgrestHttpError("DELIVERY_NOTIFICATION_CONFIRM", status, "PGRST202");
    expect(classifyPostgrestProbeError(error))
      .toBe(`HTTP_DELIVERY_NOTIFICATION_CONFIRM_${status}_PGRST202`);
  });

  it("behoudt uitsluitend expliciet vertrouwde interne probecodes", () => {
    expect(classifyPostgrestProbeError(new PostgrestProbeError("RESPONSE_INVALID")))
      .toBe("RESPONSE_INVALID");
    expect(() => new PostgrestProbeError("SECRET_MARKER"))
      .toThrow("POSTGREST_PROBE_CODE_INVALID");
    expect(classifyPostgrestProbeError(new Error("SECRET_MARKER"))).toBe("REQUEST_FAILED");
  });

  it("laat alleen bekende, niet-persoonlijke PostgREST-codes door", () => {
    expect(safeRemoteCode("PGRST106")).toBe("PGRST106");
    expect(safeRemoteCode("PGRST202")).toBe("PGRST202");
    expect(safeRemoteCode("42501")).toBe("42501");
    expect(safeRemoteCode("SECRET_MARKER")).toBe("UNKNOWN");
  });
});
