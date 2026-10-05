import assert from "node:assert/strict";
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join, resolve, sep } from "node:path";

const root = resolve(".");
const output = join(root, ".twinlens/analysis");
mkdirSync(output, { recursive: true });
const config = join(output, "config.json");
writeFileSync(config, JSON.stringify({ max_input_bytes: 134217728 }));
function cli(...args) {
  const r = spawnSync(join(root, "zig-out/bin/twinlens"), ["--config", config, ...args], {
    cwd: root,
    encoding: "utf8",
    timeout: 120000,
    maxBuffer: 128 * 1024 * 1024,
  });
  if (r.error) throw r.error;
  if (r.status !== 0) throw Error(r.stderr);
  return r.stdout ? JSON.parse(r.stdout) : undefined;
}
const read = (p) => JSON.parse(readFileSync(p, "utf8"));
function scan(input, name) {
  const path = join(output, name + ".json");
  cli("scan", input, "--language", "both", "--project", "twinlens", "--out", path);
  return path;
}
const currentPath = scan("tsconfig.json", "after");
const current = read(currentPath);
assert.equal(current.diagnostics.filter((d) => d.category === "error").length, 0);
const scratch = mkdtempSync(join(tmpdir(), "twinlens-analysis-"));
try {
  for (const name of ["tsconfig.json", "tsconfig.base.json", "package.json", "build.zig"])
    cpSync(join(root, name), join(scratch, name));
  cpSync(join(root, "src"), join(scratch, "src"), { recursive: true });
  cpSync(join(root, "packages"), join(scratch, "packages"), {
    recursive: true,
    filter: (path) => !path.split(sep).includes("node_modules"),
  });
  symlinkSync(join(root, "node_modules"), join(scratch, "node_modules"), "dir");
  for (const name of ["transport", "typescript", "typespec", "solver"]) {
    const path = join(root, "packages", name, "node_modules");
    if (existsSync(path)) symlinkSync(path, join(scratch, "packages", name, "node_modules"), "dir");
  }
  const copiedPath = scan(join(scratch, "tsconfig.json"), "copy");
  assert.deepEqual(
    read(copiedPath).document,
    current.document,
    "Unmodified copy must match current source",
  );
  const sourcePath = join(scratch, "packages/typescript/src/project.ts");
  const original = readFileSync(sourcePath, "utf8");
  const start = original.indexOf("/** Normalize option values independently");
  const end = original.indexOf("const byteMaps", start);
  assert.ok(start >= 0 && end > start, "Find extracted normalization helper");
  const before = (original.slice(0, start) + original.slice(end)).replace(
    "return normalizeOptionValue(root, value);",
    `if (typeof value === "string" && isAbsolute(value))
        return resolve(value) === root
          ? "."
          : (relativePath(root, value) ?? "<external>/" + value.split(sep).slice(-2).join("/"));
      return value;`,
  );
  assert.notEqual(before, original, "Restore pre-extraction normalization in isolated copy");
  writeFileSync(sourcePath, before);
  const beforePath = scan(join(scratch, "tsconfig.json"), "before");
  const baseline = read(beforePath);
  assert.equal(baseline.diagnostics.filter((d) => d.category === "error").length, 0);
  const beforeAnalysisPath = join(output, "before-analysis.json");
  cli("analyze", beforePath, "--out", beforeAnalysisPath);
  const analysis = read(beforeAnalysisPath);
  const normalizer = baseline.document.subjects.find(
    (s) =>
      s.key.path === "packages/typescript/src/project.ts" &&
      s.key.kind === "function" &&
      s.key.name.endsWith("/<arrow>") &&
      Buffer.from(before)
        .subarray(s.source.span.start, s.source.span.end)
        .toString()
        .includes('if (key === "configFile")'),
  );
  assert.ok(normalizer, "Locate normalization callback");
  const hypothesis = analysis.findings.find((f) => f.subject === normalizer.id);
  assert.ok(hypothesis, "Normalization should expose separate parameter usage clusters");
  const reviewedPath = join(output, "reviewed.json");
  cli(
    "review",
    beforeAnalysisPath,
    "--finding",
    hypothesis.id,
    "--status",
    "deferred",
    "--note",
    "Separate key filtering from path-value normalization for direct testing; the JSON callback still legitimately has two roles.",
    "--out",
    reviewedPath,
  );
  const afterAnalysisPath = join(output, "after-analysis.json");
  cli("analyze", currentPath, "--previous", reviewedPath, "--out", afterAnalysisPath);
  const afterAnalysis = read(afterAnalysisPath);
  const persisted = afterAnalysis.findings.find((f) => f.id === hypothesis.id);
  assert.equal(
    persisted.status,
    "deferred",
    "Preserve review without automatically declaring the hypothesis fixed",
  );
  const metric = (s, id, name) =>
    s.document.observations.find((o) => o.subject === id && o.metric === name);
  const oldBranches = metric(baseline, normalizer.id, "function.branch.count");
  const newBranches = metric(current, normalizer.id, "function.branch.count");
  assert.ok(newBranches.measurement.value < oldBranches.measurement.value);
  const helper = current.document.subjects.find(
    (s) => s.key.name === "normalizeOptionValue" && s.key.kind === "function",
  );
  assert.ok(helper);
  const helperParams = current.document.relations
    .filter(
      (r) =>
        r.from === helper.id &&
        r.kind === "contains" &&
        current.document.subjects.some(
          (s) => s.id === r.target.subject && s.key.kind === "parameter",
        ),
    )
    .map((r) => r.target.subject);
  const helperFlow = current.document.relations.filter(
    (r) =>
      helperParams.includes(r.from) &&
      ["controls", "input", "argument", "returns"].includes(r.kind),
  );
  assert.ok(helperFlow.length > 0);
  const querySubjects = current.document.subjects.filter(
    (s) => s.key.path === "src/core/store.zig" && /\/query(Filtered|Relations)$/u.test(s.key.name),
  );
  const queryBranches = querySubjects.map((s) => metric(current, s.id, "function.branch.count"));
  assert.equal(queryBranches.length, 2);
  assert.ok(queryBranches.every((o) => o.measurement.status === "measured"));
  const sensors = new Set(
    current.document.subjects
      .filter(
        (s) =>
          s.key.path.includes("scanner.ts") ||
          s.key.path.includes("flow.ts") ||
          s.key.path.includes("adapters/zig.zig"),
      )
      .map((s) => s.id),
  );
  const scores = afterAnalysis.significance.filter((s) => sensors.has(s.caller));
  assert.ok(scores.length > 0);
  assert.ok(scores.every((s) => Number.isFinite(s.score)));
  const diffPath = join(output, "diff.json");
  cli("diff", beforePath, currentPath, "--out", diffPath);
  const change = read(diffPath).observations.changed.find(
    (c) => c.before.subject === normalizer.id && c.before.metric === "function.branch.count",
  );
  assert.ok(change);
  const report = {
    hypothesis,
    review_status: persisted.status,
    change: "Extract path-value normalization from JSON key filtering",
    normalization_branches: {
      before: oldBranches,
      after: newBranches,
      helper: metric(current, helper.id, "function.branch.count"),
    },
    normalization_flow: helperFlow,
    query_engine_branches: queryBranches,
    sensor_significance: {
      count: scores.length,
      examples: [...scores].sort((a, b) => b.score - a.score).slice(0, 5),
    },
    counts: {
      files: current.files.length,
      observations: current.document.observations.length,
      relations: current.document.relations.length,
      evidence: afterAnalysis.evidence.length,
      clusters: afterAnalysis.clusters.length,
      findings: afterAnalysis.findings.length,
    },
    limits:
      "Syntactic potential dependencies; extraction moves logic, not total complexity. Hypotheses are not constraint violations.",
    artifacts: [
      "before.json",
      "after.json",
      "before-analysis.json",
      "reviewed.json",
      "after-analysis.json",
      "diff.json",
    ].map((p) => ".twinlens/analysis/" + p),
  };
  writeFileSync(join(output, "report.json"), JSON.stringify(report, null, 2) + "\n");
  console.log(JSON.stringify(report, null, 2));
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
