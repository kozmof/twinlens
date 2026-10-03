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
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join, resolve, sep } from "node:path";

const root = resolve(".");
const output = join(root, ".twinlens/self");
mkdirSync(output, { recursive: true });
const cli = (...args) => {
  const result = spawnSync(join(root, "zig-out/bin/twinlens"), args, {
    cwd: root,
    encoding: "utf8",
    timeout: 60000,
    maxBuffer: 32 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(result.stderr);
  return result.stdout ? JSON.parse(result.stdout) : undefined;
};
const read = (path) => JSON.parse(readFileSync(path, "utf8"));
const baselinePath = join(output, "baseline.json");
cli("scan", "tsconfig.json", "--project", "twinlens", "--out", baselinePath);
const baseline = read(baselinePath);
assert.equal(
  baseline.diagnostics.filter((d) => d.category === "error").length,
  0,
  "Self-scan compiler errors",
);
const scratch = mkdtempSync(join(tmpdir(), "twinlens-self-"));
try {
  for (const path of ["tsconfig.json", "tsconfig.base.json", "package.json"])
    cpSync(join(root, path), join(scratch, path));
  cpSync(join(root, "packages"), join(scratch, "packages"), {
    recursive: true,
    filter: (path) => !path.split(sep).includes("node_modules"),
  });
  symlinkSync(join(root, "node_modules"), join(scratch, "node_modules"), "dir");
  for (const name of ["transport", "typescript", "typespec"]) {
    const modules = join(root, "packages", name, "node_modules");
    if (existsSync(modules))
      symlinkSync(modules, join(scratch, "packages", name, "node_modules"), "dir");
  }
  const copy = cli("scan", join(scratch, "tsconfig.json"), "--project", "twinlens");
  assert.deepEqual(
    copy.document,
    baseline.document,
    "Copy must match the real self-scan before editing",
  );
  const source = join(scratch, "packages/transport/src/index.ts");
  const before = readFileSync(source, "utf8");
  const after = before.replace(
    "createDocument(revision: string)",
    "createDocument(revision: string, seedLabel?: string)",
  );
  assert.notEqual(after, before, "Controlled edit must match exactly");
  writeFileSync(source, after);
  const afterPath = join(output, "after.json");
  cli("scan", join(scratch, "tsconfig.json"), "--project", "twinlens", "--out", afterPath);
  assert.equal(
    read(afterPath).diagnostics.filter((d) => d.category === "error").length,
    0,
    "Edited-copy compiler errors",
  );
  const diffPath = join(output, "diff.json");
  cli("diff", baselinePath, afterPath, "--out", diffPath);
  const diff = read(diffPath);
  const subject = baseline.document.subjects.find(
    (s) => s.key.kind === "function" && s.key.name === "createDocument",
  );
  const change = diff.observations.changed.find(
    (c) => c.before.subject === subject.id && c.before.metric === "function.args.count",
  );
  assert.equal(change.before.measurement.value, 1);
  assert.equal(change.after.measurement.value, 2);
  const selected = baseline.document.subjects.filter(
    (s) => s.key.name === "scanProject" || s.key.name === "subjectId[declaration:0]/key",
  );
  const observations = baseline.document.observations.filter(
    (o) =>
      selected.some((s) => s.id === o.subject) &&
      ["function.args.count", "function.parameter.property_count"].includes(o.metric),
  );
  assert.equal(observations.length, 2, "Retain scanner arguments and IR key property evidence");
  const summary = {
    baseline_sha256: createHash("sha256").update(readFileSync(baselinePath)).digest("hex"),
    revision: baseline.document.revision,
    files: baseline.files.length,
    subjects: baseline.document.subjects.length,
    observations: baseline.document.observations.length,
    relations: baseline.document.relations.length,
    compiler_diagnostics: baseline.diagnostics.length,
    coverage: baseline.coverage,
    self_evidence: observations,
    controlled_edit: {
      source: "packages/transport/src/index.ts",
      subject: subject.id,
      metric: "function.args.count",
      before: change.before.measurement.value,
      after: change.after.measurement.value,
    },
    artifacts: [
      ".twinlens/self/baseline.json",
      ".twinlens/self/after.json",
      ".twinlens/self/diff.json",
    ],
  };
  writeFileSync(join(output, "report.json"), JSON.stringify(summary, null, 2) + "\n");
  console.log(JSON.stringify(summary, null, 2));
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
