import type { Config } from 'jest';
import { createDefaultEsmPreset } from 'ts-jest';

export default {
  ...createDefaultEsmPreset({ tsconfig: '<rootDir>/tsconfig.json' }),
  testEnvironment: 'node',
  roots: ['<rootDir>/tests', '<rootDir>/../../harness'],
  testMatch: ['<rootDir>/tests/**/*.test.ts', '<rootDir>/../../harness/**/*.test.ts'],
  fakeTimers: { enableGlobally: false },
  testTimeout: 45000,
  clearMocks: true,
  moduleNameMapper: { '^(\\.{1,2}/.*)\\.ts$': '$1' },
} satisfies Config;
