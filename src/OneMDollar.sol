// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply 1MD with a 99% transfer fee at one configured pool.
/// @dev The launch PoolManager is exempt so its exact settlement accounting remains valid.
///      The taxed pool MUST be a different, fee-on-transfer-compatible venue.
contract OneMDollar is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 public constant TAX_BPS = 9_900;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    address public immutable liquidityPool;
    address public immutable feeRecipient;
    address public immutable poolManager;

    error InvalidLiquidityPool();
    error InvalidFeeRecipient();
    error InvalidPoolManager();

    event PoolTax(address indexed from, address indexed to, uint256 fee);

    /// @param liquidityPool_ The single taxable pool, possibly a precomputed deployment address.
    /// @param feeRecipient_ Fixed treasury receiving fees in 1MD.
    /// @param poolManager_ Launch PoolManager; transfers to or from it are always untaxed.
    constructor(address liquidityPool_, address feeRecipient_, address poolManager_) ERC20("1MDollar", "1MD") {
        if (poolManager_ == address(0) || poolManager_ == address(this) || poolManager_ == msg.sender) {
            revert InvalidPoolManager();
        }
        if (feeRecipient_ == address(0) || feeRecipient_ == address(this) || feeRecipient_ == poolManager_) {
            revert InvalidFeeRecipient();
        }
        if (
            liquidityPool_ == address(0) || liquidityPool_ == address(this) || liquidityPool_ == msg.sender
                || liquidityPool_ == feeRecipient_ || liquidityPool_ == poolManager_
        ) revert InvalidLiquidityPool();

        liquidityPool = liquidityPool_;
        feeRecipient = feeRecipient_;
        poolManager = poolManager_;
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (
            from != address(0) && (from == liquidityPool || to == liquidityPool) && from != poolManager
                && to != poolManager
        ) {
            // Check the gross debit, including when the sender is also the fee recipient.
            uint256 balance = balanceOf(from);
            if (balance < value) revert ERC20InsufficientBalance(from, balance, value);

            // The balance check bounds value by the fixed supply, so multiplication cannot overflow.
            uint256 fee = (value * TAX_BPS) / BPS_DENOMINATOR;
            if (fee != 0) {
                super._update(from, feeRecipient, fee);
                emit PoolTax(from, to, fee);
            }
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}
