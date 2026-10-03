import { globSync, readFileSync, writeFileSync } from "node:fs";
import { format } from "oxfmt";

// In-process formatting avoids worker process limits and restricted process metrics.
const { ignorePatterns, ...options } = JSON.parse(readFileSync(".oxfmtrc.json", "utf8"));
const check = process.argv.includes("--check");
const files = [
  ...new Set(
    globSync(["**/*.{ts,mjs,json,yaml,yml,md}", ".github/**/*.yml", ".oxfmtrc.json"], {
      exclude: [...ignorePatterns, ".git/**", ".pnpm-data/**"],
    }),
  ),
].sort();
let failed = false;
for (const file of files) {
  const input = readFileSync(file, "utf8");
  const result = await format(file, input, options);
  if (result.errors.length) {
    console.error(file, result.errors);
    failed = true;
  } else if (result.code !== input) {
    if (check) {
      console.error(`Formatting differs: ${file}`);
      failed = true;
    } else writeFileSync(file, result.code);
  }
}
console.log(`${check ? "Checked" : "Formatted"} ${files.length} files.`);
if (failed) process.exitCode = 1;
