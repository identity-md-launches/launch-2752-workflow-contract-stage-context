// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title RoadTripVotes
/// @notice Community voting for the Hamster Road Trip game. Time is split into fixed-length epochs.
///         During an epoch every wallet may cast exactly one vote for one destination id. Once an epoch
///         has ended, anyone may finalize it: the destination with the most votes wins, ties go to the
///         lowest id, and the winner is appended to the route queue exactly once. Epochs that received
///         votes must be finalized in the order they ended, so the route queue is in epoch order no
///         matter who calls `finalize` or when.
/// @dev    The contract has no owner, admin, upgrade path, token or payments. Everything it needs is
///         fixed at construction. Epochs are absolute: `epoch = block.timestamp / epochSeconds`, so with
///         the default 86 400 seconds an epoch is one UTC calendar day and epoch boundaries are 00:00 UTC.
///         The running leader of each epoch is tracked on every vote, so `finalize` costs O(1) gas
///         regardless of the destination count.
contract RoadTripVotes {
    // ---------------------------------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------------------------------

    /// @notice One entry of the route queue: the epoch that produced it and the destination that won.
    struct RouteStop {
        uint256 epoch;
        uint256 destinationId;
    }

    /// @dev Per-epoch tally. `leader` is the destination with the most votes so far, ties to lowest id.
    struct Tally {
        uint256 leader;
        uint256 leaderVotes;
        uint256 totalVotes;
        bool finalized;
    }

    /// @dev Per-epoch, per-wallet ballot. `cast` distinguishes a vote for id 0 from no vote.
    struct Ballot {
        bool cast;
        uint256 destinationId;
    }

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    /// @notice `epochSeconds` was zero at construction.
    error ZeroEpochSeconds();
    /// @notice `destinationCount` was zero at construction.
    error ZeroDestinationCount();
    /// @notice The destination id is not in `[0, destinationCount)`.
    error InvalidDestination(uint256 destinationId, uint256 destinationCount);
    /// @notice The wallet already voted in this epoch.
    error AlreadyVoted(uint256 epoch, address voter);
    /// @notice The epoch is the current one or lies in the future, so it cannot be finalized yet.
    error EpochNotEnded(uint256 epoch, uint256 currentEpoch);
    /// @notice The epoch already has a recorded winner.
    error AlreadyFinalized(uint256 epoch);
    /// @notice The epoch received no votes, so there is nothing to add to the route.
    error NoVotes(uint256 epoch);
    /// @notice An older epoch with votes is still waiting; finalize `pendingEpoch` first.
    error NotNextInQueue(uint256 epoch, uint256 pendingEpoch);
    /// @notice The epoch has no recorded winner (yet).
    error NotFinalized(uint256 epoch);
    /// @notice The route index is beyond the end of the queue.
    error RouteIndexOutOfRange(uint256 index, uint256 length);

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    /// @notice A wallet voted for a destination in an epoch.
    event Voted(uint256 indexed epoch, address indexed voter, uint256 indexed destinationId);

    /// @notice An epoch was finalized and its winner appended to the route queue at `routeIndex`.
    event Finalized(
        uint256 indexed epoch, uint256 indexed destinationId, uint256 votes, uint256 totalVotes, uint256 routeIndex
    );

    // ---------------------------------------------------------------------------------------------
    // Immutable configuration
    // ---------------------------------------------------------------------------------------------

    /// @notice Length of one voting epoch in seconds.
    uint256 public immutable epochSeconds;

    /// @notice Number of destinations; valid ids are `0 .. destinationCount - 1`.
    uint256 public immutable destinationCount;

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    /// @dev epoch => destination id => votes
    mapping(uint256 epoch => mapping(uint256 destinationId => uint256 votes)) private _votes;

    /// @dev epoch => wallet => ballot
    mapping(uint256 epoch => mapping(address voter => Ballot ballot)) private _ballots;

    /// @dev epoch => running tally and finalization state
    mapping(uint256 epoch => Tally tally) private _tallies;

    /// @dev Winners in epoch order (finalization is forced to follow it).
    RouteStop[] private _route;

    /// @dev Every epoch that received at least one vote, in the order the votes arrived. Votes are only
    ///      accepted for the current epoch, so this is strictly increasing.
    uint256[] private _votedEpochs;

    /// @dev Index into `_votedEpochs` of the oldest epoch that is not finalized yet.
    uint256 private _finalizeCursor;

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    /// @param epochSeconds_ Length of one epoch in seconds (the game uses 86 400).
    /// @param destinationCount_ Number of destinations; ids `0 .. destinationCount_ - 1` are valid (the game uses 64).
    constructor(uint256 epochSeconds_, uint256 destinationCount_) {
        if (epochSeconds_ == 0) revert ZeroEpochSeconds();
        if (destinationCount_ == 0) revert ZeroDestinationCount();
        epochSeconds = epochSeconds_;
        destinationCount = destinationCount_;
    }

    // ---------------------------------------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------------------------------------

    /// @notice Cast the caller's single vote for the current epoch.
    /// @param destinationId Destination to vote for; must be below `destinationCount`.
    function vote(uint256 destinationId) external {
        if (destinationId >= destinationCount) revert InvalidDestination(destinationId, destinationCount);

        uint256 epoch = currentEpoch();
        Ballot storage ballot = _ballots[epoch][msg.sender];
        if (ballot.cast) revert AlreadyVoted(epoch, msg.sender);

        ballot.cast = true;
        ballot.destinationId = destinationId;

        uint256 votes = _votes[epoch][destinationId] + 1;
        _votes[epoch][destinationId] = votes;

        Tally storage tally = _tallies[epoch];
        // The first vote of an epoch enrols it in the finalization queue, so winners join the route in
        // epoch order and empty epochs never block it.
        if (tally.totalVotes == 0) _votedEpochs.push(epoch);
        tally.totalVotes += 1;
        // Keep `leader` equal to the destination with the most votes, lowest id among ties.
        if (votes > tally.leaderVotes || (votes == tally.leaderVotes && destinationId < tally.leader)) {
            tally.leader = destinationId;
            tally.leaderVotes = votes;
        }

        emit Voted(epoch, msg.sender, destinationId);
    }

    /// @notice Record the winner of an ended epoch and append it to the route queue. Anyone may call.
    /// @dev    Reverts if the epoch has not ended, was already finalized, received no votes, or is not
    ///         the oldest unfinalized epoch with votes (`NotNextInQueue`). Epochs with votes are thus
    ///         finalized strictly in epoch order, so the route queue is in epoch order whoever calls;
    ///         epochs without votes are not in the queue and never block it. Use `pendingEpoch()` to
    ///         find the epoch that must be finalized next.
    /// @param epoch Epoch to finalize.
    function finalize(uint256 epoch) external {
        uint256 current = currentEpoch();
        if (epoch >= current) revert EpochNotEnded(epoch, current);

        Tally storage tally = _tallies[epoch];
        if (tally.finalized) revert AlreadyFinalized(epoch);
        if (tally.totalVotes == 0) revert NoVotes(epoch);

        // An ended, unfinalized epoch with votes is always in `_votedEpochs` at or after the cursor, so
        // the cursor's entry exists and is at most `epoch`.
        uint256 cursor = _finalizeCursor;
        uint256 pending = _votedEpochs[cursor];
        if (pending != epoch) revert NotNextInQueue(epoch, pending);
        _finalizeCursor = cursor + 1;

        tally.finalized = true;
        uint256 winner = tally.leader;
        uint256 routeIndex = _route.length;
        _route.push(RouteStop({epoch: epoch, destinationId: winner}));

        emit Finalized(epoch, winner, tally.leaderVotes, tally.totalVotes, routeIndex);
    }

    // ---------------------------------------------------------------------------------------------
    // Views: epochs
    // ---------------------------------------------------------------------------------------------

    /// @notice The epoch that is open for voting right now.
    function currentEpoch() public view returns (uint256) {
        return block.timestamp / epochSeconds;
    }

    /// @notice First second of `epoch`.
    function epochStart(uint256 epoch) external view returns (uint256) {
        return epoch * epochSeconds;
    }

    /// @notice First second after `epoch`; voting for `epoch` is closed from this timestamp on.
    function epochEnd(uint256 epoch) external view returns (uint256) {
        return (epoch + 1) * epochSeconds;
    }

    // ---------------------------------------------------------------------------------------------
    // Views: votes
    // ---------------------------------------------------------------------------------------------

    /// @notice Votes cast for `destinationId` in `epoch`.
    function votesFor(uint256 epoch, uint256 destinationId) external view returns (uint256) {
        return _votes[epoch][destinationId];
    }

    /// @notice Total votes cast in `epoch`.
    function totalVotes(uint256 epoch) external view returns (uint256) {
        return _tallies[epoch].totalVotes;
    }

    /// @notice Whether `wallet` has voted in `epoch`.
    function hasVoted(uint256 epoch, address wallet) external view returns (bool) {
        return _ballots[epoch][wallet].cast;
    }

    /// @notice The destination `wallet` voted for in `epoch`. Reverts-free: check `hasVoted` first.
    /// @return cast Whether the wallet voted at all.
    /// @return destinationId The destination voted for (0 when `cast` is false).
    function voteOf(uint256 epoch, address wallet) external view returns (bool cast, uint256 destinationId) {
        Ballot storage ballot = _ballots[epoch][wallet];
        return (ballot.cast, ballot.destinationId);
    }

    /// @notice Provisional leader of `epoch`: the destination that would win if the epoch were finalized now.
    /// @return destinationId The leading destination (0 when no votes were cast).
    /// @return votes The leader's vote count (0 when no votes were cast).
    function leaderOf(uint256 epoch) external view returns (uint256 destinationId, uint256 votes) {
        Tally storage tally = _tallies[epoch];
        return (tally.leader, tally.leaderVotes);
    }

    // ---------------------------------------------------------------------------------------------
    // Views: finalization and route
    // ---------------------------------------------------------------------------------------------

    /// @notice Whether `epoch` has a recorded winner.
    function isFinalized(uint256 epoch) external view returns (bool) {
        return _tallies[epoch].finalized;
    }

    /// @notice The recorded winner of `epoch`. Reverts with `NotFinalized` until `finalize(epoch)` succeeds.
    function winnerOf(uint256 epoch) external view returns (uint256) {
        Tally storage tally = _tallies[epoch];
        if (!tally.finalized) revert NotFinalized(epoch);
        return tally.leader;
    }

    /// @notice The oldest epoch with votes that is not finalized yet: the only epoch `finalize` accepts.
    /// @dev    It may be the current epoch, in which case `finalize` reverts with `EpochNotEnded` until
    ///         it ends. Does not revert when nothing is waiting.
    /// @return exists Whether any epoch with votes is still unfinalized.
    /// @return epoch The pending epoch (0 when `exists` is false).
    function pendingEpoch() external view returns (bool exists, uint256 epoch) {
        uint256 cursor = _finalizeCursor;
        if (cursor >= _votedEpochs.length) return (false, 0);
        return (true, _votedEpochs[cursor]);
    }

    /// @notice Number of epochs that received at least one vote (finalized or not).
    function votedEpochCount() external view returns (uint256) {
        return _votedEpochs.length;
    }

    /// @notice Number of stops in the route queue (one per finalized epoch).
    function routeLength() external view returns (uint256) {
        return _route.length;
    }

    /// @notice The route stop at `index`, in epoch order.
    function routeAt(uint256 index) external view returns (RouteStop memory) {
        if (index >= _route.length) revert RouteIndexOutOfRange(index, _route.length);
        return _route[index];
    }

    /// @notice The whole route queue, in epoch order.
    function route() external view returns (RouteStop[] memory) {
        return _route;
    }
}
