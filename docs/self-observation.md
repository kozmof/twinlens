# TypeScript self-observation milestone

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
