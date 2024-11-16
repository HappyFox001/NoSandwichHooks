// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";

contract NoSandwichHooks is BaseHook {
    using PoolIdLibrary for PoolKey;

    mapping(address => uint256) public baseContributions;
    mapping(address => uint256) public quoteContributions;
    address[] public baseCurrencyContributors;
    address[] public quoteCurrencyContributors;
    uint256 baseCurrencyReserve;
    uint256 quoteCurrencyReserve;
    uint256 public lastSettlementTimestamp;
    uint256 public constant settlementInterval = 60;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        lastSettlementTimestamp = block.timestamp;
        quoteCurrencyReserve = 0;
        baseCurrencyReserve = 0;
        emit ContractDeployed(block.timestamp);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (params.amountSpecified > 0) {
            if (params.zeroForOne) {
                if (baseContributions[sender] == 0) {
                    baseCurrencyContributors.push(sender);
                }
                baseContributions[sender] += uint256(params.amountSpecified);
            } else {
                if (quoteContributions[sender] == 0) {
                    quoteCurrencyContributors.push(sender);
                }
                quoteContributions[sender] += uint256(params.amountSpecified);
            }
        }

        emit BeforeSwap(sender, params.amountSpecified, params.zeroForOne);

        if (block.timestamp - lastSettlementTimestamp >= settlementInterval) {
            _settleAndDistribute(key.currency0, key.currency1);
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _settleAndDistribute(Currency baseCurrency, Currency quoteCurrency) internal {
        uint256 totalBaseContribution = 0;
        uint256 totalQuoteContribution = 0;

        for (uint256 i = 0; i < baseCurrencyContributors.length; i++) {
            totalBaseContribution += baseContributions[baseCurrencyContributors[i]];
        }
        for (uint256 i = 0; i < quoteCurrencyContributors.length; i++) {
            totalQuoteContribution += quoteContributions[quoteCurrencyContributors[i]];
        }

        uint256 k = baseCurrencyReserve * quoteCurrencyReserve;
        uint256 x2m = sqrt(k + 2 * sqrt(k) * (totalBaseContribution - totalQuoteContribution));
        uint256 y2m = k / x2m;

        uint256 baseOut = baseCurrencyReserve + totalBaseContribution - x2m;
        uint256 quoteOut = quoteCurrencyReserve + totalQuoteContribution - y2m;

        baseCurrencyReserve = x2m;
        quoteCurrencyReserve = y2m;

        for (uint256 i = 0; i < baseCurrencyContributors.length; i++) {
            address contributor = baseCurrencyContributors[i];
            uint256 contribution = baseContributions[contributor];
            uint256 payout = (quoteOut * contribution) / totalBaseContribution;
            CurrencyLibrary.transfer(quoteCurrency, contributor, payout);
        }

        for (uint256 i = 0; i < quoteCurrencyContributors.length; i++) {
            address contributor = quoteCurrencyContributors[i];
            uint256 contribution = quoteContributions[contributor];
            uint256 payout = (baseOut * contribution) / totalQuoteContribution;
            CurrencyLibrary.transfer(baseCurrency, contributor, payout);
        }

        for (uint256 i = 0; i < baseCurrencyContributors.length; i++) {
            baseContributions[baseCurrencyContributors[i]] = 0;
        }
        for (uint256 i = 0; i < quoteCurrencyContributors.length; i++) {
            quoteContributions[quoteCurrencyContributors[i]] = 0;
        }
        baseCurrencyContributors = new address[](0);
        quoteCurrencyContributors = new address;
        lastSettlementTimestamp = block.timestamp;

        emit SettlementPerformed(baseOut, quoteOut, block.timestamp);
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta principalDelta,
        BalanceDelta feeDelta,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        int256 deltaBase = principalDelta.amount0() + feeDelta.amount0();
        int256 deltaQuote = principalDelta.amount1() + feeDelta.amount1();

        if (deltaBase > 0) {
            baseCurrencyReserve += uint256(deltaBase);
        } else if (deltaBase < 0) {
            baseCurrencyReserve -= uint256(-deltaBase);
        }

        if (deltaQuote > 0) {
            quoteCurrencyReserve += uint256(deltaQuote);
        } else if (deltaQuote < 0) {
            quoteCurrencyReserve -= uint256(-deltaQuote);
        }

        emit AfterAddLiquidity(deltaBase, deltaQuote);

        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta principalDelta,
        BalanceDelta feeDelta,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        int256 deltaBase = principalDelta.amount0() + feeDelta.amount0();
        int256 deltaQuote = principalDelta.amount1() + feeDelta.amount1();

        if (deltaBase < 0) {
            baseCurrencyReserve -= uint256(-deltaBase);
        }

        if (deltaQuote < 0) {
            quoteCurrencyReserve -= uint256(-deltaQuote);
        }

        emit AfterRemoveLiquidity(deltaBase, deltaQuote);

        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    event ContractDeployed(uint256 timestamp);
    event BeforeSwap(address sender, int256 amountSpecified, bool zeroForOne);
    event SettlementPerformed(uint256 baseOut, uint256 quoteOut, uint256 timestamp);
    event AfterAddLiquidity(int256 deltaBase, int256 deltaQuote);
    event AfterRemoveLiquidity(int256 deltaBase, int256 deltaQuote);

    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
}
