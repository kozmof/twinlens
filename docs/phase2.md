# Zig observation and combined snapshots

Phase 2 adds a separate Zig frontend using `std.zig.Ast` from the pinned Zig 0.16.0 toolchain. It lowers syntax into the existing IR and keeps AST data outside `src/core`. The core can query, update, and diff either language or a combined snapshot.

```sh
pnpm build
./zig-out/bin/twinlens scan src --language zig --project twinlens --out zig.json
./zig-out/bin/twinlens scan tsconfig.json --language both --project twinlens --out whole.json
./zig-out/bin/twinlens query whole.json --relations --relation calls
./zig-out/bin/twinlens query whole.json --path src/core/identity.zig --metric function.branch.count
pnpm self:observe:all
```

`--language` defaults to `typescript`. Zig input is a directory or an individual `.zig` file. The directory is the source root; single-file scans use its parent. Combined input is a directory containing `tsconfig.json`, or that configuration's path. Both adapters use the configuration directory and the same project name. An explicit `--revision` applies to all observations and relations; otherwise the combined revision hashes both adapter revisions. Subject and symbol identities remain unchanged when snapshots are combined.

Zig discovery recursively includes regular `.zig` files, including `build.zig` and test sources. It skips symlinks, dot-prefixed entries, and directories/entries named `node_modules`, `zig-out`, `dist`, or `tmp`. It does not interpret `.gitignore` or execute `build.zig`. Check `files` for the exact inventory. File paths are relative to the selected root; selecting a different root changes identities. Source bytes must be UTF-8. `max_input_bytes` limits each Zig input file, and also bounds TypeScript adapter stdout in combined scans. An empty Zig inventory is an error.

## Supported observations

The adapter extracts file, function, parameter, local/global value, named container, named field, enum member, test, and capture subjects. Names include enclosing named declarations, with discriminators separating repeated names. Spans use UTF-8 byte offsets. Functions inside containers receive their own measurements; their branches do not contribute to the enclosing function. Tests are call-graph origins but do not receive function metrics.

Lexical lookup respects block scopes, declaration order for local values, function parameters, and `if`, `while`, `for`, `switch`, `catch`, and `errdefer` captures. Direct function calls, named container methods, and literal relative module imports can resolve to subjects. Named fields can resolve through an explicit local struct/union type, a single-item pointer to that type, or a typed initializer. Simple aliases are followed with a bounded recursion depth. Imports only resolve to files in the inventory. Package imports, build-module mappings, callbacks, computed calls, and compiler-dependent type expressions remain unresolved. Aliases to function values are not treated as direct function declarations.

| Metric                                        | Zig meaning                                                                                                                                                                                      |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `function.args.count`                         | Declared parameters, including `comptime`, `anytype`, and explicit receivers; variadic signatures are unknown.                                                                                   |
| `function.parameter.property_count`           | Named fields of a resolved struct/union; supported scalar types have zero. Generic, external, tuple, slice, and other unevaluated types are unknown.                                             |
| `function.lines`                              | Inclusive source lines occupied by the declaration.                                                                                                                                              |
| `function.branch.count`                       | One per `if`, `while`, `for`, non-else switch case, `catch`, `and`, `or`, and `orelse`; a multi-value switch case counts once. Bodyless declarations are unknown.                                |
| `function.callers`, `function.callees`        | Unique resolved incoming/outgoing call edges. Repeated call sites do not increase these counts.                                                                                                  |
| `function.calls.unresolved.count`             | Unresolved call sites, including builtins.                                                                                                                                                       |
| `value.read_count`, `value.write_count`       | Resolved syntactic references; declaration initialization counts as a write, parameter/capture entry does not. Destructuring assignments write each target. Compound assignments read and write. |
| `property.read_count`, `property.write_count` | Resolved named-field references, default initializers, and supported struct initializer fields. A property write still reads its receiver.                                                       |

These metrics share TypeScript's meanings but reflect different syntax. Zig `comptime` parameters are actual declared parameters; TypeScript type parameters are not. Zig receivers such as `self` count as parameters; a TypeScript `this` annotation does not. Zig uses `catch` expressions and `orelse`; TypeScript uses catch clauses and nullish coalescing. Counts include syntactic compile-time branches, not only branches that survive compilation. Function declarations without bodies are not assigned zero branches.

Usage metrics count resolved references, not complete runtime usage. Pointer dereferences and element accesses increment unresolved-access coverage; writing through a pointer does not count as assigning the pointer binding. Anonymous initializer fields without a supported contextual type are unresolved accesses. There is no heap/alias propagation, build graph evaluation, generic instantiation, `@This` inference, or comptime execution. Unresolved accesses have aggregate coverage counts; they do not produce fabricated resolved edges. Semantic relations are deduplicated and retain one source location per edge.

## Diagnostics and evidence limits

Every syntactically valid Zig file has an unsupported `file.semantics` observation stating the semantic-analysis limits. Builtins and unresolved calls appear in coverage and unresolved `calls` relations. Parameter shapes and variadic argument counts use unknown measurements with reasons. All Zig source provenance currently has medium confidence.

Malformed files retain their digest, file subject, unsupported `file.syntax` observation, and parse diagnostics with source spans. The scanner omits recovered declarations from those files. A successful scan can therefore include parse errors. There are no Zig compiler type diagnostics: syntax acceptance is not a compilation result. The [Zig language reference](https://ziglang.org/documentation/0.16.0/) defines the language; this adapter implements a bounded syntactic subset for telemetry.

Combined snapshots concatenate language inventories, diagnostics, and coverage, preserve configuration provenance, rebase revision-dependent IDs, and validate all references. Conflicting file inventories or configuration digests are rejected. The combined graph contains both language domains; it does not infer cross-language FFI edges.

`tests/phase2-cli.test.ts` checks spans, nested scopes, captures, unresolved calls, malformed files, properties, destructuring, signatures, and equivalent Zig/TypeScript metric fixtures. It also persists a combined snapshot, queries its graph, and verifies source-linked argument-count diffs in both languages. The core merge test checks project/configuration conflicts, duplicate files, and coverage overflow.

The whole-project gate in `scripts/self-observe.mjs --all` first checks that an isolated source copy produces the same combined IR. It then adds a TypeScript argument and a Zig guard in that copy, verifies both diffs, and retains the snapshots and report under `.twinlens/whole/`. See [the self-observation report](self-observation.md). CI runs both the original TypeScript gate and the combined gate.
