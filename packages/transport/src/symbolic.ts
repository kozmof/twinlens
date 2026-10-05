import type { Source } from "./index.js";
import type { Specification, Expression, EvaluationInput, Scalar } from "./specification.js";
import type {
  ExplorationModel,
  ExplorationTrace,
  ExplorationReport,
  OracleJudgment,
} from "./exploration.js";
export interface SymbolicSort {
  name: string;
  scope: "finite" | "unbounded";
  members: string[];
}
export interface SymbolicVariable {
  name: string;
  sort: string;
  domain: Scalar[];
  source: Source;
}
export interface SymbolicFunction {
  name: string;
  parameters: string[];
  result: string;
}
export interface SolverBounds {
  timeout_ms: number;
  resource_limit: number;
  max_objects: number;
}
export interface SymbolicQuery {
  solver_version: 1;
  specification: Specification;
  claim: string;
  goal: "violation" | "satisfaction";
  assumptions: Expression[];
  evidence: EvaluationInput;
  sorts: SymbolicSort[];
  variables: SymbolicVariable[];
  functions: SymbolicFunction[];
  bounds: SolverBounds;
  simulation: { selector: string; model: ExplorationModel; traces: ExplorationTrace[] } | null;
}
export interface SolverPacket {
  backend_version: 1;
  smt: string;
  bounds: SolverBounds;
  sorts: { name: string; symbol: string; members: { name: string; symbol: string }[] }[];
  variables: { name: string; symbol: string; sort: string }[];
}
export type SolverStatus = "sat" | "unsat" | "unknown" | "unsupported" | "timeout";
export interface SolverBinding {
  name: string;
  sort: string;
  value: Scalar | null;
  symbolic_value: string;
}
export interface SolverBackendResult {
  backend_version: 1;
  backend: string;
  status: SolverStatus;
  reason: string;
  model: string | null;
  bindings: SolverBinding[];
}
export interface SymbolicReport {
  solver_version: 1;
  query: SymbolicQuery;
  status: SolverStatus;
  backend: string;
  reason: string;
  smt: string | null;
  model: string | null;
  bindings: SolverBinding[];
  witness: EvaluationInput | null;
  direct_evaluation: OracleJudgment["constraints"] | null;
  execution: ExplorationReport | null;
  interpretation: string;
}
