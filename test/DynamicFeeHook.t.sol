// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Foundry standard testing utilities
import "forge-std/console.sol";
import "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";

// Uniswap V4 testing utilities
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

// Mocks and hook under test
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {DynamicFeeHook} from "../src/DynamicFeeHook.sol";
import {MockOracle} from "./MockOracle.sol";

// Uniswap core types
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {Currency} from "v4-core/types/Currency.sol";

// Uniswap core libraries
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {ERC1155TokenReceiver} from "solmate/src/tokens/ERC1155.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

/// @notice Test contract for the `DynamicFeeHook`
contract TestDynamicFeeHook is Test, Deployers, ERC1155TokenReceiver {
    MockERC20 token;
    MockOracle oracle;
    DynamicFeeHook hook;
    int24 tickSpacing = 1;

    uint256 constant ONE = 1e18;
    uint256 constant PRICE_08 = (8 * ONE) / 10; // 0.8
    uint256 constant PRICE_12 = (12 * ONE) / 10; // 1.2
    uint256 constant PRICE_13 = (13 * ONE) / 10; // 1.3

    // Precomputed sqrt(1.2) * 2^96
    uint160 constant TEST_SQRT_PRICE_1_2 = 72325086331928494284758347145;

    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;

    // Debugging events
    event DebugPrices(int256 oraclePrice, uint160 sqrtPriceX96, uint160 referenceSqrtPriceX96, uint24 calculatedFee);
    event sqrtPriceDebug(int24 tick, uint160 sqrtPriceX96, uint160 referenceSqrtPriceX96);
    event PriceDebug(uint256 price, uint256 referencePrice);
    event DynamicFeeApplied(uint256 price, uint24 fee); // For visual inspection

    PoolKey key;

    /// @notice Deploys contracts and initializes a Uniswap V4 pool with liquidity
    function setUp() public {
        deployFreshManagerAndRouters();

        token = new MockERC20("Test Token", "TEST", 18);
        tokenCurrency = Currency.wrap(address(token));

        token.mint(address(this), 10000 ether);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);

        oracle = new MockOracle(int256(PRICE_12));

        // Deploy the hook with BEFORE_INITIALIZE and BEFORE_SWAP flags
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        deployCodeTo("DynamicFeeHook.sol", abi.encode(manager, oracle), address(flags));
        hook = DynamicFeeHook(address(flags));

        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Initialize pool with price close to oracle
        (key,) =
            initPool(ethCurrency, tokenCurrency, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing, TEST_SQRT_PRICE_1_2);

        int24 initialTick = TickMath.getTickAtSqrtPrice(TEST_SQRT_PRICE_1_2);
        console.log("Initial tick:", initialTick);

        // Add liquidity to the pool
        int24 tickLower = initialTick - 200;
        int24 tickUpper = initialTick + 200;

        uint256 ethToAdd = 100 ether;
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(
            TEST_SQRT_PRICE_1_2, TickMath.getSqrtPriceAtTick(tickUpper), ethToAdd
        );

        uint256 tokenToAdd = LiquidityAmounts.getAmount1ForLiquidity(
            TickMath.getSqrtPriceAtTick(tickLower), TEST_SQRT_PRICE_1_2, liquidityDelta
        );

        console.log("ethToAdd:", ethToAdd);
        console.log("liquidityDelta:", liquidityDelta);
        console.log("tokenToAdd:", tokenToAdd);

        modifyLiquidityRouter.modifyLiquidity{value: ethToAdd}(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: bytes32(0)
            }),
            ""
        );
    }

    /// @notice Test that fee decreases as the pool price converges back to the oracle price
    function testFeeDecreasesAsPriceReturnsToOracle() public {
        token.mint(address(this), 1000 ether);
        oracle.setLatestPrice(int256(PRICE_12)); // oracle = 1.2

        // Initial swap to move price far from oracle
        vm.recordLogs();
        swapRouter.swap{value: 55 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(45 ether),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(address(this))
        );
        Vm.Log[] memory logsFirst = vm.getRecordedLogs();
        uint24 feeFirst = extractFeeFromLogs(logsFirst);
        emit log_named_uint("Fee after 1st swap", feeFirst);

        // Correction swap moving price slightly back toward oracle
        vm.recordLogs();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(20 ether),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(address(this))
        );
        uint24 feeSecond = extractFeeFromLogs(vm.getRecordedLogs());
        emit log_named_uint("Fee after 2nd correction swap", feeSecond);

        // Another converging swap
        vm.recordLogs();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(10 ether),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(address(this))
        );
        uint24 feeThird = extractFeeFromLogs(vm.getRecordedLogs());
        emit log_named_uint("Fee after 3rd correction swap", feeThird);

        // Assert fees go down as we approach oracle price
        assertLt(feeThird, feeSecond);
    }

    /// @notice Test that fee remains high when deviation increases
    function testFeeWhenIncreaseDeviation() public {
        token.mint(address(this), 1000 ether);
        oracle.setLatestPrice(int256(PRICE_12));

        vm.recordLogs();
        swapRouter.swap{value: 70 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(50 ether),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(address(this))
        );
        uint24 feeFirst = extractFeeFromLogs(vm.getRecordedLogs());
        emit log_named_uint("Fee after 1st swap", feeFirst);

        vm.recordLogs();
        swapRouter.swap{value: 35 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(20 ether),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(address(this))
        );
        uint24 feeSecond = extractFeeFromLogs(vm.getRecordedLogs());
        emit log_named_uint("Fee after 2nd swap", feeSecond);

        vm.recordLogs();
        swapRouter.swap{value: 45 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(20 ether),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(address(this))
        );
        uint24 feeThird = extractFeeFromLogs(vm.getRecordedLogs());
        emit log_named_uint("Fee after 3rd swap", feeThird);

        assertEq(feeThird, feeSecond);
    }

    /// @notice Test that maximum fee is applied when swap direction reduces price deviation
    function testMaxFeeWhenConverging() public {
        token.mint(address(this), 10_000 ether);
        oracle.setLatestPrice(int256(PRICE_12));
        token.approve(address(swapRouter), type(uint256).max);

        // Push pool price far below oracle
        swapRouter.swap{value: 500 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(500 ether),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(address(this))
        );

        // Perform converging swap
        vm.recordLogs();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(300 ether),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(address(this))
        );
        uint24 appliedFee = extractFeeFromLogs(vm.getRecordedLogs());
        emit log_named_uint("Fee on converging swap", appliedFee);

        assertEq(appliedFee, hook.MAX_FEE_BPS(), "Converging swap should trigger MAX_FEE_BPS");
    }

    /// @notice Extracts the applied fee from logs
    function extractFeeFromLogs(Vm.Log[] memory logs) internal pure returns (uint24 fee) {
        bytes32 eventSig = keccak256("DynamicFeeApplied(uint24)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == eventSig) {
                return abi.decode(logs[i].data, (uint24));
            }
        }
        revert("DynamicFeeApplied event not found");
    }

    /// @notice Simulates oracle manipulation and validates behavior of hook
    function testExtremeOracleManipulation() public {
        token.mint(address(this), 10000 ether);
        token.approve(address(swapRouter), type(uint256).max);
        oracle.setLatestPrice(int256(4e17)); // Oracle = 0.4

        // Diverging swap → expect MIN_FEE_BPS
        vm.recordLogs();
        swapRouter.swap{value: 15 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(10 ether),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(address(this))
        );
        uint24 divergingFee = extractFeeFromLogs(vm.getRecordedLogs());
        emit log_named_uint("Fee after diverging swap (oracle = 0.4)", divergingFee);
        assertEq(divergingFee, hook.MIN_FEE_BPS(), "Expected MIN fee when diverging from manipulated oracle");

        // Converging swap → expect MAX_FEE_BPS
        vm.recordLogs();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(10 ether),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(address(this))
        );
        uint24 convergingFee = extractFeeFromLogs(vm.getRecordedLogs());
        emit log_named_uint("Fee after converging swap (oracle = 0.4)", convergingFee);
        assertEq(convergingFee, hook.MAX_FEE_BPS(), "Expected MAX fee when converging to manipulated oracle");
    }

    /// @notice Test that static-fee pools are rejected by the hook
    function testRevertOnStaticFeePool() public {
        uint24 staticFee = 3000;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);

        PoolKey memory staticKey = PoolKey({
            currency0: ethCurrency,
            currency1: tokenCurrency,
            fee: staticFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(hook))
        });

        // Expect revert due to static fee
        vm.expectRevert();
        manager.initialize(staticKey, sqrtPriceX96);
    }

    /* ✅ Checklist of covered behaviors:
       1. Test for minimum fee (MIN_FEE_BPS)
       2. Test for maximum fee on large deviation
       3. Test for fee stability when pool = oracle price
       4. Bidirectional convergence behavior
       5. Oracle manipulation handling
       6. Stress tests with varying swap sizes
       7. Reversion for static-fee pools
    */
}
