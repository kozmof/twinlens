import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve, join } from "node:path";
import { spawnSync } from "node:child_process";
import { authenticationModel } from "./authentication-fixture.mjs";
const output = resolve(".twinlens/authentication");
mkdirSync(output, { recursive: true });
function save(name, value) {
  const path = join(output, name + ".json");
  writeFileSync(path, JSON.stringify(value));
  return path;
}
function cli(...args) {
  const result = spawnSync("./zig-out/bin/twinlens", args, {
    encoding: "utf8",
    timeout: 120000,
    maxBuffer: 128 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw Error(result.stderr);
  return JSON.parse(result.stdout);
}
const weakSpec = cli(
  "compile",
  "specs/authentication/weak.tsp",
  "--project",
  "authentication-demo",
);
const strongSpec = cli(
  "compile",
  "specs/authentication/strong.tsp",
  "--project",
  "authentication-demo",
);
assert.deepEqual(weakSpec.snapshot.diagnostics, []);
assert.deepEqual(strongSpec.snapshot.diagnostics, []);
const profile = JSON.parse(readFileSync("fixtures/authentication/strict-profile.json", "utf8"));
const weakModel = authenticationModel(weakSpec, profile, "deliberately_weak");
const specifiedModel = authenticationModel(strongSpec, profile, "deliberately_weak");
const correctedModel = authenticationModel(strongSpec, profile);
const weak = cli("auth", save("weak-model", weakModel));
save("weak", weak);
const specified = cli("auth", save("specified-model", specifiedModel));
save("specified", specified);
const corrected = cli("auth", save("corrected-model", correctedModel));
save("corrected", corrected);
assert.equal(weak.counterexamples.length, 0);
assert.ok(
  weak.transitions
    .flatMap((row) => row.checks)
    .every((check) => check.judgment.outcome === "unknown"),
);
assert.equal(corrected.coverage.stop, "catalog_exhausted");
assert.equal(corrected.counterexamples.length, 0);
assert.ok(
  corrected.transitions
    .flatMap((row) => row.checks)
    .every((check) => check.judgment.outcome === "acceptable"),
);
const families = new Set(corrected.model.scenarios.map((row) => row.family));
for (const family of [
  "null_value",
  "wrong_owner",
  "old_value",
  "missing_relation",
  "many_relation",
  "expired_value",
  "unauthorized_caller",
  "deleted_entity",
  "unverified_identity",
  "shared_ownership",
  "stale_identity",
])
  assert.ok(families.has(family));
const operations = new Set(corrected.transitions.map((row) => row.action.operation));
assert.equal(operations.size, 9);
const requiredCases = [
  "wrong-owner-login",
  "old-password-reuse",
  "unauthorized-password-change",
  "expired-reset-token",
  "reused-reset-token",
  "deleted-user-session",
  "unverified-recovery",
];
for (const name of requiredCases) {
  const weakHistory = specified.transitions.filter((row) => row.scenario === name);
  const strongHistory = corrected.transitions.filter((row) => row.scenario === name);
  assert.equal(weakHistory.at(-1).result, "accepted", name);
  assert.equal(strongHistory.at(-1).result, "rejected", name);
  assert.ok(
    weakHistory.some((row) => row.checks.some((check) => check.judgment.outcome === "defect")),
    name,
  );
}
assert.ok(
  corrected.transitions
    .filter((row) => row.scenario === "legitimate-lifecycle")
    .every((row) => row.result === "accepted"),
);
const traces = [];
for (const name of requiredCases) {
  const trace = specified.counterexamples.filter((trace) => trace.scenario === name).at(-1);
  assert.ok(trace);
  const negativeRequest = { authentication_replay_version: 1, model: specifiedModel, trace };
  const positiveRequest = { ...negativeRequest, model: correctedModel };
  const negative = cli("auth-replay", save("negative-replay-" + name, negativeRequest));
  const positive = cli("auth-replay", save("corrected-replay-" + name, positiveRequest));
  assert.equal(negative.coverage.stop, "replay_complete");
  assert.ok(negative.counterexamples.length);
  assert.equal(positive.coverage.stop, "replay_complete");
  assert.equal(positive.counterexamples.length, 0);
  save("replay-result-" + name, positive);
  traces.push({
    scenario: name,
    steps: trace.actions.length,
    reproduced: negative.counterexamples.length,
    corrected: positive.counterexamples.length,
  });
}
const undecidedModel = structuredClone(correctedModel);
undecidedModel.profile.name = "undecided-session-policy";
undecidedModel.profile.sessions_after_change = "domain_dependent";
const undecided = cli("auth", save("undecided-model", undecidedModel));
save("undecided", undecided);
assert.ok(
  undecided.transitions
    .flatMap((row) => row.checks)
    .some(
      (check) =>
        check.rule === "session_invalidation" && check.judgment.outcome === "domain_dependent",
    ),
);
const retainedModel = structuredClone(correctedModel);
retainedModel.profile.name = "preserve-sessions";
retainedModel.profile.sessions_after_change = "preserve";
const retained = cli("auth", save("preserve-model", retainedModel));
save("preserve", retained);
assert.equal(retained.counterexamples.length, 0);
assert.equal(
  retained.transitions.find((row) => row.scenario === "session-invalidation-policy").after
    .sessions[0].status,
  "active",
);
const changes = specified.transitions.map((before) => {
  const after = corrected.transitions.find(
    (row) => row.scenario === before.scenario && row.step === before.step,
  );
  const prior = weak.transitions.find(
    (row) => row.scenario === before.scenario && row.step === before.step,
  );
  return {
    scenario: before.scenario,
    step: before.step,
    operation: before.action.operation,
    weak_spec_outcomes: [...new Set(prior.checks.map((check) => check.judgment.outcome))],
    before: before.result,
    after: after.result,
    violated_rules: before.checks
      .filter((check) => check.judgment.outcome === "defect")
      .map((check) => check.rule),
    suggestions: before.checks.flatMap((check) => (check.suggestion ? [check.suggestion] : [])),
    after_outcomes: [...new Set(after.checks.map((check) => check.judgment.outcome))],
  };
});
save("comparison", {
  authentication_comparison_version: 1,
  weak: weak.model_digest,
  specified: specified.model_digest,
  corrected: corrected.model_digest,
  changes,
});
// Apply BT to the Twinlens native simulator itself; a static subject is not runtime proof.
const snapshot = cli("scan", "src/core", "--language", "zig", "--project", "twinlens-auth-self");
save("snapshot", snapshot);
const implementation = snapshot.document.subjects.find(
  (row) =>
    row.key.path === "authentication.zig" &&
    row.key.kind === "function" &&
    row.key.name === "apply",
);
assert.ok(implementation);
assert.equal(snapshot.diagnostics.length, 0);
const evidence = snapshot.document.observations.filter((row) => row.subject === implementation.id);
assert.ok(evidence.length);
assert.ok(
  corrected.transitions
    .filter((row) => row.result === "rejected")
    .every((row) => JSON.stringify(row.before) === JSON.stringify(row.after)),
);
const summary = {
  target: "src/core/authentication.zig: apply",
  classification: "simulation_only",
  scenarios: corrected.coverage.executed_scenarios,
  steps: corrected.coverage.executed_steps,
  operations: [...operations],
  families: [...families],
  bounds: correctedModel.bounds,
  weak_spec_counterexamples: weak.counterexamples.length,
  strong_spec_weak_adapter_counterexamples: specified.counterexamples.length,
  corrected_counterexamples: corrected.counterexamples.length,
  coverage: corrected.coverage,
  replays: traces,
  self_evidence: { subject: implementation, observations: evidence },
  hypothesis:
    "Rejected synthetic authentication requests must leave all modeled objects unchanged; successful histories must satisfy the explicitly selected policy.",
  decision:
    "Retain the intentionally weak adapter only as a named simulation fixture. Policy-enforced transitions and rejection atomicity passed the finite catalog; static metrics alone do not establish a defect.",
  scope:
    "Synthetic labels, explicit policies, and a finite supplied history catalog. No production authentication, external execution, hashing, real secrets, concurrency, or universal proof.",
  artifacts: [
    "weak",
    "specified",
    "corrected",
    "undecided",
    "preserve",
    "comparison",
    "snapshot",
  ].map((name) => ".twinlens/authentication/" + name + ".json"),
};
writeFileSync(join(output, "report.json"), JSON.stringify(summary, null, 2) + "\n");
console.log(
  JSON.stringify(
    { ...summary, self_evidence: { subject: implementation.id, observations: evidence.length } },
    null,
    2,
  ),
);
