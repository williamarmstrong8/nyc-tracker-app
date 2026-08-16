#!/usr/bin/env node

// src/shared/cli/bin.ts
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import process from "node:process";
var PLATFORMS = {
  darwin: { arm64: ["darwin-arm64"], x64: ["darwin-x64"] },
  linux: {
    arm64: ["linux-arm64", "linux-arm64-musl"],
    x64: ["linux-x64", "linux-x64-musl"]
  },
  win32: { arm64: ["windows-arm64"], x64: ["windows-x64"] }
};
var platformMap = PLATFORMS[process.platform];
if (!platformMap)
  throw new Error(`Unsupported platform: ${process.platform}`);
var candidates = platformMap[os.arch()];
if (!candidates)
  throw new Error(`Unsupported architecture: ${os.arch()} on ${process.platform}`);
var ext = process.platform === "win32" ? ".exe" : "";
var require2 = createRequire(import.meta.url);
var binPath = process.env["SUPABASE_CLI_BINARY_OVERRIDE"];
if (!binPath) {
  for (const suffix of candidates) {
    try {
      const pkgPath = path.dirname(require2.resolve(`@supabase/cli-${suffix}/package.json`));
      binPath = path.join(pkgPath, "bin", `supabase${ext}`);
      break;
    } catch {}
  }
}
if (!binPath) {
  throw new Error(`No matching Supabase CLI binary package found for ${process.platform}-${os.arch()}`);
}
try {
  execFileSync(binPath, process.argv.slice(2), { stdio: "inherit" });
} catch (e) {
  if (e && typeof e === "object" && "status" in e && typeof e.status === "number")
    process.exit(e.status);
  throw e;
}
