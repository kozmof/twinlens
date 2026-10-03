import { createDocument, type Document } from "@twinlens/transport";

/** Transport entry point for the future compiler adapter; performs no source scan. */
export function createObservationDocument(revision: string): Document {
  return createDocument(revision);
}

export { scanProject } from "./scanner.js";
export type { ScanOptions } from "./scanner.js";
