// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Vm.sol";

/// @title RedstoneHelper
/// @notice Builds Redstone oracle payloads in pure Solidity using vm.sign for test submissions.
/// @dev Matches the binary format of @redstone-finance/protocol for on-chain verification.
library RedstoneHelper {
    // ============================================================
    // Constants — from redstone.ts:10-13
    // ============================================================
    bytes32 internal constant DATA_FEED_ID = bytes32("BTC");
    uint8 internal constant FEED_DECIMALS = 8;
    uint8 internal constant UNIQUE_SIGNERS_THRESHOLD = 3;

    // Unsigned metadata string used by Redstone protocol
    bytes internal constant UNSIGNED_METADATA = bytes("redstone-primary-prod");

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

        // Full payload = [pkg0][pkg1][pkg2][unsignedMetadata][metaBytesSize(2B)][signerCount(1B)]
        // Note: metaBytesSize is encoded as 3 bytes in Redstone format
        payload = bytes.concat(packages, UNSIGNED_METADATA, _toBytes3(uint24(UNSIGNED_METADATA.length)));
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

    /// @dev Build a single signed data package for one signer
    /// Format: [dataPointValue(32B)][dataPointFeedId(32B)][dataPointCount(3B)]
    ///         [dataPointValueByteSize(4B)][timestampMs(6B)][dataByteSize(2B)][signature(65B)]
    function _buildSignedDataPackage(
        Vm vm_,
        uint256 signerKey,
        uint256 value8dec,
        uint256 timestampSec
    ) private returns (bytes memory) {
        // Data point: value (32 bytes) + feedId (32 bytes) = 64 bytes per data point
        bytes memory dataPointValue = abi.encodePacked(value8dec);
        // Pad to 32 bytes (Redstone data point value is always 32 bytes)
        dataPointValue = _leftPad32(dataPointValue);

        bytes memory dataPointFeedId = abi.encodePacked(DATA_FEED_ID);

        uint256 timestampMs = timestampSec * 1000;

        // data bytes = [dataPointValue(32B)][dataPointFeedId(32B)] = 64 bytes total per data point
        // dataByteSize = total bytes of all data points = dataPointCount * (32 + 32) = 64
        bytes memory dataToSign = bytes.concat(
            dataPointValue,
            dataPointFeedId,
            _toBytes3(1), // dataPointCount = 1
            _toBytes4(32), // dataPointValueByteSize = 32
            _toBytes6(timestampMs) // timestampMilliseconds
        );

        uint256 dataByteSize = 64; // 32 (value) + 32 (feedId) = 64

        // Sign the data bytes with EIP-191 personal sign
        bytes32 messageHash = keccak256(dataToSign);
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        (uint8 v, bytes32 r, bytes32 s) = vm_.sign(signerKey, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Signed data package = [dataToSign][dataByteSize(2B)][signature(65B)]
        return bytes.concat(dataToSign, _toBytes2(uint16(dataByteSize)), signature);
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
