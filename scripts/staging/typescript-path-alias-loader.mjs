import { access } from "node:fs/promises";
import { register } from "node:module";
import { extname, resolve as resolvePath, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { isMainThread } from "node:worker_threads";

const sourceRoot = resolvePath(fileURLToPath(
  new URL("../../src/", import.meta.url),
));
const aliasPrefix = "@/";

if (isMainThread) register(import.meta.url);

async function existingSourcePath(relativePath) {
  const unresolved = resolvePath(sourceRoot, relativePath);
  if (unresolved !== sourceRoot && !unresolved.startsWith(`${sourceRoot}${sep}`)) {
    throw new Error("STAGING_TYPESCRIPT_ALIAS_INVALID");
  }
  const candidates = extname(unresolved)
    ? [unresolved]
    : [
        `${unresolved}.ts`,
        `${unresolved}.tsx`,
        `${unresolved}.js`,
        `${unresolved}.mjs`,
        resolvePath(unresolved, "index.ts"),
        resolvePath(unresolved, "index.tsx"),
      ];
  for (const candidate of candidates) {
    try {
      await access(candidate);
      return candidate;
    } catch {
      // Try the next TypeScript/JavaScript resolution candidate.
    }
  }
  throw new Error("STAGING_TYPESCRIPT_ALIAS_NOT_FOUND");
}

export async function resolve(specifier, context, nextResolve) {
  if (!specifier.startsWith(aliasPrefix)) {
    return nextResolve(specifier, context);
  }
  const sourcePath = await existingSourcePath(specifier.slice(aliasPrefix.length));
  return {
    shortCircuit: true,
    url: pathToFileURL(sourcePath).href,
  };
}
