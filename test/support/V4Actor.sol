// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {OneMDollar} from "../../src/OneMDollar.sol";

/// @dev Test-only factory/trader actor. Settles actual v4 deltas using its own funds.
contract V4Actor is IUnlockCallback {
    IPoolManager public immutable manager;
    address private immutable controller = msg.sender;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    modifier onlyController() {
        require(msg.sender == controller, "controller only");
        _;
    }

    receive() external payable {}

    function deploy(address taxedPool, address treasury) external onlyController returns (OneMDollar) {
        return new OneMDollar{salt: bytes32(uint256(7))}(taxedPool, treasury, address(manager));
    }

    function move(IERC20 token, address to, uint256 amount) external onlyController {
        require(token.transfer(to, amount), "transfer failed");
    }

    function seed(PoolKey calldata key, bool tokenIsZero) external onlyController {
        manager.unlock(abi.encode(true, key, tokenIsZero, int256(10_000 ether)));
    }

    function swap(PoolKey calldata key, bool zeroForOne, int256 amount) external onlyController {
        manager.unlock(abi.encode(false, key, zeroForOne, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (bool isSeed, PoolKey memory key, bool direction, int256 amount) =
            abi.decode(data, (bool, PoolKey, bool, int256));
        BalanceDelta delta;
        if (isSeed) {
            (delta,) = manager.modifyLiquidity(
                key,
                ModifyLiquidityParams(
                    direction ? int24(0) : int24(-600), direction ? int24(600) : int24(0), amount, bytes32(0)
                ),
                ""
            );
        } else {
            uint160 limit = direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            delta = manager.swap(key, SwapParams(direction, amount, limit), "");
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            uint256 paid;
            if (Currency.unwrap(currency) == address(0)) {
                paid = manager.settle{value: amount}();
            } else {
                manager.sync(currency);
                require(IERC20(Currency.unwrap(currency)).transfer(address(manager), amount), "payment failed");
                paid = manager.settle();
            }
            require(paid == amount, "settlement arrived short");
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(int256(delta)));
        }
    }
}
