// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/SignalsBaseTest.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";
import {SignalsCore} from "../../../../contracts/core/SignalsCore.sol";
import {SignalsPosition} from "../../../../contracts/position/SignalsPosition.sol";
import {SignalsLPShare} from "../../../../contracts/tokens/SignalsLPShare.sol";
import {SignalsDeployer} from "../../../../contracts/deploy/SignalsDeployer.sol";
import {TradeModule} from "../../../../contracts/modules/TradeModule.sol";
import {MarketLifecycleModule} from "../../../../contracts/modules/MarketLifecycleModule.sol";
import {RiskModule} from "../../../../contracts/modules/RiskModule.sol";
import {LPVaultModule} from "../../../../contracts/modules/LPVaultModule.sol";
import {OracleModuleHarness} from "../../../../contracts/testonly/OracleModuleHarness.sol";
import {SignalsUSDToken} from "../../../../contracts/testonly/SignalsUSDToken.sol";
import {MockFeePolicy} from "../../../../contracts/testonly/MockFeePolicy.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/utils/Create2.sol";

/// @title SignalsDeployer Integration Tests
/// @notice Tests deterministic deployment, address verification, and replay protection
///         (3 tests from signalsDeployer.spec.ts)
contract SignalsDeployerTest is SignalsBaseTest {
    address internal owner;
    SignalsUSDToken internal payment;
    TradeModule internal tradeModule;
    MarketLifecycleModule internal lifecycleModule;
    RiskModule internal riskModule;
    LPVaultModule internal vaultModule;
    OracleModuleHarness internal oracleModule;
    SignalsCore internal coreImpl;
    SignalsPosition internal positionImpl;
    SignalsLPShare internal lpShareImpl;
    SignalsDeployer internal deployer;

    bytes32 internal coreSalt;
    bytes32 internal positionSalt;
    bytes32 internal lpShareSalt;

    function setUp() public override {
        super.setUp();
        owner = makeAddr("owner");
        vm.deal(owner, 1 ether);

        payment = new SignalsUSDToken();
        tradeModule = new TradeModule();
        lifecycleModule = new MarketLifecycleModule();
        oracleModule = new OracleModuleHarness();
        riskModule = new RiskModule();
        vaultModule = new LPVaultModule();
        coreImpl = new SignalsCore();
        positionImpl = new SignalsPosition();
        lpShareImpl = new SignalsLPShare();

        vm.prank(owner);
        deployer = new SignalsDeployer(owner);

        coreSalt = keccak256("CORE_PROXY");
        positionSalt = keccak256("POSITION_PROXY");
        lpShareSalt = keccak256("LPSHARE_PROXY");
    }

    function _proxyInitCodeHash(address impl) internal pure returns (bytes32) {
        bytes memory initCode = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(impl, ""));
        return keccak256(initCode);
    }

    function _predictAddresses()
        internal
        view
        returns (address predictedCore, address predictedPosition, address predictedLPShare)
    {
        address deployerAddr = address(deployer);
        predictedCore = Create2.computeAddress(coreSalt, _proxyInitCodeHash(address(coreImpl)), deployerAddr);
        predictedPosition =
            Create2.computeAddress(positionSalt, _proxyInitCodeHash(address(positionImpl)), deployerAddr);
        predictedLPShare = Create2.computeAddress(lpShareSalt, _proxyInitCodeHash(address(lpShareImpl)), deployerAddr);
    }

    function _buildCoreParams(address predictedPosition, address predictedLPShare)
        internal
        view
        returns (SignalsCore.InitParams memory)
    {
        address[] memory ops = new address[](1);
        ops[0] = owner;

        return SignalsCore.InitParams({
            paymentToken: address(payment),
            positionContract: predictedPosition,
            lpShareToken: predictedLPShare,
            tradeModule: address(tradeModule),
            lifecycleModule: address(lifecycleModule),
            riskModule: address(riskModule),
            vaultModule: address(vaultModule),
            oracleModule: address(oracleModule),
            ownerSafe: owner,
            settlementSubmitWindow: 60,
            pendingOpsWindow: 30,
            claimDelaySeconds: 90,
            redstoneFeedId: bytes32("BTC"),
            redstoneFeedDecimals: 8,
            maxSampleDistance: 600,
            futureTolerance: 60,
            lambda: WAD / 10,
            kDrawdown: WAD,
            enforceAlpha: true,
            rhoBS: WAD / 5,
            phiLP: (WAD * 7) / 10,
            phiBS: WAD / 5,
            phiTR: WAD / 10,
            withdrawalLagBatches: 1,
            operatorAllowlist: ops
        });
    }

    function test_deploys_deterministic_proxies_and_initializes_wiring() public {
        (address predictedCore, address predictedPosition, address predictedLPShare) = _predictAddresses();
        SignalsCore.InitParams memory coreParams = _buildCoreParams(predictedPosition, predictedLPShare);

        vm.prank(owner);
        deployer.deployAllDeterministic(
            address(coreImpl),
            address(positionImpl),
            address(lpShareImpl),
            coreSalt,
            positionSalt,
            lpShareSalt,
            predictedCore,
            predictedPosition,
            predictedLPShare,
            coreParams,
            "Signals LP",
            "SIGLP"
        );

        SignalsCore core = SignalsCore(predictedCore);
        SignalsPosition position = SignalsPosition(predictedPosition);
        SignalsLPShare lpShare = SignalsLPShare(predictedLPShare);

        // Verify ownership
        assertEq(core.owner(), owner);
        assertEq(position.owner(), owner);
        assertEq(lpShare.owner(), owner);

        // Verify wiring
        assertEq(address(core.positionContract()), predictedPosition);
        assertEq(core.lpShareToken(), predictedLPShare);
        assertEq(position.core(), predictedCore);
        assertEq(lpShare.core(), predictedCore);
        assertEq(core.tradeModule(), address(tradeModule));
        assertEq(core.lifecycleModule(), address(lifecycleModule));
        assertEq(core.riskModule(), address(riskModule));
        assertEq(core.vaultModule(), address(vaultModule));
        assertEq(core.oracleModule(), address(oracleModule));
        assertTrue(core.operators(owner));
        assertTrue(deployer.executed());
    }

    function test_reverts_when_expected_addresses_mismatch() public {
        (, address predictedPosition, address predictedLPShare) = _predictAddresses();
        SignalsCore.InitParams memory coreParams = _buildCoreParams(predictedPosition, predictedLPShare);

        address badExpected = address(0xdead);
        (address predictedCore2,,) = _predictAddresses();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SE.Create2AddressMismatch.selector, badExpected, predictedCore2));
        deployer.deployAllDeterministic(
            address(coreImpl),
            address(positionImpl),
            address(lpShareImpl),
            coreSalt,
            positionSalt,
            lpShareSalt,
            badExpected,
            predictedPosition,
            predictedLPShare,
            coreParams,
            "Signals LP",
            "SIGLP"
        );
    }

    function test_reverts_on_repeated_deployment() public {
        (address predictedCore, address predictedPosition, address predictedLPShare) = _predictAddresses();
        SignalsCore.InitParams memory coreParams = _buildCoreParams(predictedPosition, predictedLPShare);

        vm.prank(owner);
        deployer.deployAllDeterministic(
            address(coreImpl),
            address(positionImpl),
            address(lpShareImpl),
            coreSalt,
            positionSalt,
            lpShareSalt,
            predictedCore,
            predictedPosition,
            predictedLPShare,
            coreParams,
            "Signals LP",
            "SIGLP"
        );

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SE.DeploymentAlreadyExecuted.selector));
        deployer.deployAllDeterministic(
            address(coreImpl),
            address(positionImpl),
            address(lpShareImpl),
            coreSalt,
            positionSalt,
            lpShareSalt,
            predictedCore,
            predictedPosition,
            predictedLPShare,
            coreParams,
            "Signals LP",
            "SIGLP"
        );
    }
}
