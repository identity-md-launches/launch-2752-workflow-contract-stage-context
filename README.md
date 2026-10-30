# Hamster Road Trip — `RoadTripVotes`

The on-chain half of the Hamster Road Trip community game. Wallets vote once per 24-hour epoch for one
of 64 destinations; when an epoch ends anyone can finalize it, the destination with the most votes wins
(ties to the lowest id) and is appended to the route queue. The contract has **no owner, admin, upgrade
path, token or payments**.

This repository is the contracts stage of the launch: implementation, tests, deploy script and ABI.
The launch manifest (`launch.json`) is written by a later assignment, and the website is a separate
deliverable that reads the deployed address and `docs/abi/RoadTripVotes.json`.

## Layout

| Path | Purpose |
| --- | --- |
| `src/RoadTripVotes.sol` | The contract (the only one this launch deploys). |
| `test/RoadTripVotes.t.sol` | Foundry unit, scenario and fuzz tests. |
| `script/DeployRoadTripVotes.s.sol` | Reviewable deploy script with the canonical constants; tests call `deploy()` directly. |
| `docs/abi/RoadTripVotes.json` | ABI export for the website (`forge inspect RoadTripVotes abi --json`). |
| `lib/forge-std` | forge-std v1.11.0 vendored as plain files (no submodule). |
| `foundry.toml` | solc `0.8.26`, optimizer on, `bytecode_hash = "none"`, no ffi, no fs permissions. |

## Build and test

```sh
forge build
forge test
forge fmt --check
```

Tests read no environment variables, use no network and pass in any order and in parallel.

## Contract behaviour

### Configuration (constructor, immutable)

| Argument | Launch value | Meaning |
| --- | --- | --- |
| `epochSeconds` | `86400` | Length of one voting epoch in seconds. Must be non-zero. |
| `destinationCount` | `64` | Number of destinations. Valid ids are `0 .. destinationCount - 1`. Must be non-zero. |

The constructor is non-payable, takes two static words, reads no other contract and no block data, so it
deploys on an empty chain. There are no other deployment parameters.

### Epochs

Epochs are absolute: `currentEpoch() = block.timestamp / epochSeconds`. With `epochSeconds = 86400`
an epoch is one UTC calendar day, epoch `N` covers `[N * 86400, (N + 1) * 86400)` and voting closes at
00:00 UTC. `epochStart(epoch)` and `epochEnd(epoch)` return those bounds for the countdown. The first
epoch after deployment is therefore the remainder of the deployment day, not a full 24 hours.

Epoch numbers are large (about 20 800 in 2027); the website should display them as dates or as
"day N of the trip" relative to the first finalized epoch, not as raw numbers.

### Voting

- `vote(destinationId)`: one vote per wallet per epoch, for the current epoch only.
- Reverts with `InvalidDestination` for `destinationId >= destinationCount` and `AlreadyVoted` on a
  second vote in the same epoch (including trying to change the choice).
- Emits `Voted(epoch, voter, destinationId)` (all three indexed).
- `hasVoted(epoch, wallet)` and `voteOf(epoch, wallet)` expose a wallet's ballot; `votesFor(epoch, id)`,
  `totalVotes(epoch)` and `leaderOf(epoch)` expose the live tally.

The running leader is updated on every vote (strictly more votes takes the lead; an equal count takes
the lead only with a lower id), so the winner is known in O(1) at finalization and the destination
count never affects gas.

### Finalization and the route queue

- `finalize(epoch)`: callable by anyone, once per epoch, only after the epoch has ended
  (`epoch < currentEpoch()`), only if at least one vote was cast.
- Records the winner, appends `(epoch, destinationId)` to the route queue and emits
  `Finalized(epoch, destinationId, votes, totalVotes, routeIndex)`.
- Reverts with `EpochNotEnded`, `AlreadyFinalized` or `NoVotes`.
- `winnerOf(epoch)` reverts with `NotFinalized` until the epoch is finalized; check `isFinalized(epoch)`
  first. `routeLength()`, `routeAt(index)` and `route()` read the queue.

