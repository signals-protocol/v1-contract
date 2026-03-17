// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseScript} from "../base/BaseScript.s.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SignalsDeployer} from "../../contracts/deploy/SignalsDeployer.sol";
import {console} from "forge-std/console.sol";

/// @title PredictCreate2 — Pure computation: predict CREATE2 deployment addresses
/// @notice Reads impl addresses from env JSON, computes deterministic addresses
/// @dev Env vars: DEPLOYER_EOA, CREATE2_RELEASE (default "v1"),
///      CREATE2_VANITY_PREFIX (default "0x516"), CREATE2_MAX_NONCE (default 1000000)
contract PredictCreate2 is BaseScript {
    function run() external {
        _enforceChainId();

        address create2Factory = _contractAddr("SignalsCreate2Factory");
        address coreImpl = _contractAddr("SignalsCoreImplementation");
        address positionImpl = _contractAddr("SignalsPositionImplementation");
        address lpShareImpl = _contractAddr("SignalsLPShareImplementation");
        address deployerEOA = vm.envAddress("DEPLOYER_EOA");

        string memory release = vm.envOr("CREATE2_RELEASE", string("v1"));
        string memory vanityPrefix = vm.envOr("CREATE2_VANITY_PREFIX", string("0x516"));
        uint256 maxNonce = vm.envOr("CREATE2_MAX_NONCE", uint256(1_000_000));

        // Compute deployer initcode hash
        bytes memory deployerInitCode = abi.encodePacked(type(SignalsDeployer).creationCode, abi.encode(deployerEOA));
        bytes32 deployerInitHash = keccak256(deployerInitCode);

        // Deployer salt (nonce=0)
        string memory deployerBase = _buildBase("DEPLOYER", release);
        bytes32 deployerSalt = _buildSalt(deployerBase, 0);
        address deployerAddr = Create2.computeAddress(deployerSalt, deployerInitHash, create2Factory);

        // Proxy initcode hashes
        bytes32 coreInitHash = _proxyInitCodeHash(coreImpl);
        bytes32 positionInitHash = _proxyInitCodeHash(positionImpl);
        bytes32 lpShareInitHash = _proxyInitCodeHash(lpShareImpl);

        // Core proxy: vanity search
        string memory coreBase = _buildBase("CORE_PROXY", release);
        bytes32 coreSalt;
        uint256 coreNonce;
        address coreAddr;

        bytes memory vanityBytes = bytes(vanityPrefix);
        for (uint256 nonce = 0; nonce <= maxNonce; nonce++) {
            bytes32 salt = _buildSalt(coreBase, nonce);
            address predicted = Create2.computeAddress(salt, coreInitHash, deployerAddr);
            if (_matchesPrefix(predicted, vanityBytes)) {
                coreSalt = salt;
                coreNonce = nonce;
                coreAddr = predicted;
                break;
            }
        }
        require(coreAddr != address(0), "Core vanity not found within MAX_NONCE");

        // Position & LPShare (nonce=0)
        string memory positionBase = _buildBase("POSITION_PROXY", release);
        string memory lpShareBase = _buildBase("LPSHARE_PROXY", release);
        bytes32 positionSalt = _buildSalt(positionBase, 0);
        bytes32 lpShareSalt = _buildSalt(lpShareBase, 0);
        address positionAddr = Create2.computeAddress(positionSalt, positionInitHash, deployerAddr);
        address lpShareAddr = Create2.computeAddress(lpShareSalt, lpShareInitHash, deployerAddr);

        console.log("[predict-create2] coreProxy=%s (nonce=%s)", coreAddr, coreNonce);
        console.log("[predict-create2] positionProxy=%s", positionAddr);
        console.log("[predict-create2] lpShareProxy=%s", lpShareAddr);
        console.log("[predict-create2] deployer=%s", deployerAddr);

        // Write output JSON
        string memory salts = vm.serializeBytes32("salts", "DEPLOYER", deployerSalt);
        salts = vm.serializeBytes32("salts", "CORE_PROXY", coreSalt);
        salts = vm.serializeBytes32("salts", "POSITION_PROXY", positionSalt);
        salts = vm.serializeBytes32("salts", "LPSHARE_PROXY", lpShareSalt);

        string memory contracts = vm.serializeAddress("contracts", "SignalsCreate2Factory", create2Factory);
        contracts = vm.serializeAddress("contracts", "SignalsDeployer", deployerAddr);
        contracts = vm.serializeAddress("contracts", "SignalsCoreProxy", coreAddr);
        contracts = vm.serializeAddress("contracts", "SignalsPositionProxy", positionAddr);
        contracts = vm.serializeAddress("contracts", "SignalsLPShareProxy", lpShareAddr);
        contracts = vm.serializeAddress("contracts", "SignalsCoreImplementation", coreImpl);
        contracts = vm.serializeAddress("contracts", "SignalsPositionImplementation", positionImpl);
        contracts = vm.serializeAddress("contracts", "SignalsLPShareImplementation", lpShareImpl);

        string memory root = vm.serializeString("root", "action", "predict-create2");
        root = vm.serializeString("root", "contracts", contracts);
        root = vm.serializeString("root", "salts", salts);
        root = vm.serializeUint("root", "coreVanityNonce", coreNonce);

        _writeOutput("predict-create2", root);
    }

    // ── Internal helpers ────────────────────────────────────────────────

    function _buildBase(string memory component, string memory release) internal view returns (string memory) {
        return string.concat("signals-v1|", vm.toString(block.chainid), "|", envName, "|", release, "|", component);
    }

    function _buildSalt(string memory base, uint256 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(base, "|", vm.toString(nonce)));
    }

    function _proxyInitCodeHash(address impl) internal pure returns (bytes32) {
        bytes memory initCode = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(impl, ""));
        return keccak256(initCode);
    }

    function _matchesPrefix(address addr, bytes memory prefix) internal pure returns (bool) {
        bytes memory addrStr = bytes(_toLowerHex(addr));
        if (addrStr.length < prefix.length) return false;
        for (uint256 i = 0; i < prefix.length; i++) {
            // Case-insensitive comparison
            bytes1 a = prefix[i];
            bytes1 b = addrStr[i];
            if (a >= 0x41 && a <= 0x5A) a = bytes1(uint8(a) + 32);
            if (b >= 0x41 && b <= 0x5A) b = bytes1(uint8(b) + 32);
            if (a != b) return false;
        }
        return true;
    }

    function _toLowerHex(address addr) internal pure returns (string memory) {
        return vm.toLowercase(vm.toString(addr));
    }
}
