import { mkdirSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";

/** Finite source catalog. Source extraction uses the production Zig scanner. */
export function createExplorationFixture(
  directory,
  cli,
  specification,
  project = "twinlens-history",
) {
  mkdirSync(directory, { recursive: true });
  const sourceWorlds = [
    { name: "empty", files: {} },
    { name: "original", files: { "value.zig": "pub fn value() u32 { return 1; }\n" } },
    {
      name: "modified",
      files: { "value.zig": "pub fn value() u32 { if (true) return 2; return 3; }\n" },
    },
    {
      name: "with-caller",
      files: {
        "value.zig": "pub fn value() u32 { return 1; }\n",
        "caller.zig":
          'const values = @import("value.zig");\npub fn invoke() u32 { return values.value(); }\n',
      },
    },
    { name: "renamed", files: { "value.zig": "pub fn replacement() u32 { return 4; }\n" } },
    {
      name: "caller-only",
      files: {
        "caller.zig":
          'const values = @import("value.zig");\npub fn invoke() u32 { return values.value(); }\n',
      },
    },
  ];
  const worlds = sourceWorlds.map((world) => {
    for (const filename of ["value.zig", "caller.zig"])
      rmSync(join(directory, filename), { force: true });
    for (const [filename, contents] of Object.entries(world.files))
      writeFileSync(join(directory, filename), contents);
    return {
      name: world.name,
      snapshot: cli("scan", directory, "--language", "zig", "--project", project),
    };
  });
  const operation = specification.snapshot.document.subjects.find(
    (subject) => subject.key.name === "refreshStore",
  ).id;
  return {
    exploration_version: 1,
    specification,
    operation,
    worlds,
    initial_states: [0, 1],
    bounds: { max_depth: 8, max_objects: 2, max_executions: 500, max_time_ms: 60000 },
    adapter: "native_store",
  };
}
