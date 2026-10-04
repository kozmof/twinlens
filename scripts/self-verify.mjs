import assert from "node:assert/strict";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const root = resolve(".");
const output = join(root, ".twinlens/specification");
mkdirSync(output, { recursive: true });
const config = join(output, "config.json");
writeFileSync(config, JSON.stringify({ max_input_bytes: 134217728 }));
function cli(...args) {
  const r = spawnSync(join(root, "zig-out/bin/twinlens"), ["--config", config, ...args], {
    cwd: root,
    encoding: "utf8",
    timeout: 180000,
    maxBuffer: 128 * 1024 * 1024,
  });
  if (r.error) throw r.error;
  if (r.status !== 0) throw Error(r.stderr);
  return r.stdout ? JSON.parse(r.stdout) : undefined;
}
const read = (p) => JSON.parse(readFileSync(p, "utf8"));
function save(name, value) {
  const path = join(output, name + ".json");
  writeFileSync(path, JSON.stringify(value));
  return path;
}
const snapshot = join(output, "snapshot.json");
cli("scan", "tsconfig.json", "--language", "both", "--project", "twinlens", "--out", snapshot);
assert.equal(read(snapshot).diagnostics.filter((d) => d.category === "error").length, 0);
const specification = join(output, "specification.json");
cli("compile", "specs/twinlens.tsp", "--project", "twinlens", "--out", specification);
const spec = read(specification);
assert.equal(spec.snapshot.diagnostics.length, 0);
const evidence = join(output, "evidence.json");
cli("inspect", root, snapshot, "--out", evidence);
const verified = join(output, "verified.json");
cli("evaluate", specification, evidence, "--out", verified);
const selected = read(verified).results.filter((r) => r.claim.state === "specified");
assert.equal(selected.length, 5);
assert.ok(
  selected.every((r) => r.outcome === "satisfied"),
  JSON.stringify(selected.map((r) => [r.claim.name, r.outcome, r.reason])),
);
const scratch = mkdtempSync(join(tmpdir(), "twinlens-verify-"));
try {
  mkdirSync(join(scratch, "src"), { recursive: true });
  cpSync(join(root, "src/core"), join(scratch, "src/core"), { recursive: true });
  const store = join(scratch, "src/core/store.zig");
  const original = readFileSync(store, "utf8");
  const changed = original.replace(
    "pub const Store = struct {",
    "pub const Store = struct {\n    tree: std.zig.Ast,",
  );
  assert.notEqual(changed, original);
  writeFileSync(store, changed);
  writeFileSync(
    join(scratch, "src/core/forbidden.zig"),
    'const frontend = @import("../adapters/zig.zig");\n',
  );
  writeFileSync(join(output, "violating-store.zig"), changed);
  writeFileSync(
    join(output, "forbidden-import.zig"),
    'const frontend = @import("../adapters/zig.zig");\n',
  );
  const negative = cli("inspect", scratch, snapshot);
  negative.graph.observations[0].subject = "sub_" + "0".repeat(64);
  const negativePath = save("violating-evidence", negative);
  const violations = join(output, "violations.json");
  cli("evaluate", specification, negativePath, "--out", violations);
  const failed = read(violations).results.filter((r) => r.claim.state === "specified");
  assert.equal(failed.length, 5);
  assert.ok(failed.every((r) => r.outcome === "violated"));
  assert.ok(failed.every((r) => r.constraint && r.evidence.length));
  const absent = save("absent-evidence", {
    input_version: 1,
    project: "twinlens",
    facts: [],
    graph: null,
    coverage: "absent",
  });
  const unknownPath = join(output, "unknown.json");
  cli("evaluate", specification, absent, "--out", unknownPath);
  assert.ok(read(unknownPath).results.every((r) => r.outcome === "unknown"));
  const unsupportedSource = join(output, "unsupported.tsp");
  writeFileSync(
    unsupportedSource,
    `import ${JSON.stringify(join(root, "packages/typespec/lib/main.tsp"))};\nusing Twinlens;\n@invariant("heap-proof", ${JSON.stringify(JSON.stringify({ unsupported: "heap reachability" }))})\nmodel Heap {}\n`,
  );
  const unsupportedSpec = join(output, "unsupported-specification.json");
  cli("compile", unsupportedSource, "--project", "twinlens", "--out", unsupportedSpec);
  assert.equal(read(unsupportedSpec).snapshot.diagnostics.length, 0);
  const unsupportedPath = join(output, "unsupported.json");
  cli("evaluate", unsupportedSpec, absent, "--out", unsupportedPath);
  assert.equal(read(unsupportedPath).results[0].outcome, "unsupported");
  const summary = {
    specification: "specs/twinlens.tsp",
    verified: selected.map((r) => ({
      claim: r.claim.name,
      constraint: r.constraint.id,
      outcome: r.outcome,
      source: r.constraint.source,
      evidence_count: r.evidence.length,
    })),
    violations: failed.map((r) => ({
      claim: r.claim.name,
      outcome: r.outcome,
      evidence_count: r.evidence.length,
      offending_records: r.records.slice(0, 3),
    })),
    missing_evidence: "unknown",
    unsupported_semantics: "unsupported",
    partial_claims: read(verified)
      .results.filter((r) => r.claim.state !== "specified")
      .map((r) => ({ state: r.claim.state, outcome: r.outcome, reason: r.reason })),
    scope:
      "Declared core imports, supported compiled Store/IR/index shape, and the supplied finite record graph; not runtime heap verification",
    artifacts: [
      "snapshot.json",
      "specification.json",
      "evidence.json",
      "verified.json",
      "violating-evidence.json",
      "violations.json",
      "unknown.json",
      "unsupported.json",
    ].map((p) => ".twinlens/specification/" + p),
  };
  writeFileSync(join(output, "report.json"), JSON.stringify(summary, null, 2) + "\n");
  console.log(JSON.stringify(summary, null, 2));
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
