# 1MDollar (1MD)

`src/OneMDollar.sol:OneMDollar` is a fixed-supply ERC-20 that **starts with no
transfer fee**, including transfers to and from its configured liquidity pool.
After launch, the fixed treasury calls `enablePoolTax()` once to permanently
activate a **99% token transfer fee** at that pool. Ordinary wallet transfers
remain untaxed. All 1,000,000,000 tokens (18 decimals) are minted once to the
constructor's `msg.sender`; activation neither moves tokens nor changes supply.

This assignment changes source and local tests only. Nothing is deployed,
redeployed, replaced or re-minted, and no transactions are broadcast. The project
history describes Ethereum mainnet launch 935 as parked and supplies no live token
address. This non-upgradeable source change cannot alter an already deployed token;
any existing deployment retains its original behavior. Deployment status and the
available code must be confirmed by the network operator without replacing a live token.

## Launch and activation

1. Confirm the constructor parameters and that the treasury can call the token.
   Deployment starts with `poolTaxEnabled() == false`.
2. Complete launch funding, liquidity seeding, distributions and initial trading
   while transfers deliver their full nominal amount. Neither the deployer nor
   launch factory can activate the tax unless it is the treasury (the constructor
   prohibits the deployer from being the treasury).
3. The treasury custodian verifies that launch has completed, the configured
   taxable venue exists and supports taxed transfers, and the intended initial
   liquidity is funded. Publish the activation timing and economics to traders.
4. The treasury itself calls `enablePoolTax()` on the correct token. Check the
   receipt for `PoolTaxEnabled(liquidityPool, feeRecipient)` and confirm
   `poolTaxEnabled() == true` before presenting the fee as active.

**Timing is an operational trust assumption.** There is no supplied launch oracle,
completion callback, activation timestamp or automatic launch detector. The treasury
can activate early or leave the tax disabled indefinitely. Only its address is
accepted as `msg.sender` (not `tx.origin`). Use a controlled treasury, preferably a
multisig capable of making arbitrary contract calls. A passive recipient contract
that can only receive tokens cannot perform activation. Treasury authority is fixed
and cannot be transferred or recovered by the token if access is lost.

Activation is one-way: subsequent authorized calls revert with
`PoolTaxAlreadyEnabled`; other callers revert with `UnauthorizedTaxActivation`.
There is no disable function, fee-rate setter, pool/treasury setter or exemption
list. Activation affects subsequent transfers, including spending approvals granted
before launch; it does not retroactively charge earlier transfers or existing pool
balances. Transactions execute under the state at their execution time, so ordering
around activation changes the received amount. Routers must protect actual received
amounts and users must review outstanding approvals before activation.

## Pool scope and compatibility

The existing project uses a **separate taxable liquidity-pool address**, distinct
from the Uniswap v4 launch PoolManager. This revision preserves that scope and
changes when the tax begins. The v4 launch manager remains untaxed before and after
activation unless a transfer's other endpoint is the separately configured pool.
This does **not** activate a fee on the v4 launch pool itself: v4 holds multiple
pools at one manager address, and its nominal settlement is incompatible with this
99% transfer tax. A pool-specific v4 AMM fee/hook is outside this implementation.
The constructor continues to reject using the manager as the taxable endpoint.

Before activation all transfers are untaxed. After activation, when either endpoint
is `liquidityPool`, `fee = floor(amount * 9900 / 10000)` is credited in 1MD to
`feeRecipient`, and the receiver gets `amount - fee`. For 100 1MD, that is 99 1MD
for the treasury and 1 1MD for the receiver, in both buy and sell directions.
Fees are not burned, swapped, converted to ETH or redistributed automatically.

The sender must hold the gross amount, including a treasury sending to the pool.
`transferFrom` requires and spends the gross allowance; standard OpenZeppelin
unlimited allowances remain unchanged. The spender alone does not determine the
fee. PoolManager relays to/from the taxable pool still pay the fee. Other pools
and wallet transfers are untaxed, including treasury wallet transfers. There is
no special deployer exemption.

