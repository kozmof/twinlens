import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  createDocument,
  encodeDocument,
  encodeSnapshot,
  observationId,
  relationId,
  validateDocument,
} from "../packages/transport/src/index.js";
import { makeFixture } from "../scripts/fixture.mjs";
import { makeProject } from "./project-fixture.mjs";

const root = makeProject();
const dir = mkdtempSync(join(tmpdir(), "twinlens-phase1-"));
afterAll(() => {
  rmSync(root, { recursive: true, force: true });
  rmSync(dir, { recursive: true, force: true });
});
let serial = 0;
function file(value: unknown) {
  const path = join(dir, `${serial++}.json`);
  writeFileSync(path, typeof value === "string" ? value : JSON.stringify(value));
  return path;
}
function cli(...args: string[]) {
  const result = spawnSync("./zig-out/bin/twinlens", args, {
    encoding: "utf8",
    timeout: 30000,
    maxBuffer: 32 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  return result;
}
function ok(...args: string[]) {
  const result = cli(...args);
  expect(result.status, result.stderr).toBe(0);
  return result.stdout ? JSON.parse(result.stdout) : undefined;
}
let snapshot: any;
let baseline: string;
beforeAll(() => {
  baseline = join(dir, "baseline.json");
  const result = cli(
    "scan",
    root,
    "--project",
    "fixture",
    "--revision",
    "before",
    "--out",
    baseline,
  );
  expect(result.status, result.stderr).toBe(0);
  expect(result.stdout).toBe("");
  snapshot = JSON.parse(readFileSync(baseline, "utf8"));
}, 30000);

describe("scan, snapshots and indexed queries", () => {
  it("persists an importable snapshot with provenance and configuration", () => {
    expect(snapshot.snapshot_version).toBe(1);
    expect(snapshot.configuration.adapter).toBe("typescript-bt/1");
    expect(ok("import", baseline)).toEqual(snapshot.document);
  });
  it("queries by symbol name/ID, revision, path and byte span", () => {
    const subject = snapshot.document.subjects.find(
      (s) => s.key.name === "scan" && s.key.kind === "function",
    );
    const symbol = snapshot.document.symbols.find((s) => s.subject === subject.id);
    const byName = ok("query", baseline, "--symbol", "scan", "--metric", "function.args.count");
    expect(byName.observations).toHaveLength(1);
    expect(ok("query", baseline, "--symbol", symbol.id, "--metric", "function.args.count")).toEqual(
      byName,
    );
    expect(
      ok(
        "query",
        baseline,
        "--path",
        "main.ts",
        "--start",
        String(subject.source.span.start),
        "--end",
        String(subject.source.span.end),
        "--metric",
        "function.args.count",
      ).observations.some((o) => o.subject === subject.id),
    ).toBe(true);
    expect(ok("query", baseline, "--revision", "different").observations).toEqual([]);
  });
  it("queries caller/callee relations and relation-associated observations", () => {
    const edges = ok(
      "query",
      baseline,
      "--relations",
      "--relation",
      "calls",
      "--symbol",
      "scan",
    ).relations;
    expect(edges.length).toBeGreaterThan(3);
    expect(edges.every((r) => r.kind === "calls")).toBe(true);
    expect(
      ok("query", baseline, "--relation", "calls", "--metric", "function.args.count").observations
        .length,
    ).toBeGreaterThan(0);
    expect(cli("query", baseline, "--relations", "--metric", "function.args.count").status).toBe(2);
  });
  it("rejects malformed snapshot metadata and dangling references", () => {
    for (const mutate of [
      (s) => {
        s.snapshot_version = 2;
      },
      (s) => {
        s.files = [];
      },
      (s) => {
        s.configuration.options_sha256 = "bad";
      },
      (s) => {
        s.files.push(s.files[0]);
      },
      (s) => {
        s.coverage.unresolved_calls = -1;
      },
      (s) => {
        s.document.subjects = [];
      },
    ]) {
      const changed = structuredClone(snapshot);
      mutate(changed);
      expect(cli("import", file(changed)).status).toBe(5);
    }
  });
  it("reports missing projects and output paths, leaving existing output intact on failure", () => {
    const path = file("preserve");
    expect(cli("scan", join(root, "absent"), "--out", path).status).toBe(4);
    expect(readFileSync(path, "utf8")).toBe("preserve");
    expect(cli("diff", baseline, baseline, "--out", join(dir, "missing/out.json")).status).toBe(4);
  });
});

describe("semantic snapshot diff", () => {
  it("ignores revision-only ID changes and input record order", () => {
    const other = structuredClone(snapshot);
    other.document.revision = "after";
    for (const o of other.document.observations) {
      o.revision = "after";
      o.id = observationId(o);
    }
    for (const r of other.document.relations) {
      r.revision = "after";
      r.id = relationId(r);
    }
    for (const key of ["subjects", "symbols", "observations", "relations"])
      other.document[key].reverse();
    const diff = ok("diff", baseline, file(encodeSnapshot(other)));
    for (const key of ["subjects", "symbols", "observations", "relations", "files"])
      expect(diff[key]).toEqual({ added: [], removed: [], changed: [] });
    expect(diff.configuration_changed).toBe(false);
  });
  it("distinguishes changed zero, missing observations, changed edges and renamed subjects", () => {
    const other = structuredClone(snapshot);
    const measured = other.document.observations.find(
      (o) => o.metric === "function.args.count" && o.measurement.value === 0,
    );
    measured.measurement.value = 1;
    const removed = other.document.observations.pop();
    other.document.relations.pop();
    const output = file(encodeSnapshot(other));
    const first = cli("diff", baseline, output);
    const second = cli("diff", baseline, output);
    expect(first.status, first.stderr).toBe(0);
    expect(second.stdout).toBe(first.stdout);
    const diff = JSON.parse(first.stdout);
    expect(
      diff.observations.changed.some(
        (c) =>
          c.before.id === measured.id &&
          c.before.measurement.value === 0 &&
          c.after.measurement.value === 1,
      ),
    ).toBe(true);
    expect(diff.observations.removed.some((o) => o.id === removed.id)).toBe(true);
    expect(diff.relations.removed).toHaveLength(1);
  });
  it("detects a real source edit, identity rename and configuration changes", () => {
    const source = join(root, "lib.ts");
    const original = readFileSync(source, "utf8");
    writeFileSync(
      source,
      original.replace(
        "export const arrow = (x: number) => x + 1;",
        "export const increment = (x: number, step: number) => x + step;",
      ),
    );
    const after = ok("scan", root, "--project", "fixture", "--revision", "edited");
    writeFileSync(source, original);
    const diff = ok("diff", baseline, file(encodeSnapshot(after)));
    expect(diff.files.changed.map((c) => c.before.path)).toEqual(["lib.ts"]);
    expect(diff.subjects.removed.some((s) => s.key.name === "arrow")).toBe(true);
    expect(diff.subjects.added.some((s) => s.key.name === "increment")).toBe(true);
    const configChange = structuredClone(snapshot);
    configChange.configuration.adapter = "typescript-bt/2";
    expect(ok("diff", baseline, file(configChange)).configuration_changed).toBe(true);
    const wrongProject = structuredClone(snapshot);
    wrongProject.project = "other";
    for (const s of wrongProject.document.subjects) s.key.project = "other";
    expect(cli("diff", baseline, file(wrongProject)).status).toBe(5);
  });
});

describe("file replacement and removal", () => {
  it("replaces observations, removes stale values, and is repeatable", () => {
    const before = makeFixture();
    const replacement = makeFixture();
    replacement.observations.splice(1, 1);
    replacement.observations[0].measurement.value = 7;
    const first = ok(
      "update",
      file(encodeDocument(before)),
      file(encodeDocument(replacement)),
      "--file",
      "src/scanner.ts",
    );
    validateDocument(first);
    expect(first.observations.some((o) => o.metric === "function.branch.count")).toBe(false);
    expect(
      first.observations.find((o) => o.metric === "function.args.count").measurement.value,
    ).toBe(7);
    expect(ok("update", file(first), file(replacement), "--file", "src/scanner.ts")).toEqual(first);
  });
  it("removes deleted declarations and explicitly invalidates incoming relations", () => {
    const before = makeFixture();
    const empty = createDocument("deleted");
    const updated = ok("update", file(before), file(empty), "--file", "src/café.ts");
    validateDocument(updated);
    expect(
      updated.observations.find((o) => o.metric === "value.write_count").measurement.status,
    ).toBe("unsupported");
    expect(updated.subjects).toHaveLength(1);
    expect(updated.symbols).toHaveLength(1);
    expect(updated.relations.every((r) => r.target.status === "unresolved")).toBe(true);
    expect(updated.relations.some((r) => r.target.reason.includes("requires rescan"))).toBe(true);
    expect(updated.observations.every((o) => o.revision === "deleted")).toBe(true);
    const last = ok(
      "update",
      file(updated),
      file(createDocument("empty")),
      "--file",
      "src/scanner.ts",
    );
    expect(last).toEqual(createDocument("empty"));
  });
});

it("invalidates project-wide counts after partial updates instead of keeping stale measurements", () => {
  const empty = createDocument("after-removal");
  const updated = ok("update", baseline, file(empty), "--file", "lib.ts");
  expect(
    updated.observations
      .filter((o) =>
        [
          "function.callers",
          "function.callees",
          "value.read_count",
          "property.write_count",
        ].includes(o.metric),
      )
      .every((o) => o.measurement.status === "unknown" && o.measurement.value === null),
  ).toBe(true);
  expect(
    updated.observations.some(
      (o) => o.metric === "function.args.count" && o.measurement.status === "measured",
    ),
  ).toBe(true);
});
