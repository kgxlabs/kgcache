'use strict';

module.exports = {
  testEnvironment: 'node',
  roots: ['<rootDir>/tests', '<rootDir>/../../harness'],
  testMatch: [
    '<rootDir>/tests/**/*.test.js',
    '<rootDir>/../../harness/**/*.test.cjs',
  ],
  fakeTimers: { enableGlobally: false },
  testTimeout: 45000,
  clearMocks: true,
};
