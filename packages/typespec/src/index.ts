import { createDocument, type Document } from "@twinlens/transport";

/** Transport entry point for future TypeSpec lowering; performs no compilation. */
export function createSpecificationDocument(revision: string): Document {
  return createDocument(revision);
}
