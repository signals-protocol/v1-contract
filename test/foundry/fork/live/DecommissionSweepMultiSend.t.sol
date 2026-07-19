// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../base/ForkBaseTest.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/console.sol";
import "../../../../contracts/modules/DecommissionModule.sol";

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
    bytes4 internal constant MULTISEND_SELECTOR = bytes4(keccak256("multiSend(bytes)"));
    uint8 internal constant CALL_OPERATION = 0;
    uint8 internal constant DELEGATECALL_OPERATION = 1;
    uint256 internal constant MULTISEND_TX_HEADER_LENGTH = 85;
    uint256 internal constant TOTAL_PENDING_DEPOSITS_SLOT = 34;
    uint256 internal constant TOTAL_PAYOUT_RESERVE_SLOT = 35;
    uint256 internal constant TOTAL_PENDING_WITHDRAWALS_SLOT = 36;

    IERC20 internal ctUSD;
    IGnosisSafe internal safe;
    bool internal enabled;

    struct ModulePointers {
        address trade;
        address lifecycle;
        address risk;
        address vault;
        address oracle;
    }

    struct MultiSendTx {
        uint8 operation;
        address to;
        uint256 value;
        bytes data;
    }

    struct WaivedLiabilities {
        uint256 totalPendingDeposits6;
        uint256 totalPayoutReserve6;
        uint256 totalPendingWithdrawals6;
        uint256 totalReservedLiabilities6;
        uint256 corePaymentTokenBalance6;
    }

    struct CriticalStorageSnapshot {
        address owner;
        bool[] operatorAllowed;
        uint256 totalPendingDeposits6;
        uint256 totalPayoutReserve6;
        uint256 totalPendingWithdrawals6;
    }

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
        // Manual release gate: reports as SKIPPED (not PASSED) in CI when no plan is provided,
        // so the baseline suite never masquerades this as real coverage.
        if (!enabled) {
            vm.skip(true);
            return;
        }

        string memory planPath = vm.envString("DECOMMISSION_SWEEP_PLAN");
        string memory plan = vm.readFile(planPath);
        address multiSend = _readSafeTarget(plan);
        bytes memory multiSendCalldata = _readSafeCalldata(plan);
        uint8 operation = uint8(_readSafeOperation(plan));
        string memory value = _readSafeValue(plan);
        address decommissionModule = _contractAddr("DecommissionModule");
        address[] memory operators = _operatorAllowlist();

        assertEq(operation, DELEGATECALL_OPERATION, "plan must delegatecall MultiSend");
        assertEq(keccak256(bytes(value)), keccak256(bytes("0")), "plan value must be zero");
        assertEq(multiSend, _configuredMultiSend(), "plan target is not configured MultiSend");
        assertTrue(multiSend.code.length > 0, "MultiSend has no code");
        assertTrue(decommissionModule.code.length > 0, "DecommissionModule has no code");
        DecommissionModule referenceModule = new DecommissionModule(paymentToken);
        assertEq(
            decommissionModule.codehash, address(referenceModule).codehash, "DecommissionModule runtime hash mismatch"
        );
        assertEq(core.owner(), ownerSafe, "core owner changed");
        assertFalse(core.paused(), "core is already paused; pause subtransaction would revert");

        ModulePointers memory originalModules = _readModules();
        WaivedLiabilities memory planLiabilities = _readPlanWaivedLiabilities(plan);
        uint256 disclosedBalance = planLiabilities.corePaymentTokenBalance6;
        _assertMultiSendPayloadShape(
            multiSendCalldata, decommissionModule, originalModules, disclosedBalance, operators
        );
        _assertWaivedLiabilitiesCurrent(plan);

        // The amount signers approve is the balance disclosed in the plan's waiver.
        uint256 corePre = ctUSD.balanceOf(address(core));
        uint256 safePre = ctUSD.balanceOf(ownerSafe);
        assertGt(corePre, 0, "core has no balance to validate");
        assertEq(corePre, disclosedBalance, "live core balance differs from disclosed waiver balance");
        CriticalStorageSnapshot memory criticalBefore = _readCriticalStorageSnapshot(operators);

        _execSafeTransaction(multiSend, multiSendCalldata, operation);

        uint256 swept = ctUSD.balanceOf(ownerSafe) - safePre;
        assertEq(ctUSD.balanceOf(address(core)), 0, "core balance not swept");
        assertEq(swept, corePre, "safe did not receive core balance");
        // Enforce that exactly the disclosed/signed amount was swept, nothing more.
        assertEq(swept, disclosedBalance, "swept amount differs from the disclosed signed balance");
        _assertModulesRestored(originalModules);
        _assertCriticalStorageAfter(criticalBefore, operators);
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

    function _assertWaivedLiabilitiesCurrent(string memory plan) internal view {
        WaivedLiabilities memory recorded = _readPlanWaivedLiabilities(plan);
        WaivedLiabilities memory current = _readCurrentWaivedLiabilities();

        console.log("SIG-820 waived liabilities from live fork:");
        console.log("_totalPendingDeposits6 slot 34: %s", current.totalPendingDeposits6);
        console.log("_totalPayoutReserve6 slot 35: %s", current.totalPayoutReserve6);
        console.log("_totalPendingWithdrawals6 slot 36: %s", current.totalPendingWithdrawals6);
        console.log("total reserved liabilities: %s", current.totalReservedLiabilities6);
        console.log("Core payment-token balance: %s", current.corePaymentTokenBalance6);

        assertEq(current.totalPendingDeposits6, recorded.totalPendingDeposits6, "stale pending deposits waiver");
        assertEq(current.totalPayoutReserve6, recorded.totalPayoutReserve6, "stale payout reserve waiver");
        assertEq(
            current.totalPendingWithdrawals6, recorded.totalPendingWithdrawals6, "stale pending withdrawals waiver"
        );
        assertEq(
            current.totalReservedLiabilities6, recorded.totalReservedLiabilities6, "stale reserved-liability total"
        );
        assertEq(
            current.corePaymentTokenBalance6, recorded.corePaymentTokenBalance6, "stale Core payment-token balance"
        );
    }

    function _readPlanWaivedLiabilities(string memory plan)
        internal
        view
        returns (WaivedLiabilities memory liabilities)
    {
        require(vm.keyExistsJson(plan, ".waivedLiabilities.totalPendingDeposits6"), "plan missing waived liabilities");
        liabilities.totalPendingDeposits6 = vm.parseJsonUint(plan, ".waivedLiabilities.totalPendingDeposits6");
        liabilities.totalPayoutReserve6 = vm.parseJsonUint(plan, ".waivedLiabilities.totalPayoutReserve6");
        liabilities.totalPendingWithdrawals6 = vm.parseJsonUint(plan, ".waivedLiabilities.totalPendingWithdrawals6");
        liabilities.totalReservedLiabilities6 = vm.parseJsonUint(plan, ".waivedLiabilities.totalReservedLiabilities6");
        liabilities.corePaymentTokenBalance6 = vm.parseJsonUint(plan, ".waivedLiabilities.corePaymentTokenBalance6");

        uint256 expectedTotal =
            liabilities.totalPendingDeposits6 + liabilities.totalPayoutReserve6 + liabilities.totalPendingWithdrawals6;
        assertEq(liabilities.totalReservedLiabilities6, expectedTotal, "plan reserved-liability total mismatch");
    }

    function _readCurrentWaivedLiabilities() internal view returns (WaivedLiabilities memory liabilities) {
        liabilities.totalPendingDeposits6 = _readStorageUint(TOTAL_PENDING_DEPOSITS_SLOT);
        liabilities.totalPayoutReserve6 = _readStorageUint(TOTAL_PAYOUT_RESERVE_SLOT);
        liabilities.totalPendingWithdrawals6 = _readStorageUint(TOTAL_PENDING_WITHDRAWALS_SLOT);
        liabilities.totalReservedLiabilities6 =
            liabilities.totalPendingDeposits6 + liabilities.totalPayoutReserve6 + liabilities.totalPendingWithdrawals6;
        liabilities.corePaymentTokenBalance6 = ctUSD.balanceOf(address(core));
    }

    function _readStorageUint(uint256 slot) internal view returns (uint256) {
        return uint256(vm.load(address(core), bytes32(slot)));
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

    function _operatorAllowlist() internal view returns (address[] memory) {
        string memory json = _loadEnvJson();
        string memory path = ".config.operatorAllowlist";
        if (!vm.keyExistsJson(json, path)) return new address[](0);
        return vm.parseJsonAddressArray(json, path);
    }

    function _readModules() internal view returns (ModulePointers memory modules) {
        modules.trade = core.tradeModule();
        modules.lifecycle = core.lifecycleModule();
        modules.risk = core.riskModule();
        modules.vault = core.vaultModule();
        modules.oracle = core.oracleModule();
    }

    function _assertModulesRestored(ModulePointers memory expected) internal view {
        assertEq(core.tradeModule(), expected.trade, "trade module not restored");
        assertEq(core.lifecycleModule(), expected.lifecycle, "lifecycle module not restored");
        assertEq(core.riskModule(), expected.risk, "risk module not restored");
        assertEq(core.vaultModule(), expected.vault, "vault module not restored");
        assertEq(core.oracleModule(), expected.oracle, "oracle module not restored");
    }

    function _readCriticalStorageSnapshot(address[] memory operators)
        internal
        view
        returns (CriticalStorageSnapshot memory snapshot)
    {
        snapshot.owner = core.owner();
        snapshot.operatorAllowed = new bool[](operators.length);
        for (uint256 i = 0; i < operators.length; i++) {
            snapshot.operatorAllowed[i] = core.operators(operators[i]);
        }
        snapshot.totalPendingDeposits6 = _readStorageUint(TOTAL_PENDING_DEPOSITS_SLOT);
        snapshot.totalPayoutReserve6 = _readStorageUint(TOTAL_PAYOUT_RESERVE_SLOT);
        snapshot.totalPendingWithdrawals6 = _readStorageUint(TOTAL_PENDING_WITHDRAWALS_SLOT);
    }

    function _assertCriticalStorageAfter(CriticalStorageSnapshot memory expected, address[] memory operators)
        internal
        view
    {
        assertEq(core.owner(), expected.owner, "core owner changed during sweep");
        assertEq(expected.operatorAllowed.length, operators.length, "operator snapshot length changed");
        assertEq(
            _readStorageUint(TOTAL_PENDING_DEPOSITS_SLOT),
            expected.totalPendingDeposits6,
            "pending deposits slot changed"
        );
        assertEq(
            _readStorageUint(TOTAL_PAYOUT_RESERVE_SLOT), expected.totalPayoutReserve6, "payout reserve slot changed"
        );
        assertEq(
            _readStorageUint(TOTAL_PENDING_WITHDRAWALS_SLOT),
            expected.totalPendingWithdrawals6,
            "pending withdrawals slot changed"
        );
        assertTrue(core.paused(), "core should be paused after sweep");
        for (uint256 i = 0; i < operators.length; i++) {
            assertFalse(core.operators(operators[i]), "operator should be revoked after sweep");
        }
    }

    function _assertMultiSendPayloadShape(
        bytes memory multiSendCalldata,
        address decommissionModule,
        ModulePointers memory modules,
        uint256 maxBalance,
        address[] memory operators
    ) internal view {
        bytes memory packedTransactions = _decodeMultiSendPayload(multiSendCalldata);
        uint256 offset;

        MultiSendTx memory pauseTx;
        (pauseTx, offset) = _decodeMultiSendTx(packedTransactions, offset);
        _assertSubTransaction(pauseTx, abi.encodeCall(SignalsCore.pause, ()), "pause");

        for (uint256 i = 0; i < operators.length; i++) {
            MultiSendTx memory revokeOperatorTx;
            (revokeOperatorTx, offset) = _decodeMultiSendTx(packedTransactions, offset);
            _assertSubTransaction(
                revokeOperatorTx, abi.encodeCall(SignalsCore.setOperator, (operators[i], false)), "revoke operator"
            );
        }

        MultiSendTx memory setDecommissionTx;
        (setDecommissionTx, offset) = _decodeMultiSendTx(packedTransactions, offset);
        _assertSubTransaction(
            setDecommissionTx,
            abi.encodeCall(
                SignalsCore.setModules,
                (modules.trade, modules.lifecycle, modules.risk, decommissionModule, modules.oracle)
            ),
            "set decommission"
        );

        MultiSendTx memory withdrawTreasuryTx;
        (withdrawTreasuryTx, offset) = _decodeMultiSendTx(packedTransactions, offset);
        _assertSubTransaction(
            withdrawTreasuryTx, abi.encodeCall(SignalsCore.withdrawTreasury, (maxBalance)), "withdraw treasury"
        );

        MultiSendTx memory restoreVaultTx;
        (restoreVaultTx, offset) = _decodeMultiSendTx(packedTransactions, offset);
        _assertSubTransaction(
            restoreVaultTx,
            abi.encodeCall(
                SignalsCore.setModules, (modules.trade, modules.lifecycle, modules.risk, modules.vault, modules.oracle)
            ),
            "restore vault"
        );

        assertEq(offset, packedTransactions.length, "unexpected MultiSend subtransaction count");
    }

    function _assertSubTransaction(MultiSendTx memory transaction, bytes memory expectedData, string memory label)
        internal
        view
    {
        assertEq(transaction.operation, CALL_OPERATION, string.concat(label, " operation"));
        assertEq(transaction.to, address(core), string.concat(label, " target"));
        assertEq(transaction.value, 0, string.concat(label, " value"));
        assertEq(transaction.data, expectedData, string.concat(label, " data"));
    }

    function _decodeMultiSendPayload(bytes memory multiSendCalldata) internal pure returns (bytes memory) {
        assertEq(_readSelector(multiSendCalldata), MULTISEND_SELECTOR, "plan data must call multiSend(bytes)");
        return abi.decode(_slice(multiSendCalldata, 4, multiSendCalldata.length - 4), (bytes));
    }

    function _decodeMultiSendTx(bytes memory packedTransactions, uint256 offset)
        internal
        pure
        returns (MultiSendTx memory transaction, uint256 nextOffset)
    {
        require(
            packedTransactions.length >= offset + MULTISEND_TX_HEADER_LENGTH,
            "MultiSend subtransaction header truncated"
        );

        transaction.operation = uint8(packedTransactions[offset]);
        transaction.to = _readAddress(packedTransactions, offset + 1);
        transaction.value = _readUint256(packedTransactions, offset + 21);
        uint256 dataLength = _readUint256(packedTransactions, offset + 53);
        uint256 dataOffset = offset + MULTISEND_TX_HEADER_LENGTH;

        require(packedTransactions.length >= dataOffset + dataLength, "MultiSend subtransaction data truncated");
        transaction.data = _slice(packedTransactions, dataOffset, dataLength);
        nextOffset = dataOffset + dataLength;
    }

    function _readSelector(bytes memory data) internal pure returns (bytes4 selector) {
        require(data.length >= 4, "calldata selector truncated");
        assembly {
            selector := mload(add(data, 32))
        }
    }

    function _readAddress(bytes memory data, uint256 offset) internal pure returns (address) {
        require(data.length >= offset + 20, "address read out of bounds");

        uint160 value;
        for (uint256 i = 0; i < 20; i++) {
            value = (value << 8) | uint160(uint8(data[offset + i]));
        }
        return address(value);
    }

    function _readUint256(bytes memory data, uint256 offset) internal pure returns (uint256 value) {
        require(data.length >= offset + 32, "uint256 read out of bounds");

        for (uint256 i = 0; i < 32; i++) {
            value = (value << 8) | uint256(uint8(data[offset + i]));
        }
    }

    function _slice(bytes memory data, uint256 offset, uint256 length) internal pure returns (bytes memory result) {
        require(data.length >= offset + length, "slice out of bounds");

        result = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            result[i] = data[offset + i];
        }
    }
}
