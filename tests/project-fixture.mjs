import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

export function makeProject() {
  const root = mkdtempSync(join(tmpdir(), "twinlens-project-"));
  writeFileSync(
    join(root, "tsconfig.json"),
    JSON.stringify({
      compilerOptions: { target: "ES2024", module: "NodeNext", strict: true, types: [] },
      include: ["*.ts"],
    }),
  );
  writeFileSync(
    join(root, "lib.ts"),
    `export function target(value: number): number;
export function target(value: string): string;
export function target(value: number | string) { return value; }
export const arrow = (x: number) => x + 1;
`,
  );
  writeFileSync(
    join(root, "main.ts"),
    `import { target, arrow } from './lib.js';
interface Options { enabled: boolean; count: number; }
// café makes compiler UTF-16 offsets differ from wire UTF-8 offsets.
export function scan(options: Options, callback: (n: number) => number) {
  let value = 0;
  value += 1;
  ++value;
  if (options.enabled) options.count = value;
  const nested = () => { if (value > 0) return target(value); return 0; };
  const shadow = () => { let value = 1; return value; };
  options.count++;
  const picked = options['count'];
  const result = target(value);
  arrow(value); arrow(value);
  callback(value);
  return nested() + shadow() + picked + result;
}
export class Counter {
  value = 0;
  constructor(start: number) { this.value = start; }
  method(x: number) { this.value += x; return this.value; }
}
const counter = new Counter(1);
counter.method(2);
export function dynamic(obj: any, key: string) { obj[key] = 1; return obj[key]; }
`,
  );
  return root;
}
