# Phase 4: specifications and direct evaluation

TypeSpec declarations now lower through the compiler API into language-independent subjects, relations, claims, and constraints. Zig validates and evaluates these records. The frontend uses TypeSpec 1.16.0 and produces `typespec-sa/1` snapshots; no compiler AST crosses the transport boundary.

## Compile, inspect, and evaluate

```sh
pnpm build
./zig-out/bin/twinlens compile specs/twinlens.tsp --project twinlens --out specification.json
./zig-out/bin/twinlens scan tsconfig.json --language both --project twinlens --out snapshot.json
./zig-out/bin/twinlens inspect . snapshot.json --out evidence.json
./zig-out/bin/twinlens evaluate specification.json evidence.json --out evaluation.json
pnpm self:verify
```

Large project snapshots require a config such as `{"max_input_bytes":134217728}`, passed as `--config FILE` before each command. The self-verification script supplies this config. `typespec_adapter` optionally overrides `packages/typespec/dist/cli.js`. Output files are replaced atomically. A valid evaluation exits successfully even when its report contains violations or incomplete results; callers must inspect outcomes.

`compile` accepts a `.tsp` entry or a directory containing `main.tsp`. It invokes the compiler with emission disabled. Local project source bytes, compiler version, imported TypeSpec sources, and loaded decorator JavaScript contribute to revision identity. Sources must be UTF-8; spans are byte offsets, including a UTF-8 BOM. Compiler diagnostics remain in the snapshot. Any compiler error blocks evaluation with an unknown result.

## TypeSpec library

Import `@twinlens/typespec` from an installed workspace package, or use the relative library path shown in `specs/twinlens.tsp`, then `using Twinlens;`.

```typespec
@require("adult", "{\"ge\":[{\"fact\":\"age\"},18]}")
op register(age: int32): string;

@status("deferred", "Runtime heap verification is outside this phase")
model RuntimeStore {}
```

`@require`, `@ensure`, `@invariant`, `@forbid`, and `@policy` take a name and a JSON expression string. `@claim` additionally takes the claim kind. A forbidden claim is violated when its predicate is true; other specified claims are satisfied when true. Names `coverage` and `domain` are reserved for generated claims.

Models, properties, operations, parameters, scalars, enums, named unions, and interfaces retain source mappings. Operations produce `inputs` and `outputs`; properties produce containment and type relations. Builtin scalar/literal type references become explicit type subjects. Unsupported local or external targets remain unresolved with reasons. Annotations on namespace targets are rejected. Complex unions, interfaces, indexers, and instantiated model semantics are retained without claiming runtime interpretation.

`@relation(kind, target)` supports `inputs`, `outputs`, `reads`, `writes`, `creates`, `deletes`, `calls`, `requires`, `ensures`, `emits`, `authorizes`, `owns`, and `derived_from`. Events use `emits`; the Authority perspective uses `authorizes`. These are declared graph edges, not observations that an effect occurred. `@derived(backingOperation)` links an explicit predicate operation to its backing function.

`@semantics(mode, optionalDefinition)` declares a function's meaning. The default is `opaque`. Both opaque and uninterpreted calls remain unknown. Axiomatized functions evaluate their declared expression using `$0`, `$1`, etc. as argument facts. Executable, mocked, and observed modes are recorded but direct execution is unsupported. Domain functions such as `emailOf` must be declared; there is no built-in domain interpretation.

`@domain` takes JSON with optional `ownership` (`unknown`, `owned`, `shared`), `nullability` (`unknown`, `nullable`, `nonnull`), and up to 64 scalar `values`. Ownership checks the fact `<qualified-name>.ownership`; nonnull and finite values check `<qualified-name>`. Generated constraints govern explicit narrowing. Nullable permits null without requiring it. An annotation with no restrictions produces a true constraint. Absent annotations leave ownership and runtime nullability unknown, regardless of static type shape.

## Wire records and evaluation

