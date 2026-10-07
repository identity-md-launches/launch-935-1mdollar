// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {OneMDollar} from "../src/OneMDollar.sol";
import {PrepareLaunch} from "../script/PrepareLaunch.s.sol";
import {V4Actor} from "./support/V4Actor.sol";

/// @dev Only proves that preflight checks code presence, not that the venue is an AMM.
contract PreflightVenueFixture {}

contract PreflightPairFixture is ERC20 {
    constructor() ERC20("Six decimal test pair", "PAIR") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract PrepareLaunchTest is Test {
    using StateLibrary for PoolManager;

    PrepareLaunch internal preflight;
    PrepareLaunch.Config internal config;
    PoolManager internal manager;
    OneMDollar internal token;
    address internal constant TREASURY = address(0xBEEF);
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        vm.chainId(1);
        manager = new PoolManager(address(this));
        address venue = address(new PreflightVenueFixture());
        token = new OneMDollar(venue, TREASURY, address(manager));
        preflight = new PrepareLaunch();
        config = PrepareLaunch.Config({
            token: address(token),
            taxablePool: venue,
            treasury: TREASURY,
            manager: address(manager),
            pairedCurrency: address(0),
            tokenHolder: address(this),
            requiredTokenAmount: 860_000_000 ether,
            initialSqrtPriceX96: uint160(1 << 96)
        });
    }

    function test_nativePlanUsesExistingSupplyAndRealManagerAcceptsCalldata() public {
        PrepareLaunch.Report memory r = preflight.run(config);
        assertEq(Currency.unwrap(r.key.currency0), address(0));
        assertEq(Currency.unwrap(r.key.currency1), address(token));
        assertEq(r.key.fee, 3000);
        assertEq(r.key.tickSpacing, 60);
        assertEq(address(r.key.hooks), address(0));
        assertEq(r.poolId, keccak256(abi.encode(r.key)));
        assertEq(r.observedBlock, block.number);
        assertEq(r.tokenCodeHash, address(token).codehash);
        assertEq(r.holderBalance, SUPPLY);
        assertEq(r.pairedCurrencyDecimals, 18);
        assertEq(r.currentSqrtPriceX96, 0);
        assertEq(r.activeLiquidity, 0);
        assertEq(r.initializationTarget, address(manager));
        // Explicit LOCAL execution, separate from the read-only script.
        (bool ok,) = r.initializationTarget.call(r.initializationCalldata);
        assertTrue(ok);
        (uint160 price,,,) = manager.getSlot0(PoolId.wrap(r.poolId));
        assertEq(price, config.initialSqrtPriceX96);
        _assertUntouchedLedger();
    }

    function test_erc20PairsSortBothWaysAndExposeActualDecimals() public {
        PreflightPairFixture pair = new PreflightPairFixture();
        // The same six-decimal fixture at both sides of the token's address exercises sorting.
        address[2] memory pairs = [address(uint160(address(token)) - 1), address(uint160(address(token)) + 1)];
        for (uint256 i; i < pairs.length; ++i) {
            vm.etch(pairs[i], address(pair).code);
            config.pairedCurrency = pairs[i];
            PrepareLaunch.Report memory r = preflight.run(config);
            assertEq(Currency.unwrap(r.key.currency0), i == 0 ? pairs[i] : address(token));
            assertEq(Currency.unwrap(r.key.currency1), i == 0 ? address(token) : pairs[i]);
            assertEq(r.pairedCurrencyDecimals, 6);
            (bool ok,) = r.initializationTarget.call(r.initializationCalldata);
            assertTrue(ok);
        }
        _assertUntouchedLedger();
    }

    function test_staticCallAndArbitraryCallerProduceIdenticalPlansWithoutInitializing() public {
        bytes memory data = abi.encodeCall(PrepareLaunch.run, (config));
        (bool ok, bytes memory first) = address(preflight).staticcall(data);
        assertTrue(ok);
        vm.prank(address(0xCA11));
        (ok, data) = address(preflight).staticcall(data);
        assertTrue(ok);
        assertEq(data, first);
        PrepareLaunch.Report memory r = abi.decode(first, (PrepareLaunch.Report));
        (uint160 price,,,) = manager.getSlot0(PoolId.wrap(r.poolId));
        assertEq(price, 0);
        _assertUntouchedLedger();
    }

    function test_initializedPoolIsReportedWithoutReinitializationEvenAtDifferentPrice() public {
        PrepareLaunch.Report memory before = preflight.run(config);
        manager.initialize(before.key, TickMath.getSqrtPriceAtTick(120));
        PrepareLaunch.Report memory afterInit = preflight.run(config);
        assertEq(afterInit.currentSqrtPriceX96, TickMath.getSqrtPriceAtTick(120));
        assertEq(afterInit.currentTick, 120);
        assertEq(afterInit.activeLiquidity, 0);
        assertEq(afterInit.initializationTarget, address(0));
        assertEq(afterInit.initializationCalldata.length, 0);
        _assertUntouchedLedger();
    }

    function test_reportsFundedPoolAndDoesNotReseedOrMoveFunds() public {
        PrepareLaunch.Report memory r = preflight.run(config);
        manager.initialize(r.key, config.initialSqrtPriceX96);
        V4Actor seedActor = new V4Actor(manager);
        token.transfer(address(seedActor), 1_000 ether);
        seedActor.seed(r.key, false);
        uint256 managerBalance = token.balanceOf(address(manager));
        uint256 holderBalance = token.balanceOf(address(this));
        // Move just inside the range: seeding at its boundary can have zero active liquidity.
        V4Actor trader = new V4Actor(manager);
        vm.deal(address(trader), 1 ether);
        trader.swap(r.key, true, -0.01 ether);
        managerBalance = token.balanceOf(address(manager));
        r = preflight.run(config);
        assertGt(r.activeLiquidity, 0);
        assertEq(r.initializationCalldata.length, 0);
        assertEq(r.holderBalance, holderBalance);
        assertEq(token.balanceOf(address(manager)), managerBalance);
        assertEq(token.totalSupply(), SUPPLY);
        assertFalse(token.poolTaxEnabled());
    }

    function test_wrongChainRejected() public {
        vm.chainId(31337);
        vm.expectRevert(abi.encodeWithSelector(PrepareLaunch.WrongChain.selector, 31337));
        preflight.run(config);
    }

    function test_missingCodeAndInheritedPlaceholderRejected() public {
        PrepareLaunch.Config memory c = config;
        c.token = address(0);
        _expectMissingCode(c, address(0));
        c = config;
        c.manager = address(0x404);
        _expectMissingCode(c, c.manager);
        c = config;
        c.taxablePool = address(0x1001);
        // Reject the known fixture even if someone puts code at that address.
        vm.etch(c.taxablePool, hex"00");
        vm.expectRevert(PrepareLaunch.PlaceholderPool.selector);
        preflight.run(c);
        c.taxablePool = address(0);
        _expectMissingCode(c, address(0));
        c = config;
        c.pairedCurrency = address(0x404);
        _expectMissingCode(c, c.pairedCurrency);
    }

    function test_wrongTokenIdentitySupplyOrTaxConstantsRejected() public {
        bytes4[6] memory selectors = [
            token.name.selector,
            token.symbol.selector,
            token.decimals.selector,
            token.totalSupply.selector,
            token.TAX_BPS.selector,
            token.BPS_DENOMINATOR.selector
        ];
        for (uint256 i; i < selectors.length; ++i) {
            bytes memory wrongValue = i < 2 ? abi.encode("Wrong token") : abi.encode(uint256(7));
            vm.mockCall(address(token), abi.encodeWithSelector(selectors[i]), wrongValue);
            vm.expectRevert(PrepareLaunch.UnexpectedToken.selector);
            preflight.run(config);
            vm.clearMockedCalls();
        }
    }

    function test_mismatchedImmutableAddressesRejected() public {
        address differentContract = address(new PreflightVenueFixture());
        PrepareLaunch.Config memory c = config;
        c.taxablePool = differentContract;
        vm.expectRevert(PrepareLaunch.ImmutableConfigurationMismatch.selector);
        preflight.run(c);
        c = config;
        c.treasury = address(0xCAFE);
        vm.expectRevert(PrepareLaunch.ImmutableConfigurationMismatch.selector);
        preflight.run(c);
        c = config;
        c.manager = differentContract;
        vm.expectRevert(PrepareLaunch.ImmutableConfigurationMismatch.selector);
        preflight.run(c);
    }

    function test_activatedTaxCannotBePresentedAsFeeFreeLaunch() public {
        vm.prank(TREASURY);
        token.enablePoolTax();
        vm.expectRevert(PrepareLaunch.TaxAlreadyEnabled.selector);
        preflight.run(config);
        assertTrue(token.poolTaxEnabled());
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_invalidTreasuryPairHolderAndAmountRejected() public {
        PrepareLaunch.Config memory c = config;
        c.treasury = address(0);
        vm.expectRevert(PrepareLaunch.InvalidTreasury.selector);
        preflight.run(c);
        address[2] memory pairs = [address(token), address(manager)];
        for (uint256 i; i < pairs.length; ++i) {
            c = config;
            c.pairedCurrency = pairs[i];
            vm.expectRevert(PrepareLaunch.InvalidPair.selector);
            preflight.run(c);
        }
        address[4] memory holders = [address(0), address(token), address(manager), config.taxablePool];
        for (uint256 i; i < holders.length; ++i) {
            c = config;
            c.tokenHolder = holders[i];
            vm.expectRevert(PrepareLaunch.InvalidHolder.selector);
            preflight.run(c);
        }
        uint256[3] memory amounts = [uint256(0), SUPPLY + 1, type(uint256).max];
        for (uint256 i; i < amounts.length; ++i) {
            c = config;
            c.requiredTokenAmount = amounts[i];
            vm.expectRevert(PrepareLaunch.InvalidAmount.selector);
            preflight.run(c);
        }
    }

    function testFuzz_requiresActualHolderFunding(uint256 required) public {
        required = bound(required, 1, SUPPLY);
        token.transfer(address(0xF00D), SUPPLY - required);
        config.requiredTokenAmount = required;
        assertEq(preflight.run(config).holderBalance, required);
        token.transfer(address(0xF00D), 1);
        vm.expectRevert(
            abi.encodeWithSelector(PrepareLaunch.InsufficientLaunchBalance.selector, required - 1, required)
        );
        preflight.run(config);
        assertEq(token.balanceOf(address(this)), required - 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_initialPriceBoundsMatchRealManager() public {
        uint160[3] memory invalidPrices = [uint160(0), TickMath.MIN_SQRT_PRICE - 1, TickMath.MAX_SQRT_PRICE];
        for (uint256 i; i < invalidPrices.length; ++i) {
            config.initialSqrtPriceX96 = invalidPrices[i];
            vm.expectRevert(PrepareLaunch.InvalidInitialPrice.selector);
            preflight.run(config);
        }
        config.initialSqrtPriceX96 = TickMath.MIN_SQRT_PRICE;
        PrepareLaunch.Report memory r = preflight.run(config);
        (bool ok,) = r.initializationTarget.call(r.initializationCalldata);
        assertTrue(ok);
    }

    function _expectMissingCode(PrepareLaunch.Config memory c, address target) internal {
        vm.expectRevert(abi.encodeWithSelector(PrepareLaunch.MissingCode.selector, target));
        preflight.run(c);
    }

    function _assertUntouchedLedger() internal view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(TREASURY), 0);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(token.balanceOf(address(preflight)), 0);
        assertEq(token.allowance(address(this), address(preflight)), 0);
        assertEq(token.allowance(address(this), address(manager)), 0);
        assertFalse(token.poolTaxEnabled());
    }
}
