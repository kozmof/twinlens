import { init, type Z3_ast, type Z3_sort } from "z3-solver";
import {
  scalar,
  type Scalar,
  type SolverPacket,
  type SolverBackendResult,
} from "@twinlens/transport";

function rational(value: string): Scalar | null {
  const match = /^(-?\d+)(?:\/(\d+))?$/u.exec(value);
  if (!match || match[1]!.length > 16 || (match[2]?.length ?? 0) > 16) return null;
  const numerator = BigInt(match[1]!);
  const denominator = BigInt(match[2] ?? "1");
  const number = Number(numerator) / Number(denominator);
  if (!Number.isFinite(number) || Math.abs(number) > Number.MAX_SAFE_INTEGER) return null;
  const decimal = /^(-?)(\d+)(?:\.(\d+))?(?:e([+-]?\d+))?$/u.exec(String(number));
  if (!decimal) return null;
  const digits = BigInt((decimal[1] ?? "") + decimal[2]! + (decimal[3] ?? ""));
  const exponent = Number(decimal[4] ?? 0) - (decimal[3]?.length ?? 0);
  const exact =
    exponent >= 0
      ? numerator === digits * denominator * 10n ** BigInt(exponent)
      : numerator * 10n ** BigInt(-exponent) === digits * denominator;
  return exact ? scalar(number) : null;
}
/** Transport only: the Zig core supplies all SMT assertions and their scope. */
export async function solve(packet: SolverPacket): Promise<SolverBackendResult> {
  const { Context, Z3, getVersionString } = await init();
  const context = Context("twinlens");
  const solver = new context.Solver();
  const backend = `z3/${getVersionString()}`;
  solver.set("timeout", packet.bounds.timeout_ms);
  solver.set("rlimit", packet.bounds.resource_limit);
  solver.fromString(packet.smt);
  const status = await solver.check();
  if (status !== "sat") {
    const reason =
      status === "unknown"
        ? Z3.solver_get_reason_unknown(context.ptr, solver.ptr)
        : "No satisfying model under the supplied assertions";
    return {
      backend_version: 1,
      backend,
      status: status === "unknown" && /timeout|canceled/iu.test(reason) ? "timeout" : status,
      reason,
      model: null,
      bindings: [],
    };
  }
  const model = solver.model();
  function sort(name: string): Z3_sort {
    if (name === "Bool") return Z3.mk_bool_sort(context.ptr);
    if (name === "Int") return Z3.mk_int_sort(context.ptr);
    if (name === "Real") return Z3.mk_real_sort(context.ptr);
    if (name === "String") return Z3.mk_string_sort(context.ptr);
    const declaration = packet.sorts.find((declaration) => declaration.name === name);
    if (!declaration) throw Error("Unknown sort in solver packet");
    return Z3.mk_uninterpreted_sort(
      context.ptr,
      Z3.mk_string_symbol(context.ptr, declaration.symbol),
    );
  }
  function evaluate(name: string, type: Z3_sort): Z3_ast {
    const expression = Z3.mk_const(context.ptr, Z3.mk_string_symbol(context.ptr, name), type);
    Z3.inc_ref(context.ptr, expression);
    try {
      const value = Z3.model_eval(context.ptr, model.ptr, expression, true);
      if (!value) throw Error("Model evaluation failed");
      Z3.inc_ref(context.ptr, value);
      return value;
    } finally {
      Z3.dec_ref(context.ptr, expression);
    }
  }
  const bindings = packet.variables.map((variable) => {
    const type = sort(variable.sort);
    const value = evaluate(variable.symbol, type);
    try {
      const symbolic_value = Z3.ast_to_string(context.ptr, value);
      let decoded: Scalar | null = null;
      if (variable.sort === "Bool" && ["true", "false"].includes(symbolic_value))
        decoded = scalar(symbolic_value === "true");
      else if (["Int", "Real"].includes(variable.sort) && Z3.is_numeral_ast(context.ptr, value))
        decoded = rational(Z3.get_numeral_string(context.ptr, value));
      else if (variable.sort === "String" && Z3.is_string(context.ptr, value))
        decoded = scalar(
          String.fromCodePoint(
            ...Z3.get_string_contents(context.ptr, value, Z3.get_string_length(context.ptr, value)),
          ),
        );
      else {
        const declaration = packet.sorts.find((declaration) => declaration.name === variable.sort);
        for (const member of declaration?.members ?? []) {
          const memberValue = evaluate(member.symbol, type);
          try {
            if (Z3.is_eq_ast(context.ptr, value, memberValue)) {
              decoded = scalar(member.name);
              break;
            }
          } finally {
            Z3.dec_ref(context.ptr, memberValue);
          }
        }
      }
      return { name: variable.name, sort: variable.sort, value: decoded, symbolic_value };
    } finally {
      Z3.dec_ref(context.ptr, value);
    }
  });
  return {
    backend_version: 1,
    backend,
    status: "sat",
    reason:
      "A symbolic model satisfies the supplied assertions; no implementation execution is implied",
    model: model.toString(),
    bindings,
  };
}
