// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {OneMDollar} from "../src/OneMDollar.sol";
import {V4Actor} from "./support/V4Actor.sol";

contract TestPairToken is ERC20 {
    constructor() ERC20("Test pair", "PAIR") {}

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }
}

/// @dev Local, environment-free checks of the supplied launch floor's token properties.
contract LaunchCompatibilityTest is Test {
    PoolManager internal manager;
    V4Actor internal factory;
    OneMDollar internal token;
    address internal constant POOL = address(0x1001);
    address internal constant TREASURY = address(0x1002);
    address internal constant DISTRIBUTOR = address(0xD157);
    address internal constant CLAIMANT = address(0xC1A1);
    address internal constant HOLDER = address(0x401D);
    address internal constant OTHER = address(0x07E5);
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        manager = new PoolManager(address(this));
        factory = new V4Actor(manager);
        token = factory.deploy(POOL, TREASURY);
    }

    function test_create2FactoryReceivesEntireSupply() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_factoryCannotBeFeeRecipient() public {
        vm.expectRevert(OneMDollar.InvalidFeeRecipient.selector);
        factory.deploy(POOL, address(factory));
    }

    function test_swarmShareAndClaimsArriveWhole() public {
        factory.move(token, DISTRIBUTOR, SUPPLY / 10);
        assertEq(token.balanceOf(DISTRIBUTOR), SUPPLY / 10);
        vm.prank(DISTRIBUTOR);
        token.transfer(CLAIMANT, SUPPLY / 10);
        assertEq(token.balanceOf(CLAIMANT), SUPPLY / 10);
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
        assertEq(token.balanceOf(TREASURY), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_nativePairSingleSidedSeedBuyAndSell() public {
        _roundTrip(address(0));
    }

    function test_erc20PairSingleSidedSeedBuyAndSell() public {
        _roundTrip(address(new TestPairToken()));
    }

    function test_noCommonAdminCallCanMintOrControlHolder() public {
        factory.move(token, HOLDER, SUPPLY / 1000);
        string[26] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)",
            "setLiquidityPool(address)",
            "setFeeRecipient(address)",
            "setTaxBps(uint256)",
            "setExempt(address,bool)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], HOLDER, 1);
            vm.prank(address(factory));
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(OTHER);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY);
            assertEq(token.balanceOf(HOLDER), SUPPLY / 1000);
        }
        vm.prank(address(factory));
        vm.expectRevert();
        token.transferFrom(HOLDER, address(factory), 1);
        vm.prank(HOLDER);
        token.transfer(OTHER, SUPPLY / 1000);
        assertEq(token.balanceOf(OTHER), SUPPLY / 1000);
    }

    function test_runtimeHasNoForbiddenOpcodesAndFitsEIP170() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }

    function test_actorRejectsForgedCallback() public {
        vm.expectRevert("manager only");
        factory.unlockCallback("");
    }

    function _roundTrip(address paired) internal {
        factory.move(token, DISTRIBUTOR, SUPPLY / 10);
        bool tokenIsZero = address(token) < paired;
        PoolKey memory key = PoolKey(
            Currency.wrap(tokenIsZero ? address(token) : paired),
            Currency.wrap(tokenIsZero ? paired : address(token)),
            3000,
            60,
            IHooks(address(0))
        );
        manager.initialize(key, uint160(1 << 96));
        uint256 beforeSeed = token.balanceOf(address(factory));
        factory.seed(key, tokenIsZero);
        uint256 seeded = beforeSeed - token.balanceOf(address(factory));
        assertGt(seeded, 0);
        assertLe(seeded, SUPPLY * 40 / 100);
        assertEq(token.balanceOf(address(manager)), seeded);

        V4Actor trader = new V4Actor(manager);
        if (paired == address(0)) vm.deal(address(trader), 10 ether);
        else TestPairToken(paired).mint(address(trader), 10 ether);
        trader.swap(key, !tokenIsZero, -0.01 ether);
        uint256 bought = token.balanceOf(address(trader));
        assertGt(bought, 0);
        // Token balance is bounded by the fixed 1e27 supply, which fits int256.
        trader.swap(key, tokenIsZero, -int256(bought));
        assertEq(token.balanceOf(address(trader)), 0);
        assertEq(token.balanceOf(address(manager)), seeded);
        assertEq(token.balanceOf(TREASURY), 0);
        assertEq(token.totalSupply(), SUPPLY);
        uint256 pairAfter =
            paired == address(0) ? address(trader).balance : TestPairToken(paired).balanceOf(address(trader));
        assertGt(pairAfter, 9.99 ether);
        assertLt(pairAfter, 10 ether);

        factory.move(token, OTHER, token.balanceOf(address(factory)));
        assertEq(token.balanceOf(OTHER), SUPPLY - SUPPLY / 10 - seeded);
    }
}
