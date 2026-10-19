// hardhat.vrm.config.ts — isolated config for VerificationRoundManager tests
// Compiles only the contracts required for V2-SC-011 tests, avoiding
// pre-existing broken contracts (syntax errors, OZ v4/v5 API mismatches)
// that exist in the main contracts/ directory.
import { HardhatUserConfig } from "hardhat/config";
import hardhatToolboxMochaEthers from "@nomicfoundation/hardhat-toolbox-mocha-ethers";
import hardhatIgnitionEthers from "@nomicfoundation/hardhat-ignition-ethers";
import * as dotenv from "dotenv";

dotenv.config();

const config: HardhatUserConfig = {
  plugins: [hardhatToolboxMochaEthers, hardhatIgnitionEthers],
  solidity: {
    version: "0.8.28",
    settings: {
      evmVersion: "cancun",
      viaIR: true,
      optimizer: { enabled: true, runs: 200 },
    },
  },
  paths: {
    sources: "./contracts-vrm",
    tests: "./test",
    cache: "./cache-vrm",
    artifacts: "./artifacts-vrm",
  },
  networks: {
    hardhat: {
      type: "edr-simulated",
      chainId: 31337,
      allowUnlimitedContractSize: true,
    },
  },
};

export default config;
