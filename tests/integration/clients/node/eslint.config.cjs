'use strict';

const js = require('@eslint/js');
const globals = require('globals');

module.exports = [
  { ignores: ['**/node_modules/**', '**/coverage/**', '**/.workspaces/**'] },
  {
    files: ['**/*.js', '**/*.cjs'],
    rules: {
      ...js.configs.recommended.rules,
      eqeqeq: 'error',
      'prefer-const': 'error',
    },
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'commonjs',
      globals: globals.node,
    },
  },
  {
    files: ['**/*.test.js', '**/*.test.cjs'],
    languageOptions: { globals: globals.jest },
  },
];
