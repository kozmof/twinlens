# Twinlens

Twinlens combines Specification Analysis (SA) with Behavioral Telemetry (BT) to expose hidden assumptions through evidence from specifications and code.

Phase 6 adds Z3-backed symbolic queries, explicit SA-to-BT mappings, policy-aware cross-perspective findings, and a complete finding-to-correction workflow. Challenges, simultaneous response judgments, bounded Store history exploration, and counterexample replay provide executable evidence. TypeSpec specifications provide explicit claims and constraints for direct evaluation and structural verification. Existing capabilities provide TypeScript and Zig telemetry, potential dataflow relationships, source-linked evidence, reviewable responsibility hypotheses, and caller significance. Twinlens can analyze both language domains and compare revisions. Symbolic witnesses and bounded simulations remain distinct from observed implementation behavior; general runtime instrumentation remains later work.

Phase 7’s [authentication demonstration](docs/authentication-demo.md) exercises nine operations with explicit policy profiles and replayable synthetic histories. Run `pnpm self:auth` to compare weak specifications, deliberate simulated violations, and policy-enforced behavior.

## Toolchain

| Tool       | Supported baseline             |
| ---------- | ------------------------------ |
| Zig        | 0.16.0                         |
| Node.js    | 26.10.0 (26.x)                 |
| pnpm       | 10.17.1                        |
| TypeScript | 7.0.2, pinned in the workspace |

The implementation uses Zig 0.16's `std.process.Init` and `std.Io` APIs. See the [Zig release notes](https://ziglang.org/download/0.16.0/release-notes.html). CI uses Linux x86_64; other targets have not been validated yet.

## Build and verify

With the toolchains above installed:

```sh
pnpm install --frozen-lockfile
pnpm build
pnpm check
```

`pnpm check` runs formatting, lint, TypeScript package type checking, both language builds, Zig unit tests, and TypeScript/CLI integration tests. CI runs the same command. For individual checks:

```sh
zig build test
pnpm typecheck
pnpm test:ts
pnpm test:integration
```

If a managed environment supplies an unwritable temporary directory, use `TMPDIR=/tmp pnpm check`. To discard stale TypeScript incremental diagnostics after a toolchain/configuration change, use `pnpm exec tsc -b --force`.

## Scan a project

```sh
./zig-out/bin/twinlens scan tsconfig.json --project twinlens --out baseline.json
./zig-out/bin/twinlens query baseline.json --symbol scanProject --metric function.args.count
./zig-out/bin/twinlens query baseline.json --relations --relation calls
./zig-out/bin/twinlens diff baseline.json baseline.json
pnpm self:observe
./zig-out/bin/twinlens scan tsconfig.json --language both --project twinlens --out whole.json
pnpm self:observe:all
pnpm self:analyze
pnpm self:verify
pnpm self:explore
```

See [Phase 5](docs/phase5.md) for challenge/oracle contracts, bounded exploration, replay, and historical equivalence. See [Phase 4](docs/phase4.md) for TypeSpec decorators, specification commands, evaluation outcomes, and structural limits. See [Phase 3](docs/phase3.md) for relationships, evidence, findings, review commands, and caller scoring. Large analysis reports require an explicit input-limit config, as shown there. See [Phase 2](docs/phase2.md) for Zig syntax support, uncertainty, and combined scans. See [Phase 1](docs/phase1.md) for sensor definitions, snapshot formats, file updates, and analysis limits. The source adapter uses the TypeScript 6.0.3 compiler API; TypeScript 7.0.2 remains the build compiler.

## Try the seed boundary

```sh
pnpm fixture
./zig-out/bin/twinlens import fixtures/seed-v1.json
./zig-out/bin/twinlens query fixtures/seed-v1.json --metric function.args.count
```

`pnpm fixture` builds the TypeScript packages and regenerates the committed fixture through the transport encoder. Import validates the whole document before emitting it. Query validates the whole document before filtering observations. Neither command modifies its input or persists a database.

```sh
zig build run -- --help
./zig-out/bin/twinlens --config twinlens.example.json import fixtures/seed-v1.json
```

Configuration is loaded only when `--config FILE` precedes the command. Its `max_input_bytes` defaults to 16 MiB and must be between 1 byte and 256 MiB. The optional `typescript_adapter` setting locates the built adapter (default: `packages/typescript/dist/cli.js`). The optional `typespec_adapter` defaults to `packages/typespec/dist/cli.js`. The optional `solver_adapter` defaults to `packages/solver/dist/cli.js`. Configuration files are limited to 64 KiB. File paths are interpreted relative to the working directory. Transport source paths use a separate project-relative convention described in [IR v1](docs/ir-v1.md).

## CLI contract

