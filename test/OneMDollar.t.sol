// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {OneMDollar} from "../src/OneMDollar.sol";

contract OneMDollarTest is Test {
    OneMDollar internal token;
    address internal constant POOL = address(0x1001);
    address internal constant TREASURY = address(0x1002);
    address internal constant MANAGER = address(0x1003);
    address internal constant ALICE = address(0x1004);
    address internal constant BOB = address(0x1005);
    address internal constant ROUTER = address(0x1006);
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event PoolTax(address indexed from, address indexed to, uint256 fee);

    function setUp() public {
        token = new OneMDollar(POOL, TREASURY, MANAGER);
    }

    function test_metadataAndEntireSupplyMintedOnceToDeployer() public view {
        assertEq(token.name(), "1MDollar");
        assertEq(token.symbol(), "1MD");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(POOL), 0);
        assertEq(token.balanceOf(TREASURY), 0);
        assertEq(token.liquidityPool(), POOL);
        assertEq(token.feeRecipient(), TREASURY);
        assertEq(token.poolManager(), MANAGER);
        assertEq(token.TAX_BPS(), 9900);
    }

    function test_constructorEmitsFullMint() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), address(this), SUPPLY);
        new OneMDollar(POOL, TREASURY, MANAGER);
    }

    function test_invalidConstructorParametersRevert() public {
        vm.expectRevert(OneMDollar.InvalidPoolManager.selector);
        new OneMDollar(POOL, TREASURY, address(0));
        vm.expectRevert(OneMDollar.InvalidPoolManager.selector);
        new OneMDollar(POOL, TREASURY, address(this));
        vm.expectRevert(OneMDollar.InvalidFeeRecipient.selector);
        new OneMDollar(POOL, address(0), MANAGER);
        vm.expectRevert(OneMDollar.InvalidFeeRecipient.selector);
        new OneMDollar(POOL, MANAGER, MANAGER);
        vm.expectRevert(OneMDollar.InvalidLiquidityPool.selector);
        new OneMDollar(address(0), TREASURY, MANAGER);
        vm.expectRevert(OneMDollar.InvalidLiquidityPool.selector);
        new OneMDollar(TREASURY, TREASURY, MANAGER);
        vm.expectRevert(OneMDollar.InvalidLiquidityPool.selector);
        new OneMDollar(MANAGER, TREASURY, MANAGER);
        vm.expectRevert(OneMDollar.InvalidLiquidityPool.selector);
        new OneMDollar(address(this), TREASURY, MANAGER);
    }

    function test_selfAddressConstructorParametersRevert() public {
        // CREATE addresses depend on the creator nonce, not constructor arguments.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(OneMDollar.InvalidLiquidityPool.selector);
        new OneMDollar(predicted, TREASURY, MANAGER);
        predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(OneMDollar.InvalidFeeRecipient.selector);
        new OneMDollar(POOL, predicted, MANAGER);
        predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(OneMDollar.InvalidPoolManager.selector);
        new OneMDollar(POOL, TREASURY, predicted);
    }

    function test_sellSends99PercentToTreasuryAnd1PercentToPool() public {
        token.transfer(ALICE, 100 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, TREASURY, 99 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit PoolTax(ALICE, POOL, 99 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, POOL, 1 ether);
        vm.prank(ALICE);
        assertTrue(token.transfer(POOL, 100 ether));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(POOL), 1 ether);
        assertEq(token.balanceOf(TREASURY), 99 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_buyTaxesPoolOutput() public {
        _fundPool(100 ether);
        vm.prank(POOL);
        assertTrue(token.transfer(ALICE, 100 ether));
        assertEq(token.balanceOf(POOL), 0);
        assertEq(token.balanceOf(ALICE), 1 ether);
        assertEq(token.balanceOf(TREASURY), 99 ether);
    }

    function test_deployerHasNoSpecialTaxExemption() public {
        token.transfer(POOL, 100 ether);
        assertEq(token.balanceOf(POOL), 1 ether);
        assertEq(token.balanceOf(TREASURY), 99 ether);
    }

    function test_walletTransfersAndOtherVenuesAreUntaxed() public {
        token.transfer(ALICE, 100 ether);
        vm.prank(ALICE);
        token.transfer(BOB, 100 ether);
        vm.prank(BOB);
        token.transfer(ROUTER, 100 ether);
        assertEq(token.balanceOf(ROUTER), 100 ether);
        assertEq(token.balanceOf(TREASURY), 0);
    }

    function test_transferFromConsumesGrossAllowanceOnSellAndBuy() public {
        token.transfer(ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(ROUTER, 100 ether);
        vm.prank(ROUTER);
        assertTrue(token.transferFrom(ALICE, POOL, 100 ether));
        assertEq(token.allowance(ALICE, ROUTER), 0);
        assertEq(token.balanceOf(POOL), 1 ether);

        vm.prank(POOL);
        token.approve(ROUTER, 1 ether);
        vm.prank(ROUTER);
        token.transferFrom(POOL, BOB, 1 ether);
        assertEq(token.allowance(POOL, ROUTER), 0);
        assertEq(token.balanceOf(POOL), 0);
        assertEq(token.balanceOf(BOB), 0.01 ether);
        assertEq(token.balanceOf(TREASURY), 99.99 ether);
    }

    function test_routerCallingOrdinaryTransferDoesNotTriggerTax() public {
        token.transfer(ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(POOL, 100 ether);
        vm.prank(POOL);
        token.transferFrom(ALICE, BOB, 100 ether);
        assertEq(token.balanceOf(BOB), 100 ether);
        assertEq(token.balanceOf(TREASURY), 0);
    }

    function test_managerAsSpenderDoesNotExemptTaxedEndpoints() public {
        token.transfer(ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(MANAGER, 100 ether);
        vm.prank(MANAGER);
        token.transferFrom(ALICE, POOL, 100 ether);
        assertEq(token.balanceOf(POOL), 1 ether);
        assertEq(token.balanceOf(TREASURY), 99 ether);
    }

    function test_poolManagerEndpointsAlwaysReceiveFullAmounts() public {
        _fundPool(100 ether);
        vm.prank(POOL);
        token.transfer(MANAGER, 100 ether);
        vm.prank(MANAGER);
        token.transfer(ALICE, 100 ether);
        assertEq(token.balanceOf(ALICE), 100 ether);
        assertEq(token.balanceOf(TREASURY), 0);
        vm.prank(ALICE);
        token.approve(ROUTER, 100 ether);
        vm.prank(ROUTER);
        token.transferFrom(ALICE, MANAGER, 100 ether);
        assertEq(token.balanceOf(MANAGER), 100 ether);
        assertEq(token.balanceOf(TREASURY), 0);
    }

    function test_approvalReplacementRevocationAndInfiniteAllowance() public {
        token.transfer(ALICE, 100 ether);
        vm.startPrank(ALICE);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(ALICE, ROUTER, 20 ether);
        token.approve(ROUTER, 20 ether);
        token.approve(ROUTER, 10 ether);
        assertEq(token.allowance(ALICE, ROUTER), 10 ether);
        token.approve(ROUTER, 0);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ROUTER, 0, 1));
        vm.prank(ROUTER);
        token.transferFrom(ALICE, POOL, 1);
        vm.prank(ALICE);
        token.approve(ROUTER, type(uint256).max);
        vm.prank(ROUTER);
        token.transferFrom(ALICE, POOL, 100 ether);
        assertEq(token.allowance(ALICE, ROUTER), type(uint256).max);
    }

    function test_insufficientAllowanceCannotPayOnlyNetAmount() public {
        token.transfer(ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(ROUTER, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ROUTER, 1 ether, 100 ether)
        );
        vm.prank(ROUTER);
        token.transferFrom(ALICE, POOL, 100 ether);
        assertEq(token.balanceOf(ALICE), 100 ether);
        assertEq(token.balanceOf(POOL), 0);
        assertEq(token.balanceOf(TREASURY), 0);
        assertEq(token.allowance(ALICE, ROUTER), 1 ether);
    }

    function test_insufficientBalanceRollsBackFeeAndAllowance() public {
        token.transfer(ALICE, 99 ether);
        vm.prank(ALICE);
        token.approve(ROUTER, 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 99 ether, 100 ether)
        );
        vm.prank(ROUTER);
        token.transferFrom(ALICE, POOL, 100 ether);
        assertEq(token.balanceOf(ALICE), 99 ether);
        assertEq(token.balanceOf(POOL), 0);
        assertEq(token.balanceOf(TREASURY), 0);
        assertEq(token.allowance(ALICE, ROUTER), 100 ether);
    }

    function test_zeroAddressesRevertWithoutBurningOrSpendingAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        token.approve(ROUTER, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(ROUTER);
        token.transferFrom(address(this), address(0), 1);
        assertEq(token.allowance(address(this), ROUTER), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), ALICE, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroAndDustTransfersRoundFeeDown() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, POOL, 0);
        vm.prank(ALICE);
        token.transfer(POOL, 0);
        token.transfer(POOL, 1);
        assertEq(token.balanceOf(POOL), 1);
        assertEq(token.balanceOf(TREASURY), 0);
        token.transfer(POOL, 99);
        assertEq(token.balanceOf(POOL), 2);
        assertEq(token.balanceOf(TREASURY), 98);
        token.transfer(POOL, 100);
        assertEq(token.balanceOf(POOL), 3);
        assertEq(token.balanceOf(TREASURY), 197);
    }

    function test_poolSelfTransferChargesFeeAndWalletSelfTransferDoesNot() public {
        _fundPool(100 ether);
        vm.prank(POOL);
        token.transfer(POOL, 100 ether);
        assertEq(token.balanceOf(POOL), 1 ether);
        assertEq(token.balanceOf(TREASURY), 99 ether);
        token.transfer(ALICE, 100 ether);
        vm.prank(ALICE);
        token.transfer(ALICE, 100 ether);
        assertEq(token.balanceOf(ALICE), 100 ether);
    }

    function test_treasuryAsSenderOrRecipientPreservesAccounting() public {
        token.transfer(TREASURY, 100 ether);
        vm.prank(TREASURY);
        token.transfer(POOL, 100 ether);
        assertEq(token.balanceOf(TREASURY), 99 ether);
        assertEq(token.balanceOf(POOL), 1 ether);
        vm.prank(POOL);
        token.transfer(TREASURY, 1 ether);
        assertEq(token.balanceOf(TREASURY), 100 ether);
        assertEq(token.balanceOf(POOL), 0);
    }

    function test_treasuryCannotTransferMoreThanItsGrossBalance() public {
        token.transfer(TREASURY, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, TREASURY, 1 ether, 100 ether)
        );
        vm.prank(TREASURY);
        token.transfer(POOL, 100 ether);
    }

    function test_extremeAmountRevertsBeforeFeeMultiplication() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.transfer(POOL, type(uint256).max);
    }

    function testFuzz_sellsConserveSupplyAndApplyExactFee(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        token.transfer(ALICE, amount);
        vm.prank(ALICE);
        token.transfer(POOL, amount);
        uint256 net = (amount + 99) / 100;
        assertEq(token.balanceOf(POOL), net);
        assertEq(token.balanceOf(TREASURY), amount - net);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(POOL) + token.balanceOf(TREASURY), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_buysConserveSupplyAndApplyExactFee(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        _fundPool(amount);
        vm.prank(POOL);
        token.transfer(ALICE, amount);
        uint256 net = (amount + 99) / 100;
        assertEq(token.balanceOf(ALICE), net);
        assertEq(token.balanceOf(TREASURY), amount - net);
        assertEq(token.balanceOf(POOL), 0);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(ALICE) + token.balanceOf(TREASURY), SUPPLY);
    }

    function testFuzz_walletTransfersHaveNoFee(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        token.transfer(ALICE, amount);
        vm.prank(ALICE);
        token.transfer(BOB, amount);
        assertEq(token.balanceOf(BOB), amount);
        assertEq(token.balanceOf(TREASURY), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _fundPool(uint256 amount) internal {
        token.transfer(MANAGER, amount);
        vm.prank(MANAGER);
        token.transfer(POOL, amount);
    }
}
