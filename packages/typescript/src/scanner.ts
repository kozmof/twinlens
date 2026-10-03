import ts from "typescript-api";
import { basename, resolve } from "node:path";
import {
  createDocument,
  subjectId,
  symbolId,
  observationId,
  relationId,
  validateSnapshot,
  type Subject,
  type Source,
  type Measurement,
  type RelationTarget,
  type Snapshot,
} from "@twinlens/transport";
import { byteOffset, digest, loadProject, relativePath } from "./project.js";

const producer = "typescript-bt/1";
type FunctionNode = ts.FunctionLikeDeclaration;
interface Entry {
  node: ts.Node;
  subject: Subject;
  checker: ts.TypeChecker;
  file: ts.SourceFile;
}
interface Usage {
  reads: number;
  writes: number;
}
export interface ScanOptions {
  project?: string;
  revision?: string;
}

function isFunction(node: ts.Node): node is FunctionNode {
  return (
    ts.isFunctionDeclaration(node) ||
    ts.isFunctionExpression(node) ||
    ts.isArrowFunction(node) ||
    ts.isMethodDeclaration(node) ||
    ts.isConstructorDeclaration(node) ||
    ts.isGetAccessor(node) ||
    ts.isSetAccessor(node)
  );
}
function kind(node: ts.Node): string | undefined {
  if (isFunction(node)) return "function";
  if (ts.isParameter(node)) return "parameter";
  if (ts.isVariableDeclaration(node) || ts.isBindingElement(node)) return "value";
  if (
    ts.isPropertyDeclaration(node) ||
    ts.isPropertySignature(node) ||
    ts.isPropertyAssignment(node) ||
    ts.isShorthandPropertyAssignment(node)
  )
    return "property";
  if (ts.isClassDeclaration(node) || ts.isClassExpression(node)) return "class";
  if (ts.isInterfaceDeclaration(node)) return "interface";
  if (ts.isTypeAliasDeclaration(node)) return "type";
  if (ts.isEnumDeclaration(node)) return "enum";
  if (ts.isEnumMember(node)) return "property";
  return undefined;
}
function display(text: string): string {
  return (
    Array.from(text)
      .map((c) => (c.charCodeAt(0) < 32 || c.charCodeAt(0) === 127 ? " " : c))
      .join("")
      .replace(/\s+/gu, " ")
      .trim() || "<missing>"
  );
}
function nodeName(node: ts.Node): string {
  const named = node as ts.NamedDeclaration;
  if (named.name) return display(named.name.getText());
  if (ts.isConstructorDeclaration(node)) return "constructor";
  if (
    isFunction(node) &&
    (ts.isVariableDeclaration(node.parent) || ts.isPropertyAssignment(node.parent))
  )
    return display(node.parent.name.getText());
  return ts.isArrowFunction(node) ? "<arrow>" : "<anonymous>";
}
function location(node: ts.Node): string {
  return `${resolve(node.getSourceFile().fileName)}:${node.pos}:${node.kind}`;
}
function branch(node: ts.Node): boolean {
  return (
    ts.isIfStatement(node) ||
    ts.isConditionalExpression(node) ||
    ts.isForStatement(node) ||
    ts.isForInStatement(node) ||
    ts.isForOfStatement(node) ||
    ts.isWhileStatement(node) ||
    ts.isDoStatement(node) ||
    ts.isCaseClause(node) ||
    ts.isCatchClause(node) ||
    (ts.isBinaryExpression(node) &&
      [
        ts.SyntaxKind.AmpersandAmpersandToken,
        ts.SyntaxKind.BarBarToken,
        ts.SyntaxKind.QuestionQuestionToken,
      ].includes(node.operatorToken.kind))
  );
}
/** Classify an access, traversing only assignment-target wrappers, not receivers/indexes. */
function access(node: ts.Node): Usage {
  let current = node;
  while (current.parent) {
    const parent = current.parent;
    if (
      ts.isParenthesizedExpression(parent) ||
      ts.isAsExpression(parent) ||
      ts.isNonNullExpression(parent) ||
      ts.isArrayLiteralExpression(parent) ||
      ts.isObjectLiteralExpression(parent) ||
      ts.isSpreadElement(parent) ||
      ts.isSpreadAssignment(parent) ||
      ts.isShorthandPropertyAssignment(parent) ||
      (ts.isPropertyAssignment(parent) && parent.initializer === current)
    ) {
      current = parent;
      continue;
    }
    if (
      ts.isBinaryExpression(parent) &&
      parent.left === current &&
      parent.operatorToken.kind >= ts.SyntaxKind.FirstAssignment &&
      parent.operatorToken.kind <= ts.SyntaxKind.LastAssignment
    )
      return { reads: parent.operatorToken.kind === ts.SyntaxKind.EqualsToken ? 0 : 1, writes: 1 };
    if (
      (ts.isPrefixUnaryExpression(parent) || ts.isPostfixUnaryExpression(parent)) &&
      (parent.operator === ts.SyntaxKind.PlusPlusToken ||
        parent.operator === ts.SyntaxKind.MinusMinusToken)
    )
      return { reads: 1, writes: 1 };
    if (
      (ts.isForInStatement(parent) || ts.isForOfStatement(parent)) &&
      parent.initializer === current
    )
      return { reads: 0, writes: 1 };
    if (ts.isDeleteExpression(parent)) return { reads: 0, writes: 1 };
    break;
  }
  return { reads: 1, writes: 0 };
}
function inType(node: ts.Node): boolean {
  for (
    let current: ts.Node | undefined = node;
    current && !ts.isSourceFile(current);
    current = current.parent
  )
    if (ts.isTypeNode(current)) return true;
  return false;
}
function isReference(node: ts.Identifier): boolean {
  const p = node.parent;
  if (ts.isShorthandPropertyAssignment(p)) return true;
  if (ts.isPropertyAccessExpression(p) && p.name === node) return false;
  if (ts.isPropertyAssignment(p) && p.name === node) return false;
  if (ts.isBindingElement(p) && (p.name === node || p.propertyName === node)) return false;
  if ((p as ts.NamedDeclaration).name === node) return false;
  if (
    ts.isImportSpecifier(p) ||
    ts.isExportSpecifier(p) ||
    ts.isImportClause(p) ||
    ts.isNamespaceImport(p) ||
    ts.isLabeledStatement(p) ||
    ts.isBreakStatement(p) ||
    ts.isContinueStatement(p)
  )
    return false;
  return !inType(node);
}

