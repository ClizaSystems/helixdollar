// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

import {HelixDToken} from "../src/HelixDToken.sol";

// --------- Minimal interfaces we need ----------
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IUniswapV3Factory {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
    function feeAmountTickSpacing(uint24 fee) external view returns (int24);
}

interface IUniswapV3Pool {
    function initialize(uint160 sqrtPriceX96) external;

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

contract DeployHelixD is Script {
    // ---------- Base mainnet addresses ----------
    address constant UNISWAP_V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address constant NFPM_BASE = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1; // NonfungiblePositionManager
    address constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // USDC (6 dec)
    address constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481; // SwapRouter02

    // ---------- Pool settings ----------
    uint24 constant FEE = 3_000; // 0.3% -> tickSpacing = 60
    int24 constant TICK_LOWER = 0; // $1 boundary (since both tokens are 6 decimals)
    int24 constant TICK_UPPER = 887_220; // max valid multiple of 60 (<= 887_272)

    // ---------- Supply / amounts ----------
    // 69,000,000,000,000 HELIXD (6 decimals)
    uint256 constant TOTAL_SUPPLY = 69_000_000_000_000 * 10 ** 6;
    // tiny HELIXD to sell to nudge price *into* the SSL range
    uint256 constant NUDGE_SELL_HELIXD = 5_000; // 0.005 HELIXD (6 decimals)

    function run() external {
        vm.startBroadcast();

        address deployer = msg.sender;
        console2.log("Deployer:", deployer);

        // 1) Deploy token (all supply to deployer)
        HelixDToken helix = new HelixDToken(TOTAL_SUPPLY);
        console2.log("HELIXD deployed at:", address(helix));
        console2.log("Deployer HELIXD balance:", helix.balanceOf(deployer));

        // 2) Determine token ordering for Uniswap (token0 < token1)
        (address token0, address token1) =
            address(helix) < USDC_BASE ? (address(helix), USDC_BASE) : (USDC_BASE, address(helix));
        console2.log("token0:", token0);
        console2.log("token1:", token1);

        // 3) Initial price at exactly $1 (tick 0) because both tokens have 6 decimals
        uint160 initSqrtPriceX96 = TickMath.getSqrtRatioAtTick(0);

        // 4) Create pool (reverts if the pool already exists)
        address pool = IUniswapV3Factory(UNISWAP_V3_FACTORY).createPool(token0, token1, FEE);
        console2.log("Pool created at:", pool);

        // 5) Initialize pool at 1:1
        IUniswapV3Pool(pool).initialize(initSqrtPriceX96);
        {
            (uint160 spX96, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();
            console2.log("slot0.sqrtPriceX96:", spX96);
            console2.log("slot0.currentTick:", currentTick); // should be 0
        }

        // 6) Compute SSL (single-sided) range + amounts
        // We place HELIXD-only liquidity on the side that uses HELIXD exclusively
        //   - If HELIXD is token0: range [ 0, +887,220 ]  => P(USDC/HELIXD) ∈ [1, +∞)
        //   - If HELIXD is token1: range [-887,220, 0 ]  => P(HELIXD/USDC) ∈ (0, 1]
        int24 tickLowerParam;
        int24 tickUpperParam;
        if (token0 == address(helix)) {
            tickLowerParam = TICK_LOWER; // 0
            tickUpperParam = TICK_UPPER; // +887,220
        } else {
            tickLowerParam = -TICK_UPPER; // -887,220
            tickUpperParam = -TICK_LOWER; // 0
        }

        // Reserve a tiny amount for the nudge swap; deposit the rest as LP
        uint256 lpAmount = TOTAL_SUPPLY - NUDGE_SELL_HELIXD;

        uint256 amount0Desired = (token0 == address(helix)) ? lpAmount : 0;
        uint256 amount1Desired = (token1 == address(helix)) ? lpAmount : 0;

        // 7) Approve NFPM to pull HELIXD for the LP mint
        helix.approve(NFPM_BASE, lpAmount);

        // 8) Mint HELIXD-only position to the deployer
        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: FEE,
            tickLower: tickLowerParam,
            tickUpper: tickUpperParam,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            recipient: deployer, // deployer receives the LP NFT
            deadline: block.timestamp + 1 hours
        });

        (uint256 tokenId, uint128 liquidity, uint256 used0, uint256 used1) =
            INonfungiblePositionManager(NFPM_BASE).mint(mintParams);

        console2.log("LP NFT tokenId:", tokenId);
        console2.log("Liquidity:", liquidity);
        console2.log("amount0 used:", used0);
        console2.log("amount1 used:", used1);

        // 9) Nudge price *into* the SSL range with a micro HELIXD -> USDC swap
        // This is the correct direction for a HELIXD-only position around $1.
        helix.approve(SWAP_ROUTER, NUDGE_SELL_HELIXD);

        ISwapRouter02.ExactInputSingleParams memory swapParams = ISwapRouter02.ExactInputSingleParams({
            tokenIn: address(helix),
            tokenOut: USDC_BASE,
            fee: FEE,
            recipient: deployer,
            amountIn: NUDGE_SELL_HELIXD,
            amountOutMinimum: 0, // NOTE: for production, set a real minOut!
            sqrtPriceLimitX96: 0 // no price limit
        });

        uint256 usdcOut = ISwapRouter02(SWAP_ROUTER).exactInputSingle(swapParams);
        console2.log("Nudge swap out (USDC):", usdcOut);

        console2.log("Deployment complete");
        vm.stopBroadcast();
    }

    receive() external payable {}
}
