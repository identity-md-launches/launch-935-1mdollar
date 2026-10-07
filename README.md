# 1MDollar (1MD)

`src/OneMDollar.sol:OneMDollar` is a fixed-supply ERC-20 with a 99% fee on
transfers into or out of one immutable liquidity-pool address. Ordinary wallet
transfers are untaxed. All 1,000,000,000 tokens (18 decimals) are minted once to
the constructor's `msg.sender`.

**Launch constraint:** the supplied launch checks require the Uniswap v4
PoolManager to settle the entire nominal transfer amount. A 99% transfer tax on
that manager would break those checks and swaps. This implementation therefore
taxes a **separate configured pool** and exempts transfers whose sender or
recipient is the launch PoolManager. The constructor rejects using that manager
as the taxed pool. The launch's v4 pool itself has **no token transfer tax**.
This is the explicit interpretation used to reconcile the request with the
checks; it does not implement a 99% tax on the launch pool itself. Requiring that
would need a change to the launch design and its acceptance checks.

## Transfer behavior and assumptions

The brief does not specify tax direction or destination. The assumptions here
are both buys and sells, with fees paid in 1MD to a fixed treasury. There is no
burn, redistribution, automatic swap, or conversion to ETH.

| Transfer endpoints | Fee |
| --- | --- |
| Either endpoint is the configured launch PoolManager | 0, including transfers involving the taxable pool |
| Otherwise, either endpoint is the configured taxable pool | 99% of gross amount, rounded down in minor units |
| All other endpoints | 0 |

For a taxable transfer of `amount`, `fee = floor(amount * 9900 / 10000)`;
the receiver gets `amount - fee`. For example, a 100 1MD sale delivers 1 1MD to
the pool and 99 1MD to the treasury. A 100 1MD pool output delivers 1 1MD to the
buyer. The sender must hold the gross amount. `transferFrom` requires and spends
the gross allowance. Standard OpenZeppelin unlimited allowances remain unchanged.
Approvals themselves have no tax, and the spender's identity does not determine
taxability.

Fees are rounded down, so transferring one minor unit charges zero fee; splitting
transfers can exploit this rounding. This is minor-unit precision, not a fee
minimum. Zero transfers succeed and emit `Transfer`. A pool-to-itself transfer
pays the fee; an ordinary self-transfer does not. If the treasury is a transfer
endpoint, its fee credit and transfer credit/debit are combined normally. It must
still hold the gross amount when sending. Taxed transfers emit the two nonzero
fee/net `Transfer` legs and a `PoolTax` event; when the fee is zero, only the
ordinary `Transfer` event is emitted.

The token sees addresses, not swaps: adding/removing liquidity, donations and
direct transfers involving the taxable pool also pay tax. Other pools are not
automatically detected or taxed. The deployer has no special exemption at the
taxable pool. Routing through the exempt manager or trading at other venues can
avoid this fee; this is not a guarantee of a 99% tax on all market activity.

The treasury receives ledger credits, with no external calls or recipient hooks.
It can spend its own tokens using ordinary ERC-20 operations. There is no owner,
tax setter, exemption setter, pause, blacklist, seizure, mint, burn, upgrade,
rescue, or post-deployment initialization function. Supply remains exactly
`1000000000000000000000000000` minor units. Transfers to the zero address revert.

## Deployment parameters

Constructor arguments are static and ordered as follows:

```solidity
new OneMDollar(liquidityPool, feeRecipient, poolManager);
```

| Argument | Required configuration |
| --- | --- |
| `liquidityPool` | Address of a separate pool whose integration supports fee-on-transfer tokens in both directions. Nonzero; distinct from this token, deployer, treasury and launch manager. |
| `feeRecipient` | Treasury controlled by the intended fee beneficiary. Nonzero; distinct from this token, pool and manager. May be the deployer. |
| `poolManager` | The actual launch PoolManager, supplied by the deployment network (`$poolManager` in launch constructor arguments). Nonzero; distinct from this token and deployer. |

