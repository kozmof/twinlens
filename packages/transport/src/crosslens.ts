import type { SubjectId, ObservationId, RelationId, Source } from "./index.js";
import type { Snapshot } from "./snapshot.js";
import type { Specification, Expression, ClaimKind } from "./specification.js";
import type {
  Challenge,
  OracleRequest,
  OracleJudgment,
  ReplayRequest,
  ExplorationReport,
  ResponseOrigin,
} from "./exploration.js";
import type { SymbolicReport } from "./symbolic.js";
export type PerspectiveRule =
  | "authority"
  | "old_lifecycle"
  | "identity_policy"
  | "dependency"
  | "derived_backing"
  | "provenance_trust"
  | "resource_lifecycle";
export type PolicyLevel = "required" | "recommended" | "domain_dependent" | "optional" | "unknown";
export type FindingStatus =
  | "open"
  | "confirmed"
  | "false_positive"
  | "accepted_risk"
  | "fixed"
  | "ignored"
  | "deferred";
export interface CrossMapping {
  id: string;
  name: string;
  subject: SubjectId;
  implementation: SubjectId | null;
  observations: ObservationId[];
  relations: RelationId[];
  effects: string[];
  source: Source;
  confidence: Source["confidence"];
  reason: string;
}
export interface PerspectivePolicy {
  subject: SubjectId;
  rule: PerspectiveRule;
  level: PolicyLevel;
  constraints: string[];
  reason: string;
  source: Source;
}
export interface CrossReview {
  finding: string;
  status: FindingStatus;
  note: string;
  revision: string;
}
export interface CrossExecution {
  name: string;
  finding: string;
  challenge: string;
  replay: ReplayRequest | null;
  response: OracleRequest | null;
}
export interface CrossInput {
  cross_version: 1;
  specification: Specification;
  snapshot: Snapshot;
  mappings: CrossMapping[];
  policies: PerspectivePolicy[];
  reviews: CrossReview[];
  symbolic_results: SymbolicReport[];
  executions: CrossExecution[];
}
export interface CrossEvidence {
  id: string;
  subject: SubjectId;
  origin: "inference" | "trace";
  confidence: Source["confidence"];
  specification_sources: Source[];
  implementation_sources: Source[];
  observations: ObservationId[];
  relations: RelationId[];
}
export interface ConstraintSuggestion {
  target: SubjectId;
  kind: ClaimKind;
  constraint: Expression[];
  governing_constraint: string | null;
  generated_from: string;
  origin: "inference" | "trace";
  confidence: Source["confidence"];
  severity: "info" | "warning" | "error";
}
export interface ConsequenceFinding {
  id: string;
  subject: SubjectId;
  affected: SubjectId;
  rule: PerspectiveRule;
  category: "policy_gap";
  level: PolicyLevel;
  status: FindingStatus;
  reason: string;
  evidence: string;
  challenge: Challenge;
  suggestion: ConstraintSuggestion;
}
export interface CrossVerification {
  name: string;
  finding: string;
  challenge: string;
  origin: ResponseOrigin;
  classification: "acceptable" | "simulated_counterexample" | "observed_violation" | "inconclusive";
  judgment: OracleJudgment;
  exploration: ExplorationReport | null;
}
export interface CrossReport {
  cross_version: 1;
  revision: string;
  input: CrossInput;
  coverage: {
    subject: SubjectId;
    state:
      | "specified_observed"
      | "specified_unobserved"
      | "unspecified_observed"
      | "unspecified_unobserved";
    mapping: "mapped" | "unmapped";
    behavior: "static_only" | "unobserved";
    mappings: string[];
    reason: string;
  }[];
  evidence: CrossEvidence[];
  findings: ConsequenceFinding[];
  uncertainties: { subject: SubjectId; reason: string; source: Source }[];
  verifications: CrossVerification[];
  contradictions: {
    finding: string;
    verification: string;
    specification_sources: Source[];
    implementation_sources: Source[];
    explanations: string[];
  }[];
  confirmed_violations: string[];
  reviews: CrossReview[];
}
export interface CrossDiff {
  cross_diff_version: 1;
  before: string;
  after: string;
  changes: {
    category: string;
    key: string;
    kind: "added" | "removed" | "changed";
    before: string | null;
    after: string | null;
  }[];
}
