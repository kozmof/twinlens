import "../packages/typespec/lib/main.tsp";
using Twinlens;

/** Core imports must remain inside the semantic core or the standard library. */
@invariant("adapter-core-boundary", "{\"fact\":\"core.dependencies.valid\"}")
model CoreBoundary {}

/** Store domain records are JSON-shaped IR, not compiler AST objects. */
@invariant("ast-free-store", "{\"fact\":\"store.ast_free\"}")
model ObservationStore {}

@invariant("stable-identities", "{\"graph\":\"identity\"}")
model SymbolIdentity {}

@invariant("observation-ownership", "{\"graph\":\"ownership\"}")
model ObservationOwnership {}

@invariant("valid-references", "{\"graph\":\"references\"}")
model StoreReferences {}

/** No runtime proof is supplied for these future capabilities. */
@status("deferred", "Runtime alias and heap verification is outside Phase 4")
model RuntimeStore {}
