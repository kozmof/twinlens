import { createHash } from "node:crypto";

declare const idBrand: unique symbol;
export type Id<K extends string> = string & { readonly [idBrand]: K };
export type SubjectId = Id<"subject">;
export type SymbolId = Id<"symbol">;
export type ObservationId = Id<"observation">;
export type RelationId = Id<"relation">;

export interface Source {
  path: string;
  language: string;
  span: { start: number; end: number };
  producer: string;
  confidence: "high" | "medium" | "low";
}
export interface SubjectKey {
  project: string;
  language: string;
  path: string;
  kind: string;
  name: string;
  discriminator: string;
}
export interface Subject {
  id: SubjectId;
  key: SubjectKey;
  source: Source;
}
export interface Symbol {
  id: SymbolId;
  subject: SubjectId;
  name: string;
}
export type Measurement =
  | { status: "measured"; value: number; reason: null }
  | { status: "unknown" | "unsupported"; value: null; reason: string };
export interface Observation {
  id: ObservationId;
  subject: SubjectId;
  metric: string;
  measurement: Measurement;
  source: Source;
  revision: string;
}
export type RelationTarget =
  | { status: "resolved"; subject: SubjectId; reason: null }
  | { status: "unresolved"; subject: null; reason: string };
export interface Relation {
  id: RelationId;
  from: SubjectId;
  kind: string;
  target: RelationTarget;
  source: Source;
  revision: string;
}
export interface Document {
  schema_version: 1;
  revision: string;
  subjects: Subject[];
  symbols: Symbol[];
  observations: Observation[];
  relations: Relation[];
}

export function stableId<K extends string>(prefix: string, fields: string[]): Id<K> {
  const hash = createHash("sha256");
  for (const field of fields) {
    const bytes = Buffer.from(field, "utf8");
    const length = Buffer.alloc(4);
    length.writeUInt32BE(bytes.length);
    hash.update(length).update(bytes);
  }
  return (prefix + hash.digest("hex")) as Id<K>;
}
export function subjectId(key: SubjectKey): SubjectId {
  return stableId("sub_", [
    "subject",
    key.project,
    key.language,
    key.path,
    key.kind,
    key.name,
    key.discriminator,
  ]);
}
export function symbolId(subject: SubjectId): SymbolId {
  return stableId("sym_", ["symbol", subject]);
}
export function observationId(value: Omit<Observation, "id">): ObservationId {
  return stableId("obs_", [
    "observation",
    value.revision,
    value.subject,
    value.metric,
    value.source.producer,
  ]);
}
export function relationId(value: Omit<Relation, "id">): RelationId {
  return stableId("rel_", [
    "relation",
    value.revision,
    value.from,
    value.kind,
    value.target.status,
    value.target.subject ?? value.target.reason,
    value.source.producer,
  ]);
}
export function createDocument(revision: string): Document {
  text(revision, "revision");
  return {
    schema_version: 1,
    revision,
    subjects: [],
    symbols: [],
    observations: [],
    relations: [],
  };
}

function fail(message: string): never {
  throw new Error(message);
}
function object(value: unknown, keys: string[], context: string): Record<string, unknown> {
  if (
    value === null ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    Object.getPrototypeOf(value) !== Object.prototype
  )
    fail(`${context}: expected a plain object`);
  const actual = Reflect.ownKeys(value);
  if (
    actual.length !== keys.length ||
    actual.some((key) => typeof key !== "string" || !keys.includes(key))
  )
    fail(`${context}: unexpected or missing fields`);
  // Accessors and custom prototypes could execute arbitrary serialization behavior.
  for (const key of keys)
    if (!Object.hasOwn(Object.getOwnPropertyDescriptor(value, key) ?? {}, "value"))
      fail(`${context}: expected data properties`);
  return value as Record<string, unknown>;
}
function text(value: unknown, context: string): asserts value is string {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    !value.isWellFormed() ||
    Array.from(value).some((char) => char.charCodeAt(0) < 32 || char.charCodeAt(0) === 127)
  )
    fail(`${context}: expected nonempty UTF-8 text`);
}
function path(value: unknown): asserts value is string {
  text(value, "path");
  if (
    /[\\:]/u.test(value) ||
    value.split("/").some((part) => part === "" || part === "." || part === "..")
  )
    fail("path: expected canonical project-relative path");
}
function uint(value: unknown, context: string): asserts value is number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0 || value > 0xffffffff)
    fail(`${context}: expected u32`);
}
function source(value: unknown): asserts value is Source {
  const row = object(value, ["path", "language", "span", "producer", "confidence"], "source");
  path(row.path);
  text(row.language, "language");
  text(row.producer, "producer");
  if (!["high", "medium", "low"].includes(row.confidence as string))
    fail("source: invalid confidence");
  const span = object(row.span, ["start", "end"], "span");
  uint(span.start, "span.start");
  uint(span.end, "span.end");
  if (span.end < span.start) fail("source: reversed span");
}
function id(value: unknown, prefix: string): asserts value is string {
  if (typeof value !== "string" || !new RegExp(`^${prefix}[0-9a-f]{64}$`, "u").test(value))
    fail("invalid ID");
}
function identical(actual: unknown, expected: string) {
  if (actual !== expected) fail("identity mismatch");
}
function unique(ids: Set<string>, value: string) {
  if (ids.has(value)) fail("duplicate ID");
  ids.add(value);
}
function reference(ids: Set<string>, value: unknown) {
  id(value, "sub_");
  if (!ids.has(value)) fail("dangling reference");
}

