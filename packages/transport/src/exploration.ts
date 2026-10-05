import type { Source, SubjectId, Document } from "./index.js";
import type { Snapshot } from "./snapshot.js";
import type {
  Claim,
  Constraint,
  EvaluationInput,
  Fact,
  Scalar,
  Specification,
} from "./specification.js";
export type ExecutionRequirement =
  | "solver_supported"
  | "simulation"
  | "runtime_execution"
  | "human_policy"
  | "unknown";
export type ResponseExpectation = "required" | "possible" | "forbidden" | "unknown";
export type EffectKind =
  | "return_value"
  | "state_change"
  | "database_change"
  | "log"
  | "event"
  | "observation"
  | "external_effect"
  | "unknown_effect";
export type ResponseOrigin = "simulation" | "runtime" | "code" | "test";
export interface Challenge {
  id: string;
  target: SubjectId;
  target_operation: SubjectId | null;
  assumptions: Fact[];
  constraints: string[];
  question: string;
  suspicious_condition: string;
  expectation: ResponseExpectation;
  execution: ExecutionRequirement;
  generated_from: { claim: string | null; finding: string | null; evidence: Source[] };
}
export interface ChallengeSet {
  challenge_version: 1;
  project: string;
  revision: string;
  challenges: Challenge[];
}
export interface ResponseEffect {
  name: string;
  kind: EffectKind;
  subject: SubjectId | null;
  value: Scalar | null;
  source: Source;
  origin: ResponseOrigin;
}
export interface ResponseSet {
  operation: SubjectId;
  origin: ResponseOrigin;
  coverage: "complete" | "partial";
  effects: ResponseEffect[];
  evidence: EvaluationInput;
}
export interface EffectExpectation {
  name: string;
  kind: EffectKind;
  classification: ResponseExpectation;
  source: Source;
}
export interface OracleRequest {
  oracle_version: 1;
  challenge: Challenge;
  response: ResponseSet;
  expectations: EffectExpectation[];
  policy: "enforced" | "domain_dependent" | "unknown";
}
export type OracleOutcome = "acceptable" | "defect" | "unknown" | "domain_dependent";
export type ConstraintOutcome = "satisfied" | "violated" | "unknown" | "unsupported";
export interface OracleJudgment {
  oracle_version: 1;
  challenge: Challenge;
  response: ResponseSet;
  outcome: OracleOutcome;
  reason: string;
  effects: { expectation: EffectExpectation; outcome: ConstraintOutcome; reason: string }[];
  constraints: {
    evaluation_version: 1;
    project: string;
    revision: string;
    results: {
      claim: Claim;
      constraint: Constraint | null;
      outcome: ConstraintOutcome;
      reason: string;
      evidence: Source[];
      facts: string[];
      records: string[];
    }[];
  };
}
export interface ExplorationBounds {
  max_depth: number;
  max_objects: number;
  max_executions: number;
  max_time_ms: number;
}
export interface SourceWorld {
  name: string;
  snapshot: Snapshot;
}
export interface ExplorationModel {
  exploration_version: 1;
  specification: Specification;
  operation: SubjectId;
  worlds: SourceWorld[];
  initial_states: number[];
  bounds: ExplorationBounds;
  adapter: "native_store" | "test_stale_delete";
}
export interface HistoryAction {
  kind: "add" | "modify" | "delete" | "scan" | "rescan";
  path: string | null;
  world: number;
}
export interface ExplorationState {
  id: string;
  world: number;
  store_digest: string;
  document: Document;
  freshness: "fresh" | "stale";
  scanned: "never" | "previously";
  depth: number;
  initial_world: number;
  incoming: number | null;
}
export interface HistoricalValue {
  phase: "old" | "new" | "current" | "historical";
  state: string;
  slot: "source" | "store";
  value: string;
}
export interface HistoryEvent {
  operation: SubjectId;
  actor: string;
  subject: string | null;
  affected_values: HistoricalValue[];
  timestamp: number;
  clock: "logical";
  evidence: Source[];
}
export interface HistoryTransition {
  id: string;
  before: string;
  after: string;
  action: HistoryAction;
  event: HistoryEvent;
  judgment: OracleJudgment;
}
export interface ExplorationTrace {
  model_digest: string;
  initial_world: number;
  actions: HistoryAction[];
  failing_transition: string | null;
}
export interface ReplayRequest {
  replay_version: 1;
  model: ExplorationModel;
  trace: ExplorationTrace;
}
export interface ExplorationReport {
  exploration_version: 1;
  model_digest: string;
  adapter: ExplorationModel["adapter"];
  bounds: ExplorationBounds;
  coverage: {
    executions: number;
    initial_states: number;
    distinct_states: number;
    excluded_worlds: number[];
    stop:
      | "exhausted"
      | "depth_limit"
      | "execution_limit"
      | "time_limit"
      | "object_limit"
      | "replay_complete";
    scope: string;
  };
  states: ExplorationState[];
  transitions: HistoryTransition[];
  counterexamples: ExplorationTrace[];
  unknown_transitions: string[];
}
