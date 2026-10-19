#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const BASELINE_PATH = 'solidity-warning-baseline.json';
const BUILD_INFO_DIR = path.join('artifacts', 'build-info');
const BASELINE_FIELDS = ['id', 'severity', 'code', 'source', 'line', 'column', 'compiler', 'message', 'rationale', 'owner', 'expires'];
const DIAGNOSTIC_FIELDS = ['severity', 'code', 'source', 'line', 'column', 'compiler', 'message'];

function normalizeSource(source) {
  if (typeof source !== 'string' || source.trim() === '') return '<unknown>';
  return path.posix.normalize(source.replaceAll('\\', '/').replace(/^\.\//, ''));
}

function normalizeMessage(message) {
  return String(message ?? '').replace(/\s+/g, ' ').trim();
}

function positionAt(sourceText, byteOffset) {
  if (!Number.isInteger(byteOffset) || byteOffset < 0 || typeof sourceText !== 'string') {
    return { line: null, column: null };
  }
  const bytes = Buffer.from(sourceText, 'utf8');
  if (byteOffset > bytes.length) return { line: null, column: null };
  const before = bytes.subarray(0, byteOffset).toString('utf8');
  const lastNewline = before.lastIndexOf('\n');
  return {
    line: before.split('\n').length,
    column: Buffer.byteLength(before.slice(lastNewline + 1), 'utf8') + 1,
  };
}

function diagnosticFromCompilerError(error, sourceText, compiler) {
  const location = error.sourceLocation || {};
  const position = positionAt(sourceText, location.start);
  return {
    severity: error.severity,
    code: error.errorCode == null ? null : String(error.errorCode),
    source: normalizeSource(location.file),
    line: position.line,
    column: position.column,
    compiler: String(compiler || 'unknown'),
    message: normalizeMessage(error.message || error.formattedMessage),
  };
}

function warningId(diagnostic) {
  const identity = {};
  for (const field of DIAGNOSTIC_FIELDS) identity[field] = diagnostic[field];
  return crypto.createHash('sha256').update(JSON.stringify(identity)).digest('hex');
}

function extractWarnings(buildInfos) {
  const warnings = new Map();
  for (const buildInfo of buildInfos) {
    const compiler = buildInfo.solcLongVersion || buildInfo.solcVersion || 'unknown';
    const sources = buildInfo.input?.sources || {};
    for (const error of buildInfo.output?.errors || []) {
      if (error.severity !== 'warning') continue;
      const sourceText = sources[error.sourceLocation?.file]?.content;
      const diagnostic = diagnosticFromCompilerError(error, sourceText, compiler);
      const id = warningId(diagnostic);
      warnings.set(id, { id, ...diagnostic });
    }
  }
  return [...warnings.values()].sort((a, b) => a.id.localeCompare(b.id));
}

function validateBaseline(document, today = new Date().toISOString().slice(0, 10)) {
  if (!document || document.version !== 1 || !Array.isArray(document.warnings)) {
    throw new Error('baseline must be a version 1 object with a warnings array');
  }
  const seen = new Set();
  for (const entry of document.warnings) {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) throw new Error('baseline entries must be objects');
    const keys = Object.keys(entry).sort();
    if (JSON.stringify(keys) !== JSON.stringify([...BASELINE_FIELDS].sort())) {
      throw new Error(`baseline entry must contain exactly: ${BASELINE_FIELDS.join(', ')}`);
    }
    if (entry.severity !== 'warning') throw new Error(`${entry.id}: only compiler warnings may be baselined`);
    if (entry.code !== null && typeof entry.code !== 'string') throw new Error(`${entry.id}: code must be a string or null`);
    if (typeof entry.source !== 'string' || entry.source !== normalizeSource(entry.source)) throw new Error(`${entry.id}: source path is not normalized`);
    for (const field of ['line', 'column']) {
      if (entry[field] !== null && (!Number.isInteger(entry[field]) || entry[field] < 1)) throw new Error(`${entry.id}: ${field} must be a positive integer or null`);
    }
    for (const field of ['compiler', 'message', 'rationale', 'owner']) {
      if (typeof entry[field] !== 'string' || entry[field].trim() === '') throw new Error(`${entry.id}: ${field} must be a non-empty string`);
    }
    if (entry.message !== normalizeMessage(entry.message)) throw new Error(`${entry.id}: message is not whitespace-normalized`);
    if (typeof entry.expires !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(entry.expires) || new Date(`${entry.expires}T00:00:00Z`).toISOString().slice(0, 10) !== entry.expires) {
      throw new Error(`${entry.id}: expires must be a valid YYYY-MM-DD date`);
    }
    if (entry.expires <= today) throw new Error(`${entry.id}: exception expired on ${entry.expires}`);
    if (warningId(entry) !== entry.id) throw new Error(`${entry.id}: warning fingerprint does not match its diagnostic fields`);
    if (seen.has(entry.id)) throw new Error(`${entry.id}: duplicate baseline entry`);
    seen.add(entry.id);
  }
  const sorted = [...document.warnings].sort((a, b) => a.id.localeCompare(b.id));
  if (JSON.stringify(sorted) !== JSON.stringify(document.warnings)) throw new Error('baseline warnings must be sorted by id');
  return document.warnings;
}

function compareBaselineChange(previous, current, reviewApproved) {
  const previousById = new Map(previous.map((entry) => [entry.id, entry]));
  const currentById = new Map(current.map((entry) => [entry.id, entry]));
  const additions = [];
  const modifications = [];
  for (const [id, entry] of currentById) {
    const oldEntry = previousById.get(id);
    if (!oldEntry) additions.push(id);
    else if (BASELINE_FIELDS.some((field) => oldEntry[field] !== entry[field])) modifications.push(id);
  }
  if ((additions.length || modifications.length) && !reviewApproved) {
    const details = [];
    if (additions.length) details.push(`added: ${additions.join(', ')}`);
    if (modifications.length) details.push(`modified: ${modifications.join(', ')}`);
    throw new Error(`baseline additions/modifications require the '${'solidity-warning-baseline-reviewed'}' PR label (${details.join('; ')})`);
  }
  return { additions, modifications, removals: [...previousById.keys()].filter((id) => !currentById.has(id)) };
}

function readBuildInfos(directory = BUILD_INFO_DIR) {
  if (!fs.existsSync(directory)) throw new Error(`no compiler build-info directory found: ${directory}`);
  const files = fs.readdirSync(directory).filter((file) => file.endsWith('.json')).sort();
  if (files.length === 0) throw new Error(`no compiler build-info JSON files found in ${directory}`);
  return files.map((file) => JSON.parse(fs.readFileSync(path.join(directory, file), 'utf8')));
}

function readBaseline(file = BASELINE_PATH) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function baselineFromGit(ref) {
  try {
    execFileSync('git', ['rev-parse', '--verify', '--quiet', ref], { stdio: 'ignore' });
  } catch (error) {
    throw new Error(`could not resolve base ref '${ref}': ${error.message}`);
  }
  try {
    return JSON.parse(execFileSync('git', ['show', `${ref}:${BASELINE_PATH}`], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }));
  } catch (error) {
    try {
      execFileSync('git', ['cat-file', '-e', `${ref}:${BASELINE_PATH}`], { stdio: 'ignore' });
    } catch {
      return { version: 1, warnings: [] };
    }
    throw new Error(`could not read ${BASELINE_PATH} from base ref '${ref}': ${error.message}`);
  }
}

