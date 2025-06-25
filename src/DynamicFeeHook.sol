// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Imports from Uniswap V4 periphery and core libraries
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ERC1155} from "solmate/src/tokens/ERC1155.sol";

import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SqrtPriceLibrary} from "./SqrtPriceLibrary.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IOracle} from "./IOracle.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

// Hook contract that dynamically adjusts the LP fee based on price deviation from an oracle
contract DynamicFeeHook is BaseHook {
    using LPFeeLibrary for uint24;

    IOracle public oracle;
    address public owner;

    // Maximum and minimum fee in basis points (bps)
    uint24 public constant MAX_FEE_BPS = 10000; // 1%
    uint24 public constant MIN_FEE_BPS = 100; // 0.01%

    event DynamicFeeApplied(uint24 fee);

    /// Error triggered if the pool is not using a dynamic fee
    error MustUseDynamicFee();

    constructor(IPoolManager _manager, IOracle _oracle) BaseHook(_manager) {
        oracle = _oracle;
        owner = msg.sender;
    }

    /// @notice Enforces that the pool must use dynamic fees at initialization
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal pure override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return this.beforeInitialize.selector;
    }

    /// @notice Allows the owner to update the oracle address
    // Should be immutable to respect the "Uniswap view"
    function setOracle(address _oracle) external {
        require(msg.sender == owner, "Not owner");
        oracle = IOracle(_oracle);
    }

    /// @notice Applies the dynamic fee before each swap
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Get current pool state
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, key.toId());

        // Convert oracle price to sqrtPriceX96 format
        uint160 referenceSqrtPriceX96 = _getReferencePriceX96(key.currency0, key.currency1);

        // Compute new LP fee based on deviation
        uint24 newFee = _calculateDynamicFee(params.zeroForOne, sqrtPriceX96, referenceSqrtPriceX96);

        // Emit debugging information
        emit DynamicFeeApplied(newFee);

        // Apply the new dynamic fee
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, newFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @notice Computes the dynamic fee using a quadratic function based on deviation and swap direction
    function _calculateDynamicFee(bool zeroForOne, uint160 poolSqrtPriceX96, uint160 referenceSqrtPriceX96)
        internal
        pure
        returns (uint24)
    {
        uint256 absPercentageDiffWad =
            SqrtPriceLibrary.absPercentageDifferenceWad(poolSqrtPriceX96, referenceSqrtPriceX96);

        bool isConverging =
            zeroForOne ? poolSqrtPriceX96 > referenceSqrtPriceX96 : poolSqrtPriceX96 < referenceSqrtPriceX96;

        if (!isConverging) {
            return MIN_FEE_BPS;
        }

        uint256 threshold = 0.02e18;

        if (absPercentageDiffWad >= threshold) {
            return MAX_FEE_BPS;
        }

        if (absPercentageDiffWad < 0.0001e18) {
            return MIN_FEE_BPS;
        }

        uint256 ratioWad = (absPercentageDiffWad * 1e18) / threshold;
        uint256 factor = (ratioWad * ratioWad) / 1e18;
        uint256 feeDelta = (factor * (MAX_FEE_BPS - MIN_FEE_BPS)) / 1e18;
        uint24 dynamicFee = uint24(MIN_FEE_BPS + feeDelta);

        // safety check
        assert(dynamicFee >= MIN_FEE_BPS && dynamicFee <= MAX_FEE_BPS);

        return dynamicFee;
    }

    /// @notice Converts the oracle price to sqrtPriceX96 format
    function _getReferencePriceX96(Currency, Currency) internal returns (uint160) {
        (, int256 rate,,,) = oracle.latestRoundData();
        return SqrtPriceLibrary.exchangeRateToSqrtPriceX96(uint256(rate));
    }

    /// @notice Converts sqrtPriceX96 back to price with 18 decimals
    function _getPriceFromSqrtX96(uint160 sqrtPriceX96) internal pure returns (uint256 price) {
        uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        price = (ratioX192 * 1e18) >> 192;
    }

    /// @notice Declares which hooks this contract implements
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
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
}
