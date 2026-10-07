// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
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

/// forge-config: default.fuzz.runs = 1000
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

    function testFuzz_relayMatchesDirectTransfer(bool sell, uint256 amount) public {
        amount = bound(amount, 0, _fundingLimit(sell));
        _fundRelay(sell, amount);
        _assertRelayMatchesDirect(sell, amount);
    }

    function testFuzz_relayOverdrawRollsBackAndAllowsRetry(bool sell, uint256 held, uint256 excess) public {
        held = bound(held, 0, _fundingLimit(sell));
        uint256 amount = bound(excess, held + 1, type(uint256).max);
        _fundRelay(sell, held);
        address from = sell ? address(trader) : address(venue);
        bytes32 before = keccak256(abi.encode(_balances(), token.totalSupply()));

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount));
        trader.relay(sell, amount);
        assertEq(keccak256(abi.encode(_balances(), token.totalSupply())), before, "failed relay changed balances");

        // A reverted unlock must not poison the next sync/settle/take cycle.
        _assertRelayMatchesDirect(sell, held);
    }

    function test_relayRoundingEdgesAndEntireAvailableBalance() public {
        uint256[7] memory edges = [uint256(0), 1, 2, 99, 100, 101, 0];
        for (uint256 direction; direction < 2; ++direction) {
            bool sell = direction == 0;
            edges[6] = _fundingLimit(sell);
            for (uint256 i; i < edges.length; ++i) {
                uint256 snapshot = vm.snapshotState();
                _fundRelay(sell, edges[i]);
                _assertRelayMatchesDirect(sell, edges[i]);
                assertTrue(vm.revertToState(snapshot));
            }
        }
    }

    function _assertRelayMatchesDirect(bool sell, uint256 amount) internal {
        uint256 snapshot = vm.snapshotState();
        vm.prank(sell ? address(trader) : address(venue));
        assertTrue(token.transfer(sell ? address(venue) : address(trader), amount));
        uint256[5] memory direct = _balances();
        assertTrue(vm.revertToState(snapshot));

        trader.relay(sell, amount);
        assertEq(abi.encode(_balances()), abi.encode(direct), "manager routing changed transfer economics");
        assertEq(token.balanceOf(address(manager)), MANAGER_RESERVE, "relay consumed existing reserves");
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function _fundingLimit(bool sell) internal pure returns (uint256) {
        uint256 available = 1_000_000_000 ether - MANAGER_RESERVE;
        return sell ? available : available / 100;
    }

    function _fundRelay(bool sell, uint256 amount) internal {
        address from = sell ? address(trader) : address(venue);
        assertTrue(token.transfer(from, sell ? amount : amount * 100));
        assertEq(token.balanceOf(from), amount, "fixture must fund the gross relay amount");
    }

    function _balances() internal view returns (uint256[5] memory) {
        return [
            token.balanceOf(address(this)),
            token.balanceOf(address(trader)),
            token.balanceOf(address(venue)),
            token.balanceOf(address(manager)),
            token.balanceOf(TREASURY)
        ];
    }
}
