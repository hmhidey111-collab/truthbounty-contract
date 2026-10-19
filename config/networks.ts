export const COMPILER_SETTINGS = {
  version: "0.8.28",
  settings: {
    optimizer: {
      enabled: true,
      runs: 200,
    },
    viaIR: false,
  },
};

export const NETWORKS = {
  hardhat: {
    type: "edr-simulated",
    chainId: 31337,
    allowUnlimitedContractSize: true,
  },
  hardhatMainnet: {
    type: "edr-simulated",
    chainId: 31337,
    allowUnlimitedContractSize: true,
  },
  optimismSepolia: {
    rpcUrlEnv: "OPTIMISM_SEPOLIA_RPC_URL",
    defaultRpcUrl: "https://sepolia.optimism.io",
    chainId: 11155420,
  },
  optimismMainnet: {
    rpcUrlEnv: "OPTIMISM_MAINNET_RPC_URL",
    defaultRpcUrl: "https://mainnet.optimism.io",
    chainId: 10,
  },
};

export const RESOLVE_NETWORK_ALIAS: Record<string, string> = {
  optimism_sepolia: "optimismSepolia",
  optimism_mainnet: "optimismMainnet",
};