Addresses are immutable and are not authenticated by the token. A constructor
code-size check would reject precomputed pool addresses and is deliberately not
used. The deployer must verify the network, address provenance, treasury control,
and actual pool integration before launch. No chain addresses, treasury address,
taxed pool address, paired asset, opening price or allocation parameters were
provided in this assignment; none have been invented for deployment.

A separately deployed pool may have a precomputed CREATE address that is
independent of the token's creation bytecode. Reserve that address first, compute
the token's CREATE2 address using the final arguments, then deploy the pool with
the intended token. An existing venue that can bind the token appropriately is
another option. Do not assume that mutually dependent token/pair CREATE2
predictions can be solved: a conventional pair address often depends on the
token address, while this token's CREATE2 address includes the pool argument.
The pool deployment/selection remains the launch operator's responsibility; this
project supplies the token, not another production AMM.

When a factory deploys the token, the entire initial supply belongs to that
factory, not `tx.origin`, the requester or the treasury. The factory remains
responsible for transferring the network's 10% swarm share, funding the v4
position and forwarding the remainder. Distributor claims and requester payouts
are ordinary untaxed transfers when recipients are not the separate taxable
pool. No factory lookup or `launchNumber` is required because taxation is limited
to that single pool. This project does not produce a network launch manifest or
choose missing economic parameters.

Use the fully qualified artifact `src/OneMDollar.sol:OneMDollar`. To inspect the
deployment ABI and creation bytecode locally:

```sh
forge inspect src/OneMDollar.sol:OneMDollar abi
forge inspect src/OneMDollar.sol:OneMDollar bytecode
```

The deployment payload is the compiled creation bytecode followed by
`abi.encode(liquidityPool, feeRecipient, poolManager)`. There are no additional
initialization calls. Review the final encoded addresses and predicted token
address before the network deployer submits anything. No deployment, broadcast
or wallet access is performed by this project.

## Build and validation

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity **0.8.26**, targets Cancun, enables the optimizer
with 200 runs and sets `bytecode_hash = "none"`. FFI and filesystem cheatcode
permissions are disabled. All imported Solidity dependencies are ordinary files
under `lib/`; there are no submodules, package installs, RPCs, environment
variables or network reads needed to build or run tests with the pinned compiler
available. Dependency commits are recorded in `DEPENDENCIES.json` and upstream
licenses accompany the vendored sources. OpenZeppelin v5.0.2 supplies the ERC-20
implementation; Uniswap v4 and Solmate are used only by local integration tests.

The delivered tests cover:

- Metadata, complete constructor mint, invalid addresses and immutable settings.
- Both tax directions, wallets, other venues, manager exemptions, treasury and
  self-transfer aliases, gross allowances, rounding, zero transfers and events.
- Rejected transfers, insufficient gross balances/allowances, rollback, approval
  revocation, and attempts to mint, freeze, seize or reconfigure the token.
- 512 cases per fuzz test and 128 invariant sequences of 64 calls, checking a
  balance model and conservation across direct and delegated transfers.
- A real local Uniswap v4 PoolManager with a CREATE2 factory, single-sided
  seeding, ordinary-trader buys/sells for native and ERC-20 pairs, swarm claims,
  requester payouts, runtime size and forbidden-opcode checks.

`test/LaunchCompatibility.t.sol` reproduces the relevant token properties from
the pinned floor without environment variables. It is not a run of the original
protected harness: that harness requires network-specific environment values
and launch helper contracts that were not included here. The local integration
uses a hookless pool; network initialization-guard behavior is outside this
token's implementation. The original network launch verification still belongs
to the independent verifier.

## Operational responsibilities

The treasury custodian manages the fee proceeds. Liquidity providers and router
operators must account for the 99% loss and use measured balance changes and
appropriate minimum received amounts. The separately taxed venue must support
fee-on-transfer tokens; the tested v4 launch is deliberately untaxed. Publish
these economics and the exemption before users trade.

The launch operator must verify deployed source/constructor arguments and
confirm all configured addresses and liquidity parameters. Changing the treasury,
taxed pool, manager or fee requires deploying a new token. An independent
adversarial review is required before release with others' funds. The local work
includes compilation, unit/fuzz/invariant tests and v4 integration tests;
Slither, Mythril, public-network tests and an independent audit were not run.
