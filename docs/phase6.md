# Phase 6: symbolic queries and cross-lens analysis

Phase 6 adds `solve`, `cross`, and `cross-diff`. The Zig core owns encoding, model validation, mappings, rules, policy handling, and report semantics. `packages/solver` is a transport adapter for the official [Z3 JavaScript bindings](https://github.com/Z3Prover/z3/blob/master/src/api/js/PUBLISHED_README.md), pinned to `z3-solver` 4.15.4. It loads the packaged WASM solver and returns plain JSON; no Z3 types enter the core.

```sh
pnpm build
./zig-out/bin/twinlens solve query.json --out symbolic.json
./zig-out/bin/twinlens cross input.json --out before.json
./zig-out/bin/twinlens cross corrected-input.json --previous before.json --out after.json
./zig-out/bin/twinlens cross-diff before.json after.json --out changes.json
TMPDIR=/tmp pnpm self:cross
```

Configuration accepts `solver_adapter`, defaulting to `packages/solver/dist/cli.js`. This is a trusted executable adapter path, like the compiler adapter settings. Input files are read-only; `--out` uses the existing atomic output path. Structural invalidity is a CLI error; a valid but unsupported solver query returns a report with `status: "unsupported"`.

## Symbolic query contract

The exact contracts are in [symbolic.ts](../packages/transport/src/symbolic.ts) and [symbolic.zig](../src/core/symbolic.zig). A version 1 query includes its full specification, selected claim ID, `goal` (`violation` or `satisfaction`), assumptions, evidence, sort/variable/function declarations, bounds, and an optional simulation selector. Assumptions use the same acyclic Constraint IR node vector as claims; its final node is the asserted predicate. Domains declared in TypeSpec remain specification metadata: solver variables and domains must be selected explicitly in the query.

Supported semantics:

- Boolean, safe integer, finite numeric decimal, and Unicode string literals; typed variables with optional finite scalar domains; equality, order, Boolean connectives, and implication.
- Named uninterpreted sorts with either an explicitly closed finite member set or an unbounded universe. Named members are distinct. Unknown unnamed model elements retain their symbolic text and have no invented concrete scalar name.
- Declared uninterpreted functions, including Boolean-valued relations, and bounded inlining of axiomatized functions. Both the specification declaration and a query signature are required. Opaque, executable, mocked, and observed functions require another adapter and are unsupported here.
- Cardinality through `{"count": [predicate, ...]}` (at most 64 predicates). The direct evaluator supports the same operator, including the empty count. Unknown or unsupported predicates keep that status.
- Ownership, authority, and time/state conditions expressed through typed facts and declared relations/functions. These names have no hidden domain axioms. For example, `owns(user, item) ⇒ authorized` or `active ⇒ now < expiry` means exactly the selected expression and assumptions.
- Fixed graph identity, ownership, and reference predicates use the existing direct evaluator and encode its definite result. Incomplete graph coverage is unsupported. This does not encode SHA-256 or prove identities over every possible future graph.

Nulls, undeclared facts/functions, invalid type combinations, incomplete claims, compiler-error specifications, and unsupported expression kinds do not silently become unconstrained values. Known evidence constrains a matching symbolic variable. A forbidden claim reverses predicate polarity consistently with direct evaluation.

Bounds are explicit: 16 named sorts, 64 variables/functions, 1–64 named objects total, 1–30000 ms solver timeout, 1–10000000 Z3 resource units, 1024 nodes per expression vector, 10000 encoding node visits, and call depth 16. Encoded SMT is limited to 32768 bytes and its adapter packet to 60000 bytes. An empty variable domain means unrestricted within its sort; a finite sort cannot have zero members. `max_objects` limits named members, not the cardinality of an unbounded sort. Time is measured inside Z3; the adapter also has a timeout plus ten-second startup/execution watchdog. These are scope limits, not universal verification guarantees.

Results preserve the complete query, SMT, backend version, reason, and one of `sat`, `unsat`, `unknown`, `unsupported`, or `timeout`. Resource exhaustion remains unknown. UNSAT means no model satisfies this particular query. SAT means a symbolic witness exists; it does not establish implementation behavior.

SAT models retain raw solver text and typed variable bindings. Finite named members, booleans, strings, safe integers, and rationals with an exact supported decimal round trip are decoded. Other numeric/algebraic/unnamed values retain symbolic text with a null concrete value. Decoded values are checked against types, declared domains, and fixed evidence. Witness facts have `origin: "inference"`. Direct evaluation checks the selected claim and assumptions again where concrete semantics are available; a contradictory model is rejected. Uninterpreted calls can legitimately leave direct evaluation unknown.

An optional `simulation` includes an Int variable selector, a validated Phase 5 exploration model, and up to 64 replay traces. A decoded selector in range executes the chosen trace through the real bounded Store simulator. Query and simulator specifications must match exactly, and trace model digests must match. Undecodable or out-of-range selectors produce no execution. This is an explicit catalog of supported concrete scenarios; arbitrary solver models are not compiled into programs or executed on external systems. Exploration bounds and simulation provenance remain in the report.

## Explicit SA-to-BT mappings

[Cross-lens contracts](../packages/transport/src/crosslens.ts) link a specification subject to an optional implementation subject, selected observation/relation IDs, named effects, source provenance, confidence, and a reason. Mapping IDs hash the name and endpoints. Selected observations must belong to the implementation endpoint; selected relations must touch it. Names or similar metric counts never create mappings automatically. Effect names describe the intended correspondence; they do not assert that an effect was executed.

Coverage uses four states: specified/observed, specified/unobserved, unspecified/observed, and unspecified/unobserved. Here “observed” means selected static telemetry exists. The separate `behavior` field remains `static_only` or `unobserved`; neither is runtime coverage. Unmapped declarations remain explicit, and unresolved specification relations retain source-linked uncertainty. A specified claim means a claim was supplied, not that it passed verification.

## Policy rules and suggestions

`@perspective("owned" | "credential" | "identity" | "derived" | "generated" | "resource")` declares a self-relation in TypeSpec. The core consumes these domain facts and ordinary relations through a common rule definition interface. Ownership can also come from an explicit owned domain or an `owns` edge.

| Rule               | Trigger                                      | Governing declaration                                                       |
| ------------------ | -------------------------------------------- | --------------------------------------------------------------------------- |
| Authority          | Write to an explicitly owned value           | Operation authorizes the value or all declared owners                       |
| Old lifecycle      | Write a credential that has a verifier       | Operation declares `old_value_policy` for the value                         |
| Identity policy    | Write an identity                            | `old_identity_policy`, `verifies`, and `uniqueness` for that value          |
| Dependency         | Write a value referenced by a dependency     | Operation declares `consequence_policy`                                     |
| Derived backing    | Explicit derived perspective                 | `derived_from` or a declared function backing                               |
| Provenance/trust   | Create/produce an explicitly generated value | Value declares `provenance`, `trust`, and `verification`                    |
| Resource lifecycle | Consume/reserve an explicit resource         | Value declares `consumption_policy`, `sharing_policy`, and `release_policy` |

Absent facets do not establish ownership, identity, or other domain meaning. A governing declaration closes the declaration gap; it is not evidence that the implementation complies. A policy profile may instead name existing specified constraints on the subject. Explicit constraints must be governed by a claim; arbitrary dangling constraint IDs are rejected.

Policy levels are `required`, `recommended`, `domain_dependent`, `optional`, and `unknown`. All gaps remain reviewable, including optional/unknown gaps. Required and recommended gaps start as warnings; other levels are informational. A gap alone is never a confirmed defect. Stable finding IDs use the rule and both affected endpoints. Reviews use the existing status vocabulary, including `accepted_risk` and `deferred`, and survive later absence of a finding through the previous report's review ledger. Absence does not mark a finding fixed.

Each finding includes a challenge linked to its ID and an editable structured suggestion with target, claim kind, Constraint IR, origin, confidence, and severity. Initial suggestions contain a named policy fact for human refinement, not an invented domain policy. When an execution actually violates a constraint, the suggestion carries that concrete governing expression and trace origin.

## Combined evidence and revision history

A cross input contains the specification, implementation snapshot, mappings, policy profile, reviews, retained symbolic results, and selected executions. The report includes those inputs, coverage, source-linked evidence, findings and challenges, uncertainties, verifications, contradictions, confirmed violations, and retained reviews. Symbolic results are retained with their own query scope; they never populate confirmed implementation violations.

Execution entries reference an existing finding/challenge and contain either a replay request or a response-oracle request. Replay requests are actually executed again, must match the current specification, and must complete their supplied trace. Response requests are rejudged by the core and must preserve the originating challenge exactly. Historical finding references require `--previous`; invalid IDs/revisions and dangling references are rejected. A previous report is history supplied by the caller, not authenticated evidence.

A defect judgment from a simulation/test is a `simulated_counterexample`. An `observed_violation` requires a runtime response with explicit runtime/code effects, code/trace fact origins, and a high-confidence mapping. Otherwise it remains inconclusive. Runtime provenance is caller-supplied evidence, not independent instrumentation or cryptographic attestation. Policy-dependent/unknown judgments remain inconclusive. Human review state remains separate from this classification.

Contradictions expose both source chains and five possible explanations: specification, model, implementation, observation, or mapping error. They do not silently choose the implementation as the cause. Oracle results retain the actual constraints, sources, response effects, and facts used.

`cross-diff` reports added/removed/changed observations, relations, evidence, findings, mappings, claims with their governing expressions, verification results, symbolic results, reviews, and policies. Observation/relation revisions and revision-derived IDs are normalized for comparison, while measurement and source changes remain visible. Full before/after values are included. Like other reports, all storage is caller-owned JSON; there is no implicit database.

## Twinlens self-application

`pnpm self:cross` compiles [cross-lens.tsp](../specs/cross-lens.tsp), scans real TypeScript/Zig sources, and explicitly maps `refreshStore` to `Store.replaceFiles`. It detects the missing dependency consequence policy and creates a question. The finite stale-delete test adapter supplies a replayable counterexample. A symbolic refresh-equivalence violation decodes to a selected scenario and executes it; direct evaluation and the bounded simulator agree on the supported witness.

The resulting report preserves a deferred review, both evidence chains, and a concrete suggested constraint. The gate adopts that suggestion as an explicit direct-IR policy profile and switches from the deliberately faulty adapter to production Store refresh. It does not rewrite a TypeSpec source file or claim a newly discovered production defect. Because adopting the policy changes the model contract, it records a new digest and deliberately rebinds the same action sequence for the corrected-model replay.

The corrected finite exploration and replay must pass. The fixed-state violation query becomes UNSAT, the policy gap disappears, the review remains deferred, and the revision diff records the added claim and changed verification. Five selected core structural invariants also pass fixed-evidence SMT checks. SAT, missing policies, high telemetry counts, and the intentional simulated defect never become confirmed implementation defects.

Artifacts are retained under ignored `.twinlens/cross/`: initial/before/after reports, solver queries and results, counterexample, strengthened specification, corrected exploration/replay, core invariant results, diff, and `report.json`. Final bounds and counts are recorded in [self-observation milestones](self-observation.md). Tests cover real Z3 results, resource-limited unknown, adapter timeout transport, concrete decoding, direct agreement, rule/policy/mapping boundaries, review preservation, malformed evidence, and allocation failure. General domain simulation, runtime instrumentation, automatic mapping inference, and authentication policy profiles remain later work.