export function scanProject(input: string, options: ScanOptions = {}): Snapshot {
  const loaded = loadProject(input);
  const project = options.project ?? basename(loaded.root);
  const revision =
    options.revision ??
    digest(
      JSON.stringify([producer, ts.version, loaded.files, loaded.configs, loaded.optionsDigest]),
    );
  const document = createDocument(revision);
  const entries: Entry[] = [];
  const lookup = new Map<string, Entry>();
  const selected = new Map<string, { file: ts.SourceFile; checker: ts.TypeChecker }>();
  const inventory = new Set(loaded.files.map((f) => f.path));
  for (const program of loaded.programs)
    for (const file of program.getSourceFiles()) {
      const path = relativePath(loaded.root, file.fileName);
      if (path && inventory.has(path) && !selected.has(path))
        selected.set(path, { file, checker: program.getTypeChecker() });
    }
  const files: Entry[] = [];
  const functionEntries: Entry[] = [];
  const counters = new Map<string, number>();
  function source(file: ts.SourceFile, node: ts.Node): Source {
    return {
      path: relativePath(loaded.root, file.fileName)!,
      language: /\.[cm]?jsx?$/u.test(file.fileName) ? "javascript" : "typescript",
      span: { start: byteOffset(file, node.getStart(file)), end: byteOffset(file, node.end) },
      producer,
      confidence: "high",
    };
  }
  function add(
    node: ts.Node,
    category: string,
    name: string,
    file: ts.SourceFile,
    checker: ts.TypeChecker,
  ): Entry {
    const origin = source(file, node);
    const base = `${origin.path}\0${category}\0${name}`;
    const ordinal = counters.get(base) ?? 0;
    counters.set(base, ordinal + 1);
    const key = {
      project,
      language: origin.language,
      path: origin.path,
      kind: category,
      name,
      discriminator: `declaration:${ordinal}`,
    };
    const subject: Subject = { id: subjectId(key), key, source: origin };
    const entry = { node, subject, file, checker };
    document.subjects.push(subject);
    document.symbols.push({ id: symbolId(subject.id), subject: subject.id, name });
    entries.push(entry);
    lookup.set(location(node), entry);
    if (category === "function") functionEntries.push(entry);
    return entry;
  }
  for (const [path, { file, checker }] of [...selected].sort(([a], [b]) =>
    a < b ? -1 : a > b ? 1 : 0,
  )) {
    files.push(add(file, "file", path, file, checker));
    function visit(node: ts.Node, scope: string) {
      const category = kind(node);
      let next = scope;
      if (category) {
        const name = scope ? `${scope}/${nodeName(node)}` : nodeName(node);
        const entry = add(node, category, name, file, checker);
        if (
          category === "function" ||
          category === "class" ||
          category === "interface" ||
          category === "enum"
        )
          next = `${name}[${entry.subject.key.discriminator}]`;
      }
      ts.forEachChild(node, (child) => visit(child, next));
    }
    ts.forEachChild(file, (node) => visit(node, ""));
  }
  const relations = new Map<string, (typeof document.relations)[number]>();
  const usage = new Map<string, Usage>();
  const unresolved = new Map<string, number>();
  const coverage = { unresolved_calls: 0, unresolved_accesses: 0 };
  function measure(entry: Entry, metric: string, measurement: Measurement) {
    const value = {
      subject: entry.subject.id,
      metric,
      measurement,
      source: entry.subject.source,
      revision,
    };
    document.observations.push({ id: observationId(value), ...value });
  }
  const measured = (value: number): Measurement => ({ status: "measured", value, reason: null });
  function relation(from: Entry, type: string, target: RelationTarget, node: ts.Node) {
    const value = {
      from: from.subject.id,
      kind: type,
      target,
      source: source(from.file, node),
      revision,
    };
    const id = relationId(value);
    if (!relations.has(id)) relations.set(id, { id, ...value });
  }
  function symbolEntry(
    symbol: ts.Symbol | undefined,
    checker: ts.TypeChecker,
    callable = false,
  ): Entry | undefined {
    if (!symbol) return undefined;
    if (symbol.flags & ts.SymbolFlags.Alias) symbol = checker.getAliasedSymbol(symbol);
    const declarations = symbol.getDeclarations() ?? [];
    if (callable) {
      for (const declaration of declarations) {
        if (isFunction(declaration) && declaration.body) {
          const entry = lookup.get(location(declaration));
          if (entry) return entry;
        }
        if (
          (ts.isVariableDeclaration(declaration) ||
            ts.isPropertyAssignment(declaration) ||
            ts.isPropertyDeclaration(declaration)) &&
          declaration.initializer &&
          isFunction(declaration.initializer)
        ) {
          const entry = lookup.get(location(declaration.initializer));
          if (entry) return entry;
        }
        if (ts.isClassDeclaration(declaration))
          for (const member of declaration.members)
            if (ts.isConstructorDeclaration(member)) {
              const entry = lookup.get(location(member));
              if (entry) return entry;
            }
      }
      return undefined;
    }
    for (const declaration of declarations) {
      const entry = lookup.get(location(declaration));
      if (entry) return entry;
    }
    return undefined;
  }
  function use(target: Entry | undefined, node: ts.Node, owner: Entry) {
    if (!target || !["parameter", "property", "value"].includes(target.subject.key.kind)) return;
    const value = access(node);
    const counts = usage.get(target.subject.id) ?? { reads: 0, writes: 0 };
    counts.reads += value.reads;
    counts.writes += value.writes;
    usage.set(target.subject.id, counts);
    if (value.reads)
      relation(
        owner,
        "reads",
        { status: "resolved", subject: target.subject.id, reason: null },
        node,
      );
    if (value.writes)
      relation(
        owner,
        "writes",
        { status: "resolved", subject: target.subject.id, reason: null },
        node,
      );
  }
  for (const fileEntry of files) {
    const checker = fileEntry.checker;
    function visit(node: ts.Node, owner: Entry) {
      if (inType(node)) return;
      const own = isFunction(node) ? (lookup.get(location(node)) ?? owner) : owner;
      if (ts.isCallExpression(node) || ts.isNewExpression(node)) {
        let target = symbolEntry(checker.getSymbolAtLocation(node.expression), checker, true);
        if (!target) {
          const declaration = checker.getResolvedSignature(node)?.declaration;
          if (declaration && isFunction(declaration) && declaration.body)
            target = lookup.get(location(declaration));
        }
        // Callable parameters and signatures are not concrete implementations.
        relation(
          own,
          "calls",
          target
            ? { status: "resolved", subject: target.subject.id, reason: null }
            : {
                status: "unresolved",
                subject: null,
                reason: `No scanned implementation for ${display(node.expression.getText())}`,
              },
          node,
        );
        if (!target) {
          coverage.unresolved_calls++;
          unresolved.set(own.subject.id, (unresolved.get(own.subject.id) ?? 0) + 1);
        }
      }
      if (ts.isBindingElement(node) && ts.isObjectBindingPattern(node.parent)) {
        const name = node.propertyName ?? node.name;
        if (node.dotDotDotToken || !(ts.isIdentifier(name) || ts.isStringLiteralLike(name)))
          coverage.unresolved_accesses++;
        else {
          const target = symbolEntry(
            checker.getTypeAtLocation(node.parent).getProperty(name.text),
            checker,
          );
          if (!target) coverage.unresolved_accesses++;
          else use(target, node, own);
        }
      }
      if (ts.isPropertyAccessExpression(node) || ts.isElementAccessExpression(node)) {
        const symbol = ts.isPropertyAccessExpression(node)
          ? checker.getSymbolAtLocation(node.name)
          : node.argumentExpression &&
              (ts.isStringLiteralLike(node.argumentExpression) ||
                ts.isNumericLiteral(node.argumentExpression))
            ? checker.getTypeAtLocation(node.expression).getProperty(node.argumentExpression.text)
            : undefined;
        const target = symbolEntry(symbol, checker);
        if (!target) coverage.unresolved_accesses++;
        use(target, node, own);
      } else if (ts.isIdentifier(node) && isReference(node)) {
        const symbol = ts.isShorthandPropertyAssignment(node.parent)
          ? checker.getShorthandAssignmentValueSymbol(node.parent)
          : checker.getSymbolAtLocation(node);
        use(symbolEntry(symbol, checker), node, own);
      }
      ts.forEachChild(node, (child) => visit(child, own));
    }
    visit(fileEntry.file, fileEntry);
  }
  for (const entry of entries) {
    const node = entry.node;
    if (["value", "property", "parameter"].includes(entry.subject.key.kind)) {
      const counts = usage.get(entry.subject.id) ?? { reads: 0, writes: 0 };
      // Declaration initialization is a write; parameter binding is not a body write.
      if (
        (ts.isVariableDeclaration(node) ||
          ts.isPropertyDeclaration(node) ||
          ts.isPropertyAssignment(node)) &&
        node.initializer
      )
        counts.writes++;
      if (ts.isShorthandPropertyAssignment(node)) counts.writes++;
      if (ts.isBindingElement(node)) {
        let root: ts.Node = node.parent;
        while (root && !ts.isVariableDeclaration(root) && !ts.isParameter(root)) root = root.parent;
        if (root && ts.isVariableDeclaration(root) && root.initializer) counts.writes++;
      }
      const prefix = entry.subject.key.kind === "property" ? "property" : "value";
      measure(entry, `${prefix}.read_count`, measured(counts.reads));
      measure(entry, `${prefix}.write_count`, measured(counts.writes));
    }
    if (ts.isParameter(node)) {
      const type = entry.checker.getTypeAtLocation(node);
      const unknown = Boolean(
        type.flags & (ts.TypeFlags.Any | ts.TypeFlags.Unknown | ts.TypeFlags.TypeParameter),
      );
      const object = Boolean(
        type.flags & (ts.TypeFlags.Object | ts.TypeFlags.Union | ts.TypeFlags.Intersection),
      );
      measure(
        entry,
        "function.parameter.property_count",
        unknown
          ? {
              status: "unknown",
              value: null,
              reason: "Parameter type does not expose a finite known property set",
            }
          : measured(object ? entry.checker.getPropertiesOfType(type).length : 0),
      );
    }
  }
  for (const entry of functionEntries) {
    const node = entry.node as FunctionNode;
    measure(
      entry,
      "function.args.count",
      measured(node.parameters.filter((p) => p.name.getText() !== "this").length),
    );
    measure(
      entry,
      "function.lines",
      measured(
        entry.file.getLineAndCharacterOfPosition(Math.max(node.getStart(), node.end - 1)).line -
          entry.file.getLineAndCharacterOfPosition(node.getStart()).line +
          1,
      ),
    );
    let count = 0;
    function branches(node: ts.Node) {
      if (isFunction(node)) return;
      if (branch(node)) count++;
      ts.forEachChild(node, branches);
    }
    if (node.body) branches(node.body);
    measure(
      entry,
      "function.branch.count",
      node.body
        ? measured(count)
        : { status: "unknown", value: null, reason: "Declaration has no executable body" },
    );
    const calls = [...relations.values()].filter(
      (r) => r.kind === "calls" && r.target.status === "resolved",
    );
    measure(
      entry,
      "function.callers",
      measured(
        new Set(calls.filter((r) => r.target.subject === entry.subject.id).map((r) => r.from)).size,
      ),
    );
    measure(
      entry,
      "function.callees",
      measured(
        new Set(calls.filter((r) => r.from === entry.subject.id).map((r) => r.target.subject)).size,
      ),
    );
    measure(
      entry,
      "function.calls.unresolved.count",
      measured(unresolved.get(entry.subject.id) ?? 0),
    );
  }
  document.relations = [...relations.values()];
  for (const rows of [
    document.subjects,
    document.symbols,
    document.observations,
    document.relations,
  ])
    rows.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  const snapshot: Snapshot = {
    snapshot_version: 1,
    project,
    configuration: {
      adapter: producer,
      compiler: ts.version,
      options_sha256: loaded.optionsDigest,
      configs: loaded.configs,
    },
    files: loaded.files,
    diagnostics: loaded.diagnostics,
    coverage,
    document,
  };
  validateSnapshot(snapshot);
  return snapshot;
}
