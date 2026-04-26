import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    coverage: {
      provider: "v8",
      reporter: ["text", "html", "lcov"],
      reportsDirectory: "coverage",
      all: true,
      include: ["**/src/**/*.ts"],
      // NOTE: vitest uses picomatch with `contains: true` for these globs.
      // Patterns like `tests/**` would match anywhere in the absolute path,
      // including the worktree directory name (`infinite-recall-fix-tests`),
      // which would silently exclude every source file. Anchor each pattern
      // with `**/.../**` so it only matches actual directory segments.
      exclude: [
        "**/node_modules/**",
        "**/dist/**",
        "**/tests/**",
        "**/*.test.ts",
        "**/*.config.*",
        "**/patched-acp-entry.mjs",
      ],
    },
  },
});
