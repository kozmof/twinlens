import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { scanProject } from "../packages/typescript/src/index.js";
import { validateSnapshot, type Snapshot } from "../packages/transport/src/index.js";
import { makeProject } from "./project-fixture.mjs";

const roots: string[] = [];
afterAll(() => roots.forEach((root) => rmSync(root, { recursive: true, force: true })));
const project = () => {
  const root = makeProject();
  roots.push(root);
  return root;
};
let root: string;
let snapshot: Snapshot;
beforeAll(() => {
  root = project();
  snapshot = scanProject(root, { project: "fixture" });
}, 30000);
function subject(name: string, kind = "function") {
  return snapshot.document.subjects.find((s) => s.key.name === name && s.key.kind === kind)!;
}
function metric(name: string, metric: string, kind = "function") {
  const id = subject(name, kind).id;
  return snapshot.document.observations.find((o) => o.subject === id && o.metric === metric)!
    .measurement;
}

describe("TypeScript compiler adapter", () => {
  it("produces a valid snapshot with deterministic identities and content", () => {
    validateSnapshot(snapshot);
    expect(scanProject(root, { project: "fixture" })).toEqual(snapshot);
    expect(snapshot.configuration.compiler).toBe("6.0.3");
    expect(snapshot.files.map((f) => f.path)).toEqual(["lib.ts", "main.ts"]);
    expect(snapshot.diagnostics).toEqual([]);
  });
  it("extracts overloads, arrows, methods, parameters, properties and scoped duplicate names", () => {
    expect(
      snapshot.document.subjects.filter(
        (s) => s.key.name === "target" && s.key.kind === "function",
      ),
    ).toHaveLength(3);
    expect(subject("arrow")).toBeDefined();
    expect(subject("Counter[declaration:0]/method")).toBeDefined();
    expect(
      snapshot.document.subjects.filter((s) => s.key.kind === "parameter").length,
    ).toBeGreaterThan(5);
    const values = snapshot.document.subjects.filter(
      (s) => s.key.kind === "value" && s.key.name.endsWith("/value"),
    );
    expect(values).toHaveLength(2);
    expect(new Set(values.map((s) => s.id)).size).toBe(2);
  });
  it("converts UTF-16 compiler positions to UTF-8 byte spans", () => {
    const row = subject("scan");
    const text = readFileSync(join(root, "main.ts"), "utf8");
    expect(row.source.span.start).toBe(
      Buffer.byteLength(text.slice(0, text.indexOf("export function scan"))),
    );
    expect(
      Buffer.from(text).subarray(row.source.span.start, row.source.span.end).toString(),
    ).toMatch(/^export function scan/u);
  });
  it("counts only each function own branches and reports parameter shape", () => {
    expect(metric("scan", "function.args.count").value).toBe(2);
    expect(metric("scan", "function.branch.count").value).toBe(1);
    expect(metric("scan[declaration:0]/nested", "function.branch.count").value).toBe(1);
    expect(
      metric("scan[declaration:0]/options", "function.parameter.property_count", "parameter").value,
    ).toBe(2);
    expect(
      metric("dynamic[declaration:0]/obj", "function.parameter.property_count", "parameter").status,
    ).toBe("unknown");
    const signatures = snapshot.document.subjects
      .filter((s) => s.key.name === "target" && s.key.kind === "function")
      .filter((s) => s.key.discriminator !== "declaration:2");
    expect(
      signatures.every(
        (s) =>
          snapshot.document.observations.find(
            (o) => o.subject === s.id && o.metric === "function.branch.count",
          )!.measurement.status === "unknown",
      ),
    ).toBe(true);
  });
  it("counts reads, initialization, compound writes, property writes and shadowing", () => {
    expect(metric("scan[declaration:0]/value", "value.read_count", "value").value).toBe(9);
    expect(metric("scan[declaration:0]/value", "value.write_count", "value").value).toBe(3);
    expect(
      metric("scan[declaration:0]/shadow[declaration:0]/value", "value.read_count", "value").value,
    ).toBe(1);
    expect(metric("Options[declaration:0]/count", "property.read_count", "property").value).toBe(2);
    expect(metric("Options[declaration:0]/count", "property.write_count", "property").value).toBe(
      2,
    );
    expect(snapshot.coverage.unresolved_accesses).toBeGreaterThanOrEqual(2);
  });
  it("resolves imported overload implementations, deduplicates calls and preserves callback uncertainty", () => {
    const target = snapshot.document.subjects.find(
      (s) => s.key.name === "target" && s.key.discriminator === "declaration:2",
    )!;
    const calls = snapshot.document.relations.filter((r) => r.kind === "calls");
    expect(calls.filter((r) => r.target.subject === target.id)).toHaveLength(2);
    expect(
      calls.filter(
        (r) => r.from === subject("scan").id && r.target.subject === subject("arrow").id,
      ),
    ).toHaveLength(1);
    expect(metric("scan", "function.callees").value).toBe(4);
    expect(metric("scan", "function.calls.unresolved.count").value).toBe(1);
    expect(
      calls.some((r) => r.target.status === "unresolved" && r.target.reason?.includes("callback")),
    ).toBe(true);
    expect(
      calls.some((r) => r.target.subject === subject("Counter[declaration:0]/method").id),
    ).toBe(true);
  });
  it("returns compiler diagnostics separately while retaining available observations", () => {
    const local = project();
    writeFileSync(
      join(local, "broken.ts"),
      'export const wrong: number = "text";\nexport function malformed( {',
    );
    const result = scanProject(local, { project: "broken" });
    expect(result.diagnostics.some((d) => d.category === "error")).toBe(true);
    expect(result.document.observations.length).toBeGreaterThan(0);
    expect(result.document).not.toHaveProperty("findings");
    validateSnapshot(result);
  });
  it("loads project references and extended configs with stable cross-program mappings", () => {
    const local = project();
    mkdirSync(join(local, "child"));
    writeFileSync(
      join(local, "tsconfig.json"),
      JSON.stringify({ files: [], references: [{ path: "child" }] }),
    );
    writeFileSync(
      join(local, "base.json"),
      JSON.stringify({ compilerOptions: { target: "ES2024", types: [] } }),
    );
    writeFileSync(
      join(local, "child/tsconfig.json"),
      JSON.stringify({ extends: "../base.json", include: ["*.ts"] }),
    );
    writeFileSync(join(local, "child/a.ts"), "export const a = (x: number) => x;");
    const result = scanProject(local, { project: "refs" });
    expect(result.files.map((f) => f.path)).toEqual(["child/a.ts"]);
    expect(result.configuration.configs.map((f) => f.path)).toEqual([
      "base.json",
      "child/tsconfig.json",
      "tsconfig.json",
    ]);
    expect(
      result.document.subjects.some((s) => s.key.name === "a" && s.key.kind === "function"),
    ).toBe(true);
  });
});

