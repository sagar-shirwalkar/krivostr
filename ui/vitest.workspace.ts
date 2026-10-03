import { defineWorkspace } from 'vitest/config';

/**
 * Vitest 2 has no `test.projects` option — that arrived in Vitest 3. On 2.1.x
 * multiple named test configurations live in a workspace file, which is what
 * makes the `--project unit` / `--project browser` scripts in package.json
 * resolve to something. With the old inline `projects` array, every script ran
 * zero test files and exited 1.
 *
 * `unit` runs under jsdom; `browser` runs the Lit component tests in a real
 * Chromium via Playwright.
 *
 * Coverage options deliberately live in `vitest.config.ts`, not here: in
 * workspace mode Vitest 2 reads coverage from the root config, and a
 * project-level block is silently ignored (no `include`, no `exclude`, and no
 * threshold failures).
 */
export default defineWorkspace([
  {
    test: {
      name: 'unit',
      environment: 'jsdom',
      globals: true,
      include: ['src/__tests__/*.test.ts'],
    },
  },
  {
    test: {
      name: 'browser',
      include: ['src/__tests__/components/*.test.ts'],
      browser: {
        enabled: true,
        headless: true,
        provider: 'playwright',
        // `browser.name` is the Vitest 2 spelling. The `browser.instances` array
        // is Vitest 3, and passing it here left `name` unset, which failed with
        // "Browser name is required".
        name: 'chromium',
      },
    },
  },
]);
