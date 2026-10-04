import ts from "typescript-api";
import { createHash } from "node:crypto";
import { readFileSync, statSync } from "node:fs";
import { isUtf8 } from "node:buffer";
import { resolve, dirname, relative, isAbsolute, sep } from "node:path";
import type { CompilerDiagnostic, FileDigest } from "@twinlens/transport";

export const digest = (data: string | Buffer): string =>
  createHash("sha256").update(data).digest("hex");
export function relativePath(root: string, file: string): string | undefined {
  const path = relative(root, resolve(file)).split(sep).join("/");
  return path && path !== ".." && !path.startsWith("../") && !isAbsolute(path) ? path : undefined;
}
/** Normalize option values independently from JSON metadata-key filtering. */
export function normalizeOptionValue(root: string, value: unknown): unknown {
  if (typeof value === "string" && isAbsolute(value))
    return resolve(value) === root
      ? "."
      : (relativePath(root, value) ?? "<external>/" + value.split(sep).slice(-2).join("/"));
  return value;
}
const byteMaps = new WeakMap<ts.SourceFile, { bom: number; positions: Map<number, number> }>();
export function byteOffset(file: ts.SourceFile, offset: number): number {
  let map = byteMaps.get(file);
  if (!map) {
    const bytes = readFileSync(file.fileName);
    const bom =
      bytes.subarray(0, 3).equals(Buffer.from([239, 187, 191])) && !file.text.startsWith("\uFEFF")
        ? 3
        : 0;
    map = { bom, positions: new Map() };
    byteMaps.set(file, map);
  }
  let value = map.positions.get(offset);
  if (value === undefined) {
    value = map.bom + Buffer.byteLength(file.text.slice(0, offset));
    map.positions.set(offset, value);
  }
  return value;
}
export interface Project {
  root: string;
  programs: ts.Program[];
  files: FileDigest[];
  configs: FileDigest[];
  optionsDigest: string;
  diagnostics: CompilerDiagnostic[];
}

export function loadProject(input: string): Project {
  const supplied = resolve(input);
  const config = statSync(supplied).isDirectory() ? resolve(supplied, "tsconfig.json") : supplied;
  const root = dirname(config);
  const configs = new Map<string, string>();
  const visited = new Set<string>();
  const programs: ts.Program[] = [];
  const rawDiagnostics: ts.Diagnostic[] = [];
  const options: unknown[] = [];
  function load(path: string) {
    path = resolve(path);
    if (visited.has(path)) return;
    visited.add(path);
    if (!relativePath(root, path))
      throw new Error(`Project reference is outside scan root: ${path}`);
    const host: ts.ParseConfigFileHost = {
      ...ts.sys,
      readFile(file) {
        const content = ts.sys.readFile(file);
        if (content !== undefined) configs.set(resolve(file), content);
        return content;
      },
      onUnRecoverableConfigFileDiagnostic(diagnostic) {
        rawDiagnostics.push(diagnostic);
      },
    };
    const parsed = ts.getParsedCommandLineOfConfigFile(path, {}, host);
    if (!parsed) throw new Error(`Cannot load TypeScript configuration: ${path}`);
    rawDiagnostics.push(...parsed.errors);
    for (const ref of parsed.projectReferences ?? []) load(ts.resolveProjectReferencePath(ref));
    const normalizedOptions = JSON.stringify(parsed.options, (key, value: unknown) => {
      if (key === "configFile") return undefined;
      return normalizeOptionValue(root, value);
    });
    options.push([relativePath(root, path), JSON.parse(normalizedOptions)]);
    if (parsed.fileNames.length) {
      const program = ts.createProgram({
        rootNames: parsed.fileNames,
        options: { ...parsed.options, noEmit: true },
        ...(parsed.projectReferences ? { projectReferences: parsed.projectReferences } : {}),
      });
      programs.push(program);
      rawDiagnostics.push(...ts.getPreEmitDiagnostics(program));
    }
  }
  load(config);
  const files = new Map<string, string>();
  for (const program of programs)
    for (const file of program.getSourceFiles()) {
      const path = relativePath(root, file.fileName);
      if (path && !file.isDeclarationFile && !path.split("/").includes("node_modules")) {
        const bytes = readFileSync(file.fileName);
        if (!isUtf8(bytes)) throw new Error("Only UTF-8 source files are supported: " + path);
        const text = bytes.toString("utf8");
        if (text !== file.text && text.replace(/^\uFEFF/u, "") !== file.text)
          throw new Error("Source changed during scan: " + path);
        files.set(path, digest(bytes));
      }
    }
  const diagnostics = new Map<string, CompilerDiagnostic>();
  for (const diagnostic of rawDiagnostics) {
    const path = diagnostic.file ? (relativePath(root, diagnostic.file.fileName) ?? null) : null;
    const start =
      path !== null && diagnostic.file && diagnostic.start !== undefined
        ? byteOffset(diagnostic.file, diagnostic.start)
        : null;
    const end =
      start !== null && diagnostic.file
        ? byteOffset(diagnostic.file, diagnostic.start! + (diagnostic.length ?? 0))
        : null;
    const row: CompilerDiagnostic = {
      category: ts.DiagnosticCategory[
        diagnostic.category
      ]!.toLowerCase() as CompilerDiagnostic["category"],
      code: diagnostic.code,
      message: ts.flattenDiagnosticMessageText(diagnostic.messageText, "\n"),
      path,
      start,
      end,
    };
    diagnostics.set(JSON.stringify(row), row);
  }
  const sortFiles = (entries: Iterable<[string, string]>): FileDigest[] =>
    [...entries]
      .map(([path, sha256]) => ({ path, sha256 }))
      .sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  const configFiles = sortFiles(
    [...configs].flatMap(([path, text]) => {
      const local = relativePath(root, path);
      return local ? [[local, digest(text)] as [string, string]] : [];
    }),
  );
  // Include inherited external config content in the fingerprint without storing machine paths.
  const dependencies = [
    ...new Set(
      programs.flatMap((p) =>
        p
          .getSourceFiles()
          .filter((f) => !files.has(relativePath(root, f.fileName) ?? ""))
          .map((f) => digest(f.text)),
      ),
    ),
  ].sort();
  const externalConfigs = [...configs]
    .filter(([path]) => !relativePath(root, path))
    .map(([, text]) => digest(text))
    .sort();
  return {
    root,
    programs,
    files: sortFiles(files),
    configs: configFiles,
    optionsDigest: digest(JSON.stringify([options, externalConfigs, dependencies])),
    diagnostics: [...diagnostics.values()].sort((a, b) =>
      JSON.stringify(a).localeCompare(JSON.stringify(b), "en"),
    ),
  };
}
