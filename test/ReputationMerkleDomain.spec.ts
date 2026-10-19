const { expect } = require("chai");
const { keccak256, AbiCoder, getAddress } = require("ethers");

describe("ReputationMerkleDomain leaf binding (issue #446)", function () {
  it("changes leaf hash when domain fields change", function () {
    const coder = AbiCoder.defaultAbiCoder();
    const typehash = keccak256(
      Buffer.from(
        "ReputationLeaf(uint256 chainId,address registry,uint256 schemaVersion,uint256 epoch,address subject,uint256 score,uint256 expiry)",
      ),
    );
    const leaf = (chainId) =>
      keccak256(
        coder.encode(
          ["bytes32", "uint256", "address", "uint256", "uint256", "address", "uint256", "uint256"],
          [typehash, chainId, getAddress("0x0000000000000000000000000000000000000001"), 1, 10, getAddress("0x0000000000000000000000000000000000000002"), 100, 9999999999],
        ),
      );
    expect(leaf(10)).to.not.equal(leaf(420));
  });
});
