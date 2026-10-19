'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const {
  checkWarnings,
  compareBaselineChange,
  extractWarnings,
  validateBaseline,
  warningId,
} = require('./solidity-warning-gate');

const TODAY = '2026-10-17';

function diagnostic(overrides = {}) {
  const value = {
    severity: 'warning',
    code: '8760',
    source: 'contracts/Example.sol',
    line: 2,
    column: 3,
    compiler: '0.8.28+commit.7893614a',
    message: 'This is a compiler warning.',
    ...overrides,
  };
  return { id: warningId(value), ...value };
}

function exception(warning, overrides = {}) {
  return {
    ...warning,
    rationale: 'Retained for backwards compatibility until the next contract revision.',
    owner: 'protocol-maintainers',
    expires: '2027-10-17',
    ...overrides,
  };
}

function baseline(warnings = []) {
  return { version: 1, warnings: [...warnings].sort((left, right) => left.id.localeCompare(right.id)) };
}

test('accepts a known warning only with a valid owned, unexpired exception', () => {
  const known = diagnostic();
  assert.deepEqual(checkWarnings([known], baseline([exception(known)]), TODAY), []);
});

test('fails on a newly observed compiler warning', () => {
  const newWarning = diagnostic();
  assert.deepEqual(checkWarnings([newWarning], baseline(), TODAY), [newWarning]);
});

test('a removed warning no longer needs an exception and baseline shrink is allowed', () => {
  const removed = diagnostic();
  const oldBaseline = baseline([exception(removed)]);
  assert.deepEqual(checkWarnings([], oldBaseline, TODAY), []);
  assert.deepEqual(compareBaselineChange(oldBaseline.warnings, [], false).removals, [removed.id]);
});

test('rejects expired exceptions even when their warning is no longer emitted', () => {
  const warning = diagnostic();
  const expired = exception(warning, { expires: TODAY });
  assert.throws(() => checkWarnings([], baseline([expired]), TODAY), /exception expired/);
});

test('compiler warnings from generated and production Solidity sources are both included', () => {
  const buildInfo = {
    solcLongVersion: '0.8.28+commit.7893614a',
    input: {
      sources: {
        'contracts/Production.sol': { content: 'contract Production {\n uint value;\n}' },
        'typechain-types/Generated.sol': { content: 'contract Generated {\n uint value;\n}' },
      },
    },
    output: {
      errors: [
        { severity: 'warning', errorCode: 8760, message: '  warning   text\n', sourceLocation: { file: 'contracts/Production.sol', start: 21 } },
        { severity: 'warning', errorCode: 8760, message: 'warning text', sourceLocation: { file: 'typechain-types/Generated.sol', start: 20 } },
      ],
    },
  };
  const warnings = extractWarnings([buildInfo]);
  assert.equal(warnings.length, 2);
  assert.deepEqual(new Set(warnings.map((warning) => warning.source)), new Set(['contracts/Production.sol', 'typechain-types/Generated.sol']));
  assert.ok(warnings.every((warning) => warning.message === 'warning text'));
});

test('passes a clean compiler build with an empty baseline', () => {
  assert.deepEqual(extractWarnings([{ input: { sources: {} }, output: { errors: [] } }]), []);
  assert.deepEqual(checkWarnings([], baseline(), TODAY), []);
});

test('requires explicit review for additions and modifications, but not removals', () => {
  const warning = diagnostic();
  const entry = exception(warning);
  assert.throws(() => compareBaselineChange([], [entry], false), /require the 'solidity-warning-baseline-reviewed' PR label/);
  assert.deepEqual(compareBaselineChange([], [entry], true).additions, [warning.id]);
  const modified = exception(warning, { owner: 'another-maintainer' });
  assert.throws(() => compareBaselineChange([entry], [modified], false), /require the 'solidity-warning-baseline-reviewed' PR label/);
  assert.equal(compareBaselineChange([entry], [modified], true).modifications.length, 1);
  assert.deepEqual(compareBaselineChange([entry], [], false).removals, [warning.id]);
});

test('rejects malformed or unowned baseline entries', () => {
  const warning = diagnostic();
  assert.throws(() => validateBaseline(baseline([exception(warning, { owner: ' ' })]), TODAY), /owner must be a non-empty string/);
  assert.throws(() => validateBaseline(baseline([exception(warning, { id: 'not-a-fingerprint' })]), TODAY), /fingerprint does not match/);
});
