import { HardhatUserConfig } from "hardhat/config";
import * as dotenv from "dotenv";
import "@nomicfoundation/hardhat-toolbox";
import "@openzeppelin/hardhat-upgrades";

dotenv.config();

const defaultAccounts = process.env.DEPLOYER_KEY ? [process.env.DEPLOYER_KEY] : [];
const CITREA_RPC = process.env.CITREA_RPC_URL || "https://rpc.testnet.citrea.xyz";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: { enabled: true, runs: 200 },
      viaIR: true
    }
  },
  paths: {
    sources: "./contracts",
    tests: "./test"
  },
  networks: {
    localhost: {
      chainId: 31337
    },
    "citrea-dev": {
      url: process.env.CITREA_DEV_RPC_URL || CITREA_RPC,
      chainId: 5115,
      accounts: defaultAccounts
    },
    "citrea-prod": {
      url: process.env.CITREA_PROD_RPC_URL || CITREA_RPC,
      chainId: 5115,
      accounts: defaultAccounts
    }
  },
  etherscan: {
    apiKey: {
      "citrea-dev": process.env.BLOCKSCOUT_API_KEY || "placeholder",
      "citrea-prod": process.env.BLOCKSCOUT_API_KEY || "placeholder"
    },
    customChains: [
      {
        network: "citrea-dev",
        chainId: 5115,
        urls: {
          apiURL: "https://explorer.testnet.citrea.xyz/api",
          browserURL: "https://explorer.testnet.citrea.xyz"
        }
      },
      {
        network: "citrea-prod",
        chainId: 5115,
        urls: {
          apiURL: "https://explorer.testnet.citrea.xyz/api",
          browserURL: "https://explorer.testnet.citrea.xyz"
        }
      }
    ]
  }
};

export default config;
