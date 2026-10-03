import { validateDocument, type Document } from "./index.js";

export interface FileDigest {
  path: string;
  sha256: string;
}
export interface CompilerDiagnostic {
  category: "error" | "warning" | "suggestion" | "message";
  code: number;
  message: string;
  path: string | null;
  start: number | null;
  end: number | null;
}
export interface Snapshot {
  snapshot_version: 1;
  project: string;
  configuration: {
    adapter: string;
    compiler: string;
    options_sha256: string;
    configs: FileDigest[];
  };
  files: FileDigest[];
  diagnostics: CompilerDiagnostic[];
  coverage: { unresolved_calls: number; unresolved_accesses: number };
  document: Document;
}

function record(value: unknown, keys: string[]): asserts value is Record<string, unknown> {
  if (
    !value ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    Object.keys(value).length !== keys.length ||
    keys.some((k) => !Object.hasOwn(value, k))
  )
    throw new Error("Invalid snapshot shape");
}
function text(value: unknown): asserts value is string {
  if (typeof value !== "string" || !value.length || !value.isWellFormed())
    throw new Error("Invalid snapshot text");
}
function hash(value: unknown): asserts value is string {
  if (typeof value !== "string" || !/^[a-f0-9]{64}$/u.test(value))
    throw new Error("Invalid snapshot digest");
}
function path(value: unknown): asserts value is string {
  text(value);
  if (/[\\:]/u.test(value) || value.split("/").some((v) => !v || v === "." || v === ".."))
    throw new Error("Invalid snapshot path");
}
function uint(value: unknown): asserts value is number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0 || value > 0xffffffff)
    throw new Error("Invalid snapshot count");
}
function files(value: unknown): asserts value is FileDigest[] {
  if (!Array.isArray(value)) throw new Error("Invalid snapshot files");
  const seen = new Set<string>();
  for (const item of value) {
    record(item, ["path", "sha256"]);
    path(item.path);
    hash(item.sha256);
    if (seen.has(item.path)) throw new Error("Duplicate snapshot path");
    seen.add(item.path);
  }
}
export function validateSnapshot(value: unknown): asserts value is Snapshot {
  record(value, [
    "snapshot_version",
    "project",
    "configuration",
    "files",
    "diagnostics",
    "coverage",
    "document",
  ]);
  if (value.snapshot_version !== 1) throw new Error("Unsupported snapshot version");
  text(value.project);
  record(value.configuration, ["adapter", "compiler", "options_sha256", "configs"]);
  text(value.configuration.adapter);
  text(value.configuration.compiler);
  hash(value.configuration.options_sha256);
  files(value.configuration.configs);
  files(value.files);
  validateDocument(value.document);
  const inventory = new Set(value.files.map((f) => f.path));
  for (const subject of value.document.subjects) {
    if (subject.key.project !== value.project || !inventory.has(subject.key.path))
      throw new Error("Snapshot subject outside inventory");
  }
  for (const row of [...value.document.observations, ...value.document.relations])
    if (!inventory.has(row.source.path)) throw new Error("Snapshot source outside inventory");
  record(value.coverage, ["unresolved_calls", "unresolved_accesses"]);
  uint(value.coverage.unresolved_calls);
  uint(value.coverage.unresolved_accesses);
  if (!Array.isArray(value.diagnostics)) throw new Error("Invalid snapshot diagnostics");
  for (const diagnostic of value.diagnostics) {
    record(diagnostic, ["category", "code", "message", "path", "start", "end"]);
    if (!["error", "warning", "suggestion", "message"].includes(diagnostic.category as string))
      throw new Error("Invalid diagnostic category");
    uint(diagnostic.code);
    text(diagnostic.message);
    if (diagnostic.path !== null) path(diagnostic.path);
    if (diagnostic.start === null) {
      if (diagnostic.end !== null) throw new Error("Invalid diagnostic span");
    } else {
      uint(diagnostic.start);
      uint(diagnostic.end);
      if (diagnostic.path === null || diagnostic.end < diagnostic.start)
        throw new Error("Invalid diagnostic span");
    }
  }
}
export function encodeSnapshot(value: Snapshot): string {
  validateSnapshot(value);
  return JSON.stringify(value, null, 2) + "\n";
}
