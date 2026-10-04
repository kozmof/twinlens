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
