# Development checklist

Each substantial new analysis capability must be applied to Twinlens before its phase is marked complete.

- Define the measurement/relationship meaning, source scope, approximation boundary, and unknown/unsupported behavior.
- Add focused fixtures for supported behavior and uncertainty; verify the shared IR/core boundary.
- Run `TMPDIR=/tmp pnpm check` (the temp override is only needed in restricted environments).
- Run the relevant self-application gates: `pnpm self:observe`, `pnpm self:observe:all`, and `pnpm self:analyze` when relationships, evidence, findings, or significance are affected.
- Run `pnpm self:verify` for specification, evaluator, or structural-inspector changes. Check selected invariants, deliberate violations, missing evidence, and unsupported semantics.
- Inspect source-linked evidence on a named Twinlens subsystem. Use the scanner for argument telemetry, IR processing for property telemetry, query/analysis for branches, normalization for dataflow, and sensor architecture for caller significance.
- Record a hypothesis with its supporting observations/relations and known gaps. Do not infer a defect from a count alone.
- Test a justified implementation/model change or document why the hypothesis should not prompt a change. Preserve any review decision rather than silently clearing it.
- Compare before/after evidence under the same project and scope. Distinguish moved logic from reduced logic, and absent evidence from a fixed finding.
- Summarize the result, limitations, reproduction command, and artifact paths in tracked documentation. Keep generated snapshots local; mark checklist tasks complete only after their gates pass.

For Phase 3's concrete example, see [relationships and findings](phase3.md) and [self-observation milestones](self-observation.md).
