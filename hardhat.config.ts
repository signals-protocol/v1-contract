import { HardhatUserConfig } from "hardhat/config";
import * as dotenv from "dotenv";
import "@nomicfoundation/hardhat-toolbox";
import "@openzeppelin/hardhat-upgrades";

dotenv.config();

const defaultAccounts = process.env.DEPLOYER_KEY
  ? [process.env.DEPLOYER_KEY]
  : [];
const hardhatAccountCount = Number.parseInt(
  process.env.HARDHAT_ACCOUNTS || "30",
  10
);
const defaultTestnetRpc = "https://rpc.testnet.citrea.xyz";
const devRpc =
  process.env.DEV_RPC_URL ||
  process.env.TESTNET_RPC_URL ||
  defaultTestnetRpc;
const testnetRpc = process.env.TESTNET_RPC_URL || defaultTestnetRpc;
const prodRpc = process.env.PROD_RPC_URL || "https://rpc.mainnet.citrea.xyz";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: { enabled: true, runs: 200 },
      viaIR: true,
    },
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
  },
  networks: {
    hardhat: {
      chainId: 31337,
      accounts: {
        count: Number.isFinite(hardhatAccountCount)
          ? hardhatAccountCount
          : 30,
      },
    },
    local: {
      chainId: 31337,
      url: process.env.LOCAL_RPC_URL || "http://127.0.0.1:8545",
    },
    dev: {
      url: devRpc,
      chainId: 5115,
      accounts: defaultAccounts,
    },
    testnet: {
      url: testnetRpc,
      chainId: 5115,
      accounts: defaultAccounts,
    },
    prod: {
      url: prodRpc,
      chainId: 4114,
      accounts: defaultAccounts,
    },
  },
  etherscan: {
    apiKey: {
      "dev": process.env.BLOCKSCOUT_API_KEY || "placeholder",
      "testnet": process.env.BLOCKSCOUT_API_KEY || "placeholder",
      "prod": process.env.BLOCKSCOUT_API_KEY || "placeholder",
    },
    customChains: [
      {
        network: "dev",
        chainId: 5115,
        urls: {
          apiURL: "https://explorer.testnet.citrea.xyz/api",
          browserURL: "https://explorer.testnet.citrea.xyz",
        },
      },
      {
        network: "testnet",
        chainId: 5115,
        urls: {
          apiURL: "https://explorer.testnet.citrea.xyz/api",
          browserURL: "https://explorer.testnet.citrea.xyz",
        },
      },
      {
        network: "prod",
        chainId: 4114,
        urls: {
          apiURL: "https://explorer.mainnet.citrea.xyz/api",
          browserURL: "https://explorer.mainnet.citrea.xyz",
        },
      },
    ],
  },
  mocha: {
    timeout: process.env.COVERAGE ? 0 : 20000,
  },
};

export default config;
