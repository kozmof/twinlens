# Phase 5: challenges, responses, and finite histories

Twinlens now generates suspicious-case questions, judges simultaneous response effects, and explores a finite catalog of source histories through the production Zig `Store.replaceFiles` implementation. The core owns these semantics. TypeScript transport types and fixture orchestration exchange JSON records; they do not decide whether a response violates a constraint.

## Commands

```sh
pnpm build
./zig-out/bin/twinlens challenges specification.json --out challenges.json
./zig-out/bin/twinlens judge specification.json request.json --out judgment.json
./zig-out/bin/twinlens explore model.json --out exploration.json
./zig-out/bin/twinlens replay replay-request.json --out replay.json
pnpm self:explore
```

Commands validate strict versioned JSON. `--out` atomically replaces the output file. A valid report exits 0 even when it contains defects, unknown results, or exhausted limits. Invalid models, references, bounds, or replay requests exit 5. Large input files can use `--config FILE` with an explicit `max_input_bytes`, as in earlier phases. The self-exploration script uses 128 MiB.

## Challenges and response contracts

A challenge carries its target subject, optional mapped operation, initial assumptions, selected constraint IDs, question, suspicious condition, expected response classification, execution requirement, and originating claim/finding/source evidence. Generated `cha_` IDs are stable hashes of the originating claim. Generation selects explicitly forbidden claims and partial specification claims. A challenge is a question, never a counterexample by itself. Non-operation targets retain a missing mapping; judging them requires an explicit operation mapping.

Execution classifications are `solver_supported`, `simulation`, `runtime_execution`, `human_policy`, and `unknown`. Generation maps axiomatized/mocked operation modes to simulation, executable/observed modes to runtime execution, policy questions to human policy, and opaque/uninterpreted or unmapped operations to unknown. `solver_supported` can be retained in an externally supplied challenge; Phase 5 supplies no solver and does not automatically assign that classification. These fields describe execution requirements, not evidence that execution occurred.

A `ResponseSet` records all simultaneous effects: return values, state changes, database changes, logs, events, observations, external effects, and unknown effects. Each effect has a name, kind, optional subject/scalar value, source, and origin (`simulation`, `runtime`, `code`, or `test`). The response carries its operation, overall origin, complete/partial effect coverage, and Phase 4 evaluation evidence. Adapters produce this contract; `judge` consumes it without executing arbitrary user functions.

Effect expectations are required, possible, forbidden, or unknown. Presence is matched by both name and kind. A missing required effect is a violation only with complete effect coverage; an unknown effect makes absence inconclusive. An observed forbidden effect is decisive even with partial coverage. A possible effect may be absent. Missing facts and unsupported constraint evaluation remain unknown.

The oracle combines effect checks with the selected governing constraints. Its outcomes are:

| Outcome            | Meaning                                                                                |
| ------------------ | -------------------------------------------------------------------------------------- |
| `acceptable`       | The observed response satisfies selected constraints and effect expectations.          |
| `defect`           | The response contradicts an explicitly enforced constraint or expectation.             |
| `unknown`          | Evidence, constraint coverage, execution meaning, or enforcement policy is incomplete. |
| `domain_dependent` | The supplied policy explicitly leaves judgment dependent on a domain decision.         |

Requests choose `enforced`, `unknown`, or `domain_dependent` policy. All individual constraint/effect results remain in the report even when policy prevents a final defect judgment. Assumptions are retained as scenario context; they are not silently promoted into observed facts. Evidence must be supplied separately. A simulated defect is a counterexample to the supplied model/adapter/constraints, not a universal assertion about external runtime behavior.

## Finite Store model

The model contains a specification, mapped operation, source worlds, initial world indices, adapter choice, and four explicit bounds. Each world is a complete previously scanned snapshot. Worlds must share project, adapter, compiler, and options identity. Compiler-error worlds are rejected. The finite catalog determines the available source variants; unknown variants are outside coverage.

The production adapter is `native_store`. `test_stale_delete` deliberately omits deleted paths during replacement and exists only for negative experiments. Each initial state starts with an empty Store, including worlds where source files already exist. The explorer therefore exercises dirty reachable states beyond the assumption that source and Store are already synchronized.

