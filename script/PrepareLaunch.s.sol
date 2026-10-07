// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {OneMDollar} from "../src/OneMDollar.sol";

/// @notice Read-only handoff for launch 935 using an EXISTING token on Ethereum.
/// @dev Run locally through forge script. This script never broadcasts, creates a token,
///      initializes a pool, approves spending, transfers funds or enables the tax.
contract PrepareLaunch {
    using StateLibrary for IPoolManager;

    uint256 public constant CHAIN_ID = 1;
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    uint24 public constant POOL_FEE = 3000;
    int24 public constant TICK_SPACING = 60;

    struct Config {
        address token;
        address taxablePool;
        address treasury;
        address manager;
        address pairedCurrency; // address(0) denotes native ETH; must be explicitly selected.
        address tokenHolder;
        uint256 requiredTokenAmount; // Gross amount required by the operator's reviewed seeding plan.
        uint160 initialSqrtPriceX96; // sqrt(currency1 minor units / currency0 minor units) * 2**96.
    }

    struct Report {
        uint256 observedBlock;
        bytes32 tokenCodeHash;
        uint256 holderBalance;
        uint8 pairedCurrencyDecimals;
        PoolKey key;
        bytes32 poolId;
        uint160 currentSqrtPriceX96;
        int24 currentTick;
        uint128 activeLiquidity; // In-range liquidity only; zero does not prove there are no positions.
        address initializationTarget;
        bytes initializationCalldata; // Empty when already initialized. Initialization is not seeding.
    }

    error WrongChain(uint256 actual);
    error MissingCode(address target);
    error PlaceholderPool();
    error InvalidTreasury();
    error InvalidPair();
    error InvalidHolder();
    error InvalidAmount();
    error InvalidInitialPrice();
    error UnexpectedToken();
    error ImmutableConfigurationMismatch();
    error TaxAlreadyEnabled();
    error InsufficientLaunchBalance(uint256 available, uint256 required);

    /// @notice Validate explicit configuration and return an unsigned, read-only snapshot.
    /// @dev Successful checks are not deployment authorization or evidence of a completed launch.
    ///      Code presence and matching getters cannot authenticate an address or prove venue compatibility.
    function run(Config calldata c) external view returns (Report memory r) {
        if (block.chainid != CHAIN_ID) revert WrongChain(block.chainid);
        _requireCode(c.token);
        _requireCode(c.manager);
        if (c.taxablePool == address(0x1001)) revert PlaceholderPool();
        _requireCode(c.taxablePool);
        if (c.treasury == address(0)) revert InvalidTreasury();
        if (c.pairedCurrency == c.token || c.pairedCurrency == c.manager) revert InvalidPair();
        if (c.pairedCurrency != address(0)) _requireCode(c.pairedCurrency);
        if (
            c.tokenHolder == address(0) || c.tokenHolder == c.token || c.tokenHolder == c.manager
                || c.tokenHolder == c.taxablePool
        ) revert InvalidHolder();
        if (c.requiredTokenAmount == 0 || c.requiredTokenAmount > SUPPLY) revert InvalidAmount();
        if (c.initialSqrtPriceX96 < TickMath.MIN_SQRT_PRICE || c.initialSqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert InvalidInitialPrice();
        }

        OneMDollar token = OneMDollar(c.token);
        if (
            keccak256(bytes(token.name())) != keccak256("1MDollar")
                || keccak256(bytes(token.symbol())) != keccak256("1MD") || token.decimals() != 18
                || token.totalSupply() != SUPPLY || token.TAX_BPS() != 9900 || token.BPS_DENOMINATOR() != 10000
        ) revert UnexpectedToken();
        if (
            token.liquidityPool() != c.taxablePool || token.feeRecipient() != c.treasury
                || token.poolManager() != c.manager
        ) revert ImmutableConfigurationMismatch();
        if (token.poolTaxEnabled()) revert TaxAlreadyEnabled();

        r.holderBalance = token.balanceOf(c.tokenHolder);
        if (r.holderBalance < c.requiredTokenAmount) {
            revert InsufficientLaunchBalance(r.holderBalance, c.requiredTokenAmount);
        }
        r.observedBlock = block.number;
        r.tokenCodeHash = c.token.codehash;
        r.pairedCurrencyDecimals = c.pairedCurrency == address(0) ? 18 : IERC20Metadata(c.pairedCurrency).decimals();
        bool tokenIsZero = c.token < c.pairedCurrency;
        r.key = PoolKey({
            currency0: Currency.wrap(tokenIsZero ? c.token : c.pairedCurrency),
            currency1: Currency.wrap(tokenIsZero ? c.pairedCurrency : c.token),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        PoolId id = r.key.toId();
        r.poolId = PoolId.unwrap(id);
        IPoolManager manager = IPoolManager(c.manager);
        (r.currentSqrtPriceX96, r.currentTick,,) = manager.getSlot0(id);
        r.activeLiquidity = manager.getLiquidity(id);
        if (r.currentSqrtPriceX96 == 0) {
            r.initializationTarget = c.manager;
            r.initializationCalldata = abi.encodeCall(IPoolManager.initialize, (r.key, c.initialSqrtPriceX96));
        }
    }

    function _requireCode(address target) private view {
        if (target.code.length == 0) revert MissingCode(target);
    }
}
