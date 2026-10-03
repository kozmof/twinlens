import { writeFileSync } from "node:fs";
import { encodeDocument } from "../packages/transport/dist/index.js";
import { makeFixture } from "./fixture.mjs";
writeFileSync(new URL("../fixtures/seed-v1.json", import.meta.url), encodeDocument(makeFixture()));
