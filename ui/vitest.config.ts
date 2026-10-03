import { defineConfig } from 'vitest/config';

/**
 * Root config. The named test configurations live in `vitest.workspace.ts`;
 * this file only holds settings that apply to the whole workspace.
 *
 * Note: `test.projects` is a Vitest 3 feature and is rejected by the installed
 * Vitest 2.1.9.
 */
export default defineConfig({
  test: {
    // Reasonable defaults for anyone invoking `vitest` with no project filter.
    environment: 'jsdom',
    globals: true,
    coverage: {
      provider: 'v8',
      reporter: ['text', 'html', 'lcov'],
      // Measure the pure logic. Lit components are covered by the browser
      // project's own tests, which do not report into this summary.
      include: ['src/fp/**', 'src/nostr/**'],
      exclude: ['src/nostr/bridge.ts'],
      thresholds: {
        lines: 80,
        functions: 80,
        branches: 80,
        statements: 80,
      },
    },
  },
});
