// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {OneMDollar} from "../src/OneMDollar.sol";

/// @dev Test venue models a pair sending its output to a trader-selected recipient.
contract RelayTestVenue {
    OneMDollar internal immutable token;

    constructor(OneMDollar token_) {
        token = token_;
    }

    function swapOut(address to, uint256 amount) external {
        token.transfer(to, amount);
    }
}

/// @dev Uses actual permissionless manager accounting, without a mock or manager impersonation.
contract RelayTestTrader is IUnlockCallback {
    IPoolManager internal immutable manager;
    OneMDollar internal immutable token;
    RelayTestVenue internal immutable venue;

    constructor(IPoolManager manager_, OneMDollar token_, RelayTestVenue venue_) {
        manager = manager_;
        token = token_;
        venue = venue_;
    }

    function relay(bool sell, uint256 amount) external {
        manager.unlock(abi.encode(sell, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (bool sell, uint256 amount) = abi.decode(data, (bool, uint256));
        Currency currency = Currency.wrap(address(token));
        manager.sync(currency);
        if (sell) token.transfer(address(manager), amount);
        else venue.swapOut(address(manager), amount);
        uint256 paid = manager.settle();
        manager.take(currency, sell ? address(venue) : address(this), paid);
        return "";
    }
}

contract PoolManagerRelayTest is Test {
    PoolManager internal manager;
    OneMDollar internal token;
    RelayTestVenue internal venue;
    RelayTestTrader internal trader;
    address internal constant TREASURY = address(0x1002);
    uint256 internal constant MANAGER_RESERVE = 30 ether;

    event PoolTax(address indexed from, address indexed to, uint256 fee);

    function setUp() public {
        manager = new PoolManager(address(this));
        address predictedVenue = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        token = new OneMDollar(predictedVenue, TREASURY, address(manager));
        venue = new RelayTestVenue(token);
        assertEq(address(venue), predictedVenue);
        trader = new RelayTestTrader(manager, token, venue);
        token.transfer(address(manager), MANAGER_RESERVE);
    }

    function test_sellRelayChargesExactly99Percent() public {
        token.transfer(address(trader), 100 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit PoolTax(address(manager), address(venue), 99 ether);
        trader.relay(true, 100 ether);
        assertEq(token.balanceOf(address(trader)), 0);
        assertEq(token.balanceOf(address(venue)), 1 ether);
        assertEq(token.balanceOf(TREASURY), 99 ether);
        assertEq(token.balanceOf(address(manager)), MANAGER_RESERVE);
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY());
    }

    function test_buyRelayChargesExactly99Percent() public {
        token.transfer(address(venue), 10_000 ether);
        assertEq(token.balanceOf(address(venue)), 100 ether);
        uint256 treasuryBefore = token.balanceOf(TREASURY);
        vm.expectEmit(true, true, false, true, address(token));
        emit PoolTax(address(venue), address(manager), 99 ether);
        trader.relay(false, 100 ether);
        assertEq(token.balanceOf(address(venue)), 0);
        assertEq(token.balanceOf(address(trader)), 1 ether);
        assertEq(token.balanceOf(TREASURY) - treasuryBefore, 99 ether);
        assertEq(token.balanceOf(address(manager)), MANAGER_RESERVE);
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY());
    }
}
