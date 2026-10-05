import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  stableId,
  claimId,
  constraintId,
  observationId,
  relationId,
  scalar,
} from "../packages/transport/dist/index.js";
import { createExplorationFixture } from "./exploration-fixture.mjs";
const root = resolve(".");
const output = join(root, ".twinlens/cross");
mkdirSync(output, { recursive: true });
const config = join(output, "config.json");
writeFileSync(config, JSON.stringify({ max_input_bytes: 134217728 }));
function cli(...args) {
  const result = spawnSync(join(root, "zig-out/bin/twinlens"), ["--config", config, ...args], {
    encoding: "utf8",
    timeout: 180000,
    maxBuffer: 128 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw Error(result.stderr);
  return result.stdout ? JSON.parse(result.stdout) : undefined;
}
function save(name, value) {
  const path = join(output, name + ".json");
  writeFileSync(path, JSON.stringify(value));
  return path;
}
function query(specification, claim, evidence, variables = [], simulation = null) {
  return {
    solver_version: 1,
    specification,
    claim: claim.id,
    goal: "violation",
    assumptions: [],
    evidence,
    sorts: [],
    variables,
    functions: [],
    bounds: { timeout_ms: 3000, resource_limit: 1000000, max_objects: 8 },
    simulation,
  };
}
const scratch = mkdtempSync(join(tmpdir(), "twinlens-cross-"));
try {
  const specification = cli("compile", "specs/cross-lens.tsp", "--project", "twinlens");
  assert.equal(specification.snapshot.diagnostics.length, 0);
  const snapshot = cli("scan", "tsconfig.json", "--language", "both", "--project", "twinlens");
  save("snapshot", snapshot);
  assert.equal(snapshot.diagnostics.filter((row) => row.category === "error").length, 0);
  const operation = specification.snapshot.document.subjects.find(
    (subject) => subject.key.name === "refreshStore",
  );
  const implementation = snapshot.document.subjects.find(
    (subject) =>
      subject.key.path === "src/core/store.zig" &&
      subject.key.name === "Store[declaration:0]/replaceFiles" &&
      subject.key.kind === "function",
  );
  assert.ok(implementation);
  const mapping = {
    id: stableId("map_", ["mapping", "store-refresh", operation.id, implementation.id]),
    name: "store-refresh",
    subject: operation.id,
    implementation: implementation.id,
    observations: snapshot.document.observations
      .filter((row) => row.subject === implementation.id)
      .map((row) => row.id),
    relations: [],
    effects: ["writes"],
    source: implementation.source,
    confidence: "high",
    reason: "Explicitly map the refresh specification to Store.replaceFiles",
  };
  const policy = {
    subject: operation.id,
    rule: "dependency",
    level: "required",
    constraints: [],
    reason: "Refresh must declare the consequence for dependent queries",
    source: operation.source,
  };
  const initial = {
    cross_version: 1,
    specification,
    snapshot,
    mappings: [mapping],
    policies: [policy],
    reviews: [],
    symbolic_results: [],
    executions: [],
  };
  const baseline = cli("cross", save("initial-input", initial));
  save("initial", baseline);
  const finding = baseline.findings.find((finding) => finding.rule === "dependency");
  assert.ok(finding);
  assert.equal(baseline.confirmed_violations.length, 0);
  const model = createExplorationFixture(join(scratch, "world"), cli, specification, "twinlens");
  const mutant = { ...model, adapter: "test_stale_delete" };
  const negative = cli("explore", save("mutant-model", mutant));
  const trace = negative.counterexamples[0];
  assert.ok(trace);
  save("counterexample", trace);
  const claim = specification.claims.find((claim) => claim.name === "refresh-equivalence");
  const absent = {
    input_version: 1,
    project: "twinlens",
    facts: [],
    graph: null,
    coverage: "absent",
  };
  const variables = [
    { name: "store.refreshed", sort: "Bool", domain: [scalar(true)], source: claim.source },
    {
      name: "store.equivalent",
      sort: "Bool",
      domain: [scalar(false), scalar(true)],
      source: claim.source,
    },
    { name: "trace_index", sort: "Int", domain: [scalar(0)], source: claim.source },
  ];
  const symbolic = cli(
    "solve",
    save(
      "symbolic-query",
      query(specification, claim, absent, variables, {
        selector: "trace_index",
        model: mutant,
        traces: [trace],
      }),
    ),
  );
  save("symbolic", symbolic);
  assert.equal(symbolic.status, "sat");
  assert.equal(symbolic.direct_evaluation.results[0].outcome, "violated");
  assert.ok(symbolic.execution.counterexamples.length);
  const execution = {
    name: "store-history",
    finding: finding.id,
    challenge: finding.challenge.id,
    replay: { replay_version: 1, model: mutant, trace },
    response: null,
  };
  const reviewed = {
    ...initial,
    reviews: [
      {
        finding: finding.id,
        status: "deferred",
        note: "Review the modeled deletion gap; retain it while testing the correction",
        revision: baseline.revision,
      },
    ],
    symbolic_results: [symbolic],
    executions: [execution],
  };
  const before = cli(
    "cross",
    save("before-input", reviewed),
    "--previous",
    save("baseline", baseline),
  );
  save("before", before);
  assert.equal(before.findings[0].status, "deferred");
  assert.equal(before.verifications[0].classification, "simulated_counterexample");
  assert.equal(before.confirmed_violations.length, 0);
  assert.equal(before.contradictions[0].explanations.length, 5);
  const suggestion = before.findings[0].suggestion;
  assert.equal(suggestion.origin, "trace");
  const strengthened = structuredClone(specification);
  const source = { ...operation.source, producer: "self-cross-policy/1", confidence: "high" };
  const constraint = {
    id: constraintId(operation.id, "dependency-consequence"),
    subject: operation.id,
    name: "dependency-consequence",
    expression: suggestion.constraint,
    source,
  };
  strengthened.constraints.push(constraint);
  strengthened.claims.push({
    id: claimId(operation.id, constraint.name, "policy"),
    subject: operation.id,
    name: constraint.name,
    kind: "policy",
    state: "specified",
    reason: "Explicit policy adopted from the replay-backed suggestion",
    constraint: constraint.id,
    source,
  });
  const revision = createHash("sha256")
    .update(JSON.stringify(strengthened.constraints))
    .digest("hex");
  strengthened.snapshot.document.revision = revision;
  for (const observation of strengthened.snapshot.document.observations) {
    observation.revision = revision;
    observation.id = observationId(observation);
  }
  for (const relation of strengthened.snapshot.document.relations) {
    relation.revision = revision;
    relation.id = relationId(relation);
  }
  save("strengthened-specification", strengthened);
  const correctedModel = { ...model, specification: strengthened };
  const corrected = cli("explore", save("corrected-model", correctedModel));
  save("corrected-exploration", corrected);
  assert.equal(corrected.counterexamples.length, 0);
  assert.equal(corrected.coverage.stop, "exhausted");
  const correctedTrace = {
    ...trace,
    model_digest: corrected.model_digest,
    failing_transition: null,
  };
  const correctedReplay = cli(
    "replay",
    save("corrected-replay-request", {
      replay_version: 1,
      model: correctedModel,
      trace: correctedTrace,
    }),
  );
  save("corrected-replay", correctedReplay);
  const evidence = correctedReplay.transitions.at(-1).judgment.response.evidence;
  const afterSymbolic = cli(
    "solve",
    save(
      "corrected-symbolic-query",
      query(
        strengthened,
        strengthened.claims.find((row) => row.id === claim.id),
        evidence,
      ),
    ),
  );
  save("corrected-symbolic", afterSymbolic);
  assert.equal(afterSymbolic.status, "unsat");
  const afterInput = {
    ...initial,
    specification: strengthened,
    policies: [{ ...policy, constraints: [constraint.id] }],
    symbolic_results: [afterSymbolic],
    executions: [
      { ...execution, replay: { replay_version: 1, model: correctedModel, trace: correctedTrace } },
    ],
  };
  const after = cli("cross", save("after-input", afterInput), "--previous", save("before", before));
  save("after", after);
  assert.equal(after.findings.length, 0);
  assert.equal(after.verifications[0].classification, "acceptable");
  assert.equal(after.reviews[0].status, "deferred");
  assert.equal(after.confirmed_violations.length, 0);
  const diff = cli("cross-diff", save("before", before), save("after", after));
  save("diff", diff);
  assert.ok(diff.changes.some((change) => change.category === "claims" && change.kind === "added"));
  assert.ok(
    diff.changes.some(
      (change) => change.category === "verification_results" && change.kind === "changed",
    ),
  );
  const invariants = cli("compile", "specs/twinlens.tsp", "--project", "twinlens");
  const structural = cli("inspect", root, save("snapshot", snapshot));
  const coreResults = [];
  for (const invariant of invariants.claims.filter((claim) => claim.state === "specified")) {
    const result = cli(
      "solve",
      save("core-query-" + invariant.name, query(invariants, invariant, structural)),
    );
    assert.equal(result.status, "unsat");
    coreResults.push({ claim: invariant.name, status: result.status });
    save("core-result-" + invariant.name, result);
  }
  const summary = {
    target: "Store.replaceFiles",
    finding: finding.id,
    challenge: finding.challenge.id,
    symbolic_before: symbolic.status,
    execution_before: before.verifications[0].classification,
    confirmed_implementation_defects: before.confirmed_violations.length,
    suggested_constraint: constraint.id,
    symbolic_after: afterSymbolic.status,
    execution_after: after.verifications[0].classification,
    review_after: after.reviews[0].status,
    exploration: corrected.coverage,
    core_invariants: coreResults,
    diff_categories: [...new Set(diff.changes.map((change) => change.category))],
    scope:
      "SAT is a symbolic witness; the deliberate stale-delete counterexample is simulation evidence. Corrected refresh is tested on a finite source catalog. Structural SMT checks use fixed graph evidence, not symbolic SHA-256 reasoning.",
    artifacts: [
      "initial",
      "before",
      "after",
      "symbolic",
      "corrected-symbolic",
      "counterexample",
      "corrected-exploration",
      "corrected-replay",
      "diff",
    ].map((name) => ".twinlens/cross/" + name + ".json"),
  };
  writeFileSync(join(output, "report.json"), JSON.stringify(summary, null, 2) + "\n");
  console.log(JSON.stringify(summary, null, 2));
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
