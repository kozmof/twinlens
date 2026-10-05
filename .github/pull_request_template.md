Describe the problem, resulting behavior, and relevant verification.

- [ ] Required checks pass.
- [ ] Analysis changes document scope and unknown/unsupported behavior.
- [ ] Substantial capabilities have a named self-application target and source-linked evidence.
- [ ] Any self-analysis hypothesis/change includes a before/after comparison or a documented decision not to change the code.
- [ ] The development checklist in `docs/development.md` is complete where applicable.
- [ ] Specification changes pass `pnpm self:verify`, including negative and incomplete-evidence cases.
- [ ] History/exploration changes pass `pnpm self:explore`, retain replayable counterexamples, and report bounds.
- [ ] Solver/cross-lens changes pass `pnpm self:cross`, preserve provenance and reviews, and distinguish modeled witnesses from observed violations.
- [ ] Authentication model changes pass `pnpm self:auth`, replay weak/corrected histories, and keep policy choices and simulation scope explicit.
