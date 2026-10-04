import { compileSpecification } from "./compiler.js";
try {
  const args = process.argv.slice(2);
  const path = args.shift();
  if (!path) throw Error("Expected TypeSpec input");
  const options: { project?: string; revision?: string } = {};
  while (args.length) {
    const flag = args.shift(),
      value = args.shift();
    if (!value) throw Error("Missing option value");
    if (flag === "--project" && options.project === undefined) options.project = value;
    else if (flag === "--revision" && options.revision === undefined) options.revision = value;
    else throw Error("Invalid option");
  }
  process.stdout.write(JSON.stringify(await compileSpecification(path, options)));
} catch (error) {
  process.stderr.write(
    JSON.stringify({
      code: "TypeSpecAdapterFailed",
      message: error instanceof Error ? error.message : String(error),
    }) + "\n",
  );
  process.exitCode = 4;
}
