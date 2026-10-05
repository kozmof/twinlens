# Phase 7 authentication demonstration

The authentication deliverable exercises Twinlens's existing Constraint IR and response oracle through a native, deterministic simulator. It covers Register, Login, Logout, ChangePassword, ResetPassword, ChangeEmail, VerifyEmail, CreateSession, and DeleteUser. It is a synthetic model for demonstrating analysis, not an authentication service.

```sh
pnpm self:auth
./zig-out/bin/twinlens auth .twinlens/authentication/corrected-model.json --out report.json
./zig-out/bin/twinlens auth-replay .twinlens/authentication/negative-replay-old-password-reuse.json
./zig-out/bin/twinlens auth-replay .twinlens/authentication/corrected-replay-old-password-reuse.json
```

Use the bounded-worker environment settings in [development](development.md) if the host has a strict thread quota. `--out` uses the existing atomic output contract. Reports and replay requests remain in ignored `.twinlens/authentication/`.

## Explicit specification and policy

[weak.tsp](../specs/authentication/weak.tsp) declares the operations and their relationships while leaving authentication policy unspecified. [strong.tsp](../specs/authentication/strong.tsp) declares operation-specific constraints over facts derived from actual simulator transitions. Its constraints use the same direct evaluator as Store histories and symbolic queries. A successful response must satisfy its applicable facts; a rejected response must leave the modeled objects unchanged.

[strict-profile.json](../fixtures/authentication/strict-profile.json) explicitly selects each rule's policy level and the session policy. Available levels are `required`, `optional`, `domain_dependent`, and `unknown`. Missing entries mean unknown. Required rules are enforced by the policy-enforcing adapter. Optional/domain-dependent rules yield domain-dependent judgments; unknown rules yield unknown judgments. Individual constraint outcomes remain visible even when final policy judgment is not enforced. A profile cannot supply a missing specification constraint by itself.

| Rule                   | Model meaning                                                                                                            |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Inputs present         | Required email/secret values are non-null and nonempty for the selected operation                                        |
| Credential binding     | The matching credential is owned by the selected account                                                                 |
| Current credential     | The credential is active and matches the account's explicit current-credential ID                                        |
| Authority              | For account/session mutation and direct session creation, the synthetic caller equals the target account                 |
| Unique identity        | Active accounts have an unambiguous selected email; registration/replacement cannot reuse another active account's email |
| Exclusive credential   | A login credential has exactly one owner                                                                                 |
| Token expiry           | A reset token belongs to the selected account and the logical action time is strictly below its expiry                   |
| Token single use       | The reset token is fresh before success and consumed afterward                                                           |
| Account active         | The selected account exists and is not deleted                                                                           |
| Identity verified      | Login, recovery, and direct session creation use a verified account identity                                             |
| Identity current       | Recovery token identity, or verification input identity, matches the account's current email                             |
| Session ownership      | Logout's target session belongs to the caller and selected account                                                       |
| Old credential revoked | Successful credential replacement revokes all previously active credentials owned by that account                        |
| Session invalidation   | Credential changes follow the explicitly selected revoke/preserve choice                                                 |
| Rejection atomicity    | Rejection leaves the complete modeled state unchanged                                                                    |

Session handling is a separate choice: `sessions_after_change` is `revoke`, `preserve`, or `domain_dependent`. Both concrete choices are demonstrated. An undecided choice stays domain-dependent and does not become a defect merely because a session survives. The selected strict demonstration revokes sessions on successful password changes and resets. These are choices of this model, not implicit rules for every authentication product.

## State and execution semantics

The precise wire types are in [authentication.ts](../packages/transport/src/authentication.ts); the native implementation is [authentication.zig](../src/core/authentication.zig). Version 1 models include the full specification, policy profile, adapter, scenario catalog, and bounds. JSON fields are strict, including explicit nulls for optional action/state values.

State contains users, credentials, sessions, and reset tokens. A user carries email, active/deleted status, verified/unverified status, and a current-credential ID. Credentials have explicit owner sets, synthetic secret labels, and active/revoked status. Sessions bind an owner and email. Reset tokens bind an owner/email, logical expiry, and fresh/used status. Null values, missing credential links, multiple active email matches, shared credentials, deleted accounts, stale token identity, and expired/used tokens can appear in the supplied initial states. These suspicious states are deliberately not pruned away by the desired policy.

Object IDs are unique within their kind; explicit credential owners and session/token owners must reference a user. Current-credential pointers may be null or missing, allowing missing-relation challenges. Names/IDs are bounded to 128 bytes (user IDs to 96 to leave space for generated IDs); email/secret/action values are bounded to 128 bytes. No secret hashing, network calls, identity provider, browser, database, authorization token verification, or real credential handling is performed. Caller names and verification actions are supplied synthetic facts; the simulator does not independently authenticate a caller or verify ownership of an actual email address.

