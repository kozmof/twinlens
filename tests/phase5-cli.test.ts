import { afterAll, beforeAll, expect, it } from "vitest";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";
import { claimId, scalar } from "../packages/transport/src/index.js";
import { createExplorationFixture } from "../scripts/exploration-fixture.mjs";
const directory = mkdtempSync(join(tmpdir(), "twinlens-phase5-"));
afterAll(() => rmSync(directory, { recursive: true, force: true }));
let serial = 0;
function file(value: unknown) {
  const path = join(directory, `input-${serial++}.json`);
  writeFileSync(path, JSON.stringify(value));
  return path;
}
const config = file({ max_input_bytes: 134217728 });
function invoke(...args: string[]) {
  const result = spawnSync("./zig-out/bin/twinlens", ["--config", config, ...args], {
    encoding: "utf8",
    timeout: 90000,
    maxBuffer: 128 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  return result;
}
function cli(...args: string[]) {
  const result = invoke(...args);
  expect(result.status, result.stderr).toBe(0);
  return result.stdout ? JSON.parse(result.stdout) : undefined;
}
let model: any, explored: any, specification: any, generated: any, origin: any;
beforeAll(() => {
  const historySpec = cli("compile", "specs/store-history.tsp", "--project", "twinlens-history");
  model = createExplorationFixture(join(directory, "world"), cli, historySpec);
  explored = cli("explore", file(model));
  const path = join(directory, "oracle.tsp");
  writeFileSync(
    path,
    `import ${JSON.stringify(resolve("packages/typespec/lib/main.tsp"))};\nusing Twinlens;\n@forbid("bad", ${JSON.stringify(JSON.stringify({ fact: "bad" }))}) op run(): void;\n@status("deferred", "Policy is not supplied") op later(): void;\n`,
  );
  specification = cli("compile", path, "--project", "oracle");
  generated = cli("challenges", file(specification));
  origin = specification.claims.find((claim) => claim.name === "bad").source;
}, 90000);
function request() {
  const challenge = generated.challenges.find((challenge) => challenge.constraints.length);
  const effect = (name: string, kind: string) => ({
    name,
    kind,
    subject: null,
    value: null,
    source: origin,
    origin: "runtime",
  });
  return {
    oracle_version: 1,
    challenge,
    response: {
      operation: challenge.target_operation,
      origin: "runtime",
      coverage: "complete",
      effects: [
        effect("result", "return_value"),
        effect("store", "state_change"),
        effect("observations", "observation"),
      ],
      evidence: {
        input_version: 1,
        project: "oracle",
        facts: [
          {
            name: "bad",
            status: "known",
            value: scalar(false),
            reason: null,
            source: origin,
            origin: "trace",
          },
        ],
        graph: null,
        coverage: "absent",
      },
    },
    expectations: ["result", "store", "observations"].map((name, index) => ({
      name,
      kind: ["return_value", "state_change", "observation"][index],
      classification: "required",
      source: origin,
    })),
    policy: "enforced",
  } as any;
}
function judge(value = request()) {
  return cli("judge", file(specification), file(value));
}
it("generates stable suspicious-case questions from forbidden and missing constraints", () => {
  expect(generated).toEqual(cli("challenges", file(specification)));
  const forbidden = generated.challenges.find((challenge) => challenge.constraints.length);
  expect(forbidden).toMatchObject({
    expectation: "forbidden",
    execution: "unknown",
    assumptions: [],
  });
  expect(forbidden.generated_from.claim).toMatch(/^clm_/);
  expect(forbidden.generated_from.evidence).toHaveLength(1);
  const missing = generated.challenges.find(
    (challenge) => challenge.target_operation && !challenge.constraints.length,
  );
  expect(missing.expectation).toBe("unknown");
  expect(forbidden.outcome).toBeUndefined();
});
it("requires simultaneous scan effects instead of accepting a return value alone", () => {
  const accepted = judge();
  expect(accepted.outcome).toBe("acceptable");
  expect(accepted.effects).toHaveLength(3);
  const missing = request();
  missing.response.effects.pop();
  expect(judge(missing).outcome).toBe("defect");
  missing.response.coverage = "partial";
  expect(judge(missing).outcome).toBe("unknown");
});
it("does not infer missing required effects from an unknown effect inventory", () => {
  const value = request();
  value.response.effects.pop();
  value.response.effects.push({
    name: "opaque-runtime",
    kind: "unknown_effect",
    subject: null,
    value: null,
    source: origin,
    origin: "runtime",
  });
  const result = judge(value);
  expect(result.outcome).toBe("unknown");
  expect(result.effects.at(-1).outcome).toBe("unknown");
});
it.each([
  "return_value",
  "state_change",
  "database_change",
  "log",
  "event",
  "observation",
  "external_effect",
])("retains simultaneous %s response provenance", (kind) => {
  const value = request();
  value.response.effects.push({
    name: "additional",
    kind,
    subject: null,
    value: scalar("observed"),
    source: origin,
    origin: "test",
  });
  expect(judge(value).response.effects.at(-1)).toMatchObject({
    name: "additional",
    kind,
    origin: "test",
    value: scalar("observed"),
  });
});
it("distinguishes forbidden, possible and unknown effect expectations", () => {
  const value = request();
  value.expectations[0].classification = "forbidden";
  expect(judge(value).outcome).toBe("defect");
  value.expectations[0].classification = "possible";
  value.response.effects.shift();
  expect(judge(value).outcome).toBe("acceptable");
  value.expectations[0].classification = "unknown";
  expect(judge(value).outcome).toBe("unknown");
});
it("retains policy-dependent and missing-evidence outcomes with governing constraints", () => {
  const value = request();
  value.response.evidence.facts[0].value = scalar(true);
  const failed = judge(value);
  expect(failed.outcome).toBe("defect");
  expect(failed.constraints.results[0]).toMatchObject({
    outcome: "violated",
    constraint: { name: "bad" },
  });
  value.policy = "domain_dependent";
  expect(judge(value).outcome).toBe("domain_dependent");
  value.policy = "unknown";
  expect(judge(value).outcome).toBe("unknown");
  value.policy = "enforced";
  value.response.evidence.facts = [];
  expect(judge(value).outcome).toBe("unknown");
});
it("rejects malformed response contracts before judgment", () => {
  const invalid = [
    (value) => {
      value.response.operation = "sub_" + "0".repeat(64);
    },
    (value) => {
      value.response.evidence.project = "different";
    },
    (value) => {
      value.expectations.push(value.expectations[0]);
    },
    (value) => {
      value.response.effects.push(value.response.effects[0]);
    },
    (value) => {
      value.challenge.constraints.push(value.challenge.constraints[0]);
    },
    (value) => {
      value.challenge.generated_from.finding = "invalid";
    },
  ];
  for (const change of invalid) {
    const value = request();
    change(value);
    expect(invoke("judge", file(specification), file(value)).status).toBe(5);
  }
});
it("explores clean and dirty reachable states and checks every transition", () => {
  expect(explored.coverage.stop).toBe("exhausted");
  expect(explored.coverage.initial_states).toBe(2);
  expect(explored.counterexamples).toEqual([]);
  expect(explored.unknown_transitions).toEqual([]);
  expect(explored.states.some((state) => state.freshness === "stale")).toBe(true);
  expect(
    explored.transitions.every(
      (transition) => transition.judgment.constraints.results.length === 6,
    ),
  ).toBe(true);
  const scan = explored.transitions.find((transition) => transition.action.kind === "scan");
  expect(scan.judgment.response.effects.map((effect) => effect.kind)).toEqual([
    "return_value",
    "state_change",
    "event",
    "observation",
  ]);
  expect(scan.event.affected_values.map((value) => value.phase)).toEqual([
    "old",
    "new",
    "current",
    "historical",
  ]);
  expect(scan.event).toMatchObject({
    actor: "finite-store-explorer",
    operation: model.operation,
    clock: "logical",
  });
});
function replay(actions: any[], adapter = "native_store", initial_world = 0) {
  return cli(
    "replay",
    file({
      replay_version: 1,
      model: { ...model, adapter },
      trace: {
        model_digest: explored.model_digest,
        initial_world,
        actions,
        failing_transition: null,
      },
    }),
  );
}
it("detects and replays a stale-store fault and verifies the corrected adapter", () => {
  const negativeModel = { ...model, adapter: "test_stale_delete" };
  const negative = cli("explore", file(negativeModel));
  expect(negative.counterexamples.length).toBeGreaterThan(0);
  const trace = negative.counterexamples[0];
  const failed = cli("replay", file({ replay_version: 1, model: negativeModel, trace }));
  expect(failed.transitions.at(-1).judgment.outcome).toBe("defect");
  const corrected = cli("replay", file({ replay_version: 1, model, trace }));
  expect(corrected.counterexamples).toEqual([]);
  expect(corrected.coverage.stop).toBe("replay_complete");
  expect(corrected.transitions.at(-1).judgment.outcome).toBe("acceptable");
}, 90000);
it("preserves identities while replacing measurements and deleting the final file", () => {
  const report = replay([
    { kind: "add", path: "value.zig", world: 1 },
    { kind: "scan", path: null, world: 1 },
    { kind: "modify", path: "value.zig", world: 2 },
    { kind: "rescan", path: null, world: 2 },
    { kind: "delete", path: "value.zig", world: 0 },
    { kind: "rescan", path: null, world: 0 },
  ]);
  expect(report.counterexamples).toEqual([]);
  const before = report.states[2].document,
    after = report.states[4].document;
  const subject = before.subjects.find(
    (subject) => subject.key.kind === "function" && subject.key.name === "value",
  );
  expect(after.subjects.find((candidate) => candidate.key.name === "value").id).toBe(subject.id);
  expect(
    before.observations.find(
      (observation) =>
        observation.subject === subject.id && observation.metric === "function.branch.count",
    ).measurement.value,
  ).toBe(0);
  expect(
    after.observations.find(
      (observation) =>
        observation.subject === subject.id && observation.metric === "function.branch.count",
    ).measurement.value,
  ).toBe(1);
  expect(report.states.at(-1).document).toMatchObject({
    subjects: [],
    symbols: [],
    observations: [],
    relations: [],
  });
});
it("refreshes changed call relations and removes renamed symbols", () => {
  const calls = replay(
    [
      { kind: "add", path: "caller.zig", world: 3 },
      { kind: "scan", path: null, world: 3 },
      { kind: "delete", path: "value.zig", world: 5 },
      { kind: "rescan", path: null, world: 5 },
    ],
    "native_store",
    1,
  );
  expect(
    calls.states[2].document.relations.some(
      (relation) => relation.kind === "calls" && relation.target.status === "resolved",
    ),
  ).toBe(true);
  expect(
    calls.states[4].document.relations.some(
      (relation) => relation.kind === "calls" && relation.target.status === "unresolved",
    ),
  ).toBe(true);
  expect(calls.counterexamples).toEqual([]);
  const renamed = replay(
    [
      { kind: "scan", path: null, world: 1 },
      { kind: "modify", path: "value.zig", world: 4 },
      { kind: "rescan", path: null, world: 4 },
    ],
    "native_store",
    1,
  );
  expect(renamed.states.at(-1).document.symbols.some((symbol) => symbol.name === "value")).toBe(
    false,
  );
  expect(
    renamed.states.at(-1).document.symbols.some((symbol) => symbol.name === "replacement"),
  ).toBe(true);
});
it.each([
  ["max_depth", 1, "depth_limit"],
  ["max_executions", 1, "execution_limit"],
  ["max_objects", 1, "object_limit"],
])("reports exhausted %s without claiming universal success", (bound, value, stop) => {
  const result = cli("explore", file({ ...model, bounds: { ...model.bounds, [bound]: value } }));
  expect(result.coverage.stop).toBe(stop);
  expect(result.coverage.scope).toContain("No universal proof");
  if (bound === "max_objects") expect(result.coverage.excluded_worlds).toContain(3);
});
it("rejects stale replay models, invalid actions, and invalid bounds", () => {
  const trace = {
    model_digest: "0".repeat(64),
    initial_world: 0,
    actions: [],
    failing_transition: null,
  };
  expect(invoke("replay", file({ replay_version: 1, model, trace })).status).toBe(5);
  trace.model_digest = explored.model_digest;
  trace.actions = [{ kind: "delete", path: "missing.zig", world: 0 }] as any;
  expect(invoke("replay", file({ replay_version: 1, model, trace })).status).toBe(5);
  expect(
    invoke("explore", file({ ...model, bounds: { ...model.bounds, max_time_ms: 0 } })).status,
  ).toBe(5);
  expect(invoke("explore", file({ ...model, initial_states: [99] })).status).toBe(5);
});
it("emits an atomic persisted exploration report and scans empty inventories", () => {
  const output = join(directory, "report.json");
  expect(
    cli(
      "explore",
      file({ ...model, bounds: { ...model.bounds, max_executions: 1 } }),
      "--out",
      output,
    ),
  ).toBeUndefined();
  expect(JSON.parse(readFileSync(output, "utf8")).coverage.executions).toBe(1);
  const empty = join(directory, "empty");
  mkdirSync(empty);
  expect(cli("scan", empty, "--language", "zig").files).toEqual([]);
});

it.each([
  ["opaque", "unknown"],
  ["uninterpreted", "unknown"],
  ["axiomatized", "simulation"],
  ["mocked", "simulation"],
  ["executable", "runtime_execution"],
  ["observed", "runtime_execution"],
])("classifies declared %s execution requirements", (mode, execution) => {
  const declared = structuredClone(specification);
  declared.functions.find((operation) => operation.name === "run").mode = mode;
  const questions = cli("challenges", file(declared));
  expect(questions.challenges.find((question) => question.constraints.length).execution).toBe(
    execution,
  );
});

it("deduplicates selected constraints shared by multiple claims", () => {
  const shared = structuredClone(model);
  const claim = {
    ...shared.specification.claims.find((claim) => claim.subject === shared.operation),
    name: "also-required",
  };
  claim.id = claimId(claim.subject, claim.name, claim.kind);
  shared.specification.claims.push(claim);
  shared.bounds.max_executions = 1;
  const report = cli("explore", file(shared));
  expect(report.counterexamples).toEqual([]);
  expect(report.transitions[0].judgment.constraints.results).toHaveLength(7);
});
it("rejects configuration drift and dangling effect subjects", () => {
  const changed = structuredClone(model);
  changed.worlds[1].snapshot.configuration.configs = [
    { path: "build.zig", sha256: "0".repeat(64) },
  ];
  expect(invoke("explore", file(changed)).status).toBe(5);
  const value = request();
  value.response.effects[0].subject = "sub_" + "0".repeat(64);
  expect(invoke("judge", file(specification), file(value)).status).toBe(5);
});