`Specification` version 1 wraps a validated snapshot plus claims, constraints, functions, and domains. Claim IDs hash target, name, and kind; constraint IDs hash target and name using the shared length-prefixed identity encoding. Claims carry provenance, a reason, and one of `specified`, `unspecified`, `intentionally_unspecified`, `deferred`, `out_of_scope`, or `unknown`. Only specified claims reference an evaluable constraint. Unspecified declarations receive an explicit coverage claim.

Constraint expressions are arrays of nodes referencing only earlier nodes. The last node is the result. The transport `expression()` helper lowers JSON expressions into this representation. Supported expressions are scalar literals, `{fact:"name"}`, binary `eq`, `ne`, `lt`, `le`, `gt`, `ge`, `and`, `or`, `implies`, unary `not`, `{call:["function", ...arguments]}`, `{graph:"predicate"}`, and `{unsupported:"reason"}`. Operator arguments use arrays. Scalars have `kind` and a textual `value`; null uses an empty string, booleans use `true`/`false`, and numbers must be finite.

The frontend bounds expression nesting at 32 and expressions at 1024 nodes. The core enforces at most 1024 nodes, 64 call arguments, a function recursion limit of 16 nested calls, and a 10,000-node work budget per claim. Exhausted limits produce unknown. Equality respects scalar types, ordered comparison requires numbers, and boolean operators require booleans. There is no implicit conversion. Boolean dominance can settle an expression with missing operands, such as false AND unknown, but does not excuse a known operand of the wrong type.

Evaluation input version 1 contains a project, named facts, an optional IR graph, and graph coverage (`complete`, `partial`, `absent`). Facts have known/unknown/unsupported status, a value or reason, source provenance, and origin (code, specification, inference, test, trace). A missing fact remains unknown. Specifications and evidence must name the same project. Evaluation preserves each claim, its governing constraint, source evidence, fact names, and relevant graph record IDs.

Outcomes are `satisfied`, `violated`, `unknown`, and `unsupported`. Unknown denotes insufficient evidence or undeclared meaning; unsupported denotes semantics outside this evaluator. Non-specified claims remain unknown with their declared reason. An explicit constant constraint can be evaluated without facts. Complete empty graphs satisfy universal structural checks vacuously. Neither case implies that unobserved implementation behavior has been verified.

## Structural scope

The native inspector extracts `core.dependencies.valid` by parsing core Zig files and checking literal imports against the standard library and inventoried core modules. Nonliteral imports or syntax errors prevent a positive conclusion. A forbidden import supplies source-linked counterevidence.

`store.ast_free` checks the declared Store representation and compiled JSON-compatible IR. Positive results require the supported Store field shape and exact agreement with the compiled Store, IR, and index source files. A field type spelling containing `Ast` or `.Node`, or exactly `Node`, violates this conservative structural policy; these checks do not resolve aliases or distinguish unrelated types with matching names. Unrecognized representation changes yield unknown. This check covers declared representation, not allocator internals, runtime aliasing, or heap reachability.

The core's `identity`, `ownership`, and `references` predicates check the supplied finite graph: recomputed/unique record IDs, observation subject/revision ownership, and subject references including resolved/unresolved target consistency. Malformed identities and dangling references are accepted as evaluation evidence so they can yield violations. A counterexample in a partial graph is decisive; absence of counterexamples requires complete coverage to yield satisfaction. Coverage is the input producer's assertion about that finite inventory, not proof that all runtime behavior was observed.

`specs/twinlens.tsp` declares these five invariants and explicitly defers runtime heap verification. `pnpm self:verify` checks the real project, injects a forbidden import, AST field, and dangling observation in isolated fixtures, and verifies all five violations with governing constraints and evidence. Missing evidence yields unknown; a heap predicate yields unsupported. Artifacts remain under ignored `.twinlens/specification/`.

There is no solver, state exploration, runtime function execution, or general heap proof in this phase. See `tests/phase4-cli.test.ts` for direct-IR/TypeSpec equivalence, semantic modes, partial coverage, invalid annotations, provenance, and structural regressions.
