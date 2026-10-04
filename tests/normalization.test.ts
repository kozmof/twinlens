import { expect, it } from "vitest";
import { resolve, isAbsolute, sep } from "node:path";
import { normalizeOptionValue, relativePath } from "../packages/typescript/src/project.js";

it("preserves option normalization while separating it from key filtering", () => {
  const root = resolve("/project");
  function previous(value: unknown) {
    if (typeof value === "string" && isAbsolute(value))
      return resolve(value) === root
        ? "."
        : (relativePath(root, value) ?? "<external>/" + value.split(sep).slice(-2).join("/"));
    return value;
  }
  const object = { enabled: true };
  for (const value of [
    null,
    undefined,
    0,
    false,
    "relative/path",
    root,
    resolve(root, "src/file.ts"),
    resolve("/external/lib/file.ts"),
    object,
    ["keep"],
  ]) {
    expect(normalizeOptionValue(root, value)).toBe(previous(value));
  }
  const options = {
    configFile: object,
    rootDir: root,
    outDir: resolve(root, "dist"),
    unknown: object,
  };
  expect(
    JSON.stringify(options, (key, value) =>
      key === "configFile" ? undefined : normalizeOptionValue(root, value),
    ),
  ).toBe(
    JSON.stringify(options, (key, value) => (key === "configFile" ? undefined : previous(value))),
  );
});
