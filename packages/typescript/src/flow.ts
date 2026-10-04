import ts from "typescript-api";
import type { RelationTarget } from "@twinlens/transport";
import type { Entry } from "./scanner.js";

interface Hooks {
  add(node: ts.Node, kind: string, name: string, owner: Entry): Entry;
  resolve(node: ts.Node, owner: Entry): Entry | undefined;
  entry(node: ts.Node): Entry | undefined;
  function(node: ts.Node): boolean;
  reference(node: ts.Identifier): boolean;
  inType(node: ts.Node): boolean;
  relation(from: Entry, kind: string, target: RelationTarget, node: ts.Node): void;
}
/** Syntactic potential dependencies. No path, alias, or interprocedural propagation. */
export function extractFlow(files: Entry[], declarations: Entry[], h: Hooks): void {
  const edge = (from: Entry, kind: string, to: Entry, node: ts.Node) =>
    h.relation(from, kind, { status: "resolved", subject: to.subject.id, reason: null }, node);
  const unknown = (event: Entry, node: ts.Node) =>
    h.relation(
      event,
      "flow_unknown",
      {
        status: "unresolved",
        subject: null,
        reason: "Expression contains unresolved dependencies; flow is syntactic and incomplete",
      },
      node,
    );
  const isValue = (e: Entry) => ["parameter", "property", "value"].includes(e.subject.key.kind);
  function references(node: ts.Node, owner: Entry, event: Entry): Entry[] {
    const found = new Map<string, Entry>();
    function visit(n: ts.Node) {
      if (h.inType(n) || h.function(n)) return;
      if (
        ts.isPropertyAccessExpression(n) ||
        ts.isElementAccessExpression(n) ||
        (ts.isIdentifier(n) && h.reference(n))
      ) {
        const entry = h.resolve(n, owner);
        if (entry && isValue(entry)) found.set(entry.subject.id, entry);
        if (!entry) unknown(event, n);
        if ((ts.isPropertyAccessExpression(n) || ts.isElementAccessExpression(n)) && entry) {
          const receiver = h.resolve(n.expression, owner);
          if (receiver && isValue(receiver)) edge(receiver, "uses_property", entry, n);
        }
      }
      ts.forEachChild(n, visit);
    }
    visit(node);
    return [...found.values()];
  }
  for (const file of files) {
    const subsystem = h.add(file.node, "subsystem", file.subject.key.path, file);
    for (const e of declarations.filter((e) => e.file === file.file)) {
      edge(e, "belongs_to", subsystem, e.node);
      let parent = e.node.parent;
      while (parent && !h.function(parent)) parent = parent.parent;
      const owner = parent && h.entry(parent);
      if (owner) edge(owner, "contains", e, e.node);
    }
    function visit(node: ts.Node, parent: Entry) {
      if (h.inType(node)) return;
      const owner = h.function(node) ? (h.entry(node) ?? parent) : parent;
      function event(kind: string, roots: readonly ts.Node[], relation: string, output?: Entry) {
        const e = h.add(node, kind, `${owner.subject.key.name}/${kind}`, owner);
        edge(owner, "contains", e, node);
        for (const root of roots)
          for (const input of references(root, owner, e)) {
            edge(input, relation, e, root);
            if (output) edge(input, "flows_to", output, root);
          }
        if (output) edge(e, "output", output, node);
        return e;
      }
      if (ts.isCallExpression(node) || ts.isNewExpression(node))
        event("call", node.arguments ?? [], "argument");
      else if (ts.isReturnStatement(node))
        event("return", node.expression ? [node.expression] : [], "returns");
      else if (ts.isArrowFunction(node) && !ts.isBlock(node.body))
        event("return", [node.body], "returns");
      else if (ts.isIfStatement(node) || ts.isConditionalExpression(node))
        event("branch", [ts.isIfStatement(node) ? node.expression : node.condition], "controls");
      else if (ts.isSwitchStatement(node) || ts.isWhileStatement(node) || ts.isDoStatement(node))
        event("branch", [node.expression], "controls");
      else if (ts.isForStatement(node))
        event("branch", node.condition ? [node.condition] : [], "controls");
      else if (ts.isForOfStatement(node) || ts.isForInStatement(node))
        event("branch", [node.expression], "controls");
      else if (
        ts.isBinaryExpression(node) &&
        [
          ts.SyntaxKind.AmpersandAmpersandToken,
          ts.SyntaxKind.BarBarToken,
          ts.SyntaxKind.QuestionQuestionToken,
        ].includes(node.operatorToken.kind)
      )
        event("branch", [node.left], "controls");
      if (
        (ts.isVariableDeclaration(node) ||
          ts.isPropertyDeclaration(node) ||
          ts.isPropertyAssignment(node)) &&
        node.initializer
      ) {
        event("computation", [node.initializer], "input", h.entry(node));
      } else if (
        ts.isBinaryExpression(node) &&
        node.operatorToken.kind >= ts.SyntaxKind.FirstAssignment &&
        node.operatorToken.kind <= ts.SyntaxKind.LastAssignment
      ) {
        const target = h.resolve(node.left, owner);
        const e = event(
          "computation",
          node.operatorToken.kind === ts.SyntaxKind.EqualsToken
            ? [node.right]
            : [node.left, node.right],
          "input",
          target,
        );
        if (!target) unknown(e, node.left);
      }
      ts.forEachChild(node, (child) => visit(child, owner));
    }
    visit(file.node, file);
    // This observation is emitted by the adapter alongside these relations.
  }
}
