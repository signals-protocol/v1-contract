// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {Constants} from "./Constants.s.sol";

abstract contract BaseScript is Script {
    string internal envName;
    string internal envJsonPath;

    function setUp() public virtual {
        envName = vm.envString("ENV");
        require(
            keccak256(bytes(envName)) == keccak256("dev") || keccak256(bytes(envName)) == keccak256("prod")
                || keccak256(bytes(envName)) == keccak256("local"),
            "ENV must be dev|prod|local"
        );
        envJsonPath = string.concat("scripts/environments/", envName, ".json");
    }

    // ── Environment JSON reading ────────────────────────────────────────

    function _loadEnvJson() internal view returns (string memory) {
        return vm.readFile(envJsonPath);
    }

    /// @dev Read contract address from env JSON. Reverts if key missing.
    function _contractAddr(string memory key) internal view returns (address) {
        string memory json = _loadEnvJson();
        string memory path = string.concat(".contracts.", key);
        return vm.parseJsonAddress(json, path);
    }

    /// @dev Try to read contract address, return address(0) if key missing.
    function _tryContractAddr(string memory key) internal view returns (address) {
        string memory json = _loadEnvJson();
        string memory path = string.concat(".contracts.", key);
        if (!vm.keyExistsJson(json, path)) return address(0);
        return vm.parseJsonAddress(json, path);
    }

    /// @dev Read config string value, return empty string if missing.
    function _tryConfigString(string memory key) internal view returns (string memory) {
        string memory json = _loadEnvJson();
        string memory path = string.concat(".config.", key);
        if (!vm.keyExistsJson(json, path)) return "";
        return vm.parseJsonString(json, path);
    }

    /// @dev Read config uint value, return 0 if missing.
    function _tryConfigUint(string memory key) internal view returns (uint256) {
        string memory json = _loadEnvJson();
        string memory path = string.concat(".config.", key);
        if (!vm.keyExistsJson(json, path)) return 0;
        return vm.parseJsonUint(json, path);
    }

    /// @dev Read config address value, return address(0) if missing.
    function _tryConfigAddr(string memory key) internal view returns (address) {
        string memory json = _loadEnvJson();
        string memory path = string.concat(".config.", key);
        if (!vm.keyExistsJson(json, path)) return address(0);
        return vm.parseJsonAddress(json, path);
    }

    /// @dev Read config address array, return empty if missing.
    function _tryConfigAddrArray(string memory key) internal view returns (address[] memory) {
        string memory json = _loadEnvJson();
        string memory path = string.concat(".config.", key);
        if (!vm.keyExistsJson(json, path)) return new address[](0);
        return vm.parseJsonAddressArray(json, path);
    }

    // ── Chain ID guard ──────────────────────────────────────────────────

    function _enforceChainId() internal view {
        uint256 expected;
        if (keccak256(bytes(envName)) == keccak256("dev")) {
            expected = Constants.DEV_CHAIN_ID;
        } else if (keccak256(bytes(envName)) == keccak256("prod")) {
            expected = Constants.PROD_CHAIN_ID;
        } else {
            return; // local — no guard
        }
        require(block.chainid == expected, "Chain ID mismatch");
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    function _toBytes32(string memory s) internal pure returns (bytes32) {
        return bytes32(bytes(s));
    }

    /// @dev Write structured output JSON for post-deploy.ts consumption.
    function _writeOutput(string memory key, string memory jsonBlob) internal {
        vm.writeFile(string.concat("script-output/", key, ".json"), jsonBlob);
    }
}
