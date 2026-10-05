import "../packages/typespec/lib/main.tsp";
using Twinlens;

model ObservationStore {}

@relation("depends_on", ObservationStore)
op queryStore(): void;

@relation("writes", ObservationStore)
@invariant("refresh-equivalence", "{\"implies\":[{\"fact\":\"store.refreshed\"},{\"fact\":\"store.equivalent\"}]}")
@invariant("replacement-deletion", "{\"implies\":[{\"fact\":\"store.refreshed\"},{\"fact\":\"store.no_stale_files\"}]}")
@invariant("identity-continuity", "{\"fact\":\"store.identity_continuity\"}")
@invariant("stable-identities", "{\"graph\":\"identity\"}")
@invariant("observation-ownership", "{\"graph\":\"ownership\"}")
@invariant("valid-references", "{\"graph\":\"references\"}")
op refreshStore(): void;
