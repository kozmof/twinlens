import { afterAll, beforeAll, expect, it } from "vitest";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";
import {
  claimId,
  constraintId,
  expression,
  scalar,
  stableId,
  relationId,
} from "../packages/transport/src/index.js";
const directory = mkdtempSync(join(tmpdir(), "twinlens-phase6-"));
afterAll(() => rmSync(directory, { recursive: true, force: true }));
let serial = 0;
function file(value: unknown) {
  const path = join(directory, `input-${serial++}.json`);
  writeFileSync(path, JSON.stringify(value));
  return path;
}
function invoke(...args: string[]) {
  const result = spawnSync("./zig-out/bin/twinlens", args, {
    encoding: "utf8",
    timeout: 60000,
    maxBuffer: 64 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  return result;
}
function cli(...args: string[]) {
  const result = invoke(...args);
  expect(result.status, result.stderr).toBe(0);
  return result.stdout ? JSON.parse(result.stdout) : undefined;
}
function compile(text: string) {
  const path = join(directory, `spec-${serial++}.tsp`);
  writeFileSync(
    path,
    `import ${JSON.stringify(resolve("packages/typespec/lib/main.tsp"))};\nusing Twinlens;\n${text}`,
  );
  return cli("compile", path, "--project", "phase6");
}
const annotation = (kind: string, name: string, value: unknown) =>
  `@${kind}(${JSON.stringify(name)}, ${JSON.stringify(JSON.stringify(value))})`;
let base: any, snapshot: any, source: any, perspectives: any;
beforeAll(() => {
  base = compile(
    `${annotation("invariant", "valid", { ge: [{ fact: "age" }, 18] })} op run(): void;\n@semantics("uninterpreted") op owns(user: string, item: string): boolean;\n@semantics("axiomatized", ${JSON.stringify(JSON.stringify({ fact: "$0" }))}) op identity(value: boolean): boolean;`,
  );
  expect(base.snapshot.diagnostics).toEqual([]);
  base.claims.sort((left, right) => Number(right.name === "valid") - Number(left.name === "valid"));
  source = base.claims[0].source;
  const project = join(directory, "code");
  mkdirSync(project);
  writeFileSync(
    join(project, "main.zig"),
    "pub fn run(value: u32) u32 { if (value > 0) return value; return 0; }\n",
  );
  snapshot = cli("scan", project, "--language", "zig", "--project", "phase6");
  perspectives = compile(`
@perspective("owned") @perspective("credential") @perspective("identity") model Value {}
@perspective("generated") model Generated {}
@perspective("resource") model Resource {}
@perspective("derived") op derived(): string;
@relation("depends_on", Value) @relation("verifies", Value) op reader(): void;
${annotation("invariant", "allowed", { fact: "allowed" })}
@relation("writes", Value) @relation("produces", Generated) @relation("consumes", Resource) op mutate(): void;
${annotation("invariant", "quiet", true)} op quiet(): void;
op unobserved(): void;
`);
  expect(perspectives.snapshot.diagnostics).toEqual([]);
}, 60000);
function input(facts: Record<string, unknown> = {}) {
  return {
    input_version: 1,
    project: "phase6",
    facts: Object.entries(facts).map(([name, value]) => ({
      name,
      status: "known",
      value: scalar(value),
      reason: null,
      source,
      origin: "test",
    })),
    graph: null,
    coverage: "absent",
  };
}
function direct(value: unknown, kind = "invariant") {
  const specification = structuredClone(base);
  const subject = base.claims[0].subject;
  const constraint = {
    id: constraintId(subject, "query"),
    subject,
    name: "query",
    expression: expression(value),
    source,
  };
  specification.constraints = [constraint];
  specification.claims = [
    {
      id: claimId(subject, "query", kind as any),
      subject,
      name: "query",
      kind,
      state: "specified",
      reason: "Fixture",
      constraint: constraint.id,
      source,
    },
  ];
  specification.domains = [];
  return specification;
}
function variable(name: string, sort: string, domain: unknown[] = []) {
  return { name, sort, domain: domain.map(scalar), source };
}
function query(specification = base, variables: any[] = [variable("age", "Int", [17, 18])]) {
  return {
    solver_version: 1,
    specification,
    claim: specification.claims[0].id,
    goal: "violation",
    assumptions: [],
    evidence: input(),
    sorts: [],
    variables,
    functions: [],
    bounds: { timeout_ms: 3000, resource_limit: 1000000, max_objects: 8 },
    simulation: null,
  } as any;
}
function solve(value: any) {
  return cli("solve", file(value));
}
it("compares finite scalar scenarios against the direct evaluator and Z3", () => {
  for (const age of [17, 18, 20]) {
    const value = query(base, [variable("age", "Int", [age])]);
    const result = solve(value);
    const evaluated = cli("evaluate", file(base), file(input({ age })));
    expect(result.status).toBe(evaluated.results[0].outcome === "violated" ? "sat" : "unsat");
    if (result.status === "sat") {
      expect(result.bindings[0].value).toEqual(scalar(age));
      expect(result.witness.facts[0].origin).toBe("inference");
      expect(result.direct_evaluation.results[0].outcome).toBe("violated");
      expect(result.execution).toBeNull();
    }
  }
}, 30000);
it("honors assumptions, known evidence, and forbidden polarity", () => {
  const value = query();
  value.assumptions = expression({ ge: [{ fact: "age" }, 18] });
  expect(solve(value).status).toBe("unsat");
  value.assumptions = [];
  value.evidence = input({ age: 18 });
  expect(solve(value).status).toBe("unsat");
  const forbidden = query(direct({ fact: "bad" }, "forbidden"), [variable("bad", "Bool", [true])]);
  expect(solve(forbidden).direct_evaluation.results[0].outcome).toBe("violated");
  forbidden.goal = "satisfaction";
  expect(solve(forbidden).status).toBe("unsat");
}, 30000);
it.each([
  ["Bool", true],
  ["Int", -7],
  ["Real", 0.125],
  ["String", 'λ 🌿 " (assert false) \\'],
])(
  "decodes %s scalar values without injecting source text into SMT",
  (sort, value) => {
    const model = query(direct({ eq: [{ fact: "value" }, value] }), [
      variable("value", sort as string, [value]),
    ]);
    model.goal = "satisfaction";
    const result = solve(model);
    expect(result.status).toBe("sat");
    expect(result.bindings[0].value).toEqual(scalar(value));
    expect(result.direct_evaluation.results[0].outcome).toBe("satisfied");
  },
  15000,
);
it("keeps resource exhaustion explicit", () => {
  const value = query();
  value.bounds.resource_limit = 1;
  const result = solve(value);
  expect(result.status).toBe("unknown");
  expect(result.model).toBeNull();
  expect(result.reason).toMatch(/resource|limit/iu);
});
it.each([
  [{ fact: "missing" }, [], "UnsupportedUndeclaredFact"],
  [{ eq: [null, null] }, [], "UnsupportedNull"],
  [{ eq: [{ fact: "age" }, "text"] }, ["age", "Int"], "UnsupportedLiteralSort"],
  [{ graph: "identity" }, [], "UnsupportedGraphCoverage"],
  [{ unsupported: "higher-order" }, [], "UnsupportedExpression"],
])("reports unsupported semantics explicitly: %j", (predicate, declaration, reason) => {
  const value = query(
    direct(predicate),
    declaration.length ? [variable(declaration[0] as string, declaration[1] as string)] : [],
  );
  const result = solve(value);
  expect(result.status).toBe("unsupported");
  expect(result.reason).toBe(reason);
  expect(result.witness).toBeNull();
});
it("refuses implicit functions and unsafe integer literals", () => {
  const value = query(direct({ call: ["owns", "alice", "file"] }), []);
  expect(solve(value).reason).toBe("UnsupportedUndeclaredFunction");
  value.variables = [variable("huge", "Int", [9007199254740992])];
  expect(solve(value).reason).toBe("UnsupportedInteger");
});
it("supports bounded cardinality including empty sets in both evaluators", () => {
  for (const predicates of [[], [true, false, true]]) {
    const specification = direct({
      eq: [{ count: predicates }, predicates.filter(Boolean).length],
    });
    const value = query(specification, []);
    expect(solve(value).status).toBe("unsat");
    expect(cli("evaluate", file(specification), file(input())).results[0].outcome).toBe(
      "satisfied",
    );
  }
  const invalid = query(direct({ eq: [{ count: [1] }, 1] }), []);
  expect(solve(invalid).status).toBe("unsupported");
}, 20000);
it("preserves unknown cardinality inputs", () => {
  const specification = direct({ eq: [{ count: [{ fact: "missing" }] }, 0] });
  expect(cli("evaluate", file(specification), file(input())).results[0].outcome).toBe("unknown");
});
it("encodes ownership and authority over finite uninterpreted sorts and functions", () => {
  const value = query(
    direct({ implies: [{ call: ["owns", { fact: "owner" }, "file"] }, { fact: "authorized" }] }),
    [variable("owner", "User"), variable("authorized", "Bool", [false])],
  );
  value.sorts = [
    { name: "User", scope: "finite", members: ["alice", "bob"] },
    { name: "Item", scope: "finite", members: ["file"] },
  ];
  value.functions = [{ name: "owns", parameters: ["User", "Item"], result: "Bool" }];
  const result = solve(value);
  expect(result.status).toBe("sat");
  expect(["alice", "bob"]).toContain(result.bindings[0].value.value);
  expect(result.direct_evaluation.results[0].outcome).toBe("unknown");
  expect(result.model).toContain("f0");
});
it("does not close unbounded sorts or invent concrete names", () => {
  const value = query(direct({ eq: [{ fact: "owner" }, "alice"] }), [variable("owner", "User")]);
  value.sorts = [{ name: "User", scope: "unbounded", members: ["alice"] }];
  const result = solve(value);
  expect(result.status).toBe("sat");
  expect(result.bindings[0].value).toBeNull();
  expect(result.direct_evaluation.results[0].outcome).toBe("unknown");
  value.sorts[0].scope = "finite";
  expect(solve(value).status).toBe("unsat");
}, 15000);
it("supports axiomatized calls and time/state predicates", () => {
  const value = query(
    direct({
      implies: [
        { call: ["identity", { fact: "active" }] },
        { lt: [{ fact: "now" }, { fact: "expiry" }] },
      ],
    }),
    [
      variable("active", "Bool", [true]),
      variable("now", "Int", [10]),
      variable("expiry", "Int", [9]),
    ],
  );
  value.functions = [{ name: "identity", parameters: ["Bool"], result: "Bool" }];
  const result = solve(value);
  expect(result.status).toBe("sat");
  expect(result.direct_evaluation.results[0].outcome).toBe("violated");
});
it.each(["duplicate", "bounds", "sort", "claim"])("rejects invalid solver query %s", (kind) => {
  const value = query();
  if (kind === "duplicate") value.variables.push(value.variables[0]);
  if (kind === "bounds") value.bounds.max_objects = 0;
  if (kind === "sort") value.variables[0].sort = "Undeclared";
  if (kind === "claim") value.claim = "clm_" + "a".repeat(64);
  expect(invoke("solve", file(value)).status).not.toBe(0);
});
function fake(value: any, result: any) {
  const path = join(directory, `backend-${serial++}.mjs`);
  writeFileSync(path, `process.stdout.write(${JSON.stringify(JSON.stringify(result))});`);
  return invoke("--config", file({ solver_adapter: path }), "solve", file(value));
}
it.each(["timeout", "unknown"])("preserves adapter %s outcomes", (status) => {
  const result = fake(query(), {
    backend_version: 1,
    backend: "fixture",
    status,
    reason: "Controlled backend outcome",
    model: null,
    bindings: [],
  });
  expect(result.status, result.stderr).toBe(0);
  expect(JSON.parse(result.stdout).status).toBe(status);
});
it.each([
  "wrong-type",
  "outside-domain",
  "wrong-goal",
  "missing-model",
  "fixed-fact",
  "assumption",
])("rejects a malformed or contradictory SAT witness: %s", (kind) => {
  const value = query();
  const backend = {
    backend_version: 1,
    backend: "fixture",
    status: "sat",
    reason: "Fixture",
    model: "(model)",
    bindings: [{ name: "age", sort: "Int", value: scalar(17), symbolic_value: "17" }],
  } as any;
  if (kind === "wrong-type") backend.bindings[0].value = scalar("17");
  if (kind === "outside-domain") backend.bindings[0].value = scalar(19);
  if (kind === "wrong-goal") backend.bindings[0].value = scalar(18);
  if (kind === "missing-model") backend.model = null;
  if (kind === "fixed-fact") value.evidence = input({ age: 18 });
  if (kind === "assumption") value.assumptions = expression({ ge: [{ fact: "age" }, 18] });
  expect(fake(value, backend).status).not.toBe(0);
});
function crossInput() {
  return {
    cross_version: 1,
    specification: structuredClone(perspectives),
    snapshot: structuredClone(snapshot),
    mappings: [],
    policies: [],
    reviews: [],
    symbolic_results: [],
    executions: [],
  } as any;
}
function target(value: any, name: string) {
  return value.specification.snapshot.document.subjects.find(
    (subject) => subject.key.name === name,
  );
}
function mapping(value: any, name: string, confidence = "high") {
  const subject = target(value, name);
  const implementation = value.snapshot.document.subjects.find(
    (subject) => subject.key.kind === "function",
  );
  return {
    id: stableId("map_", ["mapping", name, subject.id, implementation.id]),
    name,
    subject: subject.id,
    implementation: implementation.id,
    observations: value.snapshot.document.observations
      .filter((row) => row.subject === implementation.id)
      .map((row) => row.id),
    relations: [],
    effects: ["writes"],
    source: implementation.source,
    confidence,
    reason: "Explicit test mapping",
  };
}
function cross(value: any, previous?: any) {
  return cli("cross", file(value), ...(previous ? ["--previous", file(previous)] : []));
}
function addEdge(value: any, from: string, kind: string, to: string) {
  const document = value.specification.snapshot.document;
  const relation = {
    id: "",
    from: target(value, from).id,
    kind,
    target: { status: "resolved", subject: target(value, to).id, reason: null },
    source: target(value, from).source,
    revision: document.revision,
  };
  relation.id = relationId(relation as any);
  document.relations.push(relation);
}
it("reports seven perspective gaps as questions with structured suggestions", () => {
  const report = cross(crossInput());
  expect(report.findings.map((finding) => finding.rule).sort()).toEqual(
    [
      "authority",
      "old_lifecycle",
      "identity_policy",
      "dependency",
      "derived_backing",
      "provenance_trust",
      "resource_lifecycle",
    ].sort(),
  );
  expect(report.confirmed_violations).toEqual([]);
  for (const finding of report.findings) {
    expect(finding.level).toBe("unknown");
    expect(finding.challenge.generated_from.finding).toBe(finding.id);
    expect(finding.suggestion).toMatchObject({
      target: finding.subject,
      origin: "inference",
      severity: "info",
      generated_from: finding.id,
    });
  }
});
it("reports all four coverage quadrants while keeping static telemetry distinct from behavior", () => {
  const value = crossInput();
  value.mappings = [mapping(value, "mutate"), mapping(value, "reader")];
  const report = cross(value);
  expect(new Set(report.coverage.map((row) => row.state))).toEqual(
    new Set([
      "specified_observed",
      "specified_unobserved",
      "unspecified_observed",
      "unspecified_unobserved",
    ]),
  );
  expect(report.coverage.find((row) => row.subject === target(value, "mutate").id).behavior).toBe(
    "static_only",
  );
  expect(report.coverage.find((row) => row.subject === target(value, "quiet").id).mapping).toBe(
    "unmapped",
  );
  expect(report.confirmed_violations).toEqual([]);
});
it("suppresses gaps only when the governing declarations are present", () => {
  const value = crossInput();
  for (const kind of [
    "authorizes",
    "old_value_policy",
    "old_identity_policy",
    "verifies",
    "uniqueness",
    "consequence_policy",
  ])
    addEdge(value, "mutate", kind, "Value");
  addEdge(value, "derived", "derived_from", "reader");
  for (const kind of ["provenance", "trust", "verification"])
    addEdge(value, "Generated", kind, "reader");
  for (const kind of ["consumption_policy", "sharing_policy", "release_policy"])
    addEdge(value, "Resource", kind, "reader");
  expect(cross(value).findings).toEqual([]);
});
it("does not infer ownership from missing facets or unresolved annotations", () => {
  const value = crossInput();
  value.specification.snapshot.document.relations =
    value.specification.snapshot.document.relations.filter(
      (row) => row.kind !== "perspective.owned",
    );
  expect(cross(value).findings.some((row) => row.rule === "authority")).toBe(false);
});
it.each(["required", "recommended", "domain_dependent", "optional", "unknown"])(
  "retains policy level %s without claiming a defect",
  (level) => {
    const value = crossInput();
    value.policies = [
      {
        subject: target(value, "mutate").id,
        rule: "dependency",
        level,
        constraints: [],
        reason: "Explicit policy profile",
        source,
      },
    ];
    const report = cross(value);
    expect(report.findings.find((row) => row.rule === "dependency").level).toBe(level);
    expect(report.confirmed_violations).toEqual([]);
  },
);
it("preserves accepted and deferred reviews when a declared policy removes a gap", () => {
  const value = crossInput();
  const initial = cross(value);
  const dependency = initial.findings.find((row) => row.rule === "dependency");
  const authority = initial.findings.find((row) => row.rule === "authority");
  value.reviews = [
    {
      finding: dependency.id,
      status: "deferred",
      note: "Await review",
      revision: initial.revision,
    },
    {
      finding: authority.id,
      status: "accepted_risk",
      note: "Accepted for this model",
      revision: initial.revision,
    },
  ];
  const reviewed = cross(value, initial);
  expect(reviewed.findings.find((row) => row.id === dependency.id).status).toBe("deferred");
  value.reviews = [];
  value.policies = [
    {
      subject: dependency.subject,
      rule: "dependency",
      level: "required",
      constraints: [value.specification.claims.find((row) => row.name === "allowed").constraint],
      reason: "Selected governing constraint",
      source,
    },
  ];
  const after = cross(value, reviewed);
  expect(after.findings.some((row) => row.id === dependency.id)).toBe(false);
  expect(after.reviews.map((row) => row.status)).toEqual(["deferred", "accepted_risk"]);
});
it.each(["dangling", "wrong-owner", "unmapped"])("rejects %s mapping evidence", (kind) => {
  const value = crossInput();
  const mapped = mapping(value, "mutate");
  if (kind === "dangling") mapped.observations = ["obs_" + "a".repeat(64)];
  if (kind === "wrong-owner")
    mapped.observations = [
      value.snapshot.document.observations.find((row) => row.subject !== mapped.implementation).id,
    ];
  if (kind === "unmapped") {
    mapped.implementation = null;
    mapped.id = stableId("map_", ["mapping", mapped.name, mapped.subject, ""]);
  }
  value.mappings = [mapped];
  expect(invoke("cross", file(value)).status).not.toBe(0);
});
function executionFixture(origin = "runtime", factOrigin = "trace", confidence = "high") {
  const value = crossInput();
  value.mappings = [mapping(value, "mutate", confidence)];
  const initial = cross(value);
  const finding = initial.findings.find((row) => row.rule === "dependency");
  const request = {
    oracle_version: 1,
    challenge: finding.challenge,
    response: {
      operation: finding.subject,
      origin,
      coverage: "complete",
      effects: [
        { name: "write", kind: "state_change", subject: null, value: null, source, origin },
      ],
      evidence: input({ allowed: false }),
    },
    expectations: [],
    policy: "enforced",
  };
  request.response.evidence.facts[0].origin = factOrigin;
  value.executions = [
    {
      name: "mutation",
      finding: finding.id,
      challenge: finding.challenge.id,
      replay: null,
      response: request,
    },
  ];
  return { value, initial, finding };
}
it("links runtime violations to both evidence chains and five possible explanations", () => {
  const { value, initial, finding } = executionFixture();
  const report = cross(value, initial);
  expect(report.confirmed_violations).toEqual(["mutation"]);
  expect(report.verifications[0].classification).toBe("observed_violation");
  expect(report.contradictions[0].specification_sources.length).toBeGreaterThan(0);
  expect(report.contradictions[0].implementation_sources.length).toBeGreaterThan(0);
  expect(report.contradictions[0].explanations).toHaveLength(5);
  expect(report.findings.find((row) => row.id === finding.id).suggestion.origin).toBe("trace");
});
it.each([
  ["simulation", "trace", "high", "simulated_counterexample"],
  ["runtime", "inference", "high", "inconclusive"],
  ["runtime", "trace", "low", "inconclusive"],
])(
  "keeps %s/%s/%s evidence from confirming implementation defects",
  (origin, factOrigin, confidence, expected) => {
    const { value, initial } = executionFixture(origin, factOrigin, confidence);
    const report = cross(value, initial);
    expect(report.confirmed_violations).toEqual([]);
    expect(report.verifications[0].classification).toBe(expected);
  },
);
it("rejects changing a challenge under its original identifier", () => {
  const { value, initial } = executionFixture();
  value.executions[0].response.challenge.constraints = [];
  expect(invoke("cross", file(value), "--previous", file(initial)).status).not.toBe(0);
});
it("reports semantic constraint changes and evidence, findings, observations, and relation history", () => {
  const value = crossInput();
  value.mappings = [mapping(value, "mutate")];
  const before = cross(value);
  value.specification.constraints.find((row) => row.name === "allowed").expression =
    expression(true);
  value.snapshot.document.observations.find(
    (row) => row.id === value.mappings[0].observations[0],
  ).measurement = { status: "measured", value: 99999, reason: null };
  addEdge(value, "mutate", "consequence_policy", "Value");
  const after = cross(value);
  expect(after.confirmed_violations).toEqual([]);
  const diff = cli("cross-diff", file(before), file(after));
  for (const category of ["claims", "observations", "relations", "findings", "evidence"])
    expect(diff.changes.some((row) => row.category === category)).toBe(true);
});
it.each(["version", "revision", "finding"])("rejects corrupted previous reports: %s", (kind) => {
  const value = crossInput();
  const previous = cross(value);
  if (kind === "version") previous.cross_version = 2;
  if (kind === "revision") previous.revision = "fake";
  if (kind === "finding") previous.findings[0].id = "fnd_" + "a".repeat(64);
  expect(invoke("cross", file(value), "--previous", file(previous)).status).not.toBe(0);
  expect(invoke("cross-diff", file(previous), file(previous)).status).not.toBe(0);
});
it("diagnoses unsupported perspective names", () => {
  const specification = compile('@perspective("magic") model Value {}');
  expect(specification.snapshot.diagnostics.some((row) => row.category === "error")).toBe(true);
});