/** Structural transport validation; semantic analysis remains in Zig. */
export function validateDocument(value: unknown): asserts value is Document {
  const doc = object(
    value,
    ["schema_version", "revision", "subjects", "symbols", "observations", "relations"],
    "document",
  );
  if (doc.schema_version !== 1) fail("unsupported schema version");
  text(doc.revision, "revision");
  for (const key of ["subjects", "symbols", "observations", "relations"] as const)
    if (!Array.isArray(doc[key])) fail(`${key}: expected array`);
  const subjects = new Set<string>();
  const ids = new Set<string>();
  for (const value of doc.subjects as unknown[]) {
    const row = object(value, ["id", "key", "source"], "subject");
    id(row.id, "sub_");
    const key = object(
      row.key,
      ["project", "language", "path", "kind", "name", "discriminator"],
      "subject.key",
    );
    for (const [field, value] of Object.entries(key)) text(value, field);
    path(key.path);
    source(row.source);
    if (key.path !== row.source.path || key.language !== row.source.language)
      fail("source mismatch");
    identical(row.id, subjectId(key as unknown as SubjectKey));
    unique(subjects, row.id);
  }
  for (const value of doc.symbols as unknown[]) {
    const row = object(value, ["id", "subject", "name"], "symbol");
    id(row.id, "sym_");
    reference(subjects, row.subject);
    text(row.name, "symbol.name");
    identical(row.id, symbolId(row.subject as SubjectId));
    unique(ids, row.id);
  }
  for (const value of doc.observations as unknown[]) {
    const row = object(
      value,
      ["id", "subject", "metric", "measurement", "source", "revision"],
      "observation",
    );
    id(row.id, "obs_");
    reference(subjects, row.subject);
    text(row.metric, "metric");
    source(row.source);
    if (row.revision !== doc.revision) fail("revision mismatch");
    const measurement = object(row.measurement, ["status", "value", "reason"], "measurement");
    if (measurement.status === "measured") {
      if (
        typeof measurement.value !== "number" ||
        !Number.isFinite(measurement.value) ||
        measurement.reason !== null
      )
        fail("invalid measured value");
    } else if (measurement.status === "unknown" || measurement.status === "unsupported") {
      if (measurement.value !== null) fail("unmeasured value must be null");
      text(measurement.reason, "measurement.reason");
    } else fail("invalid measurement status");
    identical(row.id, observationId(row as unknown as Observation));
    unique(ids, row.id);
  }
  for (const value of doc.relations as unknown[]) {
    const row = object(value, ["id", "from", "kind", "target", "source", "revision"], "relation");
    id(row.id, "rel_");
    reference(subjects, row.from);
    text(row.kind, "relation.kind");
    source(row.source);
    if (row.revision !== doc.revision) fail("revision mismatch");
    const target = object(row.target, ["status", "subject", "reason"], "target");
    if (target.status === "resolved") {
      reference(subjects, target.subject);
      if (target.reason !== null) fail("resolved target must have a null reason");
    } else if (target.status === "unresolved") {
      if (target.subject !== null) fail("unresolved target must have a null subject");
      text(target.reason, "target.reason");
    } else fail("invalid target status");
    identical(row.id, relationId(row as unknown as Relation));
    unique(ids, row.id);
  }
}
export function encodeDocument(value: Document): string {
  validateDocument(value);
  return JSON.stringify(value, null, 2) + "\n";
}

export { encodeSnapshot, validateSnapshot } from "./snapshot.js";
export type { Snapshot, FileDigest, CompilerDiagnostic } from "./snapshot.js";

export * from "./specification.js";
export type * from "./exploration.js";
export type * from "./symbolic.js";
export type * from "./crosslens.js";
export type * from "./authentication.js";
