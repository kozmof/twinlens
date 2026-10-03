import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import {
  createDocument,
  encodeDocument,
  subjectId,
  validateDocument,
} from "../packages/transport/src/index.js";
import { makeFixture, invalidCases } from "../scripts/fixture.mjs";

describe("versioned transport", () => {
  it("emits the reproducible committed seed fixture", () => {
    expect(encodeDocument(makeFixture())).toBe(readFileSync("fixtures/seed-v1.json", "utf8"));
  });
  it("preserves measured zero, unknown, unsupported, and missing observations", () => {
    const doc = makeFixture();
    expect(doc.observations.map((o) => o.measurement.status)).toEqual([
      "measured",
      "unknown",
      "unsupported",
    ]);
    expect(JSON.parse(encodeDocument(doc))).toEqual(doc);
    expect(doc.observations[0].measurement.value).toBe(0);
    expect(doc.observations.some((o) => o.metric === "function.lines")).toBe(false);
  });
  it("accepts an empty document", () => {
    expect(() => validateDocument(createDocument("r1"))).not.toThrow();
  });
  for (const [name, mutate] of invalidCases) {
    it(`rejects ${name}`, () => {
      const doc = makeFixture();
      mutate(doc);
      expect(() => validateDocument(doc)).toThrow();
    });
  }
  it.each([NaN, Infinity, -Infinity])("rejects nonfinite measurement %s", (value) => {
    const doc = makeFixture();
    doc.observations[0].measurement.value = value;
    expect(() => encodeDocument(doc)).toThrow();
  });
  it("rejects custom objects and accessors at the adapter boundary", () => {
    const doc = makeFixture();
    Object.defineProperty(doc.subjects[0].source, "producer", {
      get() {
        throw new Error("accessor executed");
      },
      enumerable: true,
    });
    expect(() => validateDocument(doc)).toThrow("expected data properties");
    expect(() => validateDocument(new Date())).toThrow("plain object");
  });
  it("rejects unpaired UTF-16 surrogates before UTF-8 transport", () => {
    const doc = makeFixture();
    doc.revision = "\ud800";
    expect(() => validateDocument(doc)).toThrow("UTF-8");
  });
});

describe("subject identity policy", () => {
  it("is repeatable and independent of spans, metrics, and revisions", () => {
    const first = makeFixture();
    const second = makeFixture();
    second.revision = "r2";
    second.subjects[0].source.span = { start: 100, end: 200 };
    expect(subjectId(first.subjects[0].key)).toBe(subjectId(second.subjects[0].key));
    expect(first.subjects[0].id).toBe(second.subjects[0].id);
  });
  it("distinguishes same-name declarations and scoped projects/languages", () => {
    const key = makeFixture().subjects[0].key;
    for (const field of ["project", "language", "path", "kind", "name", "discriminator"]) {
      expect(subjectId({ ...key, [field]: key[field] + "-other" })).not.toBe(subjectId(key));
    }
  });
  it("treats a rename as a new identity and recreation of the same key as the same identity", () => {
    const doc = makeFixture();
    const original = doc.subjects[0];
    doc.subjects.shift();
    expect(doc.subjects.some((s) => s.id === original.id)).toBe(false);
    expect(subjectId(original.key)).toBe(original.id);
    expect(subjectId({ ...original.key, name: "rescan" })).not.toBe(original.id);
  });
});
