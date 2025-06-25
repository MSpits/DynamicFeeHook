// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Foundry standard testing utilities
import "forge-std/Test.sol";
import "forge-std/console.sol";

// Uniswap V4 testing utilities
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

// Mocks and hook under test
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {DynamicFeeHook} from "../src/DynamicFeeHook.sol";
import {MockOracle} from "./MockOracle.sol";

// Uniswap core types
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

// Uniswap core libraries
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {ERC1155TokenReceiver} from "solmate/src/tokens/ERC1155.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

contract TestDynamicFeeHook is Test, Deployers, ERC1155TokenReceiver {
    MockERC20 token;
    MockOracle oracle;
    DynamicFeeHook hook;
    int24 tickSpacing = 1;
    uint256 constant PRICE_12 = (12 * 1e18) / 10; // 1.2
    uint160 constant TEST_SQRT_PRICE_1_2 = 72325086331928494284758347145;

    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;

    function setUp() public {
        deployFreshManagerAndRouters();

        token = new MockERC20("Test Token", "TEST", 18);
        tokenCurrency = Currency.wrap(address(token));

        token.mint(address(this), 10000 ether);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);

        oracle = new MockOracle(int256(PRICE_12));

        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        deployCodeTo("DynamicFeeHook.sol", abi.encode(manager, oracle), address(flags));
        hook = DynamicFeeHook(address(flags));

        (key,) =
            initPool(ethCurrency, tokenCurrency, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing, TEST_SQRT_PRICE_1_2);

        int24 tickLower = TickMath.getTickAtSqrtPrice(TEST_SQRT_PRICE_1_2) - 200;
        int24 tickUpper = tickLower + 400;

        uint256 ethToAdd = 100 ether;
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(
            TEST_SQRT_PRICE_1_2, TickMath.getSqrtPriceAtTick(tickUpper), ethToAdd
        );

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

    function testFeeDecreasesAsPriceReturnsToOracle() public {
        token.mint(address(this), 1000 ether);
        oracle.setLatestPrice(int256(PRICE_12));

        vm.recordLogs();
        swapRouter.swap{value: 55 ether}(
            key,
            SwapParams(true, -int256(45 ether), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(address(this))
        );
        uint24 feeFirst = extractFeeFromLogs(vm.getRecordedLogs());

        vm.recordLogs();
        swapRouter.swap(
            key,
            SwapParams(false, -int256(20 ether), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(address(this))
        );
        uint24 feeSecond = extractFeeFromLogs(vm.getRecordedLogs());

        vm.recordLogs();
        swapRouter.swap(
            key,
            SwapParams(false, -int256(10 ether), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(address(this))
        );
        uint24 feeThird = extractFeeFromLogs(vm.getRecordedLogs());

        assertLt(feeThird, feeSecond);
    }

    function testFeeWhenIncreaseDeviation() public {
        token.mint(address(this), 1000 ether);
        oracle.setLatestPrice(int256(PRICE_12));

        vm.recordLogs();
        swapRouter.swap{value: 70 ether}(
            key,
            SwapParams(true, int256(50 ether), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(address(this))
        );
        uint24 feeFirst = extractFeeFromLogs(vm.getRecordedLogs());

        vm.recordLogs();
        swapRouter.swap{value: 35 ether}(
            key,
            SwapParams(true, -int256(20 ether), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(address(this))
        );
        uint24 feeSecond = extractFeeFromLogs(vm.getRecordedLogs());

        assertEq(feeSecond, feeFirst);
    }

    function testMaxFeeWhenConverging() public {
        token.mint(address(this), 10_000 ether);
        oracle.setLatestPrice(int256(PRICE_12));
        token.approve(address(swapRouter), type(uint256).max);

        swapRouter.swap{value: 500 ether}(
            key,
            SwapParams(true, -int256(500 ether), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(address(this))
        );

        vm.recordLogs();
        swapRouter.swap(
            key,
            SwapParams(false, -int256(300 ether), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(address(this))
        );
        uint24 appliedFee = extractFeeFromLogs(vm.getRecordedLogs());

        assertEq(appliedFee, hook.MAX_FEE_BPS());
    }

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

        vm.expectRevert();
        manager.initialize(staticKey, sqrtPriceX96);
    }
    /// @notice Test that hook behaves correctly when the oracle is manipulated

    function testExtremeOracleManipulation() public {
        // Setup: mint and approve token
        token.mint(address(this), 10_000 ether);
        token.approve(address(swapRouter), type(uint256).max);

        // Manipulate the oracle to return a much lower price (0.4)
        oracle.setLatestPrice(int256(4e17)); // oracle = 0.4

        // First swap: diverging from the oracle (pool price increases)
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
        assertEq(divergingFee, hook.MIN_FEE_BPS(), "Diverging swap should trigger MIN_FEE_BPS");

        // Second swap: price converges back to the oracle (pool price decreases)
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
        assertEq(convergingFee, hook.MAX_FEE_BPS(), "Converging swap should trigger MAX_FEE_BPS");
    }

    function extractFeeFromLogs(Vm.Log[] memory logs) internal pure returns (uint24 fee) {
        bytes32 eventSig = keccak256("DynamicFeeApplied(uint24)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == eventSig) {
                return abi.decode(logs[i].data, (uint24));
            }
        }
        revert("DynamicFeeApplied event not found");
    }
}