Each scenario starts from its own initial state and executes its supplied action sequence. Actions carry explicit nondecreasing logical times. Native transitions update real in-memory model records; facts are then derived from those inputs and states. Successful registration creates an unverified account and credential. Login/direct session creation append a session; logout revokes a selected session. Password change/reset creates a new current credential; enforced lifecycle rules revoke old credentials and consume reset tokens. Email change marks the identity unverified; verification marks the matching current identity verified. Deletion marks the user deleted and the policy-enforcing adapter revokes their sessions. Other policies, such as session handling on email change, are outside this demonstration.

The `deliberately_weak` adapter intentionally omits the selected checks and revocations, while still updating model objects. The `policy_enforced` adapter rejects failed required preconditions and applies required lifecycle rules. Rejected actions preserve state. State-change effects are emitted only when objects actually changed; idempotent successful actions may have only a return effect. Fresh object IDs are deterministic within a scenario; a collision rejects the action without mutation.

The supplied catalog contains 15 scenarios and 24 steps, covering all nine operations and the eleven requested challenge families: null value, wrong owner, old value, missing relation, many relation, expired value, unauthorized caller, deleted entity, unverified identity, shared ownership, and stale identity. It also includes token reuse, session policy, and a successful registration-to-deletion lifecycle. The native core generates source-linked questions for applicable rules, computes response effects and facts, and invokes the existing response oracle. This is a finite supplied history catalog, not a search over every possible authentication state or action ordering.

## Evidence, replay, and limits

Reports retain the complete model, model digest, before/after states, actions and logical time, accepted/rejected results, generated challenges, standard oracle judgments, suggestions, replayable counterexample prefixes, and coverage. A suggestion copies the governing expression actually violated and retains its target, kind, rule, source, simulation origin, confidence, and warning severity. Missing constraints remain unknown and do not yield invented suggestions.

Every report is classified `simulation_only`; effects have simulation origin. Derived facts carry trace origin to link them to the recorded transition, which does not relabel the simulator as a production runtime. An oracle `defect` here means the simulated behavior violates an explicitly enforced constraint. It does not confirm a defect in an external implementation or in production authentication.

Replay verifies the specification/profile/catalog digest and requires an exact action prefix from the named scenario. Changing the adapter or resource bounds preserves the contract digest, permitting the identical retained trace to test the corrected adapter. Changing the specification, policy profile, initial states, or catalog requires a new digest; replay never silently rebinds a changed contract. Incomplete replay remains explicitly incomplete.

Hard input limits are 64 scenarios, 32 actions per scenario, 64 objects per state, and eight owners per credential. Run bounds allow 1–64 scenarios, 1–1024 executed steps, 1–64 objects, and 1–60000 ms. Deadlines are checked between synchronous transitions. An action that would exceed the object budget is not committed. Coverage records execution counts, omitted or partially executed scenarios, and `catalog_exhausted`, `scenario_limit`, `step_limit`, `object_limit`, `time_limit`, or `replay_complete`. Catalog exhaustion is not a universal proof. Replayed coverage counts only the chosen prefix; unrelated catalog scenarios are intentionally not replayed.

## Reproducible comparison and self-application

`pnpm self:auth` runs the same catalog three ways:

1. Weak specification and weak adapter: missing policy constraints produce unknown judgments.
2. Strong specification and weak adapter: concrete simulated violations and structured suggestions appear.
3. Strong specification and policy-enforcing adapter: the finite catalog passes, including the legitimate lifecycle.

The gate demonstrates wrong-owner login, old-password reuse, unauthorized password change, expired/reused reset tokens, deleted-user sessions, and unverified recovery. For each, the final weak action succeeds while the enforced counterpart rejects it. Seven retained failure traces reproduce against the weak adapter and pass against the corrected one. Additional runs demonstrate preserved sessions and undecided session policy.

`comparison.json` aligns scenario/step/operation across the three runs and records result changes, violated rules, suggestions, and corrected judgments. It retains all three model digests rather than pretending weak and strong specifications are the same contract. The reports remain independently reproducible with the CLI.

The named Twinlens self-target is the native simulator's `apply` function. The gate scans actual core sources, records its source-linked static telemetry, and checks the hypothesis that rejected requests preserve all objects while successful histories satisfy the selected profile. The intentionally weak adapter is retained as a negative fixture. Static metric values alone never establish a defect. Existing Store, structural, solver, and cross-lens self-application gates also remain required.

This completes Phase 7's authentication demonstration subsection. The broader perspective, dataflow, frontend, domain-profile, and native/WASM expansion backlog remains open in the working checklist.