Taxation sees endpoints, not swaps: liquidity additions/removals, donations,
direct transfers and pool self-transfers pay the fee after activation. Wallet
self-transfers are untaxed. Zero transfers succeed; one minor unit incurs zero
fee because of rounding, and splitting transfers can exploit minor-unit rounding.
Nonzero fees emit `PoolTax` and fee/net ERC-20 `Transfer` events. Treasury credits
make no external calls or recipient hooks. Zero-address transfers revert. There
is no mint after construction, burn, pause, blacklist, seizure, upgrade or rescue.

## Parameters and production responsibilities

The constructor ABI and argument order are unchanged:

```solidity
new OneMDollar(liquidityPool, feeRecipient, poolManager);
```

| Parameter | Required configuration |
| --- | --- |
| `liquidityPool` | A verified separate venue supporting fee-on-transfer tokens in both directions. Nonzero; distinct from token, deployer, treasury and launch manager. |
| `feeRecipient` | Controlled treasury receiving token fees and responsible for post-launch activation. Nonzero; distinct from token, pool, manager and deployer. |
| `poolManager` | Actual launch PoolManager from the deployment network. Nonzero; distinct from token and deployer. |

These addresses are immutable and not authenticated by the token. No code-size
check is used, allowing a precomputed pool address. Verify chain, address provenance,
venue implementation, treasury control and treasury ability to spend 1MD and call
`enablePoolTax()` before launch. The constructor deploying factory receives all
initial supply, rather than `tx.origin` or the treasury; it remains responsible
for the swarm share, launch liquidity and remainder payout.

`launch.json` retains the existing constructor arguments and economic parameters.
Its first argument, `0x1001`, is an inherited **test fixture, not a verified
production pool**. The manifest is not ready for production until the network
operator supplies a functional fee-compatible venue. Treasury and paired-asset
addresses in the inherited manifest have not been verified in this assignment.
Its `pool.fee = 3000` describes a separate 0.3% AMM fee, not the 99% token tax.
No missing addresses, venue, liquidity allocation or activation date are invented.
Do not treat a placeholder endpoint as delivering production pool economics.

A precomputed CREATE pool address can be reserved independently of token creation
bytecode. Conventional mutually dependent token/pair CREATE2 predictions cannot
be assumed solvable. Pool selection/deployment remains the network operator's
responsibility; this project adds no production AMM, deployment script or wallet
access. The artifact is `src/OneMDollar.sol:OneMDollar`; creation bytecode is followed
by `abi.encode(liquidityPool, feeRecipient, poolManager)`. Activation is a separate
post-launch treasury transaction, never a constructor or factory initialization call.

The network operator must confirm the applicable deployment status, verified source,
encoded addresses, liquidity parameters and venue compatibility. The treasury
custodian coordinates and performs activation, monitors its receipt and manages
fee proceeds. Router operators and liquidity providers must account for the 99%
loss using measured balance changes and appropriate minimum received amounts.
An independent adversarial review remains necessary before release with others'
funds. Local tests are not a security audit.

## Validation

```sh
forge build
forge test
forge fmt --check
```

The existing configuration pins Solidity 0.8.26, Cancun, optimizer 200 runs and
`bytecode_hash = "none"`; it has not been modified. Existing vendored dependencies
are ordinary files in `lib/`, recorded in `DEPENDENCIES.json`. No new dependency,
network, RPC, environment variable, FFI or filesystem cheatcode is required by tests.

Tests cover fee-free launch, real CREATE2 factory deployment, funding and trading,
treasury-only irreversible activation and its event, unchanged balances/allowances
at activation, existing liquidity/approval taxation, both directions and delegation,
rounding, gross spending and atomic failure in both phases. Existing unit,
adversarial, allowance invariant and real-manager relay tests exercise the active
phase. Transfer invariants interleave untaxed/taxed direct and delegated transfers
with activation, checking conservation and monotonic activation. Real local v4
integration seeds and buys before activation, then buys/sells after activation for
native and ERC-20 pairs, confirming its settlement remains intact. See
`test/TESTING.md` for further coverage.

These local integrations do not run the network's protected launch harness or
verify production addresses. Slither, Mythril, public-chain tests and an independent
audit were not run. Build, unit, fuzz, invariant and local v4 integration checks
are the validation performed here.
