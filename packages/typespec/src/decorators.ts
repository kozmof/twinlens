/* eslint-disable no-control-regex -- Reject or sanitize control characters in wire names. */
import {
  createTypeSpecLibrary,
  setTypeSpecNamespace,
  type DecoratorContext,
  type Type,
  type Operation,
} from "@typespec/compiler";
import {
  expression,
  scalar,
  type ClaimKind,
  type DomainFunction,
  type Expression,
  type SpecificationState,
} from "@twinlens/transport";
export const $lib = createTypeSpecLibrary({
  name: "@twinlens/typespec",
  diagnostics: {
    annotation: {
      severity: "error",
      messages: {
        default:
          "Invalid Twinlens annotation: check target, kind, name, expression, and duplicate annotations.",
      },
    },
  },
} as const);
export const annotationKey = Symbol.for("twinlens.typespec.annotations.v1");
export interface Annotation {
  claims: { kind: ClaimKind; name: string; expression: Expression[] }[];
  state?: { state: SpecificationState; reason: string };
  relations: { kind: string; target: Type }[];
  semantics?: { mode: DomainFunction["mode"]; definition: Expression[] };
  backing?: Operation;
  domain?: {
    ownership: "unknown" | "owned" | "shared";
    nullability: "unknown" | "nullable" | "nonnull";
    values: ReturnType<typeof scalar>[];
  };
}
function text(value: string) {
  return !!value && !/[\u0000-\u001f\u007f]/u.test(value) && value.isWellFormed();
}
function annotate(
  context: DecoratorContext,
  target: Type,
  action: (annotation: Annotation) => void,
) {
  try {
    if (
      !["Model", "ModelProperty", "Operation", "Scalar", "Enum", "Union", "Interface"].includes(
        target.kind,
      )
    )
      throw Error("target");
    const annotations = context.program.stateMap(annotationKey);
    const annotation: Annotation = annotations.get(target) ?? { claims: [], relations: [] };
    action(annotation);
    annotations.set(target, annotation);
  } catch {
    $lib.reportDiagnostic(context.program, { code: "annotation", target: context.decoratorTarget });
  }
}
export function $claim(
  context: DecoratorContext,
  target: Type,
  kind: string,
  name: string,
  expressionText: string,
) {
  annotate(context, target, (annotation) => {
    if (
      !["requirement", "postcondition", "invariant", "forbidden", "policy"].includes(kind) ||
      !text(name) ||
      ["coverage", "domain"].includes(name) ||
      annotation.claims.some((claim) => claim.name === name)
    )
      throw Error("claim");
    annotation.claims.push({
      kind: kind as ClaimKind,
      name,
      expression: expression(JSON.parse(expressionText)),
    });
  });
}
export const $require = (
  context: DecoratorContext,
  target: Type,
  name: string,
  expressionText: string,
) => $claim(context, target, "requirement", name, expressionText);
export const $ensure = (
  context: DecoratorContext,
  target: Type,
  name: string,
  expressionText: string,
) => $claim(context, target, "postcondition", name, expressionText);
export const $invariant = (
  context: DecoratorContext,
  target: Type,
  name: string,
  expressionText: string,
) => $claim(context, target, "invariant", name, expressionText);
export const $forbid = (
  context: DecoratorContext,
  target: Type,
  name: string,
  expressionText: string,
) => $claim(context, target, "forbidden", name, expressionText);
export const $policy = (
  context: DecoratorContext,
  target: Type,
  name: string,
  expressionText: string,
) => $claim(context, target, "policy", name, expressionText);
export function $status(context: DecoratorContext, target: Type, state: string, reason: string) {
  annotate(context, target, (annotation) => {
    if (
      annotation.state ||
      !["unspecified", "intentionally_unspecified", "deferred", "out_of_scope", "unknown"].includes(
        state,
      ) ||
      !text(reason)
    )
      throw Error("state");
    annotation.state = { state: state as SpecificationState, reason };
  });
}
export function $relation(
  context: DecoratorContext,
  target: Type,
  kind: string,
  destination: Type,
) {
  annotate(context, target, (annotation) => {
    if (
      ![
        "inputs",
        "outputs",
        "reads",
        "writes",
        "creates",
        "deletes",
        "calls",
        "requires",
        "ensures",
        "emits",
        "authorizes",
        "owns",
        "derived_from",
      ].includes(kind)
    )
      throw Error("relation");
    annotation.relations.push({ kind, target: destination });
  });
}
export function $semantics(
  context: DecoratorContext,
  operation: Operation,
  mode: string,
  definition?: string,
) {
  annotate(context, operation, (annotation) => {
    if (
      annotation.semantics ||
      !["opaque", "uninterpreted", "axiomatized", "executable", "mocked", "observed"].includes(mode)
    )
      throw Error("semantics");
    annotation.semantics = {
      mode: mode as DomainFunction["mode"],
      definition: definition === undefined ? [] : expression(JSON.parse(definition)),
    };
  });
}
export function $derived(context: DecoratorContext, operation: Operation, backing: Operation) {
  annotate(context, operation, (annotation) => {
    if (annotation.backing) throw Error("backing");
    annotation.backing = backing;
  });
}
export function $domain(context: DecoratorContext, target: Type, definition: string) {
  annotate(context, target, (annotation) => {
    const domainDefinition = JSON.parse(definition);
    if (
      annotation.domain ||
      !domainDefinition ||
      typeof domainDefinition !== "object" ||
      Array.isArray(domainDefinition) ||
      Object.keys(domainDefinition).some(
        (propertyName) => !["ownership", "nullability", "values"].includes(propertyName),
      )
    )
      throw Error("domain");
    const ownership = domainDefinition.ownership ?? "unknown",
      nullability = domainDefinition.nullability ?? "unknown",
      values = domainDefinition.values ?? [];
    if (
      !["unknown", "owned", "shared"].includes(ownership) ||
      !["unknown", "nullable", "nonnull"].includes(nullability) ||
      !Array.isArray(values) ||
      values.length > 64
    )
      throw Error("domain");
    annotation.domain = { ownership, nullability, values: values.map(scalar) };
  });
}
setTypeSpecNamespace(
  "Twinlens",
  $claim,
  $require,
  $ensure,
  $invariant,
  $forbid,
  $policy,
  $status,
  $relation,
  $semantics,
  $derived,
  $domain,
);
