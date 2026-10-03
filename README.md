# Twinlens

Twinlens combines Specification Analysis (SA) with Behavioral Telemetry (BT) to expose hidden assumptions through evidence from specifications and code.

Phase 0 provides the Zig semantic core, CLI, stable identity model, and TypeScript transport packages. Source analysis, sensors, TypeSpec lowering, and verification engines are later phases. The seed fixture is synthetic; it is not a self-analysis result.

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

Configuration is loaded only when `--config FILE` precedes the command. Its `max_input_bytes` defaults to 16 MiB and must be between 1 byte and 256 MiB. Configuration files are limited to 64 KiB. File paths are interpreted relative to the working directory. Transport source paths use a separate project-relative convention described in [IR v1](docs/ir-v1.md).

## CLI contract

| Command                                     | Standard output                                                            |
| ------------------------------------------- | -------------------------------------------------------------------------- |
| `import FILE`                               | Validated IR v1 JSON document, preserving array order                      |
| `query FILE [--subject ID] [--metric NAME]` | JSON object with `schema_version`, `revision`, and matching `observations` |
| `scan PATH`                                 | No output; unsupported-command diagnostic until Phase 1                    |
| `--help`, `--version`                       | Human-readable text                                                        |

Failures emit one JSON object to stderr with `code`, `message`, and `path` (nullable), and no successful result on stdout. Query with no matches succeeds with an empty list. A missing observation is not interpreted as a zero or as a failed measurement.

| Exit | Meaning                                                                 |
| ---- | ----------------------------------------------------------------------- |
| 0    | Success                                                                 |
| 1    | Internal/allocation/output failure                                      |
| 2    | Invalid arguments or config contents                                    |
| 3    | Unsupported command/capability                                          |
| 4    | Input/config I/O failure or input limit exceeded                        |
| 5    | Invalid IR, unsupported schema, or failed reference/identity validation |

## Architecture

Zig defines Twinlens semantics. TypeScript provides permanent compiler ecosystem integration. Both frontends exchange language-independent records with the core; compiler AST objects cannot cross the transport boundary.

| Location                | Responsibility                                                                                   |
| ----------------------- | ------------------------------------------------------------------------------------------------ |
| `src/core/`             | Typed IDs, IR, strict decoding, validation, owned document store, basic query                    |
| `src/main.zig`          | CLI, config, I/O, diagnostics                                                                    |
| `packages/transport/`   | TypeScript wire types, identity encoding, structural validation, JSON encoding                   |
| `packages/typescript/`  | Package boundary for the Phase 1 compiler adapter; currently creates empty observation documents |
| `packages/typespec/`    | Package boundary for later TypeSpec lowering; currently creates empty specification documents    |
| `fixtures/`, `scripts/` | Reproducible synthetic seed document and invalid-case generators                                 |
| `tests/`                | Transport conformance, integration, and dependency-boundary checks                               |

The transport package depends on neither frontend. Frontends depend only on transport for shared records. The Zig core imports only its own modules and the standard library. The seed store owns a single validated document; persistent storage, indexes, snapshots, and incremental updates belong to Phase 1.

See [IR v1](docs/ir-v1.md) for the wire contract and identity rules. Project planning documents and the working checklist currently live in the locally ignored `tmp/` directory.
