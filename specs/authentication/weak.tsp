import "../../packages/typespec/lib/main.tsp";
using Twinlens;

// Synthetic authentication policy model; secrets are uninterpreted fixture labels.
@perspective("identity") model User {}
@perspective("owned") @perspective("credential") model Credential {}
@perspective("owned") model Session {}
@perspective("resource") model ResetToken {}

@relation("creates", User) @relation("creates", Credential)
@status("unspecified", "Authentication policy has not been supplied")
op Register(): void;

@relation("verifies", Credential) @relation("creates", Session)
@status("unspecified", "Authentication policy has not been supplied")
op Login(): void;

@relation("writes", Session)
@status("unspecified", "Authentication policy has not been supplied")
op Logout(): void;

@relation("writes", Credential)
@status("unspecified", "Authentication policy has not been supplied")
op ChangePassword(): void;

@relation("writes", Credential) @relation("consumes", ResetToken)
@status("unspecified", "Authentication policy has not been supplied")
op ResetPassword(): void;

@relation("writes", User)
@status("unspecified", "Authentication policy has not been supplied")
op ChangeEmail(): void;

@relation("writes", User)
@status("unspecified", "Authentication policy has not been supplied")
op VerifyEmail(): void;

@relation("creates", Session)
@status("unspecified", "Authentication policy has not been supplied")
op CreateSession(): void;

@relation("deletes", User)
@status("unspecified", "Authentication policy has not been supplied")
op DeleteUser(): void;
