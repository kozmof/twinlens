import { afterAll, beforeAll, expect, it } from "vitest";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";
import {
  claimId,
  constraintId,
  expression,
  scalar,
  validateSnapshot,
} from "../packages/transport/src/index.js";
const root = mkdtempSync(join(tmpdir(), "twinlens-phase4-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));
let serial = 0;
function file(value: unknown) {
  const path = join(root, `${serial++}.json`);
  writeFileSync(path, JSON.stringify(value));
  return path;
}
function cli(...args: string[]) {
  const r = spawnSync("./zig-out/bin/twinlens", args, {
    encoding: "utf8",
    timeout: 30000,
    maxBuffer: 64 * 1024 * 1024,
  });
  if (r.error) throw r.error;
  return r;
}
function ok(...args: string[]) {
  const r = cli(...args);
  expect(r.status, r.stderr).toBe(0);
  return r.stdout ? JSON.parse(r.stdout) : undefined;
}
const library = JSON.stringify(resolve("packages/typespec/lib/main.tsp"));
function compile(source: string) {
  const path = join(root, `case-${serial++}.tsp`);
  writeFileSync(path, `import ${library};\nusing Twinlens;\n${source}`);
  return ok("compile", path, "--project", "fixture");
}
const ann = (kind: string, name: string, expr: unknown) =>
  `@${kind}(${JSON.stringify(name)}, ${JSON.stringify(JSON.stringify(expr))})`;
let spec: any, source: any;
beforeAll(() => {
  spec = compile(`// Unicode: λ 🌿
${ann("require", "adult", { ge: [{ fact: "age" }, 18] })}
${ann("ensure", "email", { eq: [{ call: ["emailOf", { fact: "email" }] }, "a@example.test"] })}
${ann("forbid", "blocked", { eq: [{ fact: "blocked" }, true] })}
${ann("policy", "allowed", { or: [{ fact: "admin" }, { fact: "member" }] })}
op login(age: int32, email: string): User;
@semantics("axiomatized", ${JSON.stringify(JSON.stringify({ fact: "$0" }))})
op emailOf(user: string): string;
@derived(emailOf)
@semantics("uninterpreted")
op derivedEmail(user: string): string;
@domain(${JSON.stringify(JSON.stringify({ ownership: "owned", nullability: "nonnull", values: ["alice", "bob"] }))})
model User { name: string; }
@relation("reads", User) @relation("creates", User) @relation("deletes", User)
@relation("writes", User) @relation("calls", login) @relation("emits", User)
@relation("requires", User) @relation("ensures", User) @relation("authorizes", User)
op manage(): User;
@status("intentionally_unspecified", "External policy is not modeled") model External {}
@status("deferred", "Await runtime evidence") model Later {}
@status("out_of_scope", "Not part of this verification") model Outside {}
@status("unknown", "Ownership needs investigation") model Unclear {}
model Complex { value: string | int32; }
`);
  source = spec.claims[0].source;
  expect(spec.snapshot.diagnostics).toEqual([]);
}, 30000);
function input(
  facts: Record<string, unknown> = {},
  graph: any = null,
  coverage = graph ? "complete" : "absent",
) {
  return {
    input_version: 1,
    project: "fixture",
    facts: Object.entries(facts).map(([name, value]) => ({
      name,
      status: "known",
      value: scalar(value),
      reason: null,
      source,
      origin: "test",
    })),
    graph,
    coverage,
  };
}
function evaluate(s: any, i: any) {
  return ok("evaluate", file(s), file(i));
}
function result(name: string, facts: Record<string, unknown> = {}) {
  return evaluate(spec, input(facts)).results.find((r) => r.claim.name === name);
}
function direct(expr: unknown, kind = "invariant") {
  const s = structuredClone(spec);
  const subject = spec.claims[0].subject;
  const name = "direct";
  const c = {
    id: constraintId(subject, name),
    subject,
    name,
    expression: expression(expr),
    source,
  };
  s.constraints = [c];
  s.claims = [
    {
      id: claimId(subject, name, kind as any),
      subject,
      name,
      kind,
      state: "specified",
      reason: "Direct IR fixture",
      constraint: c.id,
      source,
    },
  ];
  s.domains = [];
  return s;
}
it("extracts TypeSpec declarations, primitive types, source spans, authority and effect relations", () => {
  validateSnapshot(spec.snapshot);
  expect(spec.snapshot.configuration).toMatchObject({
    adapter: "typespec-sa/1",
    compiler: "1.16.0",
  });
  for (const kind of ["model", "operation", "parameter", "property", "type"])
    expect(spec.snapshot.document.subjects.some((s) => s.key.kind === kind)).toBe(true);
  for (const kind of [
    "inputs",
    "outputs",
    "type",
    "reads",
    "writes",
    "creates",
    "deletes",
    "calls",
    "requires",
    "ensures",
    "emits",
    "authorizes",
    "derived_from",
  ])
    expect(
      spec.snapshot.document.relations.some(
        (r) => r.kind === kind && r.target.status === "resolved",
      ),
      kind,
    ).toBe(true);
  const login = spec.snapshot.document.subjects.find((s) => s.key.name === "login");
  const bytes = readFileSync(join(root, login.source.path));
  expect(bytes.subarray(login.source.span.start, login.source.span.end).toString()).toContain(
    "op login",
  );
  expect(
    spec.snapshot.document.relations.some(
      (r) => r.kind === "type" && r.target.status === "unresolved",
    ),
  ).toBe(true);
});
it("keeps ambiguity by default and links every explicit domain narrowing to constraints", () => {
  const user = spec.snapshot.document.subjects.find((s) => s.key.name === "User");
  const domain = spec.domains.find((d) => d.subject === user.id);
  expect(domain).toMatchObject({ ownership: "owned", nullability: "nonnull" });
  expect(domain.values).toHaveLength(2);
  expect(domain.constraints).toHaveLength(1);
  expect(
    spec.domains
      .filter((d) => d.subject !== user.id)
      .every((d) => d.ownership === "unknown" && d.nullability === "unknown"),
  ).toBe(true);
  expect(result("domain", { User: "alice", "User.ownership": "owned" }).outcome).toBe("satisfied");
  expect(result("domain", { User: null, "User.ownership": "owned" }).outcome).toBe("violated");
  expect(result("domain").outcome).toBe("unknown");
});
it("evaluates TypeSpec and direct IR constraints identically with evidence and governing constraints", () => {
  const compiled = result("adult", { age: 21 });
  const explicit = evaluate(direct({ ge: [{ fact: "age" }, 18] }), input({ age: 21 })).results[0];
  expect(compiled.outcome).toBe("satisfied");
  expect(explicit.outcome).toBe(compiled.outcome);
  expect(explicit.constraint.expression).toEqual(compiled.constraint.expression);
  expect(result("adult", { age: 17 }).outcome).toBe("violated");
  expect(result("adult").outcome).toBe("unknown");
  expect(compiled.facts).toContain("age");
  expect(compiled.evidence).toContainEqual(source);
  expect(result("blocked", { blocked: true }).outcome).toBe("violated");
  expect(result("blocked", { blocked: false }).outcome).toBe("satisfied");
  expect(result("email", { email: "a@example.test" }).outcome).toBe("satisfied");
  expect(result("allowed", { admin: true }).outcome).toBe("satisfied");
});
it.each([
  [{ and: [true, true] }, "satisfied"],
  [{ and: [false, { fact: "absent" }] }, "violated"],
  [{ or: [true, { unsupported: "runtime" }] }, "satisfied"],
  [{ implies: [false, { fact: "missing" }] }, "satisfied"],
  [{ not: [false] }, "satisfied"],
  [{ eq: [null, null] }, "satisfied"],
  [{ lt: [3, 4] }, "satisfied"],
  [{ le: [4, 4] }, "satisfied"],
  [{ gt: [5, 4] }, "satisfied"],
  [{ ne: ["a", "b"] }, "satisfied"],
  [{ lt: ["3", 4] }, "unsupported"],
  [{ and: ["not a boolean", false] }, "unsupported"],
  [{ unsupported: "solver" }, "unsupported"],
  [{ fact: "absent" }, "unknown"],
  [{ call: ["unknownDomainFunction", 1] }, "unknown"],
  [4, "unsupported"],
])("evaluates bounded scalar expressions without coercion", (expr, outcome) => {
  expect(evaluate(direct(expr), input()).results[0].outcome).toBe(outcome);
});
it.each(["opaque", "uninterpreted", "axiomatized", "executable", "mocked", "observed"])(
  "preserves %s function semantics without executing arbitrary code",
  (mode) => {
    const s = direct({ call: ["emailOf", "value"] });
    s.functions.find((f) => f.name === "emailOf").mode = mode;
    const outcome = evaluate(s, input()).results[0].outcome;
    expect(outcome).toBe(mode === "opaque" || mode === "uninterpreted" ? "unknown" : "unsupported"); // axiomatized returns a string, not a boolean
  },
);
it("bounds recursive domain functions and preserves partial specification states", () => {
  const s = direct({ call: ["emailOf", "x"] });
  s.functions.find((f) => f.name === "emailOf").definition = expression({
    call: ["emailOf", { fact: "$0" }],
  });
  expect(evaluate(s, input()).results[0]).toMatchObject({
    outcome: "unknown",
    reason: "Domain function recursion limit reached",
  });
  s.functions.find((f) => f.name === "emailOf").definition = expression({
    and: [{ call: ["emailOf", { fact: "$0" }] }, { call: ["emailOf", { fact: "$0" }] }],
  });
  expect(evaluate(s, input()).results[0].outcome).toBe("unknown");
  const partial = evaluate(spec, input()).results.filter((r) => r.claim.state !== "specified");
  expect(partial.every((r) => r.outcome === "unknown")).toBe(true);
  expect(new Set(partial.map((r) => r.claim.state))).toEqual(
    new Set(["unspecified", "intentionally_unspecified", "deferred", "out_of_scope", "unknown"]),
  );
});
it("reports invalid annotations and malformed source and never evaluates compiler errors as success", () => {
  for (const text of [
    '@require("x", "not-json") model Bad {}',
    '@status("specified", "missing constraint") model Bad {}',
    '@semantics("magic") op bad(): void;',
    '@invariant("namespace", "true") namespace Bad {}',
    '@status("deferred", "Later") @domain("{}") model Bad {}',
    "model Bad { broken: ; }",
  ]) {
    const s = compile(text);
    expect(s.snapshot.diagnostics.some((d) => d.category === "error")).toBe(true);
    expect(evaluate(s, input()).results.every((r) => r.outcome === "unknown")).toBe(true);
  }
}, 30000);
it("rejects malformed expression references, unjustified domains, duplicate facts and cross-project evidence", () => {
  const s = direct({ eq: [1, 1] });
  s.constraints[0].expression[0].args = [99];
  expect(cli("evaluate", file(s), file(input())).status).toBe(5);
  const unbacked = structuredClone(spec);
  unbacked.domains.find((d) => d.ownership === "owned").constraints = [];
  expect(cli("evaluate", file(unbacked), file(input())).status).toBe(5);
  const i = input({ age: 20 });
  i.facts.push(i.facts[0]!);
  expect(cli("evaluate", file(spec), file(i)).status).toBe(5);
  const other = input();
  other.project = "other";
  expect(cli("evaluate", file(spec), file(other)).status).toBe(5);
});
it("verifies identity, ownership and references while separating incomplete graph coverage", () => {
  const graph = structuredClone(spec.snapshot.document);
  for (const name of ["identity", "ownership", "references"]) {
    expect(evaluate(direct({ graph: name }), input({}, graph)).results[0].outcome).toBe(
      "satisfied",
    );
    expect(evaluate(direct({ graph: name }), input({}, graph, "partial")).results[0].outcome).toBe(
      "unknown",
    );
    expect(evaluate(direct({ graph: name }), input()).results[0].outcome).toBe("unknown");
  }
  const wrongId = structuredClone(graph);
  wrongId.subjects[0].id = "sub_" + "0".repeat(64);
  expect(evaluate(direct({ graph: "identity" }), input({}, wrongId)).results[0].outcome).toBe(
    "violated",
  );
  const dangling = structuredClone(graph);
  dangling.relations[0].from = "sub_" + "0".repeat(64);
  const result = evaluate(direct({ graph: "references" }), input({}, dangling, "partial"))
    .results[0];
  expect(result.outcome).toBe("violated");
  expect(result.records).toContain(dangling.relations[0].id);
});
it("detects forbidden core imports and AST fields, and leaves unfamiliar Store shapes unknown", () => {
  const copy = join(root, "source");
  mkdirSync(join(copy, "src"), { recursive: true });
  cpSync("src/core", join(copy, "src/core"), { recursive: true });
  const snapshot = file(spec.snapshot);
  const original = readFileSync(join(copy, "src/core/store.zig"), "utf8");
  const inspect = () => ok("inspect", copy, snapshot).facts;
  expect(inspect().every((f) => f.status === "known" && f.value.value === "true")).toBe(true);
  writeFileSync(join(copy, "src/core/bad.zig"), 'const frontend = @import("../adapters/zig.zig");');
  expect(inspect().find((f) => f.name === "core.dependencies.valid").value.value).toBe("false");
  rmSync(join(copy, "src/core/bad.zig"));
  writeFileSync(
    join(copy, "src/core/store.zig"),
    original.replace(
      "pub const Store = struct {",
      "pub const Store = struct {\n tree: std.zig.Ast,",
    ),
  );
  expect(inspect().find((f) => f.name === "store.ast_free").value.value).toBe("false");
  writeFileSync(
    join(copy, "src/core/store.zig"),
    original.replace(
      "pub const Store = struct {",
      "pub const Store = struct {\n extension: UnknownType,",
    ),
  );
  expect(inspect().find((f) => f.name === "store.ast_free").status).toBe("unknown");
});
it("imports and queries compiled specification subjects through the existing core store", () => {
  expect(ok("import", file(spec))).toEqual(spec.snapshot.document);
  expect(ok("query", file(spec), "--relations", "--relation", "authorizes").relations).toHaveLength(
    1,
  );
});
it("retains UTF-8 byte spans with a BOM and detects decorator dependency changes in revisions", () => {
  const path = join(root, "bom.tsp");
  const text = `\uFEFFimport ${library};\n// 🌿 λ\nmodel Unicode { name: string; }\n`;
  writeFileSync(path, text);
  const s = ok("compile", path, "--project", "fixture");
  const row = s.snapshot.document.subjects.find((s) => s.key.name === "Unicode");
  expect(Buffer.from(text).subarray(row.source.span.start, row.source.span.end).toString()).toBe(
    "model Unicode { name: string; }",
  );
  const decorator = join(root, "custom.js");
  writeFileSync(decorator, "export function $noop() {}");
  const input = join(root, "dep.tsp");
  writeFileSync(
    input,
    'import "./custom.js";\nextern dec noop(target: unknown);\n@noop model User {}',
  );
  const before = ok("compile", input, "--project", "fixture");
  writeFileSync(decorator, "export function $noop() { /* behavior version */ }");
  const after = ok("compile", input, "--project", "fixture");
  expect(after.snapshot.document.revision).not.toBe(before.snapshot.document.revision);
});
