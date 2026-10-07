# Additional adversarial coverage

`PrepareLaunch.t.sol` checks the read-only launch script against an existing local
token and real v4 PoolManager. It covers valid native/ERC-20 configurations, both
currency orders, non-18-decimal pairs, accepted initialization calldata, initialized
and funded pools, caller-independent static execution and unchanged ledgers. Failure
tests reject wrong chains, missing code, the inherited placeholder pool, unexpected
token properties, immutable-address mismatches, active tax, invalid parameters and
insufficient funding. The balance threshold is fuzzed at success and failure boundaries.
All fixtures are local; passing does not verify production addresses or complete a launch.

The existing fee-accounting suites explicitly activate the fee in setup; the launch
suite starts with the fee disabled. No tests use environment variables or RPCs.

`PoolTaxActivation.t.sol` covers fee-free funding and both trade directions, the
activation event, unchanged balances and pre-existing approvals at activation,
unauthorized callers (including factory/deployer, pool and manager), repeated
activation, absent disable/rate setters, and atomic balance/allowance failures
in both phases. A fuzz property compares direct and delegated transfers across
the switch, including zero, dust and full available balances.

`OneMDollarInvariant.t.sol` interleaves activation with direct/delegated transfers
using a separate ghost activation flag and checks fixed supply, exact balance
effects and permanent activation. The treasury is impersonated only to exercise
its authorized call; production requires an actual treasury transaction.

`LaunchCompatibility.t.sol` deploys through a real local CREATE2 factory with
the fee off. Native/ERC-20 v4 pools are seeded and bought before activation,
then bought/sold after activation; the separately configured taxable venue alone
is taxed. A factory-funded pool lifecycle also verifies full initial seeding
and 99% fees on both directions after treasury activation.

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
The isolated spending tests use `deal` to move an equal balance from the deployer
to the pool without changing supply, so full-supply spending remains covered.
This fixture does not model pool funding; the unit, invariant and relay suites
exercise the actual tax on funding transfers. A delegated manager-to-pool-to-manager
regression uses real transfers and checks the fee and gross allowance on both legs.

`OneMDollarAllowancesInvariant.t.sol` targets seven handler actions for 256 runs
of 128 calls. Three wallets, the pool, treasury, and manager start funded using real
token transfers. Approvals persist between calls rather than being refreshed by
every spend. Ghost balances start from known allocations, including the fee on
the initial manager-to-pool allocation; ghost allowances change
only on approval or a successful gross spend. The invariants check every balance,
all 36 owner/spender allowance pairs, and fixed-supply conservation after each call.
Expected failures are checked for the exact custom error; unexpected handler
reverts fail the campaign. A deterministic sequence exercises every handler and
requires nonzero direct and delegated transfers.
A second deterministic sequence checks direct and delegated transfers between
the manager and pool in both directions, comparing the ledger after each transfer.
All three invariants are also checked at the end of setup.

`PoolManagerRelay.t.sol` additionally runs two properties with 1,000 fuzz cases
each against the real local manager. Routing a transfer through `unlock`, `sync`,
`settle`, and `take` must match a direct transfer across all five tracked accounts.
An overdraw must return the exact insufficient-balance error, preserve balances
and supply, and permit a valid retry without consuming existing manager reserves.
Deterministic relay cases cover zero, one, two, 99, 100, 101 minor units and the
entire balance obtainable through real taxed funding, in both directions.

The tax oracle expresses the recipient's one-percent share as ceiling division,
independent of the implementation's fee multiplication. Every transfer involving
the configured pool is taxed, including transfers to or from the launch PoolManager.
Manager transfers with no configured-pool endpoint remain untaxed. As in the existing
launch tests, the taxed pool is a separate address. These tests do not establish a 99%
tax on the launch's v4 pool. The supplied protected harness additionally requires
external launch contracts and deployment parameters; the local compatibility
suite is not a run of that harness.

Run with the vendored dependencies and installed Solidity 0.8.26:

```sh
forge build --offline --out test/scratch/out --cache-path test/scratch/cache
FOUNDRY_FUZZ_FAILURE_PERSIST_DIR=test/scratch/fuzz \
FOUNDRY_INVARIANT_FAILURE_PERSIST_DIR=test/scratch/invariant \
FOUNDRY_TEST_FAILURES_FILE=test/scratch/test-failures \
forge test --offline --out test/scratch/out --cache-path test/scratch/cache
```

Build artifacts and caches stay in disposable scratch space. No test imports
scratch files, reads environment variables, uses a fork, or requires a network.
