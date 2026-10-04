import { defineConfig } from "vitest/config";
// Compiler-backed suites spawn additional processes; bound resource contention.
export default defineConfig({ test: { include: ["tests/**/*.test.ts"], maxWorkers: 2 } });
