import type { SubjectId, Source } from "./index.js";
import type { Specification, ClaimKind, Expression } from "./specification.js";
import type { OracleJudgment } from "./exploration.js";
export type AuthenticationOperation =
  | "Register"
  | "Login"
  | "Logout"
  | "ChangePassword"
  | "ResetPassword"
  | "ChangeEmail"
  | "VerifyEmail"
  | "CreateSession"
  | "DeleteUser";
export type AuthenticationFamily =
  | "null_value"
  | "wrong_owner"
  | "old_value"
  | "missing_relation"
  | "many_relation"
  | "expired_value"
  | "unauthorized_caller"
  | "deleted_entity"
  | "unverified_identity"
  | "shared_ownership"
  | "stale_identity"
  | "single_use"
  | "session_policy"
  | "lifecycle";
export type AuthenticationRule =
  | "inputs_present"
  | "credential_binding"
  | "current_credential"
  | "authority"
  | "unique_identity"
  | "exclusive_credential"
  | "token_expiry"
  | "token_single_use"
  | "account_active"
  | "identity_verified"
  | "identity_current"
  | "session_ownership"
  | "old_credential_revoked"
  | "session_invalidation"
  | "rejection_atomic";
export interface AuthenticationProfile {
  name: string;
  policies: {
    rule: AuthenticationRule;
    level: "required" | "optional" | "domain_dependent" | "unknown";
    reason: string;
  }[];
  sessions_after_change: "revoke" | "preserve" | "domain_dependent";
}
export interface AuthenticationState {
  users: {
    id: string;
    email: string | null;
    current_credential: string | null;
    status: "active" | "deleted";
    verification: "verified" | "unverified";
  }[];
  credentials: {
    id: string;
    owners: string[];
    secret: string | null;
    status: "active" | "revoked";
  }[];
  sessions: { id: string; owner: string; email: string | null; status: "active" | "revoked" }[];
  tokens: {
    id: string;
    owner: string;
    email: string | null;
    expires_at: number;
    status: "fresh" | "used";
  }[];
}
export interface AuthenticationAction {
  operation: AuthenticationOperation;
  actor: string | null;
  user: string;
  email: string | null;
  secret: string | null;
  token: string | null;
  session: string | null;
  at: number;
}
export interface AuthenticationScenario {
  name: string;
  family: AuthenticationFamily;
  initial: AuthenticationState;
  actions: AuthenticationAction[];
}
export interface AuthenticationModel {
  authentication_version: 1;
  specification: Specification;
  profile: AuthenticationProfile;
  adapter: "deliberately_weak" | "policy_enforced";
  scenarios: AuthenticationScenario[];
  bounds: { max_scenarios: number; max_steps: number; max_objects: number; max_time_ms: number };
}
export interface AuthenticationTrace {
  model_digest: string;
  scenario: string;
  actions: AuthenticationAction[];
}
export interface AuthenticationReplay {
  authentication_replay_version: 1;
  model: AuthenticationModel;
  trace: AuthenticationTrace;
}
export interface AuthenticationCheck {
  rule: AuthenticationRule;
  judgment: OracleJudgment;
  suggestion: {
    target: SubjectId;
    kind: ClaimKind;
    constraint: Expression[];
    rule: AuthenticationRule;
    source: Source;
    origin: "simulation";
    confidence: "high";
    severity: "warning";
  } | null;
}
export interface AuthenticationTransition {
  id: string;
  scenario: string;
  step: number;
  action: AuthenticationAction;
  before: AuthenticationState;
  after: AuthenticationState;
  result: "accepted" | "rejected";
  checks: AuthenticationCheck[];
}
export interface AuthenticationReport {
  authentication_version: 1;
  model_digest: string;
  model: AuthenticationModel;
  transitions: AuthenticationTransition[];
  counterexamples: AuthenticationTrace[];
  coverage: {
    executed_scenarios: number;
    executed_steps: number;
    supplied_scenarios: number;
    excluded_scenarios: string[];
    stop:
      | "catalog_exhausted"
      | "scenario_limit"
      | "step_limit"
      | "object_limit"
      | "time_limit"
      | "replay_complete";
    scope: string;
  };
  classification: "simulation_only";
}