| Command                                                                          | Standard output                                                            |
| -------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `import FILE`                                                                    | Validated IR v1 JSON document, preserving array order                      |
| `query FILE [--subject ID] [--metric NAME]`                                      | JSON object with `schema_version`, `revision`, and matching `observations` |
| `scan INPUT [--language LANGUAGE] [--project NAME] [--revision ID] [--out FILE]` | Snapshot JSON, or atomically write a snapshot                              |
| `diff BEFORE AFTER [--out FILE]`                                                 | Snapshot differences as JSON                                               |
| `update BASE REPLACEMENT --file PATH [--out FILE]`                               | Updated IR; invalidated aggregates become unknown                          |
| `analyze SNAPSHOT [--previous REPORT] [--out FILE]`                              | Evidence, hypotheses, caller scores, and preserved reviews                 |
| `review REPORT --finding ID --status STATE --note TEXT [--out FILE]`             | Updated review state; output is atomic with `--out`                        |
| `compile INPUT [--project NAME] [--revision ID] [--out FILE]`                    | Validated specification JSON                                               |
| `inspect ROOT SNAPSHOT [--out FILE]`                                             | Structural facts and finite graph evidence                                 |
| `evaluate SPECIFICATION EVIDENCE [--out FILE]`                                   | Constraint outcomes and source-linked evidence                             |
| `challenges SPECIFICATION [--out FILE]`                                          | Generated suspicious-case questions                                        |
| `judge SPECIFICATION REQUEST [--out FILE]`                                       | Policy-aware simultaneous response judgments                               |
| `explore MODEL [--out FILE]`                                                     | Bounded histories, coverage, and counterexamples                           |
| `replay REQUEST [--out FILE]`                                                    | Replayed transition evidence and judgments                                 |
| `solve QUERY [--out FILE]`                                                       | Symbolic outcome, model, concrete witness, and optional replay             |
| `cross INPUT [--previous REPORT] [--out FILE]`                                   | Combined policy, mapping, evidence, challenge, and verification report     |
| `cross-diff BEFORE AFTER [--out FILE]`                                           | Cross-lens revision history and semantic differences                       |
| `auth MODEL [--out FILE]`                                                        | Bounded synthetic authentication histories and policy-aware judgments      |
| `auth-replay REQUEST [--out FILE]`                                               | Validated authentication trace replay                                      |
| `--help`, `--version`                                                            | Human-readable text                                                        |

Failures emit one JSON object to stderr with `code`, `message`, and `path` (nullable), and no successful result on stdout. Query with no matches succeeds with an empty list. A missing observation is not interpreted as a zero or as a failed measurement.

| Exit | Meaning                                                                   |
| ---- | ------------------------------------------------------------------------- |
| 0    | Success                                                                   |
| 1    | Internal/allocation/output failure                                        |
| 2    | Invalid arguments or config contents                                      |
| 3    | Unsupported command/capability                                            |
| 4    | Input/config/output I/O failure, adapter failure, or input limit exceeded |
| 5    | Invalid IR, unsupported schema, or failed reference/identity validation   |

## Architecture

Zig defines Twinlens semantics. TypeScript provides permanent compiler ecosystem integration. Both frontends exchange language-independent records with the core; compiler AST objects cannot cross the transport boundary.

| Location                | Responsibility                                                                                                                                                                                                          |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/core/`             | Typed IDs, IR/snapshot validation, indexed store, queries, file replacement, diff, evidence, findings, significance, constraint evaluation, response oracles, finite histories, symbolic encoding, and cross-lens rules |
| `src/main.zig`          | CLI, config, adapter orchestration, I/O, diagnostics                                                                                                                                                                    |
| `src/adapters/`         | Zig AST extraction and static telemetry, separate from the semantic core                                                                                                                                                |
| `packages/transport/`   | TypeScript IR/snapshot types, identity encoding, structural validation, JSON encoding                                                                                                                                   |
| `packages/typescript/`  | Compiler project loading, source extraction, static sensors, snapshot production                                                                                                                                        |
| `packages/typespec/`    | TypeSpec compiler integration, decorators, and specification lowering                                                                                                                                                   |
| `packages/solver/`      | Official Z3 WASM execution and model transport; core supplies all assertions                                                                                                                                            |
| `fixtures/`, `scripts/` | Reproducible synthetic seed document and invalid-case generators                                                                                                                                                        |
| `tests/`                | Transport conformance, integration, and dependency-boundary checks                                                                                                                                                      |

The transport package depends on neither frontend. Frontends depend only on transport for shared records. The Zig core imports only its own modules and the standard library. The core owns indexed validated records; snapshots persist as explicit JSON files. Partial file replacement invalidates dependent aggregates. Phase 5 checks finite Store histories through conservative refresh; minimal dependency-based incremental scanning and general historical domain policies remain later work.

See [IR v1](docs/ir-v1.md) for the wire contract and identity rules. Project planning documents and the working checklist currently live in the locally ignored `tmp/` directory.

Development uses a [self-application checklist](docs/development.md) for substantial new analysis capabilities.

See [Phase 6](docs/phase6.md) for solver limits, policy rules, mappings, and report contracts. Run `TMPDIR=/tmp pnpm self:cross` for the full cross-lens self-application gate.
