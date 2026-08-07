import { pathToFileURL } from "node:url";

export const RUN_ID_VARIABLES = [
  "STAGING_DEPLOY_RUN_ID",
  "CORE_ACCEPTANCE_RUN_ID",
  "PHASE_B_ACCEPTANCE_RUN_ID",
  "MOLLIE_ACCEPTANCE_RUN_ID",
  "SENDGRID_ACCEPTANCE_RUN_ID",
  "RESTORE_ACCEPTANCE_RUN_ID",
  "ROLLBACK_ACCEPTANCE_RUN_ID",
  "OPERATIONS_ACCEPTANCE_RUN_ID",
];

export function validateRunIds(values) {
  const result = {};
  for (const name of RUN_ID_VARIABLES) {
    const value = values[name]?.trim();
    if (!value || !/^[1-9][0-9]*$/u.test(value)) {
      throw new Error(`${name} is geen geldige positieve workflow-run-ID`);
    }
    const parsed = Number(value);
    if (!Number.isSafeInteger(parsed)) {
      throw new Error(`${name} valt buiten het veilige gehele-getalbereik`);
    }
    result[name] = parsed;
  }
  if (new Set(Object.values(result)).size !== RUN_ID_VARIABLES.length) {
    throw new Error("Iedere acceptatiegate moet een eigen workflow-run-ID hebben");
  }
  return result;
}

if (
  process.argv[1]
  && import.meta.url === pathToFileURL(process.argv[1]).href
) {
  try {
    validateRunIds(process.env);
    process.stdout.write("Alle workflow-run-ID's zijn syntactisch geldig en uniek.\n");
  } catch (error) {
    process.stderr.write(
      `${error instanceof Error ? error.message : "Workflow-run-ID's zijn ongeldig"}\n`,
    );
    process.exitCode = 1;
  }
}
