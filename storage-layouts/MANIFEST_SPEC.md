# Canonical Storage-Layout Manifest Specification (V2-SC-121)

Status: FROZEN (v1) · Owner: contracts maintainers · Binding for CI

## 1. Purpose

Every upgradeable TruthBounty V2 contract ships with a **reviewed storage-layout
manifest**. CI regenerates the manifest from solc compiler output and fails on
any **unapproved** drift before an implementation can reach an upgrade proposal.

Layout drift discovered at proposal time is too late: the manifest freeze moves
the detection point into every day-to-day pull request, where a human maintainer
reviews the diff.

## 2. Manifest format (schema version 1)

File: `storage-layouts/manifest.json` — a single JSON document:

```jsonc
{
  "schemaVersion": 1,                         // frozen manifest schema version
  "tool": { "name": "generateStorageLayouts", "version": "1.0.0" },
  "solc": "0.8.28+commit.7893614a.Emscripten.clang",  // exact compiler build
  "generatedAt": "<ISO-8601 UTC timestamp>",
  "contracts": {
    "<ContractName>": {
      "sourcePath": "contracts/upgrade/ProtocolUpgradeable.sol",
      "kind": "upgradeable" | "proxy",
      "canonicalHash": "0x…",                  // see §3 — the binding commitment
      "frozenAt": "<ISO-8601 UTC timestamp>",
      "slots": {
        "<stateVarLabel>": { "slot": "0", "offset": 0, "type": "t_uint256", "numberOfBytes": "32" }
      }
    }
  }
}
```

* `slot` and `numberOfBytes` are strings — they are copied verbatim from the
  solc `storageLayout` output, which encodes them as strings (decimal).
* `type` is solc's internal type identifier (e.g. `t_mapping(t_address,t_uint256)`).
  The human-readable label (`uint256[46]`) is intentionally **not** part of the
  digest: reformatting a type without changing its byte encoding is not drift.
* `kind` is declarative metadata used by the checker to pick review policy; it
  is **not** part of the digest.

## 3. Canonical hash

```
preimage = keccak256(
    "TB-STORAGE-LAYOUT-V1" ||
    uint256(schemaVersion = 1) ||
    uint256(len(sourcePath))        || sourcePath ||
    uint256(len(entry JSON))        || entry JSON
)
canonicalHash = keccak256(preimage)
```

* `entry JSON` = `{"slots":{...}}` — canonical JSON with **recursively sorted
  object keys** and no insignificant whitespace (RFC 8785 spirit; solc slot
  strings copied verbatim).
* Entry order inside `contracts` is not hashed (the contract map is re-keyed
  alphabetically on every write, so re-ordering is not drift).
* Domain separation (`TB-STORAGE-LAYOUT-V1`) prevents cross-protocol hash
  confusion; the length-prefixed fields prevent concatenation ambiguity.
* Byte-length collision classes (e.g. `uint256` → `uint128[2]`) change solc's
  type ids and/or `numberOfBytes`, so they change the entry JSON and are caught.

The Foundry test `test/upgrade/StorageLayoutManifest.t.sol` mirrors this exact
preimage, so the TypeScript generator and the on-chain-commitment path must
always agree.

## 4. Drift classification and required review

The checker (`scripts/generateStorageLayouts.ts --check`) compares the
regenerated manifest against the frozen one and classifies every contract:

| Classification | Meaning | CI | Required action |
|---|---|---|---|
| `unchanged` | `canonicalHash` identical | pass | none |
| `approved` | drift recorded in `APPROVED_DRIFT.md` with the new hash | pass | maintainer review already recorded |
| `new` | contract added to the manifest | pass (requires manifest diff in PR) | review the added entry |
| `removed` | contract deleted from the manifest | fail | explicit maintainer decision; re-freeze |
| `slot-drift` | a frozen variable changed slot/offset/type/size, was renamed, or a variable was added before the `__gap` boundary | fail | maintainer review; approval record or layout-breaking migration |
| `appended` | variable added strictly **after** the last frozen slot of a `__gap`-terminated layout (slot-preserving append) | fail | maintainer review; `__gap` must shrink by the appended size (see §5) |

`--check` exits non-zero for any classification marked `fail` and prints a
 remediation block for each offending contract.

## 5. Append-only rule for `__gap`-terminated layouts

For contracts whose layout ends in a `__gap` array:

* New state variables must be appended after the last frozen slot **and** the
  `__gap` array must shrink so that the total occupied region does not move
  any pre-existing variable.
* A `__gap` change that is not accompanied by a matching append is drift.
* For namespaced (ERC-7201) layouts the equivalent rule is: the namespace id
  and the set of variables inside it are frozen; new namespaces are appends.

## 6. Freeze and approval workflow

1. `npm run test:layouts:update` regenerates `storage-layouts/manifest.json`.
2. The PR containing the manifest diff is reviewed by an **independent human
   maintainer** (this issue's review requirement); no self-merge.
3. Approved layout-breaking changes additionally append an entry to
   `storage-layouts/APPROVED_DRIFT.md` containing: contract, PR link, old and
   new `canonicalHash`, migration classification (append-only / layout-breaking
   with `ProtocolUpgradeManager.migrationHash` commitment).
4. CI `storage-layouts` job re-runs `--check`; green requires the above to hold.

## 7. Non-goals

* No on-chain enforcement is added by this change; the manifest feeds human
  review and existing governance (UpgradeController / ProtocolUpgradeManager).
* No V1 layouts, no non-upgradeable contracts, no deployment addresses.
* No frontend/API/indexer authority: the manifest is a contracts-domain
  artifact and confers no settlement or treasury rights.
