import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    projects: [
      {
        test: {
          name: 'unit',
          environment: 'jsdom',
          globals: true,
          include: ['src/__tests__/*.test.ts'],
          coverage: {
            provider: 'v8',
            reporter: ['text', 'html', 'lcov'],
            include: ['src/fp/**', 'src/nostr/**'],
            exclude: ['src/nostr/bridge.ts', 'src/nostr/relay.ts'],
            thresholds: {
              lines: 80, functions: 80, branches: 80, statements: 80,
            },
          },
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
            instances: [{ browser: 'chromium' }],
          },
        },
      },
    ],
  },
});
