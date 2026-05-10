// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./ForkBaseTest.sol";

/// @title ForkRedstoneFFI
/// @notice Minimal FFI bridge for advisory primary-settlement fork tests.
abstract contract ForkRedstoneFFI is ForkBaseTest {
    function _tryBuildPrimarySettlementCalldata(uint256 marketId)
        internal
        returns (bool ok, bytes memory fullCalldata)
    {
        try this.__buildPrimarySettlementCalldata(marketId) returns (bytes memory data) {
            return (true, data);
        } catch {
            return (false, bytes(""));
        }
    }

    function _trySubmitPrimarySettlementSample(uint256 marketId) internal returns (bool ok) {
        bytes memory fullCalldata;
        (ok, fullCalldata) = _tryBuildPrimarySettlementCalldata(marketId);
        if (!ok) {
            return false;
        }

        (ok,) = address(core).call(fullCalldata);
    }

    function __buildPrimarySettlementCalldata(uint256 marketId) external returns (bytes memory fullCalldata) {
        require(msg.sender == address(this), "ForkRedstoneFFI: self only");

        string[] memory inputs = new string[](5);
        inputs[0] = "./node_modules/.bin/tsx";
        inputs[1] = "scripts/fork/build-redstone-submit-calldata.ts";
        inputs[2] = envName;
        inputs[3] = vm.toString(address(core));
        inputs[4] = vm.toString(marketId);

        bytes memory stdout = vm.ffi(inputs);
        return vm.parseBytes(string(stdout));
    }
}
