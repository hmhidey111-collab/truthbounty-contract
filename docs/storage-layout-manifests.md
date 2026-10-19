# Canonical Storage-Layout Manifests (V2-SC-121)

Every upgradeable V2 contract has its storage layout **frozen** in
[`storage-layouts/manifest.json`](../storage-layouts/manifest.json) and CI
fails on unapproved slot, type, inheritance-area, or gap drift. The manifest
format, digest construction and review policy are specified (frozen, v1) in
[`storage-layouts/MANIFEST_SPEC.md`](../storage-layouts/MANIFEST_SPEC.md).

## Why

Layout drift discovered at upgrade-proposal time is too late: the manifest
freeze moves the detection point into every pull request, where a human
maintainer reviews the diff. The manifest is derived **from the compiler**
(solc 0.8.28 `storageLayout` output with the exact optimizer settings used by
`hardhat.config.ts`) — never from hardcoded slot counts.

## Commands

```bash
npm run test:layouts          # CI mode: regenerate in memory, fail on unapproved drift
npm run test:layouts:update   # freeze / re-freeze storage-layouts/manifest.json
```

## What is checked

For every tracked contract (see `TRACKED_STORAGE_CONTRACTS` in
`scripts/storageLayoutManifest.ts`):

| Drift | Classification | CI |
|---|---|---|
| no change | `unchanged` | pass |
| drift recorded in `storage-layouts/APPROVED_DRIFT.md` | `approved` | pass |
| contract added to the manifest | `new` | pass (manifest diff must be reviewed in the PR) |
| contract removed from the manifest | `removed` | fail |
| frozen variable moved / retyped / resized / removed, or inserted before the append boundary | `slot-drift` | fail |
| append-only growth (new variable at/after the boundary with a gap that shrank or stayed equal) | `appended` | fail (requires maintainer approval) |

Hash mismatches with byte-identical slot maps (tooling/encoding drift) are
treated as `slot-drift` and therefore fail closed.

## Reviewer workflow for layout changes

1. Regenerate the manifest (`npm run test:layouts:update`) and include the
   resulting diff in the PR.
2. Confirm the change is the intended proxy-safe pattern:
   - append-only: new variables at/after the last frozen slot, gap unchanged
     or shrunk; **no frozen variable moves**; or
   - layout-breaking: requires a `ProtocolUpgradeManager` migration commitment
     (validated `migrationHash`) and full-migration review.
3. For approved drift, add a line to `storage-layouts/APPROVED_DRIFT.md` with
   the new canonical hash and PR link.
4. Obtain **independent human maintainer approval** on the PR (automatic merge
   is prohibited for protocol-critical changes).

## Migration impact and compatibility

* Active claims and locks live in mappings whose slots are frozen; append-only
  changes preserve every storage location and require **no migration**.
* Layout-breaking changes are gated by the existing upgrade framework
  (`UpgradeController` timelock, `ProtocolUpgradeManager` storage-compatibility
  attestation and migration hash) — this manifest adds a *pre-approval gate*,
  it does not replace on-chain authorization.
* No V1 contracts, non-upgradeable contracts, or deployment addresses are
  tracked. No frontend, API, indexer, guardian, or deployer surface gains any
  new authority from this change: the manifest is a contracts-domain review
  artifact only.

## CI

`.github/workflows/ci.yml` runs `npm run test:layouts` in the dedicated
`storage-layouts` job (after the standard test job). A red run means some
contract's compiled layout differs from the reviewed manifest without an
approval record.
