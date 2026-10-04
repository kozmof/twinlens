import { createDocument, type Document } from "@twinlens/transport";

/** Create an empty IR document for transport fixtures; performs no compilation. */
export function createSpecificationDocument(revision: string): Document {
  return createDocument(revision);
}

export { compileSpecification } from "./compiler.js";
