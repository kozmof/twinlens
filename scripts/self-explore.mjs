import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";
import { createExplorationFixture } from "./exploration-fixture.mjs";
const root = resolve(".");
const output = join(root, ".twinlens/exploration");
mkdirSync(output, { recursive: true });
const config = join(output, "config.json");
writeFileSync(config, JSON.stringify({ max_input_bytes: 134217728 }));
function cli(...args) {
  const result = spawnSync(join(root, "zig-out/bin/twinlens"), ["--config", config, ...args], {
    encoding: "utf8",
    timeout: 90000,
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
const scratch = mkdtempSync(join(tmpdir(), "twinlens-explore-"));
try {
  const specification = cli("compile", "specs/store-history.tsp", "--project", "twinlens-history");
  assert.equal(specification.snapshot.diagnostics.length, 0);
  const model = createExplorationFixture(scratch, cli, specification);
  const modelPath = save("model", model);
  const corrected = cli("explore", modelPath);
  save("corrected", corrected);
  assert.equal(corrected.counterexamples.length, 0);
  assert.equal(corrected.unknown_transitions.length, 0);
  assert.equal(corrected.coverage.stop, "exhausted");
  const mutant = { ...model, adapter: "test_stale_delete" };
  const negative = cli("explore", save("mutant-model", mutant));
  save("negative", negative);
  assert.ok(negative.counterexamples.length > 0);
  const trace = negative.counterexamples[0];
  save("counterexample", trace);
  const reproduced = cli(
    "replay",
    save("negative-replay-request", { replay_version: 1, model: mutant, trace }),
  );
  save("negative-replay", reproduced);
  assert.ok(reproduced.counterexamples.length > 0);
  const replayed = cli(
    "replay",
    save("corrected-replay-request", { replay_version: 1, model, trace }),
  );
  save("corrected-replay", replayed);
  assert.equal(replayed.counterexamples.length, 0);
  const lifecycle = {
    model_digest: corrected.model_digest,
    initial_world: 0,
    failing_transition: null,
    actions: [
      { kind: "add", path: "value.zig", world: 1 },
      { kind: "scan", path: null, world: 1 },
      { kind: "modify", path: "value.zig", world: 2 },
      { kind: "rescan", path: null, world: 2 },
      { kind: "delete", path: "value.zig", world: 0 },
      { kind: "rescan", path: null, world: 0 },
    ],
  };
  const history = cli(
    "replay",
    save("lifecycle-request", { replay_version: 1, model, trace: lifecycle }),
  );
  save("lifecycle", history);
  assert.equal(history.counterexamples.length, 0);
  assert.equal(history.transitions.length, 6);
  assert.equal(history.states.at(-1).document.observations.length, 0);
  const observations = history.states.filter(
    (state) => state.freshness === "fresh" && state.document.observations.length,
  );
  assert.notEqual(observations[0].store_digest, observations[1].store_digest);
  const summary = {
    target: "src/core/store.zig: Store.replaceFiles",
    bounds: model.bounds,
    corrected: corrected.coverage,
    negative_counterexamples: negative.counterexamples.length,
    reproduced: reproduced.counterexamples.length,
    corrected_replay: replayed.counterexamples.length,
    lifecycle: lifecycle.actions.map((action) => action.kind),
    limitations:
      "Finite supplied Zig worlds; conservative refresh includes all current and previously stored paths. Fault injection is confined to the test adapter. No universal proof.",
    artifacts: [
      "model",
      "corrected",
      "negative",
      "counterexample",
      "negative-replay",
      "corrected-replay",
      "lifecycle",
    ].map((name) => `.twinlens/exploration/${name}.json`),
  };
  writeFileSync(join(output, "report.json"), JSON.stringify(summary, null, 2) + "\n");
  console.log(JSON.stringify(summary, null, 2));
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