An add, modify, or delete action moves between two worlds differing in exactly one file digest. A first refresh is `scan`; later refreshes are `rescan`. Source edits change the source world while retaining the old Store. Refresh invokes the real Store replacement API and compares its result with the selected world's fresh-scan records. Empty Zig directories now produce empty snapshots, allowing deletion of the last file to be checked against a fresh scan.

Refresh conservatively includes every current file and every previously stored file path. This refreshes dependencies and project-wide aggregates together. Phase 1's file-only update still invalidates incomplete aggregates; Phase 5 does not treat those unknown values as equivalent to a complete scan. This implementation establishes history correctness for conservative refresh, not a minimal dependency-based incremental scanner or a performance improvement.

Semantic equivalence compares the stored IR projection of a full snapshot. It sorts record arrays and normalizes revision fields and revision-derived observation/relation IDs. Subject and symbol identity, source locations, extractor provenance, measurement values/status/reasons, and relation resolution remain significant. Snapshot diagnostics, configuration, and file inventory are model metadata rather than Store records; the model validates their compatibility separately. No uncertainty is erased to make a comparison pass.

## States, events, and replay

State records retain the world index, complete Store document, semantic digest, freshness, scan history, depth, initial world, and incoming transition. Every transition includes its action, before/after state IDs, challenge, complete response set, governing constraints, and oracle judgment. Scan responses require return, Store change, event, and observation effects together; edit responses identify the source change instead.

Events retain the mapped operation, actor, affected file, source evidence, and logical transition timestamp. Value references explicitly distinguish old/new Store digests and current/historical source revisions. They are references into retained states, not wall-clock runtime observations.

Breadth-first exploration checks every generated transition, including transitions from dirty states. Equivalent source/Store/scan-history states share a queue entry; each executed edge still retains its response. This deduplication supports the current state-based constraints. General history-sensitive policies that distinguish otherwise identical states need a richer state key and remain future work.

A counterexample trace retains the model digest, initial world, action sequence, and failing transition. Replay executes the supplied sequence without state deduplication and checks every intermediate response. The digest includes specification, operation, and source worlds. It deliberately excludes execution budgets, initial seed selection, and adapter choice so the same witness can be replayed with larger bounds and against the corrected adapter. Changing the source-world/specification model invalidates the trace. The stored failing-transition ID identifies the original failure; replay derives fresh judgments.

## Bounds and coverage

Bounds are required and limited to depth 1–32, 1–8 file objects, 1–2000 executed transitions, and 1–60000 milliseconds. A model contains at most 64 worlds. Time is monotonic and checked between synchronous bounded operations; it is a cooperative budget, not hard preemption of parsing or a native Store call. Reports expose executed transitions, initial and distinct states, object-excluded worlds, unknown transitions, and the stopping reason: finite graph exhausted, depth/execution/time/object limit, or replay complete. No counterexamples within these bounds is never a universal proof.

The file-object limit bounds world inventory, not all IR subjects. Input byte limits and the finite transition limit additionally bound accepted work, but reports can be larger than their model because they retain evidence and full states. Use small catalogs and bounds appropriate to the experiment.

## Self-exploration gate

`specs/store-history.tsp` declares refresh equivalence, deletion cleanup, identity continuity, stable IDs, observation ownership, and valid references. `scripts/exploration-fixture.mjs` scans six Zig source worlds covering empty source, original and modified function bodies, a caller/callee pair, a renamed function, and a caller whose target was removed.

`pnpm self:explore` verifies the production adapter across the reachable finite graph, finds a stale-store counterexample in the deliberate negative adapter, reproduces its trace, and verifies the corrected adapter on the same trace. It also explicitly replays add → scan → modify → rescan → delete → rescan, retaining changed measurements and the final empty Store. Generated artifacts live under ignored `.twinlens/exploration/`, including the model, positive/negative reports, counterexample, replay requests/results, lifecycle, and summary.

Tests additionally cover simultaneous effects, partial/unknown response inventories, policy outcomes, malformed contracts, removed symbols, changed call relations, every bound (including a deterministic clock test), semantic equivalence, and allocation-failure cleanup. CI runs this gate alongside observation, analysis, and structural specification verification. Solver-backed search, general runtime adapters, and arbitrary state-dependent domain simulations remain later work.
