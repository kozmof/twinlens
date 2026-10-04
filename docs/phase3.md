# Relationships, evidence, and reviewable hypotheses

Phase 3 adds potential dataflow relationships to the TypeScript and Zig adapters. The Zig core builds evidence, candidate responsibility clusters, findings, and caller significance from their shared IR. It does not need either compiler AST.

## Analyze and review

```sh
pnpm build
./zig-out/bin/twinlens scan tsconfig.json --language both --project twinlens --out snapshot.json
./zig-out/bin/twinlens --config analysis-config.json analyze snapshot.json --out analysis.json
./zig-out/bin/twinlens --config analysis-config.json review analysis.json \
  --finding fnd_REPLACE_WITH_ID --status deferred \
  --note "Inspect unresolved aliases before extracting responsibilities" --out reviewed.json
./zig-out/bin/twinlens --config analysis-config.json analyze next-snapshot.json \
  --previous reviewed.json --out next-analysis.json
pnpm self:analyze
```

Create `analysis-config.json` with `{"max_input_bytes":134217728}` for large self-snapshots/reports. Relationship-rich whole-project snapshots exceed the CLI's default 16 MiB input limit. The self-observation scripts write their own explicit 128 MiB configuration. Reports embed the input snapshot, so their size includes all original evidence. `--out` atomically writes the result; omitting it emits JSON. Neither analyze nor review silently modifies its input. Review requires an existing finding ID, a valid state, and a nonempty note. Invalid reports or mismatched project histories fail before replacing output.

## Relationship vocabulary

Events are ordinary source-linked subjects with kinds `branch`, `call`, `return`, and `computation`. Each source file is also represented by a `subsystem` subject; these are source modules, not inferred architectural boundaries.

| Relation        | Meaning                                                                       |
| --------------- | ----------------------------------------------------------------------------- |
| `contains`      | Function owns a declaration or usage event.                                   |
| `belongs_to`    | Declaration belongs to its source module.                                     |
| `uses_property` | A resolved value/parameter is the receiver of a resolved property access.     |
| `controls`      | Value or property occurs in a branch/switch/loop condition.                   |
| `argument`      | Value or property occurs in a call argument.                                  |
| `returns`       | Value or property occurs in a return expression.                              |
| `input`         | Value or property occurs in a supported initializer or assignment expression. |
| `output`        | Computation writes a resolved destination value/property.                     |
| `flows_to`      | A potential direct dependency from a computation input to its destination.    |
| `flow_unknown`  | An expression or assignment contains unresolved flow.                         |

Repeated semantic edges are deduplicated. Each retained edge has an original byte span and extractor provenance. Events have scoped names and ordinal discriminators; inserting earlier events can change their identity. Findings are anchored to function identities, not event ordinals.

TypeScript handles function declarations and expressions, arrows (including expression returns), property/element accesses supported by its existing resolver, assignments, variable/property initializers, calls/new expressions, and branch conditions. Zig handles its existing lexical values and fields, variable initializers, direct/compound assignments, calls/builtins, return expressions, and if/while/for/switch/boolean/error/optional conditions. Nested function bodies are excluded from enclosing expression dependencies. Zig destructuring flow and unresolved assignment targets emit `flow_unknown`; scalar usage counting remains available.

These are syntactic potential dependencies. A value occurring in an argument expression is not mapped to a callee parameter. The adapters do not follow aliases through the heap, propagate capture values or intermediate transformations transitively, prove control-dependent return values, distinguish execution paths, or model exceptions/interprocedural effects. A receiver occurring in an expression is also an input; that does not mean the whole object is semantically consumed. Computed accesses and external/generic Zig semantics remain incomplete. Every valid file has an unsupported `file.flow` observation explaining this boundary. There is no claim that an empty edge set proves independence.

## Evidence and finding contract

`analysis_version: 1` reports contain `generator`, the complete `snapshot`, `evidence`, `clusters`, `findings`, `significance`, and `reviews`. Required fields, enums, typed IDs, referenced records, and score inputs are validated by the Zig core. IR/snapshot versions remain unchanged; relation and metric names are extensible. The extractor versions advance to `typescript-bt/2` and `zig-bt/2`, so unchanged user source receives a new content-derived revision when relationship extraction is introduced. Producer-dependent observation/relation identities also change across that upgrade; subject identities remain stable.

