import "../../packages/typespec/lib/main.tsp";
using Twinlens;

// Synthetic authentication policy model; secrets are uninterpreted fixture labels.
@perspective("identity") model User {}
@perspective("owned") @perspective("credential") model Credential {}
@perspective("owned") model Session {}
@perspective("resource") model ResetToken {}

@relation("creates", User) @relation("creates", Credential)
@invariant("inputs_present", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.inputs_present\"}]}")
@invariant("unique_identity", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.unique_identity\"}]}")
@invariant("rejection_atomic", "{\"fact\":\"auth.rejection_atomic\"}")
op Register(): void;

@relation("verifies", Credential) @relation("creates", Session)
@invariant("inputs_present", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.inputs_present\"}]}")
@invariant("credential_binding", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.credential_binding\"}]}")
@invariant("current_credential", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.current_credential\"}]}")
@invariant("unique_identity", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.unique_identity\"}]}")
@invariant("exclusive_credential", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.exclusive_credential\"}]}")
@invariant("account_active", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.account_active\"}]}")
@invariant("identity_verified", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.identity_verified\"}]}")
@invariant("rejection_atomic", "{\"fact\":\"auth.rejection_atomic\"}")
op Login(): void;

@relation("writes", Session)
@invariant("inputs_present", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.inputs_present\"}]}")
@invariant("authority", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.authority\"}]}")
@invariant("account_active", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.account_active\"}]}")
@invariant("session_ownership", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.session_ownership\"}]}")
@invariant("rejection_atomic", "{\"fact\":\"auth.rejection_atomic\"}")
op Logout(): void;

@relation("writes", Credential)
@invariant("inputs_present", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.inputs_present\"}]}")
@invariant("authority", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.authority\"}]}")
@invariant("account_active", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.account_active\"}]}")
@invariant("old_credential_revoked", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.old_credential_revoked\"}]}")
@invariant("session_invalidation", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.session_invalidation\"}]}")
@invariant("rejection_atomic", "{\"fact\":\"auth.rejection_atomic\"}")
op ChangePassword(): void;

@relation("writes", Credential) @relation("consumes", ResetToken)
@invariant("inputs_present", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.inputs_present\"}]}")
@invariant("token_expiry", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.token_expiry\"}]}")
@invariant("token_single_use", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.token_single_use\"}]}")
@invariant("account_active", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.account_active\"}]}")
@invariant("identity_verified", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.identity_verified\"}]}")
@invariant("identity_current", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.identity_current\"}]}")
@invariant("old_credential_revoked", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.old_credential_revoked\"}]}")
@invariant("session_invalidation", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.session_invalidation\"}]}")
@invariant("rejection_atomic", "{\"fact\":\"auth.rejection_atomic\"}")
op ResetPassword(): void;

@relation("writes", User)
@invariant("inputs_present", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.inputs_present\"}]}")
@invariant("authority", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.authority\"}]}")
@invariant("unique_identity", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.unique_identity\"}]}")
@invariant("account_active", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.account_active\"}]}")
@invariant("rejection_atomic", "{\"fact\":\"auth.rejection_atomic\"}")
op ChangeEmail(): void;

@relation("writes", User)
@invariant("inputs_present", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.inputs_present\"}]}")
@invariant("authority", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.authority\"}]}")
@invariant("account_active", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.account_active\"}]}")
@invariant("identity_current", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.identity_current\"}]}")
@invariant("rejection_atomic", "{\"fact\":\"auth.rejection_atomic\"}")
op VerifyEmail(): void;

@relation("creates", Session)
@invariant("inputs_present", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.inputs_present\"}]}")
@invariant("authority", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.authority\"}]}")
@invariant("account_active", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.account_active\"}]}")
@invariant("identity_verified", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.identity_verified\"}]}")
@invariant("rejection_atomic", "{\"fact\":\"auth.rejection_atomic\"}")
op CreateSession(): void;

@relation("deletes", User)
@invariant("inputs_present", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.inputs_present\"}]}")
@invariant("authority", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.authority\"}]}")
@invariant("account_active", "{\"implies\":[{\"fact\":\"response.success\"},{\"fact\":\"auth.account_active\"}]}")
@invariant("rejection_atomic", "{\"fact\":\"auth.rejection_atomic\"}")
op DeleteUser(): void;
