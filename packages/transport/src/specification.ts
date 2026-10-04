/* eslint-disable no-control-regex -- Reject or sanitize control characters in wire names. */
import { stableId, type Document, type Source, type SubjectId } from "./index.js";
import type { Snapshot } from "./snapshot.js";
export type Scalar = { kind: "null" | "boolean" | "number" | "string"; value: string };
export type Expression = {
  op:
    | "literal"
    | "fact"
    | "eq"
    | "ne"
    | "lt"
    | "le"
    | "gt"
    | "ge"
    | "and"
    | "or"
    | "not"
    | "implies"
    | "call"
    | "graph"
    | "unsupported";
  args: number[];
  name: string | null;
  value: Scalar | null;
};
export type ClaimKind = "requirement" | "postcondition" | "invariant" | "forbidden" | "policy";
export type SpecificationState =
  | "specified"
  | "unspecified"
  | "intentionally_unspecified"
  | "deferred"
  | "out_of_scope"
  | "unknown";
export interface Constraint {
  id: string;
  subject: SubjectId;
  name: string;
  expression: Expression[];
  source: Source;
}
export interface Claim {
  id: string;
  subject: SubjectId;
  name: string;
  kind: ClaimKind;
  state: SpecificationState;
  reason: string;
  constraint: string | null;
  source: Source;
}
export interface DomainFunction {
  subject: SubjectId;
  name: string;
  mode: "opaque" | "uninterpreted" | "axiomatized" | "executable" | "mocked" | "observed";
  arity: number;
  definition: Expression[];
  backing: SubjectId | null;
}
export interface Domain {
  subject: SubjectId;
  ownership: "unknown" | "owned" | "shared";
  nullability: "unknown" | "nullable" | "nonnull";
  values: Scalar[];
  constraints: string[];
  reason: string;
}
export interface Specification {
  specification_version: 1;
  snapshot: Snapshot;
  claims: Claim[];
  constraints: Constraint[];
  functions: DomainFunction[];
  domains: Domain[];
}
export interface Fact {
  name: string;
  status: "known" | "unknown" | "unsupported";
  value: Scalar | null;
  reason: string | null;
  source: Source;
  origin: "code" | "specification" | "inference" | "test" | "trace";
}
export interface EvaluationInput {
  input_version: 1;
  project: string;
  facts: Fact[];
  graph: Document | null;
  coverage: "complete" | "partial" | "absent";
}
export const claimId = (subject: SubjectId, name: string, kind: ClaimKind): string =>
  stableId("clm_", ["claim", subject, name, kind]);
export const constraintId = (subject: SubjectId, name: string): string =>
  stableId("con_", ["constraint", subject, name]);
export function scalar(value: unknown): Scalar {
  if (value === null) return { kind: "null", value: "" };
  if (typeof value === "boolean") return { kind: "boolean", value: String(value) };
  if (typeof value === "number" && Number.isFinite(value))
    return { kind: "number", value: String(value) };
  if (typeof value === "string" && value.isWellFormed()) return { kind: "string", value };
  throw new Error("Only finite scalar literals are supported");
}
/** Lower a small JSON expression grammar into a bounded, acyclic node vector. */
export function expression(value: unknown): Expression[] {
  const nodes: Expression[] = [];
  function visit(operand: unknown, depth: number): number {
    if (depth > 32 || nodes.length >= 1024) throw new Error("Expression limit exceeded");
    let node: Expression;
    if (operand === null || typeof operand !== "object")
      node = { op: "literal", value: scalar(operand), name: null, args: [] };
    else {
      if (Array.isArray(operand) || Object.keys(operand).length !== 1)
        throw new Error("Expected a single expression operator");
      const [operator, argument] = Object.entries(operand)[0]!;
      if (["fact", "graph", "unsupported"].includes(operator)) {
        if (
          typeof argument !== "string" ||
          !argument.length ||
          /[\u0000-\u001f\u007f]/u.test(argument)
        )
          throw new Error("Expected a nonempty expression name");
        node = { op: operator as Expression["op"], name: argument, value: null, args: [] };
      } else if (operator === "call") {
        if (
          !Array.isArray(argument) ||
          typeof argument[0] !== "string" ||
          !argument[0] ||
          /[\u0000-\u001f\u007f]/u.test(argument[0]) ||
          argument.length > 65
        )
          throw new Error("Call requires a function name followed by arguments");
        node = {
          op: operator,
          name: argument[0],
          value: null,
          args: argument.slice(1).map((operand) => visit(operand, depth + 1)),
        };
      } else {
        const arity =
          operator === "not"
            ? 1
            : ["eq", "ne", "lt", "le", "gt", "ge", "and", "or", "implies"].includes(operator)
              ? 2
              : 0;
        if (!arity || !Array.isArray(argument) || argument.length !== arity)
          throw new Error("Invalid operator or argument count");
        node = {
          op: operator as Expression["op"],
          name: null,
          value: null,
          args: argument.map((operand) => visit(operand, depth + 1)),
        };
      }
    }
    nodes.push(node);
    if (nodes.length > 1024) throw new Error("Expression limit exceeded");
    return nodes.length - 1;
  }
  visit(value, 0);
  return nodes;
}
