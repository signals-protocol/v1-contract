// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseScript} from "../base/BaseScript.s.sol";
import {SignalsCore} from "../../contracts/core/SignalsCore.sol";
import {ISignalsCore} from "../../contracts/interfaces/ISignalsCore.sol";
import {RiskModule} from "../../contracts/modules/RiskModule.sol";
import {SeedData} from "../../contracts/utils/SeedData.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {console} from "forge-std/console.sol";

/// @title CreateMarket — Full market creation: config + fund + create + seed
/// @notice Reads config from script/config/market-{env}.json
/// @dev Config TXs (setWithdrawalLagBatches, setRiskConfig, etc.) are onlyOwner.
///      Only works when caller IS the owner (initial setup / local).
///      For prod/dev with Safe owner, use Safe TX for config, then this script for market ops only.
contract CreateMarket is BaseScript {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BATCH_SECONDS = 86400;
    uint256 internal constant BATCH_TIMEZONE_OFFSET = 8 * 3600;

    function run() external {
        _enforceChainId();

        address coreProxy = _contractAddr("SignalsCoreProxy");
        address paymentAddr = _contractAddr("PaymentToken");
        SignalsCore core = SignalsCore(coreProxy);

        require(IERC20Metadata(paymentAddr).decimals() == 6, "Payment token must have 6 decimals");

        string memory configPath = string.concat("script/config/market-", envName, ".json");
        string memory json = vm.readFile(configPath);

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // Parse config
        address feePolicyAddress = vm.parseJsonAddress(json, ".feePolicyAddress");
        require(feePolicyAddress != address(0), "feePolicyAddress required");

        bool skipConfig = vm.parseJsonBool(json, ".skipConfig");

        vm.startBroadcast(deployerKey);

        // ── Step 1-5: Config TXs (only if skipConfig=false) ─────────────
        if (!skipConfig) {
            uint64 withdrawalLag = uint64(vm.parseJsonUint(json, ".vault.withdrawalLagBatches"));
            core.setWithdrawalLagBatches(withdrawalLag);

            uint256 lambdaWad = _parseWad(json, ".risk.lambda");
            uint256 kDrawdownWad = _parseWad(json, ".risk.kDrawdown");
            bool enforceAlpha = vm.parseJsonBool(json, ".risk.enforceAlpha");
            core.setRiskConfig(lambdaWad, kDrawdownWad, enforceAlpha);

            core.setFeeWaterfallConfig(
                _parseWad(json, ".feeWaterfall.rhoBS"),
                _parseWad(json, ".feeWaterfall.phiLP"),
                _parseWad(json, ".feeWaterfall.phiBS"),
                _parseWad(json, ".feeWaterfall.phiTR")
            );

            uint64 submitWindow = uint64(vm.parseJsonUint(json, ".settlement.submitWindowSec"));
            uint64 pendingOps = uint64(vm.parseJsonUint(json, ".settlement.pendingOpsWindowSec"));
            uint64 claimDelay = uint64(vm.parseJsonUint(json, ".settlement.claimDelaySec"));
            core.setSettlementTimeline(submitWindow, pendingOps, claimDelay);

            string memory feedId = vm.parseJsonString(json, ".redstone.feedId");
            uint8 feedDecimals = uint8(vm.parseJsonUint(json, ".redstone.feedDecimals"));
            uint64 maxSampleDist = uint64(vm.parseJsonUint(json, ".redstone.maxSampleDistanceSec"));
            uint64 futureTol = uint64(vm.parseJsonUint(json, ".redstone.futureToleranceSec"));
            core.setRedstoneConfig(_toBytes32(feedId), feedDecimals, maxSampleDist, futureTol);
        }

        // ── Step 6-9: Funding ───────────────────────────────────────────
        uint256 seedAmount6 = vm.parseJsonUint(json, ".vault.seedAmountUsd") * 1e6;
        uint256 backstopAmount6 = vm.parseJsonUint(json, ".capitalStack.backstopNavUsd") * 1e6;
        uint256 treasuryAmount6 = vm.parseJsonUint(json, ".capitalStack.treasuryNavUsd") * 1e6;

        uint256 requiredAllowance = seedAmount6 + backstopAmount6 + treasuryAmount6;
        if (requiredAllowance > 0) {
            uint256 allowance = IERC20(paymentAddr).allowance(deployer, coreProxy);
            if (allowance < requiredAllowance) {
                IERC20(paymentAddr).approve(coreProxy, requiredAllowance);
            }
        }

        if (backstopAmount6 > 0) {
            core.fundBackstop(backstopAmount6);
        }
        if (treasuryAmount6 > 0) {
            core.fundTreasury(treasuryAmount6);
        }

        bool seeded = core.isVaultSeeded();
        if (!seeded && seedAmount6 > 0) {
            core.seedVault(seedAmount6);
        }

        // ── Step 10: Compute alpha ──────────────────────────────────────
        int256 minTick = vm.parseJsonInt(json, ".market.minTick");
        int256 maxTick = vm.parseJsonInt(json, ".market.maxTick");
        int256 tickSpacing = vm.parseJsonInt(json, ".market.tickSpacing");
        uint32 numBins = uint32(uint256((maxTick - minTick) / tickSpacing));
        require(numBins > 0 && (maxTick - minTick) % tickSpacing == 0, "Invalid ticks");

        string memory liquidityMode = vm.parseJsonString(json, ".market.liquidity.mode");
        uint256 alphaWad;

        if (keccak256(bytes(liquidityMode)) == keccak256("manual")) {
            alphaWad = vm.parseJsonUint(json, ".market.liquidity.manualAlphaWad");
            require(alphaWad > 0, "manualAlphaWad required for manual mode");
        } else {
            // Auto mode: compute from risk params
            uint256 navWad = core.getVaultNav();
            if (navWad == 0) navWad = seedAmount6 * 1e12; // scale 6→18
            uint256 drawdownWad = core.getVaultDrawdown();
            (uint256 lambdaOnChain, uint256 kDrawdownOnChain, bool enforceAlphaOnChain) = core.getRiskConfig();
            address riskModuleAddr = core.riskModule();
            RiskModule rm = RiskModule(riskModuleAddr);
            uint256 lnN = rm.lnWad(numBins);
            require(lnN > 0, "lnN returned zero");

            uint256 alphaBase = (lambdaOnChain * navWad) / WAD;
            uint256 alphaBaseDiv = (alphaBase * WAD) / lnN;
            uint256 alphaLimit = alphaBaseDiv;

            if (enforceAlphaOnChain) {
                uint256 kDD = (kDrawdownOnChain * drawdownWad) / WAD;
                uint256 factor = kDD >= WAD ? 0 : WAD - kDD;
                alphaLimit = (alphaBaseDiv * factor) / WAD;
            }

            uint256 safetyFactorWad = _parseWad(json, ".market.liquidity.safetyFactor");
            alphaWad = (alphaLimit * safetyFactorWad) / WAD;
            require(alphaWad > 0, "alphaWad computed as zero");
        }

        // ── Step 11: Deploy SeedData ────────────────────────────────────
        string memory baseFactorsMode = vm.parseJsonString(json, ".market.baseFactors.mode");
        bytes memory packedFactors;

        if (keccak256(bytes(baseFactorsMode)) == keccak256("custom")) {
            uint256[] memory customFactors = vm.parseJsonUintArray(json, ".market.baseFactors.customWad");
            require(customFactors.length == numBins, "baseFactors length mismatch");
            packedFactors = abi.encodePacked(customFactors);
        } else {
            // Uniform: all WAD
            uint256[] memory factors = new uint256[](numBins);
            for (uint256 i = 0; i < numBins; i++) {
                factors[i] = WAD;
            }
            packedFactors = abi.encodePacked(factors);
        }

        SeedData seedData = new SeedData(packedFactors);

        // ── Step 12: Timing ─────────────────────────────────────────────
        uint256 startDelaySec = vm.parseJsonUint(json, ".market.startDelaySec");
        uint256 durationSec = vm.parseJsonUint(json, ".market.durationSec");
        uint256 settlementDelaySec = vm.parseJsonUint(json, ".market.settlementDelaySec");

        uint64 startTimestamp = uint64(block.timestamp + startDelaySec);
        uint64 endTimestamp = uint64(uint256(startTimestamp) + durationSec);
        uint64 settlementTimestamp = uint64(uint256(endTimestamp) + settlementDelaySec);

        // ── Step 13: Create market ──────────────────────────────────────
        uint256 marketId = core.createMarket(
            minTick,
            maxTick,
            tickSpacing,
            startTimestamp,
            endTimestamp,
            settlementTimestamp,
            numBins,
            alphaWad,
            feePolicyAddress,
            address(seedData)
        );

        console.log("[create-market] marketId=%s", marketId);

        // ── Step 14: Seed chunks ────────────────────────────────────────
        uint32 seedChunkSize = uint32(vm.parseJsonUint(json, ".market.seedChunkSize"));
        if (seedChunkSize == 0) seedChunkSize = 50;

        uint32 remaining = numBins;
        while (remaining > 0) {
            uint32 count = remaining > seedChunkSize ? seedChunkSize : remaining;
            console.log("[create-market] seeding chunk count=%s remaining=%s", count, remaining);
            core.seedNextChunks(marketId, count);
            remaining -= count;
        }

        vm.stopBroadcast();

        // ── Write output ────────────────────────────────────────────────
        string memory root = vm.serializeString("root", "action", "create-market");
        root = vm.serializeUint("root", "marketId", marketId);
        root = vm.serializeAddress("root", "deployer", deployer);
        _writeOutput("create-market", root);
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    function _parseWad(string memory json, string memory key) internal pure returns (uint256) {
        string memory value = vm.parseJsonString(json, key);
        return _parseDecimalToWad(value);
    }

    function _parseDecimalToWad(string memory value) internal pure returns (uint256) {
        bytes memory b = bytes(value);
        uint256 dotIndex = type(uint256).max;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ".") {
                dotIndex = i;
                break;
            }
        }
        if (dotIndex == type(uint256).max) return vm.parseUint(value) * 1e18;

        uint256 intPart = 0;
        if (dotIndex > 0) {
            bytes memory intBytes = new bytes(dotIndex);
            for (uint256 i = 0; i < dotIndex; i++) intBytes[i] = b[i];
            intPart = vm.parseUint(string(intBytes));
        }

        uint256 fracLen = b.length - dotIndex - 1;
        uint256 fracPart = 0;
        if (fracLen > 0) {
            bytes memory fracBytes = new bytes(fracLen);
            for (uint256 i = 0; i < fracLen; i++) fracBytes[i] = b[dotIndex + 1 + i];
            fracPart = vm.parseUint(string(fracBytes));
        }

        require(fracLen <= 18, "Too many decimal places (max 18)");
        return intPart * 1e18 + fracPart * (10 ** (18 - fracLen));
    }
}
