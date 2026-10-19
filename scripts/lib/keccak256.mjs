/**
 * @file keccak256.mjs
 * @description Dependency-free Keccak-256 (the pre-NIST padding used by the EVM and Solidity).
 *
 * Node's built-in `crypto` only exposes NIST SHA3-256, whose padding differs from Keccak-256, so
 * it cannot be used to derive EVM storage slots. This module keeps the V2-SC-159 storage
 * namespace checker runnable in the lint job without a compiler or a network install. It is
 * cross-checked in `test/scripts/check-storage-namespaces.test.mjs` against published vectors,
 * against `ethers.keccak256` when ethers is installed, and against the Solidity recomputation in
 * `test/upgrade/StorageNamespaceCollision.t.sol`.
 */

const MASK_64 = (1n << 64n) - 1n;
const RATE_BYTES = 136; // 1088-bit rate for a 256-bit output

/** Round constants for Keccak-f[1600]. */
const ROUND_CONSTANTS = [
  0x0000000000000001n, 0x0000000000008082n, 0x800000000000808an, 0x8000000080008000n,
  0x000000000000808bn, 0x0000000080000001n, 0x8000000080008081n, 0x8000000000008009n,
  0x000000000000008an, 0x0000000000000088n, 0x0000000080008009n, 0x000000008000000an,
  0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
  0x8000000000008002n, 0x8000000000000080n, 0x000000000000800an, 0x800000008000000an,
  0x8000000080008081n, 0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n
];

/** Rotation offsets indexed by lane `x + 5 * y`. */
const ROTATION_OFFSETS = [
  0, 1, 62, 28, 27,
  36, 44, 6, 55, 20,
  3, 10, 43, 25, 39,
  41, 45, 15, 21, 8,
  18, 2, 61, 56, 14
];

function rotl64(value, shift) {
  if (shift === 0) return value;
  const s = BigInt(shift);
  return ((value << s) | (value >> (64n - s))) & MASK_64;
}

function keccakF1600(state) {
  const c = new Array(5);
  const b = new Array(25);
  for (let round = 0; round < 24; round++) {
    // theta
    for (let x = 0; x < 5; x++) {
      c[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20];
    }
    for (let x = 0; x < 5; x++) {
      const d = c[(x + 4) % 5] ^ rotl64(c[(x + 1) % 5], 1);
      for (let y = 0; y < 25; y += 5) state[x + y] ^= d;
    }
    // rho + pi
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) {
        b[y + 5 * ((2 * x + 3 * y) % 5)] = rotl64(state[x + 5 * y], ROTATION_OFFSETS[x + 5 * y]);
      }
    }
    // chi
    for (let y = 0; y < 25; y += 5) {
      for (let x = 0; x < 5; x++) {
        state[x + y] = b[x + y] ^ ((b[((x + 1) % 5) + y] ^ MASK_64) & b[((x + 2) % 5) + y]);
      }
    }
    // iota
    state[0] ^= ROUND_CONSTANTS[round];
  }
}

/**
 * Converts a hex string (with or without 0x) or a UTF-8 string/Uint8Array into bytes.
 * @param {Uint8Array | string} input Bytes, or a string. Strings are UTF-8 encoded.
 * @returns {Uint8Array} Input bytes.
 */
function toBytes(input) {
  if (input instanceof Uint8Array) return input;
  if (typeof input === "string") return new TextEncoder().encode(input);
  throw new TypeError("keccak256: input must be a Uint8Array or a string");
}

/**
 * Keccak-256 of the input.
 * @param {Uint8Array | string} input Bytes, or a string that is UTF-8 encoded first.
 * @returns {string} 0x-prefixed lowercase 32-byte hex digest.
 */
export function keccak256(input) {
  const data = toBytes(input);
  const paddedLength = (Math.floor(data.length / RATE_BYTES) + 1) * RATE_BYTES;
  const padded = new Uint8Array(paddedLength);
  padded.set(data);
  padded[data.length] ^= 0x01;
  padded[paddedLength - 1] ^= 0x80;

  const state = new Array(25).fill(0n);
  for (let offset = 0; offset < paddedLength; offset += RATE_BYTES) {
    for (let lane = 0; lane < RATE_BYTES / 8; lane++) {
      let word = 0n;
      for (let i = 7; i >= 0; i--) word = (word << 8n) | BigInt(padded[offset + lane * 8 + i]);
      state[lane] ^= word;
    }
    keccakF1600(state);
  }

  let hex = "0x";
  for (let lane = 0; lane < 4; lane++) {
    let word = state[lane];
    for (let i = 0; i < 8; i++) {
      hex += Number(word & 0xffn).toString(16).padStart(2, "0");
      word >>= 8n;
    }
  }
  return hex;
}

/**
 * Parses a 0x-prefixed 32-byte hex word into bytes.
 * @param {string} hex 0x-prefixed hex.
 * @returns {Uint8Array} 32 bytes.
 */
export function wordToBytes(hex) {
  const clean = hex.replace(/^0x/i, "").padStart(64, "0");
  if (!/^[0-9a-fA-F]{64}$/.test(clean)) throw new Error(`not a 32-byte word: ${hex}`);
  const out = new Uint8Array(32);
  for (let i = 0; i < 32; i++) out[i] = parseInt(clean.slice(i * 2, i * 2 + 2), 16);
  return out;
}

/**
 * Formats a bigint as a 0x-prefixed 32-byte lowercase hex word.
 * @param {bigint} value Value in [0, 2^256).
 * @returns {string} 32-byte hex word.
 */
export function toWord(value) {
  return "0x" + BigInt.asUintN(256, value).toString(16).padStart(64, "0");
}

/**
 * EIP-1967 style unstructured slot: `bytes32(uint256(keccak256(id)) - 1)`.
 * @param {string} id Slot identifier, e.g. `eip1967.proxy.implementation`.
 * @returns {string} Slot as a 32-byte hex word.
 */
export function eip1967Slot(id) {
  return toWord(BigInt(keccak256(id)) - 1n);
}

/**
 * ERC-7201 namespace root:
 * `keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~bytes32(uint256(0xff))`.
 * @param {string} id Namespace id (without the `erc7201:` formula prefix).
 * @returns {string} Namespace root slot as a 32-byte hex word.
 */
export function erc7201Slot(id) {
  const inner = BigInt(keccak256(id)) - 1n;
  const outer = BigInt(keccak256(wordToBytes(toWord(inner))));
  return toWord(outer & ~0xffn);
}