Epochs may be finalized in any order and epochs without votes are simply skipped (they can never be
finalized). The route queue is in **finalization order**, which is what "added to the end of the route
queue" means on chain. In normal play the website or any community member finalizes each day as soon as
it ends, so finalization order equals epoch order; the `epoch` field of each stop lets the site sort or
label stops by day if it ever differs.

### Trust assumptions and security notes

- No privileged roles. Nothing can pause, upgrade, change configuration or move value. There is no
  `receive`/`fallback`, so plain ETH transfers revert.
- No external calls, no delegatecall, no selfdestruct, no assembly, no libraries. Reentrancy is not
  possible; every state change emits an event.
- Sybil resistance is out of scope by design: one vote per *wallet* per epoch, and anyone can create
  wallets. Voting costs Sepolia gas, which is the only cost. This matches the brief and is suitable
  for a testnet community game, not for decisions of value.
- Finalization is permissionless and unincentivised; see "Operational responsibilities".
- Block timestamps are set by validators and may drift by a few seconds around an epoch boundary.
  No value depends on this.
- Tests passing is not an audit. The brief requires an independent review of the contract before
  deployment; that review is a separate assignment.

Automated analysis run here: `forge build`, `forge test` with the verifier's fuzz seed, `forge fmt
--check`, and a scratch rehearsal of the launch's deployment probe (CREATE2 from a factory, runtime
size and forbidden-opcode scan). Slither is run by the verifier, not on this machine. The contract uses
none of the constructs its blocking detectors target.

## Deployment

The IMD launch deploys `RoadTripVotes` through its factory from the bytecode as built here, with the
constructor arguments `86400` and `64`. The manifest assignment writes `launch.json` with exactly those
two static words; there is no `$owner` argument because the contract has no owner.

The deploy script `script/DeployRoadTripVotes.s.sol` exists as a reviewable reference and for local
rehearsal (`deploy(epochSeconds, destinationCount)` is unit-tested). Nothing in this repository
broadcasts, holds keys or reads the environment.

Chain: Sepolia (chain id 11155111). Compiler: solc 0.8.26, optimizer 200 runs, EVM `cancun`,
`bytecode_hash = "none"`. Runtime size is well under the EIP-170 limit.

## After launch

There are no owner settings: the contract is fully configured by its constructor and has no setters.

Operational responsibilities (anyone can perform these; the website should offer them):

1. **Finalize each day.** After 00:00 UTC, call `finalize(previousEpoch)` for the day that just ended
   so its winner joins the route queue. If nobody calls it, the route simply pauses until someone does;
   votes are never lost, and the epoch can be finalized at any later time. Days with zero votes cannot
   be finalized and are skipped.
2. **Index events for the UI.** `Voted` gives live counts and the Navigator leaderboard (count, per
   wallet, the epochs where `voteOf(epoch, wallet)` equals `winnerOf(epoch)`); `Finalized` gives the
   route queue and trip log in order.
3. **Verify source on the explorer** after deployment (`forge verify-contract`), a task for the launch's
   deployer.

## Choices the brief left open

| Choice | Decision |
| --- | --- |
| Epoch alignment | Absolute UTC days (`timestamp / epochSeconds`), so the countdown is to 00:00 UTC and no genesis timestamp is stored. |
| Epoch with no votes | `finalize` reverts with `NoVotes`; nothing is added to the route. (The tie rule would otherwise make id 0 win every quiet day.) |
| Out-of-order finalization | Allowed; the route queue is in finalization order and each stop records its epoch. |
| `winnerOf` on an unfinalized epoch | Reverts with `NotFinalized` rather than returning a sentinel; `isFinalized` is the guard. |
| Destination id type | `uint256` in the ABI for simple JS handling; range-checked against `destinationCount`. |
