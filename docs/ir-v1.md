# Twinlens IR v1

The seed transport is UTF-8 JSON. TypeScript emits it; Zig validates it before admitting records to its store. JSON keeps the initial boundary inspectable without introducing a protocol generator. Any incompatible field or semantic change requires a new `schema_version`; unknown versions and fields are rejected rather than silently discarded.

Canonical code definitions are [Zig IR](../src/core/ir.zig) and [TypeScript transport](../packages/transport/src/index.ts). Cross-language tests exercise the same valid and invalid fixtures against both. Zig remains the semantic authority; TypeScript validation checks the transport contract and does not perform SA/BT judgment.

## Document

Every document contains all six fields:

```json
{
  "schema_version": 1,
  "revision": "revision-identifier",
  "subjects": [],
  "symbols": [],
  "observations": [],
  "relations": []
}
```

Collections are arrays and preserve input order. A revision identifies the source/configuration snapshot chosen by the caller; Phase 0 does not derive Git revisions. Every observation and relation must match its enclosing document's revision. Distinct records of the same ID are rejected, even if their contents are identical.

All fields in each record are required, including nullable fields. Unknown fields, duplicate JSON keys, nonfinite measurements, numeric strings for numeric fields, invalid enums, and invalid references are rejected. There is no arbitrary payload field that could carry an AST or compiler object. Identity/revision/name/reason text must be nonempty, well-formed UTF-8 without ASCII control characters. Numbers are finite IEEE-754 doubles; counts beyond exact double precision require a future wire version.

## Sources and subjects

A `Source` has `path`, `language`, `span: {start, end}`, `producer`, and `confidence` (`high`, `medium`, or `low`). Spans are unsigned 32-bit, zero-based, half-open **UTF-8 byte offsets** into the source. Adapters must convert compiler-specific coordinates, including TypeScript's UTF-16 offsets. Start may equal end, but cannot exceed it. Phase 0 validates structure, not whether a span lies in a real source file.

Paths are case-sensitive, project-relative, slash-separated strings. Absolute paths, drive prefixes, backslashes, empty segments, `.` and `..` segments are rejected. Adapters must canonicalize paths before emitting them. Core validation does not access the source filesystem or resolve symlinks.

A `Subject` contains:

- `id`: subject ID.
- `key`: `project`, `language`, `path`, `kind`, `name`, and `discriminator`.
- `source`: source/provenance record whose path and language match the key.

Project, kind, and language names are open vocabulary; the core does not hardcode a frontend language. A `Symbol` contains `id`, a `subject` reference, and its display `name`. Sources live on the referenced subject rather than being copied into each symbol. There is at most one symbol identity per subject; aliases can later be modeled as distinct subjects/relations.

## Stable IDs

Zig uses distinct ID wrapper types; TypeScript uses branded strings. On the wire an ID is a prefix followed by 64 lowercase hexadecimal SHA-256 characters. The hash input is a sequence of fields. Encode each field as UTF-8, prefix it with a four-byte unsigned big-endian byte length, and concatenate those framed fields. No JSON serialization or Unicode normalization is involved in hashing.

| Record      | Prefix | Ordered hash fields                                                                                         |
| ----------- | ------ | ----------------------------------------------------------------------------------------------------------- |
| Subject     | `sub_` | `subject`, project, language, path, kind, name, discriminator                                               |
| Symbol      | `sym_` | `symbol`, subject ID                                                                                        |
| Observation | `obs_` | `observation`, revision, subject ID, metric, source producer                                                |
| Relation    | `rel_` | `relation`, revision, from ID, kind, target status, target subject ID or unresolved reason, source producer |

The core recomputes every identity and rejects mismatches. IDs do not depend on array order or ingestion order. Producer identifiers should include a sensor/extractor version when its output semantics change.

| Change                                                                    | Identity behavior                                                                   |
| ------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Same declaration rescanned                                                | Same subject/symbol ID                                                              |
| Span moves, measurement changes, or revision changes                      | Same subject/symbol ID; observation/relation IDs change with revision               |
| Project, language, file path, scoped name, kind, or discriminator changes | New subject/symbol ID                                                               |
| Duplicate names in different files/scopes                                 | Distinct keys and IDs                                                               |
| Overloads/anonymous declarations in the same scope                        | Adapter supplies distinct, repeatable discriminators                                |
| Deletion                                                                  | Subject absent in the new document; remaining references to it are invalid          |
| Same key later recreated                                                  | Same ID; distinguish incarnations by revision until a future lifecycle model exists |

Discriminators must be stable across repeated scans. An adapter may use a declaration ordinal when no stronger discriminator exists, but must document identity churn when declarations reorder. Source offsets should not be used as the default discriminator. Rename tracking and historical identity mapping are deferred.

An observation ID permits one observation per `(revision, subject, metric, producer)`. Relation IDs represent unique semantic edges, not individual call-site events. A later sensor needing call-site multiplicity must model distinct call-site subjects or adopt an explicit extension; duplicate edge IDs are not silently merged.

## Observations

An observation contains `id`, `subject`, `metric`, `measurement`, `source`, and `revision`. The subject must exist in the same document. Metrics are open names such as `function.args.count`; Phase 0 validates values as finite numbers without assigning metric-specific semantics.

| State          | `measurement`                                                             | Meaning                               |
| -------------- | ------------------------------------------------------------------------- | ------------------------------------- |
| Measured zero  | `{"status":"measured","value":0,"reason":null}`                           | The sensor measured zero              |
| Measured value | `{"status":"measured","value":3,"reason":null}`                           | The sensor measured a finite number   |
| Unknown        | `{"status":"unknown","value":null,"reason":"body not observed"}`          | The value could not be established    |
| Unsupported    | `{"status":"unsupported","value":null,"reason":"sensor not implemented"}` | The producer cannot measure this case |
| Missing        | No observation record                                                     | No claim about measurement or support |

Measurements alone are not findings or violations. No argument-count threshold or other design judgment is embedded in this contract.

## Relations

A relation contains `id`, `from`, `kind`, `target`, `source`, and `revision`. Its kind is an open relation name, such as `calls`. The source subject must exist. The target uses one of two explicit shapes:

```json
{ "status": "resolved", "subject": "sub_<64 lowercase hex characters>", "reason": null }
```

```json
{ "status": "unresolved", "subject": null, "reason": "dynamic call target" }
```

Resolved targets must exist in the same document. Unresolved targets require a reason and cannot pretend to reference a known subject.

## Storage and compatibility

`Store.decode` owns its parsed records and strings independently of the input buffer. Validation finishes before the store is returned. `Store.deinit` releases the document. Query results own their outer slice but borrow record strings from the store and must not outlive it. Encoding produces a complete IR document; CLI query output is a projection and is not itself an importable document.

Imports do not merge documents or mutate files. The Phase 1 store adds owned indexes and explicit file replacement. The IR v1 wire schema remains unchanged. See [Phase 1](phase1.md) for snapshot envelopes, query filters, partial-update invalidation, and revision-aware diff semantics.

The fixture generator exercises same-name subjects in separate files, Unicode identity input, source spans, measured zero, unknown/unsupported values, and resolved/unresolved calls. Integration tests check both-language rejection of malformed records, unsupported versions, duplicate IDs, identity mismatches, and dangling references.
