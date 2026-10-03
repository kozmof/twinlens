# TypeScript observation and history

Phase 1 observes code through the TypeScript compiler API and lowers its results to the Zig core. It does not execute the program or turn measurements into design judgments.

## Scan and inspect

```sh
pnpm install --frozen-lockfile
pnpm build
./zig-out/bin/twinlens scan tsconfig.json --project twinlens --out baseline.json
./zig-out/bin/twinlens query baseline.json --symbol scanProject --metric function.args.count
./zig-out/bin/twinlens query baseline.json --path packages/transport/src/index.ts
./zig-out/bin/twinlens query baseline.json --relations --relation calls --symbol scanProject
```

The scan input is a `tsconfig.json` path or a directory containing one. The root is the configuration's directory. Project references below that root are loaded recursively, and inherited compiler settings are honored. A solution config with only references works. Reference cycles are visited once. A reference outside the root is rejected; select a common solution root to scan multiple packages.

Source files below the scan root are included, except declaration files and `node_modules`. Imported local source files can be included even when not explicitly listed as root files. JavaScript is included when the TypeScript configuration allows it. Standard libraries and external declarations provide type information but do not become subjects. UTF-8 source, including a BOM, is supported; other source encodings are rejected to avoid incorrect byte locations. Source edits detected during loading abort the scan.

