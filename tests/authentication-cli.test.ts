import { afterAll, beforeAll, expect, it } from "vitest";
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";
import { authenticationModel } from "../scripts/authentication-fixture.mjs";
const directory = mkdtempSync(join(tmpdir(), "twinlens-auth-test-"));
afterAll(() => rmSync(directory, { recursive: true, force: true }));
let serial = 0;
function file(value: unknown) {
  const path = join(directory, `${serial++}.json`);
  writeFileSync(path, JSON.stringify(value));
  return path;
}
function invoke(...args: string[]) {
  const result = spawnSync("./zig-out/bin/twinlens", args, {
    encoding: "utf8",
    timeout: 30000,
    maxBuffer: 64 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  return result;
}
function cli(...args: string[]) {
  const result = invoke(...args);
  expect(result.status, result.stderr).toBe(0);
  return JSON.parse(result.stdout);
}
let strong: any, weak: any, negative: any, positive: any, unspecified: any;
beforeAll(() => {
  const profile = JSON.parse(readFileSync("fixtures/authentication/strict-profile.json", "utf8"));
  const strongSpec = cli(
    "compile",
    "specs/authentication/strong.tsp",
    "--project",
    "authentication-test",
  );
  const weakSpec = cli(
    "compile",
    "specs/authentication/weak.tsp",
    "--project",
    "authentication-test",
  );
  expect(strongSpec.snapshot.diagnostics).toEqual([]);
  expect(weakSpec.snapshot.diagnostics).toEqual([]);
  strong = authenticationModel(strongSpec, profile);
  weak = { ...strong, adapter: "deliberately_weak" };
  negative = cli("auth", file(weak));
  positive = cli("auth", file(strong));
  unspecified = cli("auth", file(authenticationModel(weakSpec, profile, "deliberately_weak")));
}, 30000);
function model(name: string) {
  const value = structuredClone(strong);
  value.scenarios = value.scenarios.filter((row) => row.name === name);
  return value;
}
function run(value: any) {
  return cli("auth", file(value));
}
function replay(value: any, trace: any) {
  return cli("auth-replay", file({ authentication_replay_version: 1, model: value, trace }));
}
it("executes all operations and all requested challenge families with explicit finite coverage", () => {
  expect(new Set(positive.transitions.map((row) => row.action.operation)).size).toBe(9);
  expect(positive.coverage).toMatchObject({
    executed_scenarios: 15,
    executed_steps: 24,
    stop: "catalog_exhausted",
    excluded_scenarios: [],
  });
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
    expect(strong.scenarios.some((row) => row.family === family)).toBe(true);
  expect(positive.classification).toBe("simulation_only");
});
it("does not invent constraints or defects when the specification is weak", () => {
  expect(unspecified.counterexamples).toEqual([]);
  expect(
    unspecified.transitions
      .flatMap((row) => row.checks)
      .every((check) => check.judgment.outcome === "unknown"),
  ).toBe(true);
  expect(unspecified.transitions[0].checks[0].judgment.challenge.constraints).toEqual([]);
});
it.each([
  "wrong-owner-login",
  "old-password-reuse",
  "unauthorized-password-change",
  "expired-reset-token",
  "reused-reset-token",
  "deleted-user-session",
  "unverified-recovery",
  "shared-credential",
  "stale-recovery-identity",
  "ambiguous-identity",
  "missing-credential",
  "null-password",
  "foreign-session-logout",
])("exposes %s in the weak adapter and rejects it under the explicit policy", (name) => {
  const before = negative.transitions.filter((row) => row.scenario === name);
  const after = positive.transitions.filter((row) => row.scenario === name);
  expect(before.at(-1).result).toBe("accepted");
  expect(
    before.some((row) => row.checks.some((check) => check.judgment.outcome === "defect")),
  ).toBe(true);
  expect(after.at(-1).result).toBe("rejected");
  expect(
    after.every((row) => row.checks.every((check) => check.judgment.outcome === "acceptable")),
  ).toBe(true);
});
it("permits a legitimate registration, verification, login, logout, and deletion history", () => {
  const history = positive.transitions.filter((row) => row.scenario === "legitimate-lifecycle");
  expect(history.every((row) => row.result === "accepted")).toBe(true);
  const final = history.at(-1).after;
  expect(final.users.find((user) => user.id === "carol").status).toBe("deleted");
  expect(final.sessions.find((session) => session.owner === "carol").status).toBe("revoked");
});
it("derives old credential evidence from the changed current binding", () => {
  const transition = negative.transitions.find(
    (row) => row.scenario === "old-password-reuse" && row.step === 1,
  );
  const check = transition.checks.find((row) => row.rule === "current_credential");
  expect(check.judgment.outcome).toBe("defect");
  expect(
    check.judgment.response.evidence.facts.find((row) => row.name === "auth.current_credential")
      .value.value,
  ).toBe("false");
  expect(transition.before.users[0].current_credential).not.toBe("alice-credential");
});
it("revokes old credentials, consumes reset tokens, and applies session policy as simultaneous effects", () => {
  const transition = positive.transitions.find(
    (row) => row.scenario === "reused-reset-token" && row.step === 0,
  );
  expect(transition.after.tokens[0].status).toBe("used");
  expect(transition.after.credentials[0].status).toBe("revoked");
  expect(transition.after.sessions[0].status).toBe("revoked");
  expect(transition.after.credentials.at(-1).secret).toBe("synthetic-new");
  expect(transition.checks[0].judgment.response.effects.map((row) => row.kind)).toEqual([
    "return_value",
    "state_change",
  ]);
});
it("keeps rejection atomic and does not report nonexistent state changes", () => {
  for (const transition of positive.transitions.filter((row) => row.result === "rejected")) {
    expect(transition.after).toEqual(transition.before);
    expect(transition.checks[0].judgment.response.effects.map((row) => row.kind)).toEqual([
      "return_value",
    ]);
  }
  const value = model("legitimate-lifecycle");
  value.scenarios[0].actions = [
    {
      ...value.scenarios[0].actions[1],
      user: "alice",
      actor: "alice",
      email: "alice@example.test",
    },
  ];
  const result = run(value).transitions[0];
  expect(result.result).toBe("accepted");
  expect(result.before).toEqual(result.after);
  expect(result.checks[0].judgment.response.effects).toHaveLength(1);
});
it.each([9, 10, 11])("uses a strict logical reset expiry boundary at time %i", (at) => {
  const value = model("expired-reset-token");
  value.scenarios[0].actions[0].at = at;
  expect(run(value).transitions[0].result).toBe(at < 10 ? "accepted" : "rejected");
});
it.each(["preserve", "domain_dependent"])(
  "keeps session invalidation choice %s explicit",
  (choice) => {
    const value = model("session-invalidation-policy");
    value.profile.sessions_after_change = choice;
    const transition = run(value).transitions[0];
    expect(transition.after.sessions[0].status).toBe("active");
    expect(
      transition.checks.find((row) => row.rule === "session_invalidation").judgment.outcome,
    ).toBe(choice === "preserve" ? "acceptable" : "domain_dependent");
  },
);
it.each(["optional", "domain_dependent", "unknown"])(
  "preserves %s policy judgments separately from individual constraints",
  (level) => {
    const value = model("wrong-owner-login");
    value.adapter = "deliberately_weak";
    value.profile.policies.find((row) => row.rule === "credential_binding").level = level;
    const check = run(value).transitions[0].checks.find((row) => row.rule === "credential_binding");
    expect(check.judgment.constraints.results[0].outcome).toBe("violated");
    expect(check.judgment.outcome).toBe(level === "unknown" ? "unknown" : "domain_dependent");
    expect(check.suggestion).toBeNull();
  },
);
it("does not assume an omitted policy is required", () => {
  const value = model("wrong-owner-login");
  value.profile.policies = value.profile.policies.filter(
    (row) => row.rule !== "credential_binding",
  );
  expect(
    run(value).transitions[0].checks.find((row) => row.rule === "credential_binding").judgment
      .outcome,
  ).toBe("unknown");
});
it("keeps structured suggestions tied to the actual violated constraint and simulation origin", () => {
  const check = negative.transitions
    .find((row) => row.scenario === "wrong-owner-login")
    .checks.find((row) => row.rule === "credential_binding");
  expect(check.suggestion).toMatchObject({
    target: check.judgment.challenge.target,
    rule: "credential_binding",
    origin: "simulation",
    confidence: "high",
    severity: "warning",
  });
  expect(check.suggestion.constraint).toEqual(
    check.judgment.constraints.results[0].constraint.expression,
  );
  expect(check.judgment.response.origin).toBe("simulation");
  expect(check.judgment.challenge.generated_from.claim).toMatch(/^clm_/);
});
it("replays the same exact history against both adapters without rewriting its contract digest", () => {
  const trace = negative.counterexamples
    .filter((row) => row.scenario === "old-password-reuse")
    .at(-1);
  expect(trace.actions).toHaveLength(2);
  const reproduced = replay(weak, trace);
  const corrected = replay(strong, trace);
  expect(reproduced.counterexamples.length).toBeGreaterThan(0);
  expect(corrected.counterexamples).toEqual([]);
  expect(corrected.model_digest).toBe(reproduced.model_digest);
  expect(corrected.coverage.stop).toBe("replay_complete");
  expect(corrected.transitions).toEqual(
    positive.transitions.filter((row) => row.scenario === trace.scenario),
  );
});
it.each(["digest", "scenario", "action", "profile", "specification", "version"])(
  "rejects altered replay %s",
  (kind) => {
    const value = structuredClone(strong);
    const trace = structuredClone(negative.counterexamples[0]);
    const request = { authentication_replay_version: 1, model: value, trace };
    if (kind === "digest") trace.model_digest = "0".repeat(64);
    if (kind === "scenario") trace.scenario = "absent";
    if (kind === "action") trace.actions[0].secret = "other";
    if (kind === "profile") value.profile.sessions_after_change = "preserve";
    if (kind === "specification") value.specification.claims[0].reason = "changed contract";
    if (kind === "version") request.authentication_replay_version = 2;
    expect(invoke("auth-replay", file(request)).status).not.toBe(0);
  },
);
it.each(["scenario_limit", "step_limit", "object_limit"])(
  "reports %s as incomplete coverage",
  (stop) => {
    const value = structuredClone(strong);
    if (stop === "scenario_limit") value.bounds.max_scenarios = 1;
    if (stop === "step_limit") value.bounds.max_steps = 1;
    if (stop === "object_limit") value.bounds.max_objects = 1;
    const report = run(value);
    expect(report.coverage.stop).toBe(stop);
    expect(report.coverage.excluded_scenarios.length).toBeGreaterThan(0);
    expect(report.coverage.executed_steps).toBeLessThan(24);
  },
);
it("stops before committing a transition that exceeds the object budget", () => {
  const value = model("legitimate-lifecycle");
  value.bounds.max_objects = 6;
  const report = run(value);
  expect(report.coverage.stop).toBe("object_limit");
  expect(report.transitions).toEqual([]);
});
it("does not label a truncated replay complete", () => {
  const value = structuredClone(strong);
  value.bounds.max_steps = 1;
  const trace = negative.counterexamples
    .filter((row) => row.scenario === "old-password-reuse")
    .at(-1);
  const report = replay(value, trace);
  expect(report.coverage.stop).toBe("step_limit");
  expect(report.transitions).toHaveLength(1);
});
it.each([
  "duplicate-policy",
  "duplicate-user",
  "duplicate-owner",
  "dangling-owner",
  "time-reversal",
  "bounds",
  "missing-operation",
  "unknown-field",
  "wrong-version",
  "malformed-state",
])("rejects invalid model %s", (kind) => {
  const value = model("old-password-reuse");
  const state = value.scenarios[0].initial;
  if (kind === "duplicate-policy") value.profile.policies.push(value.profile.policies[0]);
  if (kind === "duplicate-user") state.users.push(state.users[0]);
  if (kind === "duplicate-owner") state.credentials[0].owners.push("alice");
  if (kind === "dangling-owner") state.sessions[0].owner = "missing";
  if (kind === "time-reversal") value.scenarios[0].actions[1].at = 0;
  if (kind === "bounds") value.bounds.max_steps = 0;
  if (kind === "missing-operation")
    value.specification.snapshot.document.subjects.find(
      (row) => row.key.name === "Login",
    ).key.name = "Different";
  if (kind === "unknown-field") value.hidden = true;
  if (kind === "wrong-version") value.authentication_version = 2;
  if (kind === "malformed-state") delete state.users[0].current_credential;
  expect(invoke("auth", file(value)).status).not.toBe(0);
});
it("writes reports atomically through the existing output contract", () => {
  const path = join(directory, "report.json");
  const result = invoke("auth", file(model("wrong-owner-login")), "--out", path);
  expect(result.status, result.stderr).toBe(0);
  expect(result.stdout).toBe("");
  expect(JSON.parse(readFileSync(path, "utf8")).coverage.executed_steps).toBe(1);
});
