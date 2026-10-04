/* eslint-disable no-control-regex -- Reject or sanitize control characters in wire names. */
import {
  compile,
  NodeHost,
  navigateProgram,
  getSourceLocation,
  getTypeName,
  getNamespaceFullName,
  type Type,
  type Operation,
} from "@typespec/compiler";
import { createRequire } from "node:module";
import { createHash } from "node:crypto";
import { isUtf8 } from "node:buffer";
import { readFileSync, statSync } from "node:fs";
import { basename, dirname, relative, resolve, sep } from "node:path";
import {
  createDocument,
  subjectId,
  symbolId,
  relationId,
  observationId,
  validateSnapshot,
  claimId,
  constraintId,
  expression,
  type Subject,
  type Source,
  type Specification,
  type ClaimKind,
  type Constraint,
} from "@twinlens/transport";
import { annotationKey, type Annotation } from "./decorators.js";
const version: string = createRequire(import.meta.url)("@typespec/compiler/package.json").version;
const producer = "typespec-sa/1";
const digest = (value: string | Buffer) => createHash("sha256").update(value).digest("hex");
const display = (value: string) =>
  value.replace(/[\u0000-\u001f\u007f]/gu, " ").trim() || "<anonymous>";
export async function compileSpecification(
  input: string,
  options: { project?: string; revision?: string } = {},
): Promise<Specification> {
  const path = resolve(statSync(input).isDirectory() ? resolve(input, "main.tsp") : input),
    root = dirname(path);
  const project = options.project ?? basename(root);
  const program = await compile(NodeHost, path, { noEmit: true });
  function local(file: string) {
    const relativePath = relative(root, file).split(sep).join("/");
    return relativePath &&
      !relativePath.startsWith("../") &&
      relativePath !== ".." &&
      !relativePath.split("/").includes("node_modules")
      ? relativePath
      : undefined;
  }
  const inventory = [...program.sourceFiles.values()].filter(
    (sourceFile) =>
      local(sourceFile.file.path) &&
      program.getSourceFileLocationContext(sourceFile.file).type === "project",
  );
  const bomOffsets = new Map<string, number>();
  const files = inventory
    .map((sourceFile) => {
      const bytes = readFileSync(sourceFile.file.path);
      bomOffsets.set(
        sourceFile.file.path,
        bytes.subarray(0, 3).equals(Buffer.from([0xef, 0xbb, 0xbf])) &&
          !sourceFile.file.text.startsWith("\uFEFF")
          ? 3
          : 0,
      );
      if (!isUtf8(bytes)) throw Error("Only UTF-8 TypeSpec sources are supported");
      if (
        bytes.toString("utf8").replace(/^\uFEFF/u, "") !==
        sourceFile.file.text.replace(/^\uFEFF/u, "")
      )
        throw Error("Source changed while compiling");
      return { path: local(sourceFile.file.path)!, sha256: digest(bytes) };
    })
    .sort((left, right) => left.path.localeCompare(right.path));
  const dependencies = [...program.sourceFiles.values()]
    .filter((sourceFile) => !inventory.includes(sourceFile))
    .map((sourceFile) => ({
      path: sourceFile.file.path.split(sep).slice(-3).join("/"),
      sha256: digest(sourceFile.file.text),
    }))
    .sort((left, right) => left.path.localeCompare(right.path));
  const javascript = [...program.jsSourceFiles.keys()]
    .map((path) => ({
      path: local(path) ?? path.split(sep).slice(-3).join("/"),
      sha256: digest(readFileSync(path)),
    }))
    .sort((left, right) => left.path.localeCompare(right.path));
  const optionsDigest = digest(JSON.stringify([producer, version, dependencies, javascript]));
  const revision = options.revision ?? digest(JSON.stringify([project, files, optionsDigest]));
  const document = createDocument(revision);
  const specification: Specification = {
    specification_version: 1,
    snapshot: {
      snapshot_version: 1,
      project,
      configuration: {
        adapter: producer,
        compiler: version,
        options_sha256: optionsDigest,
        configs: [],
      },
      files,
      diagnostics: [],
      coverage: { unresolved_calls: 0, unresolved_accesses: 0 },
      document,
    },
    claims: [],
    constraints: [],
    functions: [],
    domains: [],
  };
  const known = new Map<Type, Subject>();
  const counters = new Map<string, number>();
  function byteOffset(file: { path: string; text: string }, position: number) {
    return (bomOffsets.get(file.path) ?? 0) + Buffer.byteLength(file.text.slice(0, position));
  }
  function origin(type: Type): Source | undefined {
    if (!type.node) return;
    const location = getSourceLocation(type);
    const path = local(location.file.path);
    if (!path || !files.some((sourceFile) => sourceFile.path === path)) return;
    return {
      path,
      language: "typespec",
      span: {
        start: byteOffset(location.file, location.pos),
        end: byteOffset(location.file, location.end),
      },
      producer,
      confidence: "high",
    };
  }
  function add(type: Type, kind?: string, name?: string): Subject | undefined {
    const existing = known.get(type);
    if (existing) return existing;
    const source = origin(type);
    if (!source) return;
    const category = kind ?? type.kind.toLowerCase();
    const label = display(name ?? getTypeName(type));
    const base = `${source.path}\0${category}\0${label}`;
    const ordinal = counters.get(base) ?? 0;
    counters.set(base, ordinal + 1);
    const key = {
      project,
      language: "typespec",
      path: source.path,
      kind: category,
      name: label,
      discriminator: String(ordinal),
    };
    const subject = { id: subjectId(key), key, source };
    known.set(type, subject);
    document.subjects.push(subject);
    document.symbols.push({ id: symbolId(subject.id), subject: subject.id, name: label });
    return subject;
  }
  function edge(from: Subject, kind: string, target: Subject | undefined, label: string) {
    const value = {
      from: from.id,
      kind,
      target: target
        ? { status: "resolved" as const, subject: target.id, reason: null }
        : {
            status: "unresolved" as const,
            subject: null,
            reason: `TypeSpec target is outside the supported local inventory: ${display(label)}`,
          },
      source: from.source,
      revision,
    };
    const id = relationId(value);
    if (!document.relations.some((relation) => relation.id === id))
      document.relations.push({ id, ...value });
  }
  const builtinTypes = new Map<string, Subject>();
  function typeTarget(type: Type, at: Subject): Subject | undefined {
    const local = known.get(type);
    if (local) return local;
    if (!["Scalar", "Intrinsic", "String", "Number", "Boolean"].includes(type.kind)) return;
    const name = getTypeName(type),
      token = at.source.path + "\0" + name;
    const existing = builtinTypes.get(token);
    if (existing) return existing;
    const key = {
      project,
      language: "typespec",
      path: at.source.path,
      kind: "type",
      name,
      discriminator: "builtin",
    };
    const subject = { id: subjectId(key), key, source: at.source };
    builtinTypes.set(token, subject);
    document.subjects.push(subject);
    document.symbols.push({ id: symbolId(subject.id), subject: subject.id, name });
    specification.domains.push({
      subject: subject.id,
      ownership: "unknown",
      nullability: "unknown",
      values: [],
      constraints: [],
      reason: "Declared type shape; runtime ownership and nullability require explicit constraints",
    });
    return subject;
  }
  const operations: Operation[] = [];
  navigateProgram(
    program,
    {
      model: (type) => {
        if (type.name) add(type, "model");
      },
      modelProperty: (type) => {
        if (type.model?.name) add(type, "property", `${getTypeName(type.model)}.${type.name}`);
      },
      operation: (type) => {
        const namespaceName = type.interface
          ? getTypeName(type.interface)
          : type.namespace
            ? getNamespaceFullName(type.namespace)
            : "";
        if (add(type, "operation", [namespaceName, type.name].filter(Boolean).join(".")))
          operations.push(type);
      },
      scalar: (type) => {
        add(type, "scalar");
      },
      enum: (type) => {
        add(type, "enum");
      },
      union: (type) => {
        if (type.name) add(type, "union");
      },
      interface: (type) => {
        add(type, "interface");
      },
    },
    { includeTemplateDeclaration: true },
  );
  for (const operation of operations) {
    const owner = known.get(operation)!;
    for (const parameter of operation.parameters.properties.values()) {
      const entry = add(parameter, "parameter", `${owner.key.name}.${parameter.name}`);
      if (entry) {
        edge(owner, "inputs", entry, parameter.name);
        edge(entry, "type", typeTarget(parameter.type, entry), getTypeName(parameter.type));
      }
    }
    edge(
      owner,
      "outputs",
      typeTarget(operation.returnType, owner),
      getTypeName(operation.returnType),
    );
  }
  function constraint(
    subject: Subject,
    name: string,
    kind: ClaimKind,
    constraintExpression: Constraint["expression"],
  ) {
    const constraintRecord = {
      id: constraintId(subject.id, name),
      subject: subject.id,
      name,
      expression: constraintExpression,
      source: subject.source,
    };
    specification.constraints.push(constraintRecord);
    specification.claims.push({
      id: claimId(subject.id, name, kind),
      subject: subject.id,
      name,
      kind,
      state: "specified",
      reason: "Explicit TypeSpec annotation",
      constraint: constraintRecord.id,
      source: subject.source,
    });
    return constraintRecord.id;
  }
  for (const [type, subject] of known) {
    const annotation: Annotation | undefined = program.stateMap(annotationKey).get(type);
    if (type.kind === "ModelProperty") {
      if (type.model && known.has(type.model))
        edge(known.get(type.model)!, "contains", subject, type.name);
      edge(subject, "type", typeTarget(type.type, subject), getTypeName(type.type));
    }
    for (const relation of annotation?.relations ?? [])
      edge(subject, relation.kind, known.get(relation.target), getTypeName(relation.target));
    const ids: string[] = [];
    for (const claim of annotation?.claims ?? [])
      ids.push(constraint(subject, claim.name, claim.kind, claim.expression));
    if (annotation?.state && (annotation.claims.length || annotation.domain))
      specification.snapshot.diagnostics.push({
        category: "error",
        code: 1,
        message: "A target cannot be both explicitly constrained and marked unspecified/deferred",
        path: subject.source.path,
        start: subject.source.span.start,
        end: subject.source.span.end,
      });
    if (!annotation?.claims.length)
      specification.claims.push({
        id: claimId(subject.id, "coverage", "invariant"),
        subject: subject.id,
        name: "coverage",
        kind: "invariant",
        state: annotation?.state?.state ?? "unspecified",
        reason: annotation?.state?.reason ?? "No explicit Twinlens constraints were supplied",
        constraint: null,
        source: subject.source,
      });
    if (type.kind === "Operation") {
      const mode = annotation?.semantics?.mode ?? "opaque";
      specification.functions.push({
        subject: subject.id,
        name: subject.key.name,
        mode,
        arity: type.parameters.properties.size,
        definition: annotation?.semantics?.definition ?? [],
        backing: annotation?.backing ? (known.get(annotation.backing)?.id ?? null) : null,
      });
      if (annotation?.backing)
        edge(
          subject,
          "derived_from",
          known.get(annotation.backing),
          getTypeName(annotation.backing),
        );
    }
    const domain = {
      subject: subject.id,
      ownership: annotation?.domain?.ownership ?? ("unknown" as const),
      nullability: annotation?.domain?.nullability ?? ("unknown" as const),
      values: annotation?.domain?.values ?? [],
      constraints: [] as string[],
      reason: annotation?.domain
        ? "Explicit domain constraints; unspecified dimensions remain unknown"
        : "Ambiguity-first: type shape alone does not establish ownership or runtime nullability",
    };
    if (annotation?.domain) {
      const rules: unknown[] = [];
      if (domain.ownership !== "unknown")
        rules.push({ eq: [{ fact: `${subject.key.name}.ownership` }, domain.ownership] });
      if (domain.nullability === "nonnull") rules.push({ ne: [{ fact: subject.key.name }, null] });
      if (domain.values.length) {
        const choices = domain.values.map((value) => ({
          eq: [
            { fact: subject.key.name },
            value.kind === "null"
              ? null
              : value.kind === "number"
                ? Number(value.value)
                : value.kind === "boolean"
                  ? value.value === "true"
                  : value.value,
          ],
        }));
        rules.push(
          choices
            .slice(1)
            .reduce((combinedRule: unknown, rule) => ({ or: [combinedRule, rule] }), choices[0]),
        );
      }
      const constraintExpression = rules.length
        ? rules
            .slice(1)
            .reduce((combinedRule: unknown, rule) => ({ and: [combinedRule, rule] }), rules[0])
        : true;
      domain.constraints.push(
        constraint(subject, "domain", "invariant", expression(constraintExpression)),
      );
    }
    specification.domains.push(domain);
    if (
      ["Union", "Interface"].includes(type.kind) ||
      (type.kind === "Model" && type.indexer) ||
      (type.kind === "Model" && type.templateMapper)
    ) {
      const row = {
        subject: subject.id,
        metric: "specification.shape",
        measurement: {
          status: "unsupported" as const,
          value: null,
          reason:
            "Complex or instantiated type semantics are retained as declarations without runtime evaluation",
        },
        source: subject.source,
        revision,
      };
      document.observations.push({ id: observationId(row), ...row });
    }
  }
  for (const diagnostic of program.diagnostics) {
    let source: Source | undefined;
    try {
      const location = getSourceLocation(diagnostic.target);
      if (!location) throw Error("No diagnostic source");
      const relativePath = local(location.file.path);
      if (relativePath)
        source = {
          path: relativePath,
          language: "typespec",
          span: {
            start: byteOffset(location.file, location.pos),
            end: byteOffset(location.file, location.end),
          },
          producer,
          confidence: "high",
        };
    } catch {}
    specification.snapshot.diagnostics.push({
      category: diagnostic.severity,
      code: parseInt(digest(diagnostic.code).slice(0, 8), 16),
      message: `${diagnostic.code}: ${diagnostic.message}`,
      path: source?.path ?? null,
      start: source?.span.start ?? null,
      end: source?.span.end ?? null,
    });
  }
  for (const rows of [
    document.subjects,
    document.symbols,
    document.relations,
    document.observations,
    specification.claims,
    specification.constraints,
  ])
    rows.sort((left, right) => left.id.localeCompare(right.id));
  validateSnapshot(specification.snapshot);
  return specification;
}
