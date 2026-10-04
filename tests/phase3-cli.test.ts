import { afterAll, beforeAll, expect, it } from "vitest";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";
import { validateSnapshot } from "../packages/transport/src/index.js";
const root = mkdtempSync(join(tmpdir(), "twinlens-phase3-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));
let serial = 0;
function file(value: unknown) {
  const p = join(root, `report-${serial++}.json`);
  writeFileSync(p, JSON.stringify(value));
  return p;
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
const tsSource = `interface Options { amount: number }
function utility(value: unknown) { return value; }
function specialized(value: number) { return value; }
export function split(amount: number, label: string) { specialized(amount); utility(label); }
export function together(a: number, b: number) { return specialized(a + b); }
export function transform(options: Options, flag: boolean) { const amount = options.amount + 1; if (flag) { utility(amount); } return options.amount; }
export function extra() { utility(0); }
export function unknown(value: any) { return value.missing(); }
`;
const zigSource = `const Options = struct { amount: i32 };
fn utility(value: anytype) void { _ = value; }
fn specialized(value: i32) i32 { return value; }
pub fn split(amount: i32, label: []const u8) void { _ = specialized(amount); utility(label); }
pub fn together(a: i32, b: i32) i32 { return specialized(a + b); }
pub fn transform(options: Options, flag: bool) i32 { const amount = options.amount + 1; if (flag) { utility(amount); } return options.amount; }
pub fn extra() void { utility(0); }
`;
let snapshot: any, report: any, baseline: string;
beforeAll(() => {
  writeFileSync(join(root, "main.ts"), tsSource);
  writeFileSync(join(root, "main.zig"), zigSource);
  writeFileSync(
    join(root, "tsconfig.json"),
    JSON.stringify({ compilerOptions: { strict: true, target: "ES2022" }, files: ["main.ts"] }),
  );
  snapshot = ok("scan", root, "--language", "both", "--project", "phase3", "--revision", "before");
  validateSnapshot(snapshot);
  baseline = file(snapshot);
  report = ok("analyze", baseline);
}, 30000);
function subject(name: string, language = "typescript", kind = "function") {
  const s = snapshot.document.subjects.find(
    (s) => s.key.name === name && s.key.language === language && s.key.kind === kind,
  );
  expect(s, name).toBeDefined();
  return s;
}
function relations(from: string, kind: string) {
  return snapshot.document.relations.filter((r) => r.from === from && r.kind === kind);
}
it("captures equivalent value, control, call, return, property and transformation relationships", () => {
  for (const language of ["typescript", "zig"]) {
    const flag = subject("transform[declaration:0]/flag", language, "parameter");
    const options = subject("transform[declaration:0]/options", language, "parameter");
    const field = subject("Options[declaration:0]/amount", language, "property");
    const amount = subject("transform[declaration:0]/amount", language, "value");
    expect(relations(flag.id, "controls")).toHaveLength(1);
    expect(relations(options.id, "uses_property").some((r) => r.target.subject === field.id)).toBe(
      true,
    );
    expect(relations(field.id, "returns")).toHaveLength(1);
    expect(relations(options.id, "returns")).toHaveLength(1);
    expect(relations(field.id, "input")).toHaveLength(1);
    expect(relations(field.id, "flows_to").some((r) => r.target.subject === amount.id)).toBe(true);
    expect(relations(amount.id, "argument")).toHaveLength(1);
    expect(
      snapshot.document.relations.some(
        (r) => r.kind === "output" && r.target.subject === amount.id,
      ),
    ).toBe(true);
    expect(relations(subject("transform", language).id, "belongs_to")).toHaveLength(1);
  }
  expect(
    snapshot.document.relations.some(
      (r) => r.kind === "flow_unknown" && r.target.status === "unresolved",
    ),
  ).toBe(true);
  expect(
    snapshot.document.observations
      .filter((o) => o.metric === "file.flow")
      .every((o) => o.measurement.status === "unsupported"),
  ).toBe(true);
});
it("creates stable hypotheses with navigable aggregate and source evidence", () => {
  for (const language of ["typescript", "zig"]) {
    const f = report.findings.find((f) => f.subject === subject("split", language).id);
    expect(f).toMatchObject({
      category: "hypothesis",
      severity: "info",
      status: "open",
      kind: "responsibility_split",
      generator: "bt-analysis/1",
    });
    expect(f.id).toMatch(/^fnd_[0-9a-f]{64}$/u);
    expect(report.findings.some((f) => f.subject === subject("together", language).id)).toBe(false);
    const aggregate = report.evidence.find((e) => e.id === f.evidence[0]);
    expect(aggregate.origin).toBe("inference");
    expect(aggregate.parents).toHaveLength(2);
    for (const id of aggregate.parents) {
      const leaf = report.evidence.find((e) => e.id === id);
      expect(leaf.origin).toBe("code");
      expect(leaf.relations.length).toBeGreaterThan(0);
      expect(leaf.observations.length).toBeGreaterThan(0);
      expect(
        leaf.sources.every((s) => s.path === `main.${language === "zig" ? "zig" : "ts"}`),
      ).toBe(true);
      for (const id of leaf.relations)
        expect(snapshot.document.relations.some((r) => r.id === id)).toBe(true);
    }
  }
  expect(ok("analyze", baseline)).toEqual(report);
});
it("retains raw caller inputs and explains specialized versus common targets", () => {
  for (const language of ["typescript", "zig"]) {
    const caller = subject("split", language).id;
    const utility = report.significance.find(
      (s) => s.caller === caller && s.callee === subject("utility", language).id,
    );
    const specialized = report.significance.find(
      (s) => s.caller === caller && s.callee === subject("specialized", language).id,
    );
    expect(utility.callee_in_degree).toBe(3);
    expect(specialized.callee_in_degree).toBe(2);
    expect(specialized.score).toBeGreaterThan(utility.score);
    for (const s of [utility, specialized]) {
      expect(s.caller_out_degree).toBe(2);
      expect(s.local_share).toBe(0.5);
      expect(s.edge_count).toBe(1);
      expect(s.score).toBeCloseTo(
        ((1 / s.caller_out_degree) *
          (Math.log((s.function_population + 1) / (s.callee_in_degree + 1)) + 1)) /
          (Math.log(s.function_population + 1) + 1),
        12,
      );
      expect(s.score).toBeGreaterThan(0);
      expect(s.score).toBeLessThanOrEqual(1);
    }
  }
});
it.each(["open", "confirmed", "false_positive", "accepted_risk", "fixed", "ignored", "deferred"])(
  "persists %s review decisions through revision changes",
  (status) => {
    const f = report.findings.find((f) => f.subject === subject("split").id);
    const reviewed = ok(
      "review",
      file(report),
      "--finding",
      f.id,
      "--status",
      status,
      "--note",
      "Reviewed source and incomplete flow",
    );
    const fresh = ok(
      "scan",
      root,
      "--language",
      "both",
      "--project",
      "phase3",
      "--revision",
      "next",
    );
    const next = ok("analyze", file(fresh), "--previous", file(reviewed));
    expect(next.findings.find((finding) => finding.id === f.id)).toMatchObject({
      status,
      reviewed_revision: "before",
    });
    expect(next.reviews).toEqual(reviewed.reviews);
  },
  30000,
);
it("keeps absent review decisions without declaring them fixed and reattaches on recurrence", () => {
  const f = report.findings.find((f) => f.subject === subject("split").id);
  const reviewed = ok(
    "review",
    file(report),
    "--finding",
    f.id,
    "--status",
    "deferred",
    "--note",
    "Need alias evidence",
  );
  const empty = {
    ...snapshot,
    files: [],
    diagnostics: [],
    document: { ...snapshot.document, subjects: [], symbols: [], observations: [], relations: [] },
  };
  const absent = ok("analyze", file(empty), "--previous", file(reviewed));
  expect(absent.findings).toEqual([]);
  expect(absent.significance).toEqual([]);
  expect(absent.reviews).toEqual(reviewed.reviews);
  const restored = ok("analyze", baseline, "--previous", file(absent));
  expect(restored.findings.find((row) => row.id === f.id).status).toBe("deferred");
});
it("rejects invalid reports, reviews, and mismatched projects without replacing output", () => {
  const output = join(root, "keep.json");
  writeFileSync(output, "keep");
  const corrupt = structuredClone(report);
  corrupt.evidence[0].relations = ["rel_" + "0".repeat(64)];
  expect(cli("analyze", baseline, "--previous", file(corrupt), "--out", output).status).toBe(5);
  expect(readFileSync(output, "utf8")).toBe("keep");
  const missing = structuredClone(report);
  delete missing.findings[0].challenges;
  expect(
    cli(
      "review",
      file(missing),
      "--finding",
      report.findings[0].id,
      "--status",
      "fixed",
      "--note",
      "done",
    ).status,
  ).toBe(5);
  expect(
    cli(
      "review",
      file(report),
      "--finding",
      report.findings[0].id,
      "--status",
      "bad",
      "--note",
      "reason",
    ).status,
  ).toBe(2);
  expect(
    cli(
      "review",
      file(report),
      "--finding",
      "fnd_" + "0".repeat(64),
      "--status",
      "fixed",
      "--note",
      "reason",
    ).status,
  ).toBe(5);
  const different = {
    ...snapshot,
    project: "other",
    files: [],
    diagnostics: [],
    document: { ...snapshot.document, subjects: [], symbols: [], observations: [], relations: [] },
  };
  expect(cli("analyze", file(different), "--previous", file(report)).status).toBe(5);
});
it("rejects significance input tampering even when the forged formula is internally consistent", () => {
  const forged = structuredClone(report);
  const score = forged.significance[0];
  score.function_population += 10;
  score.inverse_prevalence =
    Math.log((score.function_population + 1) / (score.callee_in_degree + 1)) + 1;
  score.normalization = Math.log(score.function_population + 1) + 1;
  score.score = (score.local_share * score.inverse_prevalence) / score.normalization;
  expect(cli("analyze", baseline, "--previous", file(forged)).status).toBe(5);
});
