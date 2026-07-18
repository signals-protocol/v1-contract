// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../base/ForkBaseTest.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IGnosisSafe {
    function getOwners() external view returns (address[] memory);
    function nonce() external view returns (uint256);
    function approveHash(bytes32 hashToApprove) external;
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 _nonce
    ) external view returns (bytes32);
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes calldata signatures
    ) external payable returns (bool success);
}

/// @title DecommissionSweepMultiSendTest
/// @notice Manual release-gate test for SIG-820. It executes the exact plan JSON
///         MultiSend calldata through Safe.execTransaction on a latest prod fork.
contract DecommissionSweepMultiSendTest is ForkBaseTest {
    IERC20 internal ctUSD;
    IGnosisSafe internal safe;
    bool internal enabled;

    function setUp() public override {
        envName = vm.envOr("FORK_ENV", string("prod"));
        envJsonPath = string.concat("scripts/environments/", envName, ".json");
        if (_isDevEnv()) return;

        vm.createSelectFork(envName);
        assertEq(block.chainid, 4114, "chain ID mismatch");

        core = SignalsCore(_contractAddr("SignalsCoreProxy"));
        ownerSafe = _requireConfigAddr("owners.core");
        paymentToken = _contractAddr("PaymentToken");
        ctUSD = IERC20(paymentToken);
        safe = IGnosisSafe(ownerSafe);

        enabled = bytes(vm.envOr("DECOMMISSION_SWEEP_PLAN", string(""))).length != 0;
    }

    function test_exact_plan_multisend_sweeps_core_and_restores_vault() public {
        if (!enabled) return;

        string memory planPath = vm.envString("DECOMMISSION_SWEEP_PLAN");
        string memory plan = vm.readFile(planPath);
        address multiSend = _readSafeTarget(plan);
        bytes memory multiSendCalldata = _readSafeCalldata(plan);
        uint8 operation = uint8(_readSafeOperation(plan));
        string memory value = _readSafeValue(plan);

        assertEq(operation, 1, "plan must delegatecall MultiSend");
        assertEq(keccak256(bytes(value)), keccak256(bytes("0")), "plan value must be zero");
        assertEq(multiSend, _configuredMultiSend(), "plan target is not configured MultiSend");
        assertTrue(multiSend.code.length > 0, "MultiSend has no code");
        assertEq(core.owner(), ownerSafe, "core owner changed");

        address originalVault = core.vaultModule();
        uint256 corePre = ctUSD.balanceOf(address(core));
        uint256 safePre = ctUSD.balanceOf(ownerSafe);
        assertGt(corePre, 0, "core has no balance to validate");

        _execSafeTransaction(multiSend, multiSendCalldata, operation);

        assertEq(ctUSD.balanceOf(address(core)), 0, "core balance not swept");
        assertEq(ctUSD.balanceOf(ownerSafe) - safePre, corePre, "safe did not receive core balance");
        assertEq(core.vaultModule(), originalVault, "vault module not restored");
    }

    function _execSafeTransaction(address to, bytes memory data, uint8 operation) internal {
        uint256 value = 0;
        uint256 safeTxGas = 0;
        uint256 baseGas = 0;
        uint256 gasPrice = 0;
        address gasToken = address(0);
        address refundReceiver = address(0);
        uint256 safeNonce = safe.nonce();

        bytes32 txHash = safe.getTransactionHash(
            to, value, data, operation, safeTxGas, baseGas, gasPrice, gasToken, refundReceiver, safeNonce
        );
        address owner = safe.getOwners()[0];
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        safe.approveHash(txHash);

        bytes memory signatures = abi.encodePacked(bytes32(uint256(uint160(owner))), bytes32(0), uint8(1));
        bool success = safe.execTransaction(
            to, value, data, operation, safeTxGas, baseGas, gasPrice, gasToken, payable(refundReceiver), signatures
        );
        assertTrue(success, "Safe execTransaction failed");
    }

    function _readSafeTarget(string memory plan) internal view returns (address) {
        return vm.keyExistsJson(plan, ".safe_args.to")
            ? vm.parseJsonAddress(plan, ".safe_args.to")
            : vm.parseJsonAddress(plan, ".safe.to");
    }

    function _readSafeCalldata(string memory plan) internal view returns (bytes memory) {
        return vm.keyExistsJson(plan, ".safe_args.data")
            ? vm.parseJsonBytes(plan, ".safe_args.data")
            : vm.parseJsonBytes(plan, ".safe.calldata");
    }

    function _readSafeOperation(string memory plan) internal view returns (uint256) {
        return vm.keyExistsJson(plan, ".safe_args.operation")
            ? vm.parseJsonUint(plan, ".safe_args.operation")
            : vm.parseJsonUint(plan, ".safe.operation");
    }

    function _readSafeValue(string memory plan) internal view returns (string memory) {
        return vm.keyExistsJson(plan, ".safe_args.value")
            ? vm.parseJsonString(plan, ".safe_args.value")
            : vm.parseJsonString(plan, ".safe.value");
    }

    function _configuredMultiSend() internal view returns (address) {
        string memory configPath = string.concat("script/config/deploy-", envName, ".json");
        string memory json = vm.readFile(configPath);
        return vm.parseJsonAddress(json, ".safe.multiSendAddress");
    }
}
