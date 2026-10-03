import { afterAll, describe, expect, it } from "vitest";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { encodeDocument, validateDocument } from "../packages/transport/src/index.js";
import { invalidCases, makeFixture } from "../scripts/fixture.mjs";

const dir = mkdtempSync(join(tmpdir(), "twinlens-test-"));
afterAll(() => rmSync(dir, { recursive: true, force: true }));
let serial = 0;
function file(contents: string) {
  const path = join(dir, `${serial++}.json`);
  writeFileSync(path, contents);
  return path;
}
function cli(...args: string[]) {
  const result = spawnSync("./zig-out/bin/twinlens", args, { encoding: "utf8", timeout: 10000 });
  if (result.error) throw result.error;
  return result;
}
function failure(args: string[], status: number) {
  const result = cli(...args);
  expect(result.status, result.stderr).toBe(status);
  expect(result.stdout).toBe("");
  expect(JSON.parse(result.stderr)).toEqual({
    code: expect.any(String),
    message: expect.any(String),
    path: expect.toSatisfy((v) => v === null || typeof v === "string"),
  });
  return JSON.parse(result.stderr);
}

describe("TypeScript → Zig → JSON boundary", () => {
  it("round trips every field including Unicode IDs, unknown values, and unresolved relations", () => {
    const input = file(encodeDocument(makeFixture()));
    const result = cli("import", input);
    expect(result.status, result.stderr).toBe(0);
    expect(result.stderr).toBe("");
    const restored = JSON.parse(result.stdout);
    validateDocument(restored);
    expect(restored).toEqual(makeFixture());
    const second = cli("import", file(result.stdout));
    expect(second.status, second.stderr).toBe(0);
    expect(second.stdout).toBe(result.stdout);
  });
  it("imports the checked-in fixture", () => {
    const result = cli("import", "fixtures/seed-v1.json");
    expect(result.status, result.stderr).toBe(0);
    expect(JSON.parse(result.stdout)).toEqual(
      JSON.parse(readFileSync("fixtures/seed-v1.json", "utf8")),
    );
  });
  for (const [name, mutate] of invalidCases) {
    it(`rejects ${name} in Zig as well as TypeScript`, () => {
      const doc = makeFixture();
      mutate(doc);
      failure(["import", file(JSON.stringify(doc))], 5);
    });
  }
  it.each(["{", "null", "[]", '{"schema_version":1,"schema_version":1}'])(
    "rejects malformed or invalid top-level input %s",
    (raw) => {
      failure(["import", file(raw)], 5);
    },
  );
  it("filters observations by subject and metric, retaining zero", () => {
    const doc = makeFixture();
    const result = cli(
      "query",
      "fixtures/seed-v1.json",
      "--subject",
      doc.subjects[0].id,
      "--metric",
      "function.args.count",
    );
    expect(result.status, result.stderr).toBe(0);
    expect(JSON.parse(result.stdout)).toEqual({
      schema_version: 1,
      revision: doc.revision,
      observations: [doc.observations[0]],
    });
    expect(
      JSON.parse(cli("query", "fixtures/seed-v1.json", "--metric", "absent").stdout).observations,
    ).toEqual([]);
  });
});

describe("CLI diagnostics and configuration", () => {
  it("provides help and version", () => {
    expect(cli("--help").stdout).toContain("import FILE");
    expect(cli().status).toBe(0);
    expect(cli("--version").stdout).toContain("0.1.0");
  });
  it.each([
    ["unknown"],
    ["import"],
    ["query", "a.json", "--metric"],
    ["--config"],
    ["import", "a.json", "--wat"],
    ["query", "a.json", "--subject", "invalid"],
  ])("rejects invalid arguments %j", (...args) => {
    failure(args, 2);
  });
  it("reports unreadable input and config paths", () => {
    expect(failure(["import", join(dir, "absent")], 4).path).toContain("absent");
    failure(["--config", join(dir, "absent-config"), "import", "fixtures/seed-v1.json"], 4);
  });
  it("loads valid config and enforces input limits", () => {
    expect(
      cli("--config", file('{"max_input_bytes":16384}'), "import", "fixtures/seed-v1.json").status,
    ).toBe(0);
    failure(["--config", file('{"max_input_bytes":16}'), "import", "fixtures/seed-v1.json"], 4);
  });
  it.each([
    "{",
    '{"max_input_bytes":0}',
    '{"max_input_bytes":-1}',
    '{"max_input_bytes":"10000"}',
    '{"max_input_bytes":268435457}',
    '{"unexpected":1}',
  ])("rejects invalid config %s", (config) => {
    failure(["--config", file(config), "import", "fixtures/seed-v1.json"], 2);
  });
  it("reports missing TypeScript configuration without claiming a successful scan", () => {
    expect(failure(["scan", "src"], 4).code).toBe("AdapterFailed");
  });
});