it("handles UTF-8 BOMs, multiline names/callbacks, and destructuring writes", () => {
  const local = project();
  const text =
    "\uFEFFexport function f(\n {n}: {n:number}, callback: () => void\n) {\n let value = 0;\n ({value} = {value: n});\n (\n callback\n )();\n return value;\n}";
  writeFileSync(join(local, "edge.ts"), text);
  const result = scanProject(local, { project: "edge" });
  validateSnapshot(result);
  const fn = result.document.subjects.find((s) => s.key.name === "f" && s.key.kind === "function")!;
  expect(fn.source.span.start).toBe(3);
  const value = result.document.subjects.find(
    (s) => s.key.name === "f[declaration:0]/value" && s.key.kind === "value",
  )!;
  expect(
    result.document.observations.find(
      (o) => o.subject === value.id && o.metric === "value.write_count",
    )!.measurement.value,
  ).toBe(2);
  expect(
    result.document.observations.find(
      (o) => o.subject === value.id && o.metric === "value.read_count",
    )!.measurement.value,
  ).toBe(1);
  expect(
    result.document.relations.some((r) => r.from === fn.id && r.target.status === "unresolved"),
  ).toBe(true);
});
it("keeps automatic revisions stable when an unchanged project moves directories", () => {
  const a = project();
  const b = project();
  for (const path of [a, b])
    writeFileSync(
      join(path, "tsconfig.json"),
      JSON.stringify({
        compilerOptions: {
          target: "ES2024",
          module: "NodeNext",
          strict: true,
          types: [],
          rootDir: ".",
        },
        include: ["*.ts"],
      }),
    );
  expect(scanProject(a, { project: "portable" })).toEqual(scanProject(b, { project: "portable" }));
});
it("rejects source encodings whose physical byte offsets cannot use UTF-8", () => {
  const local = project();
  writeFileSync(
    join(local, "encoded.ts"),
    Buffer.concat([Buffer.from([255, 254]), Buffer.from("export const x = 1;", "utf16le")]),
  );
  expect(() => scanProject(local)).toThrow("Only UTF-8 source files");
});
