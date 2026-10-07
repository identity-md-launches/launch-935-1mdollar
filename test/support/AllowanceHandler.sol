// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {OneMDollar} from "src/OneMDollar.sol";

/// @dev Independent approvals persist across calls; failed operations leave the ghosts unchanged.
contract AllowanceHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    OneMDollar public immutable token;
    address[6] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    uint256 public nonzeroTransfers;
    uint256 public nonzeroSpends;
    uint256 public rejectedCalls;

    constructor(OneMDollar token_) {
        token = token_;
        actors = [
            address(0xA11CE),
            address(0xB0B),
            address(0xCA401),
            token_.liquidityPool(),
            token_.feeRecipient(),
            token_.poolManager()
        ];
        for (uint256 i; i < actors.length; ++i) {
            expectedBalance[actors[i]] = i == 0 ? SUPPLY - 5 * (SUPPLY / 6) : SUPPLY / 6;
        }
        // The manager's initial allocation to the pool is taxable too.
        uint256 poolNet = (SUPPLY / 6 + 99) / 100;
        expectedBalance[actors[3]] = poolNet;
        expectedBalance[actors[4]] += SUPPLY / 6 - poolNet;
    }

    function approve(uint8 ownerSeed, uint8 spenderSeed, uint256 amountSeed, uint8 mode) public {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = mode % 3 == 0 ? 0 : mode % 3 == 1 ? type(uint256).max : bound(amountSeed, 0, SUPPLY);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function transfer(uint8 fromSeed, uint8 toSeed, uint256 amountSeed, uint8 mode) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = _amount(amountSeed, expectedBalance[from], mode);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _recordTransfer(from, to, amount);
        if (amount != 0) ++nonzeroTransfers;
    }

    function spend(uint8 fromSeed, uint8 spenderSeed, uint8 toSeed, uint256 amountSeed, uint8 mode) external {
        address from = _actor(fromSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowance = expectedAllowance[from][spender];
        uint256 limit = expectedBalance[from] < allowance ? expectedBalance[from] : allowance;
        uint256 amount = _amount(amountSeed, limit, mode);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        if (allowance != type(uint256).max) expectedAllowance[from][spender] = allowance - amount;
        _recordTransfer(from, to, amount);
        if (amount != 0) ++nonzeroSpends;
    }

    function rejectOverBalance(uint8 fromSeed, uint8 toSeed, bool delegated, bool maximum) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = expectedBalance[from];
        uint256 amount = maximum ? type(uint256).max : held + 1;
        // A separate approval action is intentional: only the failed spend must roll back.
        if (delegated) approve(fromSeed, 2, amount, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount));
        vm.prank(delegated ? actors[2] : from);
        if (delegated) token.transferFrom(from, to, amount);
        else token.transfer(to, amount);
        ++rejectedCalls;
    }

    function revokeAndReject(uint8 fromSeed, uint8 spenderSeed, uint8 toSeed) external {
        address from = _actor(fromSeed);
        address spender = _actor(spenderSeed);
        approve(fromSeed, spenderSeed, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(from, _actor(toSeed), 1);
        ++rejectedCalls;
    }

    function rejectZeroReceiver(uint8 fromSeed, uint8 spenderSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address spender = _actor(spenderSeed);
        uint256 allowance = expectedAllowance[from][spender];
        // Include positive, finite allowance consumption before _transfer rejects the receiver.
        uint256 amount = bound(amountSeed, 0, allowance < SUPPLY ? allowance : SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(from, address(0), amount);
        ++rejectedCalls;
    }

    function rejectZeroSpender(uint8 ownerSeed, uint256 amount) external {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(_actor(ownerSeed));
        token.approve(address(0), amount);
        ++rejectedCalls;
    }

    function _recordTransfer(address from, address to, uint256 gross) internal {
        // Independent oracle: receiver keeps ceil(gross / 100), without using token constants
        // or copying its multiply-then-divide fee calculation. Aggregate credits handle aliases.
        uint256 net = gross;
        if (from == actors[3] || to == actors[3]) {
            net = gross / 100 + (gross % 100 == 0 ? 0 : 1);
        }
        expectedBalance[from] -= gross;
        expectedBalance[to] += net;
        expectedBalance[actors[4]] += gross - net;
    }

    function _amount(uint256 seed, uint256 limit, uint8 mode) internal pure returns (uint256) {
        if (mode % 5 == 0) return 0;
        if (mode % 5 == 1) return limit == 0 ? 0 : 1;
        if (mode % 5 == 2) return limit;
        if (mode % 5 == 3) return bound(seed, 0, limit < 101 ? limit : 101);
        return bound(seed, 0, limit);
    }

    function _actor(uint8 seed) internal view returns (address) {
        return actors[uint256(seed) % actors.length];
    }
}