The adapter uses `typescript-api`, a pinned npm alias for TypeScript 6.0.3, while repository builds continue to use TypeScript 7.0.2. This keeps source analysis on the classic [TypeScript compiler API](https://github.com/microsoft/TypeScript/wiki/Using-the-Compiler-API). Changing the analysis compiler can change diagnostics or symbol resolution and is recorded in each snapshot.

The default adapter path is `packages/typescript/dist/cli.js`, relative to the working directory. To invoke the binary elsewhere, set `typescript_adapter` to the built adapter's absolute path in an explicit config file. The CLI launches Node directly with an argument array. It validates the returned snapshot in Zig before emitting or persisting it. `max_input_bytes` also bounds adapter stdout; stderr is bounded to 64 KiB.

Compiler diagnostics appear in the snapshot's `diagnostics` array with category, code, message, source path, and byte span when available. Syntax/type errors do not automatically make observations into findings. A successful partial scan can contain compiler errors; consumers must examine diagnostics and coverage. A missing/unreadable configuration or failed adapter produces an error exit and no new snapshot.

## Subjects, identity and locations

The adapter extracts files, functions, methods, constructors, accessors, arrow functions, parameters, variables, binding elements, classes, interfaces, aliases, enums and properties. Overload declarations and implementations are separate subjects. Calls bind to an available implementation rather than treating an overload signature as an executed body.

Names carry lexical function/class scope. Same-name declarations use an ordinal within `(file, kind, scoped name)`; unrelated names do not advance that counter. Anonymous functions use their binding name when available. Reordering same-name overloads or anonymous declarations can change ordinals. Renames remain removals/additions, not automatically inferred moves.

Source spans are half-open UTF-8 byte ranges into the original file, including any UTF-8 BOM. The adapter converts TypeScript's UTF-16 coordinates. Counts and locations always describe the selected source snapshot, not observed runtime executions.

## Sensor definitions

| Metric                                        | Subject              | Counting rule                                                                                                                                                |
| --------------------------------------------- | -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `function.args.count`                         | Function             | Declared parameters, including optional/rest parameters; excludes the special TypeScript `this` parameter                                                    |
| `function.parameter.property_count`           | Parameter            | Named properties exposed by its static object/union/intersection type; primitives have zero; `any`, `unknown`, and unconstrained type parameters are unknown |
| `function.lines`                              | Function             | Inclusive line range of the declaration, including its signature/body and excluding leading comments                                                         |
| `function.branch.count`                       | Function             | Count of `if`, conditional expressions, loops, non-default `case`, `catch`, and `&&`/`                                                                       |     | `/`??`; excludes nested function bodies; bodyless declarations are unknown |
| `function.callers`                            | Function             | Distinct scanned subjects with resolved incoming call edges; file-level callers can be included                                                              |
| `function.callees`                            | Function             | Distinct scanned function subjects with resolved outgoing call edges                                                                                         |
| `function.calls.unresolved.count`             | Function             | Unresolved call sites, before edge deduplication                                                                                                             |
| `value.read_count`, `value.write_count`       | Value/parameter      | Resolved syntactic references across included files, with lexical symbol binding                                                                             |
| `property.read_count`, `property.write_count` | Property declaration | Resolved property references across included files, including literal element accesses                                                                       |

Plain assignment is a write; compound assignment and increment/decrement are both reads and writes. Declaration initialization is a write for variables/properties. Function parameter entry is not counted as a body write. Receivers and computed indexes are read even when the accessed property is written. Object binding reads are associated with a known declared property where resolvable. Destructuring assignment targets are writes. Type-only references, declaration names, and import/export declarations are excluded from runtime usage counts.

Call edges describe static declaration relationships, not proof of runtime dispatch. Direct/imported functions, overload implementations, function initializers, explicit constructors, and statically resolved methods can be linked. Callback parameters, external functions, unresolved dynamic targets, and implicit constructors remain unresolved when there is no scanned implementation. Dynamic reassignment, alias flow, overriding, reflection, spreads, and heap identity are not fully modeled. Repeated calls with the same endpoints share one semantic edge; source evidence retains the first occurrence.

The snapshot counts unresolved call sites and unresolved property/element accesses in `coverage`. A measured usage count is the number of **resolved syntactic references**, not a guarantee that every runtime access was found. Known zero, unknown, unsupported, and missing retain the distinctions from IR v1. High counts do not produce findings or violations.

## Snapshot v1

A snapshot wraps an unchanged IR v1 document:

| Field              | Meaning                                                                                                    |
| ------------------ | ---------------------------------------------------------------------------------------------------------- |
| `snapshot_version` | `1`; other versions are rejected                                                                           |
| `project`          | Stable project identity; every subject must belong to it                                                   |
| `configuration`    | Adapter and analysis-compiler versions, effective-options/dependency fingerprint, and config paths/digests |
| `files`            | Sorted scanned source paths and SHA-256 digests of source bytes                                            |
| `diagnostics`      | Compiler diagnostics, separate from the IR observations                                                    |
| `coverage`         | Unresolved call-site and property-access counts                                                            |
| `document`         | Validated IR v1 subjects, symbols, observations and relations                                              |

The default revision is a content hash over the adapter/compiler identity, source inventory, config digests, and effective options/dependency fingerprint. Compiler-consumed declaration files and inherited external configuration content contribute to that fingerprint. Machine-specific root paths are normalized. `--revision ID` supplies a caller-selected label instead; it is not assumed to be a Git commit.

`--out FILE` atomically replaces a file after analysis and validation finish. Its parent directory must exist. Snapshots remain ordinary JSON files and can be retained under arbitrary revision names. `import` accepts either an IR document or a snapshot and emits only its IR document. `query` accepts both. No hidden database is required.

## Indexed queries

The Zig store owns validated records and indexes subjects, symbol names/IDs, observations by subject/metric/path/revision, and relations by kind/endpoint. It rebuilds these indexes after a successful replacement. Query results are sorted by record ID, independent of input array order.

Observation queries combine `--subject`, `--symbol`, `--metric`, `--relation`, `--path`, `--start`, `--end`, and `--revision`. A symbol name can match multiple same-name declarations; use a symbol ID to disambiguate. `--relation KIND` selects observations whose subjects participate at either end of an edge of that kind. Source offsets filter overlapping half-open byte spans and require `--path`.

`--relations` switches the result collection from `observations` to `relations`; it supports endpoint, symbol, kind, path/span, and revision filters. Combining it with `--metric` is an argument error. Zero matches is a successful empty result, not an unknown measurement.

## Diff

```sh
./zig-out/bin/twinlens scan tsconfig.json --project twinlens --out after.json
./zig-out/bin/twinlens diff baseline.json after.json --out changes.json
```

Diff requires two valid snapshots from the same project. It reports added, removed, and changed files, subjects, symbols, observations, and relations, plus both revision labels and whether configuration changed. Each changed record contains `before` and `after` evidence.

Observation matching uses `(subject, metric, producer)` and relation matching uses `(from, kind, target status/identity/reason, producer)`. Revision-derived IDs alone do not create changes. Measurements and source evidence are compared, so moving a source span is a change even when a numeric value stays the same. An absent observation is a removal; measured zero remains an explicit value. Renames or new endpoints appear as removal/addition. Configuration changes are exposed rather than silently treated as directly comparable sensor runs.

## File replacement and removal

```sh
./zig-out/bin/twinlens update baseline.json replacement.json --file src/example.ts --out updated-ir.json
```

The replacement is a validated complete IR document or snapshot. Records owned by the selected source file replace its previous subjects, symbols, observations, and relations. An empty replacement document removes that file. Other source records are retained, all observation/relation IDs are rebased to the replacement revision, and indexes are rebuilt. Several files can be replaced together through the Zig `Store.replaceFiles` API. Cross-project replacement is rejected.

Incoming edges to deleted subjects become unresolved and explicitly require caller rescanning. After a partial file update, measured project-wide caller/callee and value/property usage counts become unknown until a full scan recomputes them. Existing unsupported and unknown states are preserved. This avoids retaining stale measured aggregates. Repeating the same update is deterministic. Failed validation leaves the original store intact.

`update` emits IR, not a new snapshot: it cannot certify source-file fingerprints or compiler diagnostics for an edited workspace. Run `scan` to create a trustworthy new snapshot. Automatic file watching, dependency-driven rescans, and proving full/incremental equivalence remain later work.

## Self-observation milestone

```sh
TMPDIR=/tmp pnpm self:observe
```

This builds Twinlens, scans its TypeScript packages, and retains `.twinlens/self/baseline.json`. It inspects scanner argument telemetry and the property count of the IR identity key. It then copies the source/configuration into a temporary project, verifies that the copy's baseline matches, adds an optional argument to `createDocument` in the copy, rescans, and verifies an argument-count change from 1 to 2 through the Zig diff engine.

The original source is not edited by the experiment. The temporary copy is removed after use; baseline, edited snapshot, full diff, and report remain under `.twinlens/self/`. That directory is ignored because it contains generated snapshots. [The retained milestone report](self-observation.md) records the validated run and the command needed to reproduce it.
