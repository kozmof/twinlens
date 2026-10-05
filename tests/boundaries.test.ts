import { expect, it } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { createObservationDocument } from "../packages/typescript/src/index.js";
import { createSpecificationDocument } from "../packages/typespec/src/index.js";
import { validateDocument } from "../packages/transport/src/index.js";

it("keeps both frontend package entry points compatible with the shared transport", () => {
  for (const doc of [createObservationDocument("r1"), createSpecificationDocument("r1")]) {
    expect(() => validateDocument(doc)).not.toThrow();
  }
});
it("keeps package dependencies directed toward transport", () => {
  for (const name of ["transport", "typescript", "typespec", "solver"]) {
    const pkg = JSON.parse(readFileSync(`packages/${name}/package.json`, "utf8"));
    const internal = Object.keys(pkg.dependencies ?? {}).filter((key) =>
      key.startsWith("@twinlens/"),
    );
    expect(internal).toEqual(name === "transport" ? [] : ["@twinlens/transport"]);
  }
});
it("keeps source-language packages out of Zig semantic core imports", () => {
  for (const entry of readdirSync("src/core", { recursive: true })) {
    if (!entry.endsWith(".zig")) continue;
    const source = readFileSync(join("src/core", entry), "utf8");
    for (const match of source.matchAll(/@import\("([^"]+)"\)/gu)) {
      expect(match[1] === "std" || /^[a-z_]+\.zig$/u.test(match[1])).toBe(true);
    }
  }
});