function checkWarnings(observed, baseline, today) {
  const accepted = validateBaseline(baseline, today);
  const acceptedIds = new Set(accepted.map((entry) => entry.id));
  return observed.filter((warning) => !acceptedIds.has(warning.id));
}

function parseArgs(argv) {
  const options = { command: argv[0] || 'check', baseRef: '', reviewApproved: false };
  for (let index = 1; index < argv.length; index += 1) {
    if (argv[index] === '--base-ref') options.baseRef = argv[++index] || '';
    else if (argv[index] === '--review-approved') options.reviewApproved = argv[++index] === 'true';
    else throw new Error(`unknown argument: ${argv[index]}`);
  }
  return options;
}

function main(argv) {
  const options = parseArgs(argv);
  if (options.command !== 'check') throw new Error(`unknown command: ${options.command}`);
  const baseline = readBaseline();
  const today = new Date().toISOString().slice(0, 10);
  validateBaseline(baseline, today);
  if (options.baseRef) {
    const previous = baselineFromGit(options.baseRef);
    validateBaseline(previous, '0000-01-01');
    const change = compareBaselineChange(previous.warnings, baseline.warnings, options.reviewApproved);
    if (change.removals.length) console.log(`Baseline shrank by ${change.removals.length} warning exception(s).`);
  }
  const warnings = extractWarnings(readBuildInfos());
  const newWarnings = checkWarnings(warnings, baseline, today);
  if (newWarnings.length) {
    console.error(`Solidity warning gate failed: ${newWarnings.length} unowned/new warning(s).`);
    for (const warning of newWarnings) {
      console.error(`- ${warning.severity} ${warning.code || 'no-code'} ${warning.source}:${warning.line ?? '?'}:${warning.column ?? '?'} [${warning.compiler}] ${warning.message}`);
    }
    console.error(`Review each warning, then add a complete owned exception to ${BASELINE_PATH} (PR additions/modifications require the review label).`);
    process.exitCode = 1;
    return;
  }
  console.log(`Solidity warning gate passed: ${warnings.length} compiler warning(s), all explicitly baselined.`);
}

module.exports = {
  BASELINE_FIELDS,
  checkWarnings,
  compareBaselineChange,
  diagnosticFromCompilerError,
  extractWarnings,
  normalizeMessage,
  normalizeSource,
  positionAt,
  validateBaseline,
  warningId,
};

if (require.main === module) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    console.error(`Solidity warning gate failed: ${error.message}`);
    process.exitCode = 1;
  }
}
