import { describe, expect, it, vi } from "vitest";
import { finishOperationRun, startOperationRun } from "./run-ledger";

const runId = "71000000-0000-4000-8000-000000000001";

function adminWith(rpc: ReturnType<typeof vi.fn>) {
  return { schema: () => ({ rpc }) } as never;
}

describe("operation runledger boundary", () => {
  it("accepts only the expected start identity", async () => {
    const rpc = vi.fn().mockResolvedValue({
      data: { runId, operation: "email_worker", startedAt: "2026-07-21T10:00:00.000Z" },
      error: null,
    });
    await expect(startOperationRun(adminWith(rpc), "email_worker", runId)).resolves.toBe(true);
    expect(rpc).toHaveBeenCalledWith("start_operation_run", { p_operation: "email_worker", p_run_id: runId });
    rpc.mockResolvedValueOnce({ data: { runId, operation: "retention", startedAt: "2026-07-21T10:00:00.000Z" }, error: null });
    await expect(startOperationRun(adminWith(rpc), "email_worker", runId)).resolves.toBe(false);
  });

  it("rejects malformed or mismatched completion responses", async () => {
    const rpc = vi.fn().mockResolvedValue({
      data: { runId, operation: "retention", status: "succeeded", finishedAt: "2026-07-21T10:00:01.000Z" },
      error: null,
    });
    await expect(finishOperationRun(adminWith(rpc), "retention", runId, "succeeded", 4)).resolves.toBe(true);
    rpc.mockResolvedValueOnce({ data: { status: "succeeded" }, error: null });
    await expect(finishOperationRun(adminWith(rpc), "retention", runId, "succeeded", 4)).resolves.toBe(false);
  });
});
