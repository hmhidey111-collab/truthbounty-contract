import { expect } from "chai";
import { network } from "hardhat";
import { keccak256, toUtf8Bytes, AbiCoder, ZeroHash, ZeroAddress } from "ethers";

// Solidity-mirroring type string: the library hashes this to derive the EIP-712 type hash.
const TYPE_STRING =
  "V2SignedOperation(bytes32 actionType,address verifyingContract,uint256 chainId,uint16 version,address signer,uint256 entityId,uint256 nonce,uint256 deadline)";

// Independent re-derivation of the digest using the ethers ABI coder, mirroring the library's
// keccak256(abi.encode(SIGNED_OPERATION_TYPEHASH, actionType, verifyingContract, chainId,
// version, signer, entityId, nonce, deadline)).
function expectedDigest(
  typehash: string,
  actionType: string,
  verifyingContract: string,
  chainId: bigint,
  version: number,
  signer: string,
  entityId: bigint,
  nonce: bigint,
  deadline: bigint
): string {
  const coder = AbiCoder.defaultAbiCoder();
  return keccak256(
    coder.encode(
      ["bytes32", "bytes32", "address", "uint256", "uint16", "address", "uint256", "uint256", "uint256"],
      [typehash, actionType, verifyingContract, chainId, version, signer, entityId, nonce, deadline]
    )
  );
}

describe("V2ReplayDomain (V2-SC-086 cross-chain replay domains)", function () {
  const ACTION = keccak256(toUtf8Bytes("verification_submission"));
  const SIGNER = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
  const ENTITY = 42n;
  const NONCE = 7n;
  const DEADLINE = 4102444800n; // 2100-01-01, matches canonical vectors
  const CHAIN = 10n; // optimism mainnet
  const VERSION = 1;

  let ethers: any;
  let harness: any;
  let typehash: string;

  before(async function () {
    ({ ethers } = await network.connect());
  });

  beforeEach(async function () {
    const Factory = await ethers.getContractFactory("V2ReplayDomainHarness");
    harness = await Factory.deploy();
    await harness.waitForDeployment();
    typehash = await harness.typehash();
  });

  it("pins the EIP-712 type hash to the canonical field order", async function () {
    expect(typehash).to.equal(keccak256(toUtf8Bytes(TYPE_STRING)));
    expect(await harness.domainVersion()).to.equal(VERSION);
  });

  it("matches an independent ethers re-derivation of the digest", async function () {
    const verifyingContract = await harness.getAddress();
    const got = await harness.digest(ACTION, verifyingContract, CHAIN, VERSION, SIGNER, ENTITY, NONCE, DEADLINE);
    const want = expectedDigest(typehash, ACTION, verifyingContract, CHAIN, VERSION, SIGNER, ENTITY, NONCE, DEADLINE);
    expect(got).to.equal(want);
  });

  it("binds the live chain id and the live verifying contract", async function () {
    const netChain = (await ethers.provider.getNetwork()).chainId;
    const verifyingContract = await harness.getAddress();
    const live = await harness.liveDigest(ACTION, SIGNER, ENTITY, NONCE, DEADLINE);
    // liveDigest must equal the explicit digest with block.chainid and address(this)
    const explicit = await harness.digest(ACTION, verifyingContract, netChain, VERSION, SIGNER, ENTITY, NONCE, DEADLINE);
    expect(live).to.equal(explicit);
    // and must NOT equal the digest for a different chain (cross-chain replay is impossible)
    const otherChain = await harness.digest(ACTION, verifyingContract, netChain + 1n, VERSION, SIGNER, ENTITY, NONCE, DEADLINE);
    expect(live).to.not.equal(otherChain);
  });

  it("changes the digest when any single replay dimension changes", async function () {
    const vc = await harness.getAddress();
    const base = await harness.digest(ACTION, vc, CHAIN, VERSION, SIGNER, ENTITY, NONCE, DEADLINE);
    const mutations: Record<string, () => Promise<string>> = {
      actionType: () => harness.digest(keccak256(toUtf8Bytes("staking")), vc, CHAIN, VERSION, SIGNER, ENTITY, NONCE, DEADLINE),
      verifyingContract: () => harness.digest(ACTION, "0x000000000000000000000000000000000000bEEF", CHAIN, VERSION, SIGNER, ENTITY, NONCE, DEADLINE),
      chainId: () => harness.digest(ACTION, vc, 42161n, VERSION, SIGNER, ENTITY, NONCE, DEADLINE),
      signer: () => harness.digest(ACTION, vc, CHAIN, VERSION, "0x70997970C51812dc3A010C7d01b50e0d17dc79C8", ENTITY, NONCE, DEADLINE),
      entityId: () => harness.digest(ACTION, vc, CHAIN, VERSION, SIGNER, 43n, NONCE, DEADLINE),
      nonce: () => harness.digest(ACTION, vc, CHAIN, VERSION, SIGNER, ENTITY, 8n, DEADLINE),
      deadline: () => harness.digest(ACTION, vc, CHAIN, VERSION, SIGNER, ENTITY, NONCE, DEADLINE + 1n),
    };
    // Each of the seven free replay dimensions must change the digest relative to the base.
    // The domain `version` is not a free dimension: it is pinned by `requireVersion`, so it is
    // covered by the fail-closed test below instead of a sensitivity mutation here.
    for (const [name, fn] of Object.entries(mutations)) {
      const changed = await fn();
      expect(changed, `dimension ${name} must change the digest`).to.not.equal(base);
    }
  });

  it("enforces the inclusive deadline bound", async function () {
    await harness.requireNotExpired(DEADLINE, DEADLINE); // equal is valid
    await harness.requireNotExpired(DEADLINE, DEADLINE - 1n); // before is valid
    await expect(harness.requireNotExpired(DEADLINE, DEADLINE + 1n))
      .to.be.revertedWithCustomError(harness, "ReplayDomainDeadlineExpired");
  });

  it("fails closed on malformed domain inputs", async function () {
    const vc = await harness.getAddress();
    await expect(harness.digest(ZeroHash, vc, CHAIN, VERSION, SIGNER, ENTITY, NONCE, DEADLINE))
      .to.be.revertedWithCustomError(harness, "ReplayDomainEmptyActionType");
    await expect(harness.digest(ACTION, ZeroAddress, CHAIN, VERSION, SIGNER, ENTITY, NONCE, DEADLINE))
      .to.be.revertedWithCustomError(harness, "ReplayDomainZeroVerifier");
    await expect(harness.digest(ACTION, vc, CHAIN, VERSION, ZeroAddress, ENTITY, NONCE, DEADLINE))
      .to.be.revertedWithCustomError(harness, "ReplayDomainZeroSigner");
    await expect(harness.digest(ACTION, vc, CHAIN, 9, SIGNER, ENTITY, NONCE, DEADLINE))
      .to.be.revertedWithCustomError(harness, "ReplayDomainInvalidVersion").withArgs(9, 1);
  });
});
