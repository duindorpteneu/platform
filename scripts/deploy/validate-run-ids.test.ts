import { describe, expect, it } from "vitest";
// @ts-expect-error Plain Node.js workflow helper without declaration file.
import { RUN_ID_VARIABLES, validateRunIds } from "./validate-run-ids.mjs";

const runIdVariables = RUN_ID_VARIABLES as string[];
const values = Object.fromEntries(
  runIdVariables.map((name, index) => [name, String(index + 101)]),
);

describe("promotion workflow run IDs", () => {
  it("accepts eight distinct positive safe integers", () => {
    expect(validateRunIds(values)).toEqual(Object.fromEntries(
      runIdVariables.map((name, index) => [name, index + 101]),
    ));
  });

  it.each(["", "0", "-1", "1.5", "01", "1e3", "abc", "9007199254740992"])(
    "rejects unsafe run ID %j before artifact download",
    (candidate) => {
      expect(() => validateRunIds({
        ...values,
        CORE_ACCEPTANCE_RUN_ID: candidate,
      })).toThrow();
    },
  );

  it("rejects reuse of one workflow run for two independent gates", () => {
    expect(() => validateRunIds({
      ...values,
      CORE_ACCEPTANCE_RUN_ID: values.STAGING_DEPLOY_RUN_ID,
    })).toThrow("eigen workflow-run-ID");
  });
});
