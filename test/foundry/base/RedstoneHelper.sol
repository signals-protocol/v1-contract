// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Vm.sol";

/// @title RedstoneHelper
/// @notice Builds Redstone oracle payloads in pure Solidity using vm.sign for test submissions.
/// @dev Matches the binary format of @redstone-finance/protocol for on-chain verification.
///      Format reference: https://docs.redstone.finance/docs/smart-contract-devs/how-it-works
library RedstoneHelper {
    // ============================================================
    // Constants — from redstone.ts:10-13
    // ============================================================
    bytes32 internal constant DATA_FEED_ID = bytes32("BTC");
    uint8 internal constant FEED_DECIMALS = 8;
    uint8 internal constant UNIQUE_SIGNERS_THRESHOLD = 3;

    // Unsigned metadata string used by Redstone protocol
    bytes internal constant UNSIGNED_METADATA = bytes("redstone-primary-prod");

    // Redstone calldata marker (9 bytes) — signals start of payload when parsing from end
    bytes9 internal constant REDSTONE_MARKER = 0x000002ed57011e0000;

    // ============================================================
    // Hardhat default account private keys — from OracleModuleHarness:8-10
    // These are public test keys, NOT secrets.
    // ============================================================
    uint256 internal constant LOCAL_SIGNER_KEY_0 = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant LOCAL_SIGNER_KEY_1 = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant LOCAL_SIGNER_KEY_2 = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;

    // ============================================================
    // Price conversion — from redstone.ts:113-123
    // ============================================================

    /// @notice Convert human-readable price to settlement value (6-decimal USDC)
    /// @dev humanPrice=2 => 2_000_000 (same as 2 USDC)
    function toSettlementValue(uint256 humanPrice) internal pure returns (int256) {
        return int256(humanPrice * 1_000_000);
    }

    /// @notice Convert settlement value to settlement tick
    function toSettlementTick(int256 settlementValue) internal pure returns (int256) {
        return settlementValue / 1_000_000;
    }

    // ============================================================
    // Redstone payload builder
    // ============================================================

    /// @notice Build a complete Redstone calldata payload signed by 3 local signers
    /// @param vm_ The Vm cheatcode instance
    /// @param value8dec The data point value with 8 decimals (e.g. 100000 * 1e8 for $100000)
    /// @param timestampSec The timestamp in seconds
    /// @return payload The encoded Redstone payload bytes (to be appended to calldata)
    function buildRedstonePayload(
        Vm vm_,
        uint256 value8dec,
        uint256 timestampSec
    ) internal returns (bytes memory payload) {
        uint256[3] memory keys = [LOCAL_SIGNER_KEY_0, LOCAL_SIGNER_KEY_1, LOCAL_SIGNER_KEY_2];

        // Build 3 signed data packages
        bytes memory packages;
        for (uint256 i = 0; i < 3; i++) {
            bytes memory pkg = _buildSignedDataPackage(vm_, keys[i], value8dec, timestampSec);
            packages = bytes.concat(packages, pkg);
        }

        // Full payload = [pkgs][pkgCount(2B)][metadata][metaBytesSize(3B)][REDSTONE_MARKER(9B)]
        // pkgCount is part of serializeSignedDataPackages(), comes right after the packages
        payload = bytes.concat(
            packages,
            _toBytes2(uint16(3)), // 3 data packages — part of signed packages section
            UNSIGNED_METADATA,
            _toBytes3(uint24(UNSIGNED_METADATA.length)),
            REDSTONE_MARKER
        );
    }

    /// @notice Submit a settlement sample with Redstone payload appended to calldata
    /// @param vm_ The Vm cheatcode instance
    /// @param core The SignalsCore (or harness) address
    /// @param submitter The address that sends the transaction
    /// @param marketId The market ID to settle
    /// @param priceHuman Human-readable price (e.g. 100000 for $100,000 BTC)
    /// @param timestampSec The settlement sample timestamp in seconds
    function submitWithPayload(
        Vm vm_,
        address core,
        address submitter,
        uint256 marketId,
        uint256 priceHuman,
        uint256 timestampSec
    ) internal {
        // Build Redstone payload with 8-decimal encoding
        uint256 value8dec = priceHuman * 10 ** FEED_DECIMALS;
        bytes memory redstonePayload = buildRedstonePayload(vm_, value8dec, timestampSec);

        // Encode submitSettlementSample(uint256) call
        bytes memory callData = abi.encodeWithSignature("submitSettlementSample(uint256)", marketId);

        // Append Redstone payload to calldata
        bytes memory fullData = bytes.concat(callData, redstonePayload);

        // Send as raw transaction from submitter
        vm_.prank(submitter);
        (bool success, bytes memory ret) = core.call(fullData);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    // ============================================================
    // Internal: Redstone binary format helpers
    // ============================================================

    /// @dev Build a single signed data package for one signer.
    /// DataPackage.toBytes() = [dataPoints][timestamp(6B)][valueByteSize(4B)][count(3B)]
    /// SignedDataPackage = [dataBytes][signature(65B)]
    /// Note: no dataByteSize trailer — on-chain extractor computes size from metadata.
    function _buildSignedDataPackage(
        Vm vm_,
        uint256 signerKey,
        uint256 value8dec,
        uint256 timestampSec
    ) private returns (bytes memory) {
        // Data point: [feedId(32B)][value(32B)] — on-chain CalldataExtractor reads feedId first
        bytes memory dataPointFeedId = abi.encodePacked(DATA_FEED_ID);
        bytes memory dataPointValue = abi.encodePacked(value8dec);
        dataPointValue = _leftPad32(dataPointValue);

        uint256 timestampMs = timestampSec * 1000;

        // DataPackage.toBytes() = [dataPoints][timestamp(6B)][valueByteSize(4B)][dataPointsCount(3B)]
        bytes memory dataBytes = bytes.concat(
            dataPointFeedId,
            dataPointValue,
            _toBytes6(timestampMs), // timestampMilliseconds
            _toBytes4(32), // dataPointValueByteSize = 32
            _toBytes3(1) // dataPointCount = 1
        );

        // Sign with raw keccak256 (NOT EIP-191) — matches Redstone SDK SigningKey.signDigest
        bytes32 hash = keccak256(dataBytes);
        (uint8 v, bytes32 r, bytes32 s) = vm_.sign(signerKey, hash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // SignedDataPackage = [dataBytes][signature(65B)]
        return bytes.concat(dataBytes, signature);
    }

    function _leftPad32(bytes memory data) private pure returns (bytes memory) {
        if (data.length >= 32) return data;
        bytes memory padded = new bytes(32);
        uint256 offset = 32 - data.length;
        for (uint256 i = 0; i < data.length; i++) {
            padded[offset + i] = data[i];
        }
        return padded;
    }

    function _toBytes2(uint16 x) private pure returns (bytes2) {
        return bytes2(x);
    }

    function _toBytes3(uint24 x) private pure returns (bytes3) {
        return bytes3(x);
    }

    function _toBytes4(uint32 x) private pure returns (bytes4) {
        return bytes4(x);
    }

    function _toBytes6(uint256 x) private pure returns (bytes memory) {
        bytes memory b = new bytes(6);
        for (uint256 i = 0; i < 6; i++) {
            b[5 - i] = bytes1(uint8(x & 0xff));
            x >>= 8;
        }
        return b;
    }
}
