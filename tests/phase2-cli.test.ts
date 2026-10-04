import { afterAll, expect, it } from "vitest";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";
import { validateSnapshot, type Snapshot } from "../packages/transport/src/index.js";
const roots: string[] = [];
afterAll(() => roots.forEach((p) => rmSync(p, { recursive: true, force: true })));
function project(files: Record<string, string>) {
  const root = mkdtempSync(join(tmpdir(), "twinlens-zig-"));
  roots.push(root);
  for (const [path, source] of Object.entries(files)) {
    mkdirSync(join(root, path, ".."), { recursive: true });
    writeFileSync(join(root, path), source);
  }
  return root;
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
function scan(root: string, language = "zig"): Snapshot {
  const s = ok("scan", root, "--project", "fixture", "--language", language);
  validateSnapshot(s);
  return s;
}
function subject(s: Snapshot, name: string, kind = "function") {
  const row = s.document.subjects.find((r) => r.key.name === name && r.key.kind === kind);
  expect(row, `${kind} ${name}`).toBeDefined();
  return row!;
}
function metric(s: Snapshot, name: string, metric: string, kind = "function") {
  const id = subject(s, name, kind).id;
  const o = s.document.observations.find((r) => r.subject === id && r.metric === metric);
  expect(o, metric).toBeDefined();
  return o!.measurement;
}
const zig = `// Unicode before declarations: λ 🌿
const lib = @import("lib.zig");
const Options = struct { count: i32, ready: bool };
fn target(x: i32) i32 { return x; }
pub fn scan(options: *Options, callback: anytype) i32 {
    var value: i32 = options.count;
    value += 1;
    options.count = value;
    if (options.ready) { value = target(value); }
    _ = lib.helper(value);
    callback(value);
    return value;
}
extern fn external(x: i32) void;
`;
it("extracts declarations, UTF-8 spans, calls and common metrics into valid deterministic IR", () => {
  const root = project({ "main.zig": zig, "lib.zig": "pub fn helper(x: i32) i32 { return x; }" });
  const s = scan(root);
  expect(scan(root)).toEqual(s);
  expect(s.diagnostics).toEqual([]);
  expect(s.files.map((f) => f.path)).toEqual(["lib.zig", "main.zig"]);
  expect(metric(s, "scan", "function.args.count").value).toBe(2);
  expect(metric(s, "scan", "function.branch.count").value).toBe(1);
  expect(metric(s, "scan", "function.lines").value).toBe(9);
  expect(metric(s, "scan", "function.callees").value).toBe(2);
  expect(metric(s, "target", "function.callers").value).toBe(1);
  expect(metric(s, "scan", "function.calls.unresolved.count").value).toBe(1);
  expect(metric(s, "external", "function.branch.count").status).toBe("unknown");
  expect(
    metric(s, "scan[declaration:0]/options", "function.parameter.property_count", "parameter")
      .value,
  ).toBe(2);
  expect(
    metric(s, "scan[declaration:0]/callback", "function.parameter.property_count", "parameter")
      .status,
  ).toBe("unknown");
  expect(metric(s, "scan[declaration:0]/value", "value.write_count", "value").value).toBe(3);
  expect(metric(s, "Options[declaration:0]/count", "property.read_count", "property").value).toBe(
    1,
  );
  expect(metric(s, "Options[declaration:0]/count", "property.write_count", "property").value).toBe(
    1,
  );
  const row = subject(s, "scan");
  expect(row.source.span.start).toBe(Buffer.byteLength(zig.slice(0, zig.indexOf("pub fn scan"))));
  expect(Buffer.from(zig).subarray(row.source.span.start, row.source.span.end).toString()).toMatch(
    /^pub fn scan.*\n[\s\S]*\}$/u,
  );
  expect(s.document.observations.some((o) => o.measurement.status === "unsupported")).toBe(true);
});
it("resolves lexical scopes and captures without binding siblings or nested functions", () => {
  const s = scan(
    project({
      "main.zig": `
fn outer(input: ?i32) void {
    var value: i32 = 0;
    { var value: i32 = 1; _ = value; }
    { var sibling: i32 = 2; _ = sibling; }
    _ = value;
    if (input) |value| { _ = value; }
    const Nested = struct { fn inner() void { if (true) {} } };
    Nested.inner();
    missing();
}`,
    }),
  );
  expect(metric(s, "outer", "function.branch.count").value).toBe(1);
  expect(
    metric(s, "outer[declaration:0]/Nested[declaration:0]/inner", "function.branch.count").value,
  ).toBe(1);
  expect(metric(s, "outer", "function.callees").value).toBe(1);
  const values = s.document.subjects.filter(
    (r) => r.key.kind === "value" && r.key.name === "outer[declaration:0]/value",
  );
  expect(values).toHaveLength(3);
  expect(
    values.map(
      (v) =>
        s.document.observations.find((o) => o.subject === v.id && o.metric === "value.read_count")!
          .measurement.value,
    ),
  ).toEqual([1, 1, 1]);
});
it("retains malformed files and diagnostics without inventing recovered measurements", () => {
  const s = scan(project({ "bad.zig": "fn broken( {", "ok.zig": "fn ok() void {}" }));
  expect(s.diagnostics[0]).toMatchObject({ category: "error", path: "bad.zig" });
  expect(
    s.document.subjects.filter((r) => r.key.path === "bad.zig").map((r) => r.key.kind),
  ).toEqual(["file"]);
  expect(s.document.observations.find((o) => o.source.path === "bad.zig")!.measurement.status).toBe(
    "unsupported",
  );
});
it("bounds discovery, does not follow symlinks, and supports a single input file", () => {
  const root = project({
    "main.zig": "fn main() void {}",
    "tmp/skip.zig": "invalid",
    ".hidden/skip.zig": "invalid",
    "node_modules/skip.zig": "invalid",
  });
  symlinkSync(root, join(root, "cycle"), "dir");
  expect(scan(root).files.map((f) => f.path)).toEqual(["main.zig"]);
  expect(scan(join(root, "main.zig")).files.map((f) => f.path)).toEqual(["main.zig"]);
  expect(cli("scan", root, "--language", "rust").status).toBe(2);
  expect(cli("query", "x", "--language", "zig").status).toBe(2);
});
it("combines equivalent language fixtures and preserves source-linked revision diffs", () => {
  const root = project({
    "main.zig":
      "fn target(x: i32) i32 { return x; }\npub fn run(x: i32) i32 { if (x > 0) { return target(x); } return 0; }\n",
    "main.ts":
      "function target(x: number): number { return x; }\nexport function run(x: number): number { if (x > 0) { return target(x); } return 0; }\n",
    "tsconfig.json": JSON.stringify({
      compilerOptions: { strict: true, target: "ES2022" },
      files: ["main.ts"],
    }),
  });
  const s = scan(root, "both");
  expect(new Set(s.document.subjects.map((r) => r.key.language))).toEqual(
    new Set(["zig", "typescript"]),
  );
  for (const name of ["target", "run"])
    for (const metricName of [
      "function.args.count",
      "function.lines",
      "function.branch.count",
      "function.callers",
      "function.callees",
    ]) {
      const ids = s.document.subjects
        .filter((r) => r.key.name === name && r.key.kind === "function")
        .map((r) => r.id);
      const obs = s.document.observations.filter(
        (o) => ids.includes(o.subject) && o.metric === metricName,
      );
      expect(obs).toHaveLength(2);
      expect(obs[0].measurement).toEqual(obs[1].measurement);
    }
  expect(scan(join(root, "tsconfig.json"), "both")).toEqual(s);
  const baseline = join(root, "before.json");
  writeFileSync(baseline, JSON.stringify(s));
  for (const [path, before, after] of [
    ["main.zig", "run(x: i32)", "run(x: i32, extra: bool)"],
    ["main.ts", "run(x: number)", "run(x: number, extra?: boolean)"],
  ])
    writeFileSync(join(root, path), readFileSync(join(root, path), "utf8").replace(before, after));
  const afterPath = join(root, "after.json");
  ok(
    "scan",
    root,
    "--language",
    "both",
    "--project",
    "fixture",
    "--revision",
    "after",
    "--out",
    afterPath,
  );
  const after = JSON.parse(readFileSync(afterPath, "utf8"));
  validateSnapshot(after);
  expect(after.document.revision).toBe("after");
  const diff = ok("diff", baseline, afterPath);
  const changed = diff.observations.changed.filter(
    (c) => c.before.metric === "function.args.count",
  );
  expect(changed).toHaveLength(2);
  expect(new Set(changed.map((c) => c.before.source.language))).toEqual(
    new Set(["zig", "typescript"]),
  );
  for (const c of changed) {
    expect(c.before.measurement.value).toBe(1);
    expect(c.after.measurement.value).toBe(2);
  }
  expect(ok("query", afterPath, "--relations", "--relation", "calls").relations).toHaveLength(2);
}, 30000);
it("counts property initialization and destructuring without claiming indirect writes", () => {
  const s = scan(
    project({
      "main.zig": `
const Obj = struct { field: i32 = 0 };
fn f() void {
    var obj: Obj = .{ .field = 2 };
    var first: i32 = 0;
    var second: i32 = 0;
    first, second = .{ 1, 2 };
    obj.field += first;
    const ptr = &second;
    ptr.* = 3;
}`,
    }),
  );
  expect(metric(s, "Obj[declaration:0]/field", "property.write_count", "property").value).toBe(3);
  expect(metric(s, "Obj[declaration:0]/field", "property.read_count", "property").value).toBe(1);
  expect(metric(s, "f[declaration:0]/first", "value.write_count", "value").value).toBe(2);
  expect(metric(s, "f[declaration:0]/second", "value.write_count", "value").value).toBe(2);
  expect(metric(s, "f[declaration:0]/ptr", "value.write_count", "value").value).toBe(1);
  expect(s.coverage.unresolved_accesses).toBeGreaterThan(0);
});
it("keeps variadic and tuple shapes unknown and records generic/external calls", () => {
  const s = scan(
    project({
      "main.zig": `
const Tuple = struct { i32, bool };
extern fn c_log(format: [*:0]const u8, ...) void;
fn generic(comptime T: type, value: T, tuple: Tuple) void {
    @import("unavailable").run();
    _ = value;
    _ = tuple;
}`,
    }),
  );
  expect(metric(s, "c_log", "function.args.count").status).toBe("unknown");
  expect(metric(s, "generic", "function.args.count").value).toBe(3);
  expect(
    metric(s, "generic[declaration:0]/tuple", "function.parameter.property_count", "parameter")
      .status,
  ).toBe("unknown");
  expect(metric(s, "generic", "function.calls.unresolved.count").value).toBe(2);
});
it("captures error handlers and loop payloads once and counts syntax branches", () => {
  const s = scan(
    project({
      "main.zig": `
fn f(input: ?i32, result: anyerror!i32, list: []i32) void {
    while (input) |item| : (_ = item) { _ = item; }
    for (list, 0..) |item, index| { _ = item; _ = index; }
    _ = result catch |failure| blk: { _ = failure; break :blk 0; };
    errdefer |failure| { _ = failure; }
    switch (list.len) { 0 => {}, 1, 2 => {}, else => {} }
    if (input != null and list.len > 0 or false) {}
    _ = input orelse 0;
}`,
    }),
  );
  expect(s.diagnostics).toEqual([]);
  expect(metric(s, "f", "function.branch.count").value).toBe(9);
  const items = s.document.subjects.filter((r) => r.key.name === "f[declaration:0]/item");
  expect(items).toHaveLength(2);
  expect(
    items
      .map(
        (i) =>
          s.document.observations.find(
            (o) => o.subject === i.id && o.metric === "value.read_count",
          )!.measurement.value,
      )
      .sort(),
  ).toEqual([1, 2]);
  const errors = s.document.subjects.filter((r) => r.key.name === "f[declaration:0]/failure");
  expect(errors).toHaveLength(2);
  expect(
    errors.every(
      (i) =>
        s.document.observations.find((o) => o.subject === i.id && o.metric === "value.read_count")!
          .measurement.value === 1,
    ),
  ).toBe(true);
});
