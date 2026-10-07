# Additional adversarial coverage

These tests extend the existing token and launch suites without changing their fixtures.

`OneMDollarAdversarial.t.sol` runs four properties with 1,000 fuzz cases each:

- Direct and delegated transfers have identical balance effects, including sender,
  receiver, spender, and treasury aliases.
- An overdraw preserves every tracked balance and allowance, with sufficient finite
  or unlimited approval so the call reaches the balance check.
- An insufficient gross allowance cannot move balances or consume approval.
- Repeating an approval replaces the grant and never moves tokens.

Deterministic cases pin zero, one, rounding boundaries, the full supply, and a
near-maximum uint256 spend. They also cover stale approvals, spender isolation,
pool self-transfers, treasury fee credits, zero recipients, and zero-transfer logs.

`OneMDollarAllowancesInvariant.t.sol` targets seven handler actions for 256 runs
of 128 calls. Three wallets, the pool, treasury, and manager start funded using real
token transfers. Approvals persist between calls rather than being refreshed by
every spend. Ghost balances start from known allocations; ghost allowances change
only on approval or a successful gross spend. The invariants check every balance,
all 36 owner/spender allowance pairs, and fixed-supply conservation after each call.
Expected failures are checked for the exact custom error; unexpected handler
reverts fail the campaign. A deterministic sequence exercises every handler and
requires nonzero direct and delegated transfers.

The tax oracle expresses the recipient's one-percent share as ceiling division,
independent of the implementation's fee multiplication. It includes the launch
PoolManager exemption required for exact settlement. As in the existing launch
tests, the taxed pool is a separate address. These tests do not establish a 99%
tax on the launch's v4 pool. The supplied protected harness additionally requires
external launch contracts and deployment parameters; the local compatibility
suite is not a run of that harness.

Run with the vendored dependencies and installed Solidity 0.8.26:

```sh
forge build --offline --out test/scratch/out --cache-path test/scratch/cache
forge test --offline --out test/scratch/out --cache-path test/scratch/cache
```

Build artifacts and caches stay in disposable scratch space. No test imports
scratch files, reads environment variables, uses a fork, or requires a network.
