# Invariant failure seeds (PREWAVE-SC-065)

## Purpose

Persist Foundry invariant/fuzz counterexample seeds so a failure on CI can be
replayed locally with the same test id, commit binding, and toolchain metadata.

## Schema

See `schemas/invariant-failure-seed.schema.json`.

Required fields:

- `schemaVersion` (1)
- `kind` (`invariant` | `fuzz`)
- `test` (`ContractName:test_or_invariant_name`)
- `commit` (git SHA)
- `toolchain.forge` / `toolchain.solc`
- `seed` (decimal string)
- `createdAt` (ISO date-time)

## Local replay

```bash
node scripts/invariant-seed-tools.mjs replay-cmd test/invariant/seeds/known-counterexample.json
Run the printed forge test ... --fuzz-seed ... command.
Validate / redact (no secrets)
node scripts/invariant-seed-tools.mjs validate path/to/seed.json
node scripts/invariant-seed-tools.mjs redact path/to/seed.json
Artifacts must not contain private keys, mnemonics, API tokens, or .env values.
