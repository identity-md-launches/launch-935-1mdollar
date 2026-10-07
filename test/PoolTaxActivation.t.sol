// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {OneMDollar} from "../src/OneMDollar.sol";

contract PoolTaxActivationTest is Test {
    OneMDollar internal token;
    address internal constant POOL = address(0x1001);
    address internal constant TREASURY = address(0x1002);
    address internal constant MANAGER = address(0x1003);
    address internal constant ALICE = address(0x1004);
    address internal constant BOB = address(0x1005);
    address internal constant ROUTER = address(0x1006);
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    event PoolTaxEnabled(address indexed liquidityPool, address indexed feeRecipient);

    function setUp() public {
        token = new OneMDollar(POOL, TREASURY, MANAGER);
    }

    function test_launchFundingAndTradingAreUntaxedInBothDirections() public {
        assertFalse(token.poolTaxEnabled());
        vm.recordLogs();
        token.transfer(POOL, 1_000 ether);
        vm.prank(POOL);
        token.transfer(ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(ROUTER, 100 ether);
        vm.prank(ROUTER);
        token.transferFrom(ALICE, POOL, 100 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != keccak256("PoolTax(address,address,uint256)"));
        }
        assertEq(token.balanceOf(POOL), 1_000 ether);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(TREASURY), 0);
        assertEq(token.allowance(ALICE, ROUTER), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_activationEmitsEventAndDoesNotMoveBalancesOrAllowances() public {
        token.transfer(POOL, 1_000 ether);
        token.transfer(ALICE, 200 ether);
        vm.prank(ALICE);
        token.approve(ROUTER, 100 ether);
        bytes32 before = _ledger();
        vm.expectEmit(true, true, false, true, address(token));
        emit PoolTaxEnabled(POOL, TREASURY);
        _enable();
        assertTrue(token.poolTaxEnabled());
        assertEq(_ledger(), before);
        assertEq(token.liquidityPool(), POOL);
        assertEq(token.feeRecipient(), TREASURY);
        assertEq(token.poolManager(), MANAGER);
    }

    function test_launchThenActivateTaxesExistingLiquidityAndExistingApproval() public {
        token.transfer(POOL, 1_000 ether);
        token.transfer(ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(ROUTER, 100 ether);
        _enable();
        vm.prank(POOL);
        token.transfer(BOB, 100 ether);
        assertEq(token.balanceOf(BOB), 1 ether);
        assertEq(token.balanceOf(TREASURY), 99 ether);
        vm.prank(ROUTER);
        token.transferFrom(ALICE, POOL, 100 ether);
        assertEq(token.allowance(ALICE, ROUTER), 0);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(POOL), 901 ether);
        assertEq(token.balanceOf(TREASURY), 198 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_onlyTreasuryCanActivateIncludingDeployerAndManagerRejection() public {
        address[6] memory callers = [address(this), POOL, MANAGER, ALICE, ROUTER, address(0)];
        bytes32 before = _ledger();
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(OneMDollar.UnauthorizedTaxActivation.selector);
            vm.prank(callers[i]);
            token.enablePoolTax();
            assertFalse(token.poolTaxEnabled());
            assertEq(_ledger(), before);
        }
        _enable();
        assertTrue(token.poolTaxEnabled());
    }

    function test_repeatedActivationRevertsWithoutChangingLedger() public {
        token.transfer(POOL, 100 ether);
        _enable();
        bytes32 before = _ledger();
        vm.expectRevert(OneMDollar.PoolTaxAlreadyEnabled.selector);
        vm.prank(TREASURY);
        token.enablePoolTax();
        assertTrue(token.poolTaxEnabled());
        assertEq(_ledger(), before);
        vm.prank(POOL);
        token.transfer(ALICE, 100 ether);
        assertEq(token.balanceOf(ALICE), 1 ether);
        assertEq(token.balanceOf(TREASURY), 99 ether);
    }

    function test_noDisableOrRateChangeExistsEvenForTreasury() public {
        _enable();
        vm.startPrank(TREASURY);
        (bool disabled,) = address(token).call(abi.encodeWithSignature("disablePoolTax()"));
        (bool toggled,) = address(token).call(abi.encodeWithSignature("setPoolTaxEnabled(bool)", false));
        (bool changed,) = address(token).call(abi.encodeWithSignature("setTaxBps(uint256)", 0));
        vm.stopPrank();
        assertFalse(disabled);
        assertFalse(toggled);
        assertFalse(changed);
        assertTrue(token.poolTaxEnabled());
        token.transfer(POOL, 100 ether);
        assertEq(token.balanceOf(POOL), 1 ether);
    }

    function test_failedTransfersRollBackInBothPhases() public {
        token.transfer(ALICE, 99 ether);
        vm.prank(ALICE);
        token.approve(ROUTER, 100 ether);
        for (uint256 phase; phase < 2; ++phase) {
            if (phase == 1) _enable();
            bytes32 before = _ledger();
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 99 ether, 100 ether)
            );
            vm.prank(ROUTER);
            token.transferFrom(ALICE, POOL, 100 ether);
            assertEq(_ledger(), before);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ROUTER, 100 ether, 101 ether)
            );
            vm.prank(ROUTER);
            token.transferFrom(ALICE, POOL, 101 ether);
            assertEq(_ledger(), before);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            vm.prank(POOL);
            token.transfer(address(0), 0);
            assertEq(_ledger(), before);
            assertEq(token.poolTaxEnabled(), phase == 1);
        }
    }

    function test_walletsAndManagerStayUntaxedAfterActivation() public {
        _enable();
        token.transfer(ALICE, 100 ether);
        vm.prank(ALICE);
        token.transfer(MANAGER, 100 ether);
        vm.prank(MANAGER);
        token.transfer(BOB, 100 ether);
        assertEq(token.balanceOf(BOB), 100 ether);
        assertEq(token.balanceOf(TREASURY), 0);
    }

    function testFuzz_bothDirectionsAndDelegationAcrossActivation(uint256 amount, bool buy, bool delegated) public {
        amount = bound(amount, 0, SUPPLY / 2);
        address from = buy ? POOL : ALICE;
        address to = buy ? ALICE : POOL;
        token.transfer(from, amount * 2);
        vm.prank(from);
        token.approve(ROUTER, amount * 2);
        _move(from, to, amount, delegated);
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(TREASURY), 0);
        _enable();
        _move(from, to, amount, delegated);
        uint256 net = (amount + 99) / 100;
        assertEq(token.balanceOf(to), amount + net);
        assertEq(token.balanceOf(from), 0);
        assertEq(token.balanceOf(TREASURY), amount - net);
        assertEq(token.allowance(from, ROUTER), delegated ? 0 : amount * 2);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(to) + token.balanceOf(TREASURY), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _enable() internal {
        vm.prank(TREASURY);
        token.enablePoolTax();
    }

    function _move(address from, address to, uint256 amount, bool delegated) internal {
        vm.prank(delegated ? ROUTER : from);
        if (delegated) assertTrue(token.transferFrom(from, to, amount));
        else assertTrue(token.transfer(to, amount));
    }

    function _ledger() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                token.balanceOf(address(this)),
                token.balanceOf(POOL),
                token.balanceOf(TREASURY),
                token.balanceOf(ALICE),
                token.balanceOf(BOB),
                token.balanceOf(MANAGER),
                token.allowance(ALICE, ROUTER),
                token.totalSupply()
            )
        );
    }
}
