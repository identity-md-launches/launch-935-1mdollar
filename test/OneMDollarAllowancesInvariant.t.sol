// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OneMDollar} from "src/OneMDollar.sol";
import {AllowanceHandler} from "./support/AllowanceHandler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract OneMDollarAllowancesInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    OneMDollar internal token;
    AllowanceHandler internal handler;

    function setUp() public {
        token = new OneMDollar(address(0x1001), address(0x1002), address(0x1003));
        handler = new AllowanceHandler(token);
        address manager = token.poolManager();
        token.transfer(manager, SUPPLY);
        for (uint256 i; i < 5; ++i) {
            address actor = handler.actors(i);
            uint256 allocation = i == 0 ? SUPPLY - 5 * (SUPPLY / 6) : SUPPLY / 6;
            vm.prank(manager);
            token.transfer(actor, allocation);
        }
        // Begin with real spendable grants; subsequent approve/revoke actions mutate them.
        for (uint8 i; i < 6; ++i) {
            handler.approve(i, (i + 1) % 6, SUPPLY / 12, 2);
            handler.approve(i, (i + 2) % 6, 0, 1);
        }
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = AllowanceHandler.approve.selector;
        selectors[1] = AllowanceHandler.transfer.selector;
        selectors[2] = AllowanceHandler.spend.selector;
        selectors[3] = AllowanceHandler.rejectOverBalance.selector;
        selectors[4] = AllowanceHandler.revokeAndReject.selector;
        selectors[5] = AllowanceHandler.rejectZeroReceiver.selector;
        selectors[6] = AllowanceHandler.rejectZeroSpender.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_balancesMatchPersistentGhostLedger() public view {
        for (uint256 i; i < 6; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.expectedBalance(actor), "unexpected balance mutation");
        }
    }

    function invariant_onlyAuthorizedGrossSpendsReduceAllowances() public view {
        for (uint256 i; i < 6; ++i) {
            address owner = handler.actors(i);
            assertEq(token.allowance(owner, address(0)), 0);
            for (uint256 j; j < 6; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender), "approval history");
            }
        }
    }

    function invariant_supplyCannotLeakToUntrackedAccounts() public view {
        uint256 sum;
        for (uint256 i; i < 6; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(this)), 0);
    }

    /// @dev Deterministic witness that every handler is reachable and ghosts survive failures.
    function test_handlerExercisesSpendsRevocationAndBalanceFailures() public {
        handler.transfer(0, 3, 100 ether, 4);
        handler.spend(3, 4, 1, 100 ether, 4);
        handler.approve(4, 1, 100 ether, 2);
        handler.spend(4, 1, 3, 100 ether, 4);
        handler.revokeAndReject(4, 1, 3);
        handler.rejectOverBalance(3, 4, true, true);
        handler.rejectOverBalance(4, 3, false, false);
        handler.rejectZeroReceiver(0, 1, 1 ether);
        handler.rejectZeroSpender(3, type(uint256).max);
        invariant_balancesMatchPersistentGhostLedger();
        invariant_onlyAuthorizedGrossSpendsReduceAllowances();
        invariant_supplyCannotLeakToUntrackedAccounts();
        assertEq(handler.nonzeroTransfers(), 1);
        assertEq(handler.nonzeroSpends(), 2);
        assertEq(handler.rejectedCalls(), 5);
    }
}
