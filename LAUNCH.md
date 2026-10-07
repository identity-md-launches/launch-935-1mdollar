# Launch 935 operator handoff

The supplied project history records **Ethereum mainnet (chain 1), parked**.
It supplies no token address, deployment receipt, PoolManager address or hosting
details. No on-chain operation has been performed by this assignment. The token
source, constructor ABI, supply, economics and inherited `launch.json` are unchanged.

`script/PrepareLaunch.s.sol:PrepareLaunch` is an executable, read-only preflight
for continuing with an **existing** token. It checks the configuration against
that token and produces a pool-state snapshot plus unsigned initialization
calldata when needed. It does not mark the launch complete. There is no token
creation, approval, transfer, pool initialization, seeding or tax activation in
the script, and no wallet or private key is needed to run it.

## Required operator inputs

All addresses below must come from the network operator's authoritative deployment
record, not an upstream address list. No production address was verified here.

| Input, in argument order | Meaning and checks |
| --- | --- |
| `token` | Existing 1MD token with code. Name `1MDollar`, symbol `1MD`, decimals 18, supply 1e27 minor units, tax constants 9900/10000 and disabled tax must match. |
| `taxablePool` | Existing, separately verified fee-compatible venue; must exactly match the token's immutable `liquidityPool`. Code is required and inherited fixture `0x1001` is explicitly rejected. |
| `treasury` | Nonzero controlled address matching `feeRecipient`. Custodian must be able to call the token and spend fees. |
| `manager` | Verified v4 PoolManager with code, matching the token's immutable `poolManager`. The script uses the storage layout of the vendored v4-core. |
| `pairedCurrency` | Verified ERC-20 with code and a `decimals()` getter, or explicitly chosen zero address for native ETH. Cannot equal token or manager. |
| `tokenHolder` | Custodian/factory holding the existing supply needed for launch. Cannot be zero, the token, manager or taxable venue. Control and spending ability require separate verification. |
| `requiredTokenAmount` | Positive gross 1MD amount required by the reviewed seeding plan, at most 1e27. The holder must own at least this amount. This checks balance, not spending authorization. |
| `initialSqrtPriceX96` | Valid v4 initial price in sorted currency order; must be at least `MIN_SQRT_PRICE` and strictly below `MAX_SQRT_PRICE`. |

The preflight preserves a static AMM fee of 3000, tick spacing 60 and no hooks.
It sorts the currencies by address and returns the resulting key and pool ID.
Price is `sqrt(currency1 minor units / currency0 minor units) * 2**96`; account
for token ordering and both decimal counts. The report exposes the paired asset's
actual decimals (18 for native ETH). It does not compute a market-cap quote.

The inherited manifest records poolBps 8600, initialMarketCapWei
2680000000000000000000, initialPrice 79228162514264337593543950336, and the treasury
as remainder recipient. Its paired currency and treasury remain unverified. Do not
infer a token allocation or economically correct price from those values alone:
the launch operator must reconcile allocations, network shares, paired funding,
tick range, price, LP ownership and the existing launch pipeline before signing.

If the existing token's immutable pool is actually `0x1001`, changing a JSON value
cannot repair it. The preflight rejects that case. Report the incompatibility to
the network operator; this assignment offers no replacement or re-mint route.
Similarly, an already enabled tax cannot be disabled for a fee-free launch.

## Run and interpret the preflight

Populate the shell variables with the reviewed inputs above and an Ethereum RPC.
These are public configuration values, not secrets or private keys. The script
itself reads no environment variables or files. The command is a local simulation
with chain reads; there are no broadcast calls in its implementation.

```sh
forge script script/PrepareLaunch.s.sol:PrepareLaunch \
  --rpc-url "$ETHEREUM_RPC_URL" \
  --sig 'run((address,address,address,address,address,address,uint256,uint160))' \
  "($TOKEN,$TAXABLE_POOL,$TREASURY,$POOL_MANAGER,$PAIRED_CURRENCY,$TOKEN_HOLDER,$REQUIRED_TOKEN_AMOUNT,$INITIAL_SQRT_PRICE_X96)"
```

Record the returned observed block, token runtime code hash, pool key/ID, balances,
price, tick, active liquidity and calldata alongside the reviewed inputs. Match
the runtime and immutable values to the verified deployment artifact; matching
getters or the presence of code alone do not authenticate a contract. In particular,
a dummy venue with code can pass the code-presence check without supporting swaps.

- Zero current price means the v4 pool is uninitialized. The returned target and
  calldata describe `initialize(key, initialSqrtPriceX96)` only. This creates no
  liquidity and transfers no supply; initialization alone is not a token launch.
- A nonzero current price means the pool is already initialized. Initialization
  target and calldata are empty, even when its current price differs from the
  proposed price. Review its existing positions and trading history before resuming.
- Active liquidity is liquidity at the current tick. Zero does not prove no positions
  exist, or that seeding has never happened. The report is not a replay guard or a
  decision to seed again. It does not verify funding for the paired currency.
- Failure identifies a missing or inconsistent prerequisite. Fix the operator
  inputs or funding as appropriate; do not replace an existing token to pass checks.

Rerun against current state immediately before the operator's separately reviewed
transactions. State can change after a successful read. The report neither reserves
a price nor protects a later liquidity transaction from ordering or price movement.

## Responsibilities for actual release

1. The network operator supplies the existing token address and receipt, confirms
   verified source and treasury control, and resolves the placeholder venue. If
   no token deployment exists, stop and have the network operator resolve the
   parked launch record; this script cannot deploy one.
2. The operator reviews the launch pipeline's actual initialization, seeding and
   distribution transactions, exact approvals, deadline and slippage limits, funds
   and LP ownership. Its executor ABI and allocation rules were not supplied here,
   so the script cannot generate a complete funding or distribution transaction.
   Submit through the authorized network process after independent adversarial
   review; no signing or broadcaster is included in this deliverable.
3. The operator confirms receipts, pool positions, intended token distributions,
   and working buys/sells, then records transaction hashes, token address, pool ID
   and LP ownership in the launch record. A passing preflight is not that evidence.
4. Preserve the prior request's fee-free launch. The fixed treasury separately
   coordinates and discloses any later `enablePoolTax()` call. Activation is
   permanent and can be performed early by that treasury; there is no launch oracle.
   The 99% fee applies to the separate taxable endpoint, **not** the v4 launch pool.
   Changing that scope would require a different design, not a launch operation.

These are outstanding operational steps, not transactions completed by local tests.
There is no new contract to deploy for the preflight itself. No token was deployed,
redeployed, replaced or re-minted on a network. Tests create isolated local fixtures.

## Local validation

```sh
forge build
forge test
forge fmt --check
```

`test/PrepareLaunch.t.sol` exercises the actual script with a real local PoolManager:
native and both ERC-20 sort orders, six-decimal reporting, executable initialization
calldata, already initialized and funded pools, static/caller-independent execution,
wrong chain, missing code, placeholder pool, token/immutable mismatches, active tax,
invalid parameters, price bounds and fuzzed balance shortfalls. Reads preserve supply,
balances, allowances and activation state. The existing token's unit, fuzz, invariant
and v4 integration suites remain in place. Tests use no RPC, environment, FFI or
filesystem cheatcodes. Solidity remains pinned to 0.8.26 by the existing configuration.
No dependency was added. Mainnet verification, Slither, Mythril and independent
adversarial review were not performed by this assignment.
