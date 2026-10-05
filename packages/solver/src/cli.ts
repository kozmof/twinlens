import { solve } from "./index.js";
import type { SolverPacket, SolverBackendResult } from "@twinlens/transport";
let emitted = false;
function emit(result: SolverBackendResult) {
  if (emitted) return;
  emitted = true;
  process.stdout.write(JSON.stringify(result), () => process.exit(0));
}
try {
  const packet: SolverPacket = JSON.parse(process.argv[2] ?? "null");
  if (
    !packet ||
    packet.backend_version !== 1 ||
    typeof packet.smt !== "string" ||
    packet.smt.length > 32768 ||
    !Number.isInteger(packet.bounds?.timeout_ms) ||
    packet.bounds.timeout_ms < 1 ||
    packet.bounds.timeout_ms > 30000
  )
    throw Error("Invalid core solver packet");
  const watchdog = setTimeout(
    () =>
      emit({
        backend_version: 1,
        backend: "z3-adapter/1",
        status: "timeout",
        reason: "Adapter startup/execution watchdog expired",
        model: null,
        bindings: [],
      }),
    packet.bounds.timeout_ms + 10000,
  );
  const result = await solve(packet);
  clearTimeout(watchdog);
  emit(result);
} catch (error) {
  emit({
    backend_version: 1,
    backend: "z3-adapter/1",
    status: "unsupported",
    reason: error instanceof Error ? error.message : String(error),
    model: null,
    bindings: [],
  });
}
