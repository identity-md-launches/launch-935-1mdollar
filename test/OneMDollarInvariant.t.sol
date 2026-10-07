// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OneMDollar} from "../src/OneMDollar.sol";

contract TransferHandler is Test {
    OneMDollar public immutable token;
    address[6] public actors;
    bool public activated;

    constructor(OneMDollar token_) {
        token = token_;
        actors = [
            address(this),
            address(0xA11CE),
            address(0xB0B),
            token.liquidityPool(),
            token.feeRecipient(),
            token.poolManager()
        ];
    }

    function move(uint8 fromSeed, uint8 toSeed, uint256 amountSeed, bool delegated) external {
        uint256 fromIndex = uint256(fromSeed) % actors.length;
        uint256 toIndex = uint256(toSeed) % actors.length;
        address from = actors[fromIndex];
        address to = actors[toIndex];
        uint256 amount = bound(amountSeed, 0, token.balanceOf(from));
        uint256[6] memory expected;
        for (uint256 i; i < actors.length; ++i) {
            expected[i] = token.balanceOf(actors[i]);
        }

        uint256 fee;
        if (activated && (fromIndex == 3 || toIndex == 3)) {
            fee = amount - (amount + 99) / 100;
        }
        // Apply aggregate balance changes, including aliased sender, receiver, and treasury.
        expected[fromIndex] -= amount;
        expected[4] += fee;
        expected[toIndex] += amount - fee;
        if (delegated) {
            vm.prank(from);
            token.approve(address(this), amount);
            token.transferFrom(from, to, amount);
            assertEq(token.allowance(from, address(this)), 0, "gross allowance");
        } else {
            vm.prank(from);
            token.transfer(to, amount);
        }
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]), expected[i], "balance model");
        }
    }

    function activate() external {
        if (activated) return;
        vm.prank(actors[4]);
        token.enablePoolTax();
        activated = true;
    }
}

contract OneMDollarInvariantTest is Test {
    OneMDollar internal token;
    TransferHandler internal handler;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        token = new OneMDollar(address(0x1001), address(0x1002), address(0x1003));
        handler = new TransferHandler(token);
        token.transfer(address(handler), SUPPLY);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = TransferHandler.move.selector;
        selectors[1] = TransferHandler.activate.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_fixedSupplyAndConservationAcrossTransfers() public view {
        uint256 sum;
        for (uint256 i; i < 6; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.poolTaxEnabled(), handler.activated());
    }
}
