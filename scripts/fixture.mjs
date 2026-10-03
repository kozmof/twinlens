import {
  createDocument,
  subjectId,
  symbolId,
  observationId,
  relationId,
} from "../packages/transport/dist/index.js";

/** Deliberately synthetic transport fixture, not a source-analysis result. */
export function makeFixture() {
  const doc = createDocument("fixture-r1");
  for (const [path, start] of [
    ["src/scanner.ts", 0],
    ["src/café.ts", 100],
  ]) {
    const key = {
      project: "twinlens-seed",
      language: "typescript",
      path,
      kind: "function",
      name: "scan",
      discriminator: "declaration:0",
    };
    const source = {
      path,
      language: "typescript",
      span: { start, end: start + 80 },
      producer: "seed-fixture/1",
      confidence: "high",
    };
    const id = subjectId(key);
    doc.subjects.push({ id, key, source });
    doc.symbols.push({ id: symbolId(id), subject: id, name: key.name });
  }
  const [caller, callee] = doc.subjects;
  for (const [metric, measurement] of [
    ["function.args.count", { status: "measured", value: 0, reason: null }],
    ["function.branch.count", { status: "unknown", value: null, reason: "body not observed" }],
    ["value.write_count", { status: "unsupported", value: null, reason: "sensor not implemented" }],
  ]) {
    const observation = {
      subject: caller.id,
      metric,
      measurement,
      source: caller.source,
      revision: doc.revision,
    };
    doc.observations.push({ id: observationId(observation), ...observation });
  }
  for (const target of [
    { status: "resolved", subject: callee.id, reason: null },
    { status: "unresolved", subject: null, reason: "dynamic call target" },
  ]) {
    const relation = {
      from: caller.id,
      kind: "calls",
      target,
      source: caller.source,
      revision: doc.revision,
    };
    doc.relations.push({ id: relationId(relation), ...relation });
  }
  return doc;
}

export const invalidCases = [
  [
    "unsupported version",
    (doc) => {
      doc.schema_version = 2;
    },
  ],
  [
    "missing collection",
    (doc) => {
      delete doc.symbols;
    },
  ],
  [
    "top-level AST",
    (doc) => {
      doc.ast = {};
    },
  ],
  [
    "nested AST",
    (doc) => {
      doc.subjects[0].source.ast = {};
    },
  ],
  [
    "duplicate subject",
    (doc) => {
      doc.subjects.push(doc.subjects[0]);
    },
  ],
  [
    "duplicate observation",
    (doc) => {
      doc.observations.push(doc.observations[0]);
    },
  ],
  [
    "duplicate symbol",
    (doc) => {
      doc.symbols.push(doc.symbols[0]);
    },
  ],
  [
    "duplicate relation",
    (doc) => {
      doc.relations.push(doc.relations[0]);
    },
  ],
  [
    "forged identity",
    (doc) => {
      doc.subjects[0].key.name = "renamed";
    },
  ],
  [
    "wrong ID prefix",
    (doc) => {
      doc.subjects[0].id = doc.subjects[0].id.replace("sub_", "sym_");
    },
  ],
  [
    "dangling symbol",
    (doc) => {
      doc.symbols[0].subject = "sub_" + "f".repeat(64);
    },
  ],
  [
    "dangling observation",
    (doc) => {
      doc.observations[0].subject = "sub_" + "f".repeat(64);
    },
  ],
  [
    "dangling relation source",
    (doc) => {
      doc.relations[0].from = "sub_" + "f".repeat(64);
    },
  ],
  [
    "dangling relation target",
    (doc) => {
      doc.relations[0].target.subject = "sub_" + "f".repeat(64);
    },
  ],
  [
    "unresolved with subject",
    (doc) => {
      doc.relations[1].target.subject = doc.subjects[0].id;
    },
  ],
  [
    "resolved with reason",
    (doc) => {
      doc.relations[0].target.reason = "unexpected";
    },
  ],
  [
    "unresolved without reason",
    (doc) => {
      doc.relations[1].target.reason = null;
    },
  ],
  [
    "empty metric",
    (doc) => {
      doc.observations[0].metric = "";
    },
  ],
  [
    "revision mismatch",
    (doc) => {
      doc.observations[0].revision = "r2";
    },
  ],
  [
    "relation revision mismatch",
    (doc) => {
      doc.relations[0].revision = "r2";
    },
  ],
  [
    "unknown with value",
    (doc) => {
      doc.observations[1].measurement.value = 0;
    },
  ],
  [
    "measured without value",
    (doc) => {
      doc.observations[0].measurement.value = null;
    },
  ],
  [
    "measured with reason",
    (doc) => {
      doc.observations[0].measurement.reason = "unexpected";
    },
  ],
  [
    "missing nullable field",
    (doc) => {
      delete doc.observations[0].measurement.reason;
    },
  ],
  [
    "unknown state",
    (doc) => {
      doc.observations[0].measurement.status = "missing";
    },
  ],
  [
    "numeric string measurement",
    (doc) => {
      doc.observations[0].measurement.value = "0";
    },
  ],
  [
    "numeric string span",
    (doc) => {
      doc.subjects[0].source.span.start = "0";
    },
  ],
  [
    "negative span",
    (doc) => {
      doc.subjects[0].source.span.start = -1;
    },
  ],
  [
    "fractional span",
    (doc) => {
      doc.subjects[0].source.span.start = 0.5;
    },
  ],
  [
    "reversed span",
    (doc) => {
      doc.subjects[0].source.span.start = 99;
    },
  ],
  [
    "source mismatch",
    (doc) => {
      doc.subjects[0].source.path = "other.ts";
    },
  ],
  [
    "parent traversal",
    (doc) => {
      doc.subjects[0].key.path = "../a.ts";
    },
  ],
  [
    "unknown confidence",
    (doc) => {
      doc.subjects[0].source.confidence = "certain";
    },
  ],
];
