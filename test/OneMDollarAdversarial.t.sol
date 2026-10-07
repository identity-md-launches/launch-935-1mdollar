// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {OneMDollar} from "src/OneMDollar.sol";

/// forge-config: default.fuzz.runs = 1000
contract OneMDollarAdversarialTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    address internal constant ALICE = address(0x2001);
    address internal constant BOB = address(0x2002);
    address internal constant ROUTER = address(0x2003);
    address internal constant POOL = address(0x2004);
    address internal constant TREASURY = address(0x2005);
    address internal constant MANAGER = address(0x2006);
    OneMDollar internal token;
    address[6] internal actors = [ALICE, BOB, ROUTER, POOL, TREASURY, MANAGER];

    function setUp() public {
        token = new OneMDollar(POOL, TREASURY, MANAGER);
    }

    function testFuzz_delegationMatchesDirectTransferIncludingAliases(
        uint8 fromSeed,
        uint8 toSeed,
        uint8 spenderSeed,
        uint256 amount,
        bool infinite
    ) public {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        address spender = _actor(spenderSeed);
        amount = bound(amount, 0, SUPPLY);
        _fund(from, amount);
        uint256 snapshot = vm.snapshotState();
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        uint256[7] memory direct = _balances();
        assertTrue(vm.revertToState(snapshot));

        vm.prank(from);
        token.approve(spender, infinite ? type(uint256).max : amount);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        uint256[7] memory delegated = _balances();
        for (uint256 i; i < direct.length; ++i) {
            assertEq(delegated[i], direct[i], "delegation changed economics");
        }
        assertEq(token.allowance(from, spender), infinite ? type(uint256).max : 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_overdrawRevertsAtomicallyAcrossRoles(
        uint8 fromSeed,
        uint8 toSeed,
        uint8 spenderSeed,
        uint256 held,
        uint256 excess,
        bool delegated,
        bool infinite
    ) public {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        address spender = _actor(spenderSeed);
        held = bound(held, 0, SUPPLY);
        uint256 amount = bound(excess, held + 1, type(uint256).max);
        _fund(from, held);
        vm.prank(from);
        token.approve(spender, infinite ? type(uint256).max : amount);
        bytes32 before = _stateDigest();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount));
        vm.prank(delegated ? spender : from);
        if (delegated) token.transferFrom(from, to, amount);
        else token.transfer(to, amount);
        assertEq(_stateDigest(), before, "overdraw changed balances or allowances");
    }

    function testFuzz_shortGrossAllowanceRevertsAtomically(
        uint8 fromSeed,
        uint8 toSeed,
        uint8 spenderSeed,
        uint256 held,
        uint256 amount,
        uint256 allowed
    ) public {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        address spender = _actor(spenderSeed);
        held = bound(held, 1, SUPPLY);
        amount = bound(amount, 1, held);
        allowed = bound(allowed, 0, amount - 1);
        _fund(from, held);
        vm.prank(from);
        token.approve(spender, allowed);
        bytes32 before = _stateDigest();
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
        );
        vm.prank(spender);
        token.transferFrom(from, to, amount);
        assertEq(_stateDigest(), before, "unauthorized spend changed state");
    }

    function testFuzz_approvalIsIdempotentAndDoesNotMoveValue(uint8 ownerSeed, uint8 spenderSeed, uint256 amount)
        public
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        _fund(owner, SUPPLY);
        uint256[7] memory before = _balances();
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(owner, spender), amount);
        bytes32 approved = _stateDigest();
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        assertEq(_stateDigest(), approved, "approval added instead of replacing");
        uint256[7] memory afterBalances = _balances();
        for (uint256 i; i < before.length; ++i) {
            assertEq(afterBalances[i], before[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroDirectAndDelegatedTransfersEmitOnlyOneTransferAcrossAllRoles() public {
        bytes32 before = _stateDigest();
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                vm.recordLogs();
                vm.prank(actors[i]);
                assertTrue(token.transfer(actors[j], 0));
                _assertZeroTransferLog(vm.getRecordedLogs(), actors[i], actors[j]);
                vm.recordLogs();
                vm.prank(ROUTER);
                assertTrue(token.transferFrom(actors[i], actors[j], 0));
                _assertZeroTransferLog(vm.getRecordedLogs(), actors[i], actors[j]);
            }
        }
        assertEq(_stateDigest(), before);
    }

    function test_zeroReceiverRejectsEvenZeroTransfersAndInfiniteAllowance() public {
        _fund(POOL, 100 ether);
        vm.prank(POOL);
        token.approve(ROUTER, type(uint256).max);
        bytes32 before = _stateDigest();
        for (uint256 i; i < 2; ++i) {
            uint256 amount = i == 0 ? 0 : 100 ether;
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            vm.prank(POOL);
            token.transfer(address(0), amount);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            vm.prank(ROUTER);
            token.transferFrom(POOL, address(0), amount);
            assertEq(_stateDigest(), before);
        }
    }

    function test_treasuryCannotReuseAllowanceAfterReceivingItsOwnFee() public {
        _fund(TREASURY, 100 ether);
        vm.prank(TREASURY);
        token.approve(ROUTER, 100 ether);
        vm.prank(ROUTER);
        token.transferFrom(TREASURY, POOL, 100 ether);
        assertEq(token.balanceOf(TREASURY), 99 ether);
        assertEq(token.allowance(TREASURY, ROUTER), 0);
        bytes32 before = _stateDigest();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ROUTER, 0, 99 ether));
        vm.prank(ROUTER);
        token.transferFrom(TREASURY, POOL, 99 ether);
        assertEq(_stateDigest(), before);
    }

    function test_poolSelfTransferStillConsumesGrossAllowance() public {
        _fund(POOL, 100 ether);
        vm.prank(POOL);
        token.approve(ROUTER, 100 ether);
        vm.prank(ROUTER);
        token.transferFrom(POOL, POOL, 100 ether);
        assertEq(token.balanceOf(POOL), 1 ether);
        assertEq(token.balanceOf(TREASURY), 99 ether);
        assertEq(token.allowance(POOL, ROUTER), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ROUTER, 0, 1));
        vm.prank(ROUTER);
        token.transferFrom(POOL, POOL, 1);
    }

    function test_replacedAllowanceIsNotAddedAndOtherSpenderCannotUseIt() public {
        _fund(ALICE, 100 ether);
        vm.startPrank(ALICE);
        token.approve(ROUTER, 100 ether);
        token.approve(ROUTER, 2 ether);
        vm.stopPrank();
        bytes32 before = _stateDigest();
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ROUTER, 2 ether, 3 ether)
        );
        vm.prank(ROUTER);
        token.transferFrom(ALICE, POOL, 3 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        vm.prank(BOB);
        token.transferFrom(ALICE, POOL, 1);
        assertEq(_stateDigest(), before);
        vm.prank(ROUTER);
        token.transferFrom(ALICE, POOL, 2 ether);
        assertEq(token.allowance(ALICE, ROUTER), 0);
        assertEq(token.balanceOf(ALICE), 98 ether);
        assertEq(token.balanceOf(POOL), 0.02 ether);
        assertEq(token.balanceOf(TREASURY), 1.98 ether);
    }

    function test_fullSupplyCanBeSoldThenEntirePoolBalanceBought() public {
        _fund(ALICE, SUPPLY);
        vm.prank(ALICE);
        token.transfer(POOL, SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(POOL), 10_000_000 ether);
        assertEq(token.balanceOf(TREASURY), 990_000_000 ether);
        vm.prank(POOL);
        token.transfer(BOB, 10_000_000 ether);
        assertEq(token.balanceOf(POOL), 0);
        assertEq(token.balanceOf(BOB), 100_000 ether);
        assertEq(token.balanceOf(TREASURY), 999_900_000 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_roundingEdgesInBothDirections() public {
        uint256[7] memory gross = [uint256(0), 1, 2, 99, 100, 101, SUPPLY];
        uint256[7] memory net = [uint256(0), 1, 1, 1, 1, 2, 10_000_000 ether];
        for (uint256 direction; direction < 2; ++direction) {
            for (uint256 i; i < gross.length; ++i) {
                uint256 snapshot = vm.snapshotState();
                address from = direction == 0 ? ALICE : POOL;
                address to = direction == 0 ? POOL : ALICE;
                _fund(from, gross[i]);
                vm.prank(from);
                token.approve(ROUTER, gross[i]);
                vm.prank(ROUTER);
                token.transferFrom(from, to, gross[i]);
                assertEq(token.balanceOf(from), 0);
                assertEq(token.balanceOf(to), net[i]);
                assertEq(token.balanceOf(TREASURY), gross[i] - net[i]);
                assertEq(token.allowance(from, ROUTER), 0);
                assertEq(token.totalSupply(), SUPPLY);
                assertTrue(vm.revertToState(snapshot));
            }
        }
    }

    function test_maximumDelegatedOverdrawPreservesFiniteAllowance() public {
        _fund(TREASURY, SUPPLY);
        vm.prank(TREASURY);
        token.approve(ROUTER, type(uint256).max - 1);
        bytes32 before = _stateDigest();
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, TREASURY, SUPPLY, type(uint256).max - 1
            )
        );
        vm.prank(ROUTER);
        token.transferFrom(TREASURY, POOL, type(uint256).max - 1);
        assertEq(_stateDigest(), before);
    }

    function test_delegatedPoolManagerEndpointsPayTaxAndSpendGrossAllowance() public {
        token.transfer(MANAGER, 100 ether);
        vm.prank(MANAGER);
        token.approve(ROUTER, 100 ether);
        vm.prank(ROUTER);
        assertTrue(token.transferFrom(MANAGER, POOL, 100 ether));
        assertEq(token.balanceOf(MANAGER), 0);
        assertEq(token.balanceOf(POOL), 1 ether);
        assertEq(token.balanceOf(TREASURY), 99 ether);
        assertEq(token.allowance(MANAGER, ROUTER), 0);

        vm.prank(POOL);
        token.approve(ROUTER, 1 ether);
        vm.prank(ROUTER);
        assertTrue(token.transferFrom(POOL, MANAGER, 1 ether));
        assertEq(token.balanceOf(POOL), 0);
        assertEq(token.balanceOf(MANAGER), 0.01 ether);
        assertEq(token.balanceOf(TREASURY), 99.99 ether);
        assertEq(token.allowance(POOL, ROUTER), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _fund(address account, uint256 amount) internal {
        if (account == POOL) {
            // Isolate spending from seeding fees, retaining full-supply balance edges.
            // Move fixture balances without changing supply; real funding is tested elsewhere.
            deal(address(token), address(this), token.balanceOf(address(this)) - amount);
            deal(address(token), POOL, token.balanceOf(POOL) + amount);
        } else {
            token.transfer(account, amount);
        }
        assertEq(token.balanceOf(account), amount, "fixture must fund the gross spend");
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _actor(uint8 seed) internal view returns (address) {
        return actors[uint256(seed) % actors.length];
    }

    function _balances() internal view returns (uint256[7] memory balances) {
        for (uint256 i; i < actors.length; ++i) {
            balances[i] = token.balanceOf(actors[i]);
        }
        balances[6] = token.balanceOf(address(this));
    }

    function _stateDigest() internal view returns (bytes32 digest) {
        digest = keccak256(abi.encode(_balances(), token.totalSupply(), token.balanceOf(address(0))));
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                digest = keccak256(abi.encode(digest, token.allowance(actors[i], actors[j])));
            }
        }
    }

    function _assertZeroTransferLog(Vm.Log[] memory logs, address from, address to) internal view {
        assertEq(logs.length, 1, "zero transfer must not emit a tax");
        assertEq(logs[0].emitter, address(token));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(from))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(to))));
        assertEq(abi.decode(logs[0].data, (uint256)), 0);
    }
}
