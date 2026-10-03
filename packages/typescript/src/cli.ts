import { scanProject } from "./scanner.js";
import { encodeSnapshot } from "@twinlens/transport";

try {
  const [input, ...args] = process.argv.slice(2);
  if (!input || args.length % 2)
    throw new Error("Usage: node cli.js TSCONFIG [--project NAME] [--revision ID]");
  const options: { project?: string; revision?: string } = {};
  for (let i = 0; i < args.length; i += 2) {
    const key =
      args[i] === "--project" ? "project" : args[i] === "--revision" ? "revision" : undefined;
    if (!key || options[key] !== undefined || !args[i + 1])
      throw new Error("Invalid scan arguments");
    options[key] = args[i + 1]!;
  }
  process.stdout.write(encodeSnapshot(scanProject(input, options)));
} catch (error) {
  process.stderr.write(
    JSON.stringify({
      code: "TypeScriptAdapterError",
      message: error instanceof Error ? error.message : String(error),
      path: process.argv[2] ?? null,
    }) + "\n",
  );
  process.exitCode = 4;
}