Evidence has an `evd_` identity, subject, kind/key, origin, extractor, confidence, original observation/relation IDs, parent evidence IDs, source locations, and a summary. Origin distinguishes `code`, `specification`, `inference`, `test`, and `trace`; current BT extraction produces code-backed leaves and inference aggregates. Other origins are represented for future producers, not fabricated by BT. Current aggregates link directly to leaf evidence; cyclic/deeper hierarchies are rejected. Navigate an aggregate to its parents, then resolve leaf observation/relation IDs in `report.snapshot.document`. Original producer/confidence/span information remains on each source record.

For each function, the analyzer connects used parameters that occur in the same owned usage event and computes connected components. Unused parameters are excluded. A `clu_` cluster identifies its function and sorted parameter members; it retains event IDs and leaf evidence. Two or more disconnected components produce one informational `responsibility_split` hypothesis. This is deliberately local, syntactic, and conservative about its conclusion: hidden/transitive dependencies can join apparently separate groups. Numeric branch/argument thresholds do not generate defects.

Findings have a stable `fnd_` identity derived from generator, function identity, and finding kind. They carry subject, category, severity, status, hypothesis, evidence, generator, challenges, traces, suggestions, and the reviewed revision. Current findings are hypotheses, never constraint violations. Challenge/trace links are empty until actual records exist. Renaming/reidentifying a function creates a different finding; Twinlens does not guess rename equivalence.

Supported statuses are `open`, `confirmed`, `false_positive`, `accepted_risk`, `fixed`, `ignored`, and `deferred`. A review stores the latest explicit state, note, and reviewed revision. `analyze --previous` carries decisions to matching findings from the same project. Decisions for absent findings remain in the review ledger, and can reattach if the finding recurs. Absence never automatically means fixed. A reviewed state, including fixed, is retained when evidence changes; the prior reviewed revision remains visible so humans can revisit it. Evidence IDs change with the snapshot revision while finding IDs remain stable. There is no automatic severity escalation or lifecycle transition.

## Caller significance

The normalization scope is all `function` subjects in one snapshot, across included languages, including uncalled/bodyless functions. Only resolved function-to-function `calls` edges participate. File/test origins and unresolved targets are excluded. Repeated edges between the same caller and callee contribute once; call-site frequency is not recoverable from the deduplicated graph and is not invented.

For an edge from caller `c` to callee `t`:

```text
N = number of function subjects
out(c) = number of distinct resolved function callees of c
df(t) = number of distinct resolved function callers of t
local_share = 1 / out(c)
inverse_prevalence = 1 + ln((N + 1) / (df(t) + 1))
normalization = 1 + ln(N + 1)
score = local_share * inverse_prevalence / normalization
```

Scores are finite and between zero and one. An empty graph produces no scores. Each row retains `function_population`, `caller_out_degree`, `callee_in_degree`, `edge_count` (one), all calculation terms, and the supporting relation/evidence IDs. The decoder checks counts against the embedded graph as well as checking the formula. A specialized target scores higher than a ubiquitous utility when local shares match. Scores describe an edge, not function quality. Changing the scan scope changes normalization; compare the raw inputs when comparing projects or revisions.

## Self-application and validation

The [self-analysis gate](../scripts/self-analyze.mjs) captures query-engine branch metrics, normalization flow, and sensor caller scores. Its controlled experiment reverses only the normalization extraction in an isolated copy, reconstructs the hypothesis and before evidence, then compares the actual implementation. The initial copy must match the real tree. The callback's five branches become one in the callback and four in `normalizeOptionValue`; this is a testable responsibility boundary, not a reduction in total logic. The hypothesis remains deferred because a JSON serialization callback legitimately combines key filtering with value handling.

The gate retains `.twinlens/analysis/{before,after,before-analysis,reviewed,after-analysis,diff,report}.json`. These large generated files are ignored by Git. CI runs the full test suite and all three self-observation/analysis gates. Tests cover both adapters' relationships, evidence navigation, common versus specialized callers, empty graphs, all lifecycle states, disappearance/recurrence, invalid references, project mismatch, score tampering, normalization equivalence, and allocation-failure cleanup for analysis/decoding/review/rescan ownership.

Follow the [development checklist](development.md) for each substantial new capability.
