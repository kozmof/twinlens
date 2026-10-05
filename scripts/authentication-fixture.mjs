/** Synthetic values only; the native core owns transitions and derives all evidence. */
export const authenticationRules = {
  inputs_present: [
    "Register",
    "Login",
    "Logout",
    "ChangePassword",
    "ResetPassword",
    "ChangeEmail",
    "VerifyEmail",
    "CreateSession",
    "DeleteUser",
  ],
  credential_binding: ["Login"],
  current_credential: ["Login"],
  authority: [
    "Logout",
    "ChangePassword",
    "ChangeEmail",
    "VerifyEmail",
    "CreateSession",
    "DeleteUser",
  ],
  unique_identity: ["Register", "Login", "ChangeEmail"],
  exclusive_credential: ["Login"],
  token_expiry: ["ResetPassword"],
  token_single_use: ["ResetPassword"],
  account_active: [
    "Login",
    "Logout",
    "ChangePassword",
    "ResetPassword",
    "ChangeEmail",
    "VerifyEmail",
    "CreateSession",
    "DeleteUser",
  ],
  identity_verified: ["Login", "ResetPassword", "CreateSession"],
  identity_current: ["ResetPassword", "VerifyEmail"],
  session_ownership: ["Logout"],
  old_credential_revoked: ["ChangePassword", "ResetPassword"],
  session_invalidation: ["ChangePassword", "ResetPassword"],
  rejection_atomic: [
    "Register",
    "Login",
    "Logout",
    "ChangePassword",
    "ResetPassword",
    "ChangeEmail",
    "VerifyEmail",
    "CreateSession",
    "DeleteUser",
  ],
};
export function authenticationScenarios() {
  const initial = () => ({
    users: [
      {
        id: "alice",
        current_credential: "alice-credential",
        email: "alice@example.test",
        status: "active",
        verification: "verified",
      },
      {
        id: "bob",
        current_credential: "bob-credential",
        email: "bob@example.test",
        status: "active",
        verification: "verified",
      },
    ],
    credentials: [
      { id: "alice-credential", owners: ["alice"], secret: "synthetic-alice", status: "active" },
      { id: "bob-credential", owners: ["bob"], secret: "synthetic-bob", status: "active" },
    ],
    sessions: [
      { id: "alice-session", owner: "alice", email: "alice@example.test", status: "active" },
    ],
    tokens: [
      {
        id: "alice-reset",
        owner: "alice",
        email: "alice@example.test",
        expires_at: 10,
        status: "fresh",
      },
    ],
  });
  const action = (operation, changes = {}) => ({
    operation,
    actor: "alice",
    user: "alice",
    email: "alice@example.test",
    secret: "synthetic-alice",
    token: "alice-reset",
    session: "alice-session",
    at: 1,
    ...changes,
  });
  const scenario = (name, family, actions, change = () => {}) => {
    const state = initial();
    change(state);
    return { name, family, initial: state, actions };
  };
  return [
    scenario("null-password", "null_value", [
      action("Register", { user: "carol", email: "carol@example.test", secret: null }),
    ]),
    scenario("wrong-owner-login", "wrong_owner", [action("Login", { secret: "synthetic-bob" })]),
    scenario("old-password-reuse", "old_value", [
      action("ChangePassword", { secret: "synthetic-new" }),
      action("Login", { at: 2 }),
    ]),
    scenario("missing-credential", "missing_relation", [action("Login")], (state) => {
      state.credentials = [];
    }),
    scenario("ambiguous-identity", "many_relation", [action("Login")], (state) => {
      state.users[1].email = state.users[0].email;
    }),
    scenario("expired-reset-token", "expired_value", [
      action("ResetPassword", { at: 10, secret: "synthetic-new" }),
    ]),
    scenario("unauthorized-password-change", "unauthorized_caller", [
      action("ChangePassword", { actor: "bob", secret: "synthetic-new" }),
    ]),
    scenario("deleted-user-session", "deleted_entity", [
      action("DeleteUser"),
      action("CreateSession", { at: 2 }),
    ]),
    scenario(
      "unverified-recovery",
      "unverified_identity",
      [action("ResetPassword", { secret: "synthetic-new" })],
      (state) => {
        state.users[0].verification = "unverified";
      },
    ),
    scenario("shared-credential", "shared_ownership", [action("Login")], (state) => {
      state.credentials[0].owners.push("bob");
    }),
    scenario("stale-recovery-identity", "stale_identity", [
      action("ChangeEmail", { email: "alice-new@example.test" }),
      action("VerifyEmail", { at: 2, email: "alice-new@example.test" }),
      action("ResetPassword", { at: 3, secret: "synthetic-new" }),
    ]),
    scenario("reused-reset-token", "single_use", [
      action("ResetPassword", { secret: "synthetic-new" }),
      action("ResetPassword", { at: 2, secret: "synthetic-newer" }),
    ]),
    scenario("session-invalidation-policy", "session_policy", [
      action("ChangePassword", { secret: "synthetic-new" }),
    ]),
    scenario("foreign-session-logout", "wrong_owner", [
      action("Logout", { actor: "bob", user: "bob" }),
    ]),
    scenario("legitimate-lifecycle", "lifecycle", [
      action("Register", { user: "carol", email: "carol@example.test", secret: "synthetic-carol" }),
      action("VerifyEmail", { user: "carol", actor: "carol", email: "carol@example.test", at: 2 }),
      action("Login", {
        user: "carol",
        email: "carol@example.test",
        secret: "synthetic-carol",
        at: 3,
      }),
      action("Logout", { user: "carol", actor: "carol", session: "created:carol:2", at: 4 }),
      action("DeleteUser", { user: "carol", actor: "carol", at: 5 }),
    ]),
  ];
}
export function authenticationModel(specification, profile, adapter = "policy_enforced") {
  return {
    authentication_version: 1,
    specification,
    profile,
    adapter,
    scenarios: authenticationScenarios(),
    bounds: { max_scenarios: 32, max_steps: 128, max_objects: 32, max_time_ms: 60000 },
  };
}
