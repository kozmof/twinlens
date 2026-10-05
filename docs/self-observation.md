# Self-observation milestones

Phase 1 scanned Twinlens's own TypeScript packages through the compiler adapter and imported the result into the Zig core. The run completed with 0 compiler diagnostics.

| Baseline measurement                 | Result |
| ------------------------------------ | ------ |
| Source files                         | 7      |
| Subjects                             | 601    |
| Observations                         | 1603   |
| Relations                            | 796    |
| Unresolved call sites                | 356    |
| Unresolved property/element accesses | 608    |

These are static code observations. Unresolved cases remain visible; the counts do not imply defects or complete runtime coverage.

The [scanner](../packages/typescript/src/scanner.ts) reports two arguments for `scanProject`. The [IR identity encoder](../packages/transport/src/index.ts) reports six named properties on `subjectId`'s `key` parameter. Both observations retain source-byte spans and producer identity.

The controlled experiment first confirmed that an isolated copy produced the same IR as the real source tree. It then added an optional parameter to `createDocument` in that copy. A fresh scan and the Zig diff engine identified `function.args.count` changing from **1 to 2** on the same function identity. No source edit from the experiment was applied to the working repository.

Baseline revision:

```text
e4adbaf9d72a7ae4d19afcd71a292d7f1c2e8e47b688f8de0c0ddfbf15f5dadb
```

SHA-256 of the retained baseline JSON:

```text
44ae5f0d38e521dc10c4a663d69097543cb527c3a3d716a216fd3052e7c989a1
```

Reproduce the experiment with `TMPDIR=/tmp pnpm self:observe` (the temp-directory override is only needed in restricted environments). It rebuilds both language domains and writes:

- `.twinlens/self/baseline.json` — full initial snapshot.
- `.twinlens/self/after.json` — snapshot from the controlled edit.
- `.twinlens/self/diff.json` — full source-linked comparison.
- `.twinlens/self/report.json` — selected self-evidence, counts, and hashes.

Generated snapshots are retained locally in the ignored `.twinlens/` directory. Source changes will change the baseline counts and digest; the command checks the experiment itself rather than enforcing these numbers as design limits. CI runs the same self-observation gate after the normal checks.

## Phase 2: both language domains

The combined gate passed on 2026-10-03 with 19 source files, 1641 subjects, 4176 observations, and 2124 relations. It retained 0 diagnostics and 12 unsupported observations. Coverage reports 1023 unresolved call sites and 2654 unresolved accesses. Zig diagnostics cover syntax only; these numbers do not claim compiler-equivalent analysis.

The combined call graph includes 98 resolved TypeScript edges and 136 resolved Zig edges. Every resolved endpoint exists in the combined snapshot. No cross-language FFI edges are inferred.

The isolated copy matched the original combined IR before editing. Adding an optional TypeScript parameter changed `createDocument`'s argument count from 1 to 2. Adding a guard in `src/core/identity.zig` changed `valid`'s branch count from 7 to 8, preserving its subject identity and source links.

Run `TMPDIR=/tmp pnpm self:observe:all` to reproduce the experiment. It retains `.twinlens/whole/{baseline,after,diff,report}.json` locally; these generated artifacts are ignored by Git. The report includes graph examples, source-linked metric changes, coverage, and a baseline digest. Counts can change as the implementation grows.

## Phase 3: evidence-guided normalization

The Phase 3 gate on 2026-10-04 applied branch telemetry to both query methods in `src/core/store.zig`, potential dataflow to compiler-option normalization, and caller significance to the scanner/flow adapters. It produced an informational responsibility-split hypothesis for the JSON normalization callback: `key` controls metadata filtering while `value` controls path normalization.

The justified change extracts `normalizeOptionValue` for direct testing. The callback's branch count changes from **5 to 1**, while the helper contains **4** branches. Equivalence tests preserve handling of root, local and external paths, relative strings, primitive values, object identity, and metadata-key filtering. Total logic was moved into a testable boundary, not eliminated. Both query methods report 13 syntactic branches in this run.

The self-analysis experiment reconstructs the pre-extraction code only in an isolated copy, verifies its finding and source evidence, and compares it with the real implementation. The finding retains its stable identity and a deferred review; the script does not claim that a legitimate JSON callback's dual role is a defect or automatically fixed. It also verifies normalization parameter-flow edges and finite caller scores backed by graph counts.

Run `TMPDIR=/tmp pnpm self:analyze`. Evidence, scores, reviewed hypotheses, snapshots, and the source-linked diff are retained in `.twinlens/analysis/`; the concise `report.json` records reproduction evidence and current counts. See [Phase 3's contract](phase3.md) for inference limits and lifecycle semantics.

## Phase 4: structural specification

`TMPDIR=/tmp pnpm self:verify` compiles `specs/twinlens.tsp` and evaluates five selected invariants against the real code and combined snapshot: core dependencies, AST-free Store representation, stable IDs, observation ownership, and valid references. An isolated fixture introduces a forbidden import, an AST field, and a dangling observation. All five constraints must report violations with source evidence. Missing evidence remains unknown, unsupported heap semantics remain unsupported, and the runtime claim stays deferred.

The gate retains specification, graph evidence, positive and negative reports, uncertainty cases, and `report.json` in ignored `.twinlens/specification/`. See [Phase 4](phase4.md) for the exact structural scope; positive results do not establish runtime heap safety. CI runs this gate alongside the three earlier self-application gates.

The final Phase 4 run on 2026-10-04 passed all four self-application gates and all 179 integration/unit tests in the TypeScript runner, alongside Zig unit tests. The combined scan covered 26 source files with zero compiler diagnostics. All five selected invariants were satisfied on the real project and violated in the deliberate negative fixture. Compiler-backed test suites run sequentially to stay within the development environment’s thread limit.

## Phase 5: replayable Store histories

`TMPDIR=/tmp pnpm self:explore` exercises the production `Store.replaceFiles` implementation against six finite source worlds scanned by the Zig adapter. The worlds cover changed measurements, stable declaration IDs, renamed symbols, and changed or removed call targets. The production adapter must satisfy six historical/structural constraints across the reachable finite graph. A test adapter intentionally omits deleted paths; its stale-record trace must reproduce, then pass against the corrected production adapter. An explicit six-step add/scan/modify/rescan/delete/rescan history ends with an empty Store.

Reports and replay requests remain under ignored `.twinlens/exploration/`; `report.json` records actual coverage and configured bounds. Refresh conservatively includes all current and previously stored paths. These results establish bounded correctness for that refresh policy, not universal equivalence or minimal incremental scanning. See [Phase 5](phase5.md) for semantics and limits.

The final run on 2026-10-04 exhausted the supplied finite graph after **168 transitions across 42 distinct states**, with no production counterexamples or unknown judgments. Bounds were depth 8, 2 file objects, 500 executions, and 60000 ms. The negative adapter produced 47 counterexamples; the selected trace reproduced its defect and passed against the native adapter. All 209 TypeScript/integration tests, Zig unit tests, and all five self-application gates passed. The combined scan covered 29 source files with zero compiler diagnostics.
