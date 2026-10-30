// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RoadTripVotes} from "../src/RoadTripVotes.sol";

/// @dev Drives `RoadTripVotes` with random votes, finalizations and time jumps from a fixed set of wallets,
///      keeping an independent model (ghost state) of every tally. Each action checks that the call
///      succeeded or reverted exactly as the model predicts; the invariant contract then compares the
///      whole model with the contract's views after every step.
contract RoadTripVotesHandler is Test {
    RoadTripVotes public immutable votes;
    uint256 public immutable destinationCount;
    uint256 public immutable epochSeconds;

    address[] public actors;

    /// @dev Every epoch any action touched, in first-touch order.
    uint256[] public touchedEpochs;
    mapping(uint256 epoch => bool) public touched;

    mapping(uint256 epoch => mapping(uint256 id => uint256)) public ghostVotes;
    mapping(uint256 epoch => uint256) public ghostTotal;
    mapping(uint256 epoch => mapping(address => bool)) public ghostVoted;
    mapping(uint256 epoch => mapping(address => uint256)) public ghostChoice;
    mapping(uint256 epoch => bool) public ghostFinalized;

    uint256[] public ghostRouteEpochs;
    uint256[] public ghostRouteIds;

    /// @dev Counts every call whose outcome disagreed with the model. Must stay zero.
    uint256 public mismatches;

    uint256 public calls_vote;
    uint256 public calls_voteRejected;
    uint256 public calls_finalize;
    uint256 public calls_finalizeRejected;

    constructor(RoadTripVotes votes_, uint256 actorCount_) {
        votes = votes_;
        destinationCount = votes_.destinationCount();
        epochSeconds = votes_.epochSeconds();
        for (uint256 i; i < actorCount_; ++i) {
            actors.push(address(uint160(uint256(keccak256(abi.encode("roadtrip-actor", i))))));
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------------------------------------

    /// @notice A wallet votes. Ids are biased towards a few low ids so ties and lead changes are common,
    ///         and sometimes lie out of range.
    function vote(uint256 actorSeed, uint256 idSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 id;
        uint256 mode = idSeed % 8;
        if (mode < 4) id = (idSeed >> 8) % 3; // contested low ids
        else if (mode < 7) id = _bound(idSeed >> 8, 0, destinationCount - 1);
        else id = _bound(idSeed >> 8, destinationCount, type(uint256).max); // out of range

        uint256 epoch = votes.currentEpoch();
        _touch(epoch);

        bytes memory expectedError;
        if (id >= destinationCount) {
            expectedError = abi.encodeWithSelector(RoadTripVotes.InvalidDestination.selector, id, destinationCount);
        } else if (ghostVoted[epoch][actor]) {
            expectedError = abi.encodeWithSelector(RoadTripVotes.AlreadyVoted.selector, epoch, actor);
        }

        vm.prank(actor);
        try votes.vote(id) {
            calls_vote++;
            if (expectedError.length != 0) mismatches++;
            ghostVoted[epoch][actor] = true;
            ghostChoice[epoch][actor] = id;
            ghostVotes[epoch][id] += 1;
            ghostTotal[epoch] += 1;
        } catch (bytes memory err) {
            calls_voteRejected++;
            if (keccak256(err) != keccak256(expectedError) || expectedError.length == 0) mismatches++;
        }
    }

    /// @notice A wallet tries to vote a second time in the same epoch (always for a valid id).
    function revote(uint256 actorSeed, uint256 idSeed) external {
        uint256 epoch = votes.currentEpoch();
        address actor = actors[actorSeed % actors.length];
        if (!ghostVoted[epoch][actor]) return;
        uint256 id = idSeed % destinationCount;
        vm.prank(actor);
        try votes.vote(id) {
            mismatches++;
        } catch (bytes memory err) {
            calls_voteRejected++;
            if (keccak256(err) != keccak256(abi.encodeWithSelector(RoadTripVotes.AlreadyVoted.selector, epoch, actor)))
            {
                mismatches++;
            }
        }
    }

    /// @notice Anyone finalizes a touched epoch, the current one, or a future one.
    function finalize(uint256 epochSeed, address caller) external {
        uint256 current = votes.currentEpoch();
        uint256 epoch;
        uint256 mode = epochSeed % 4;
        if (mode == 0 || touchedEpochs.length == 0) epoch = current + ((epochSeed >> 8) % 3); // not ended
        else epoch = touchedEpochs[(epochSeed >> 8) % touchedEpochs.length];
        _touch(epoch);

        bytes memory expectedError;
        if (epoch >= current) {
            expectedError = abi.encodeWithSelector(RoadTripVotes.EpochNotEnded.selector, epoch, current);
        } else if (ghostFinalized[epoch]) {
            expectedError = abi.encodeWithSelector(RoadTripVotes.AlreadyFinalized.selector, epoch);
        } else if (ghostTotal[epoch] == 0) {
            expectedError = abi.encodeWithSelector(RoadTripVotes.NoVotes.selector, epoch);
        }

        vm.prank(caller);
        try votes.finalize(epoch) {
            calls_finalize++;
            if (expectedError.length != 0) mismatches++;
            ghostFinalized[epoch] = true;
            (uint256 expectedWinner,) = modelLeader(epoch);
            ghostRouteEpochs.push(epoch);
            ghostRouteIds.push(expectedWinner);
        } catch (bytes memory err) {
            calls_finalizeRejected++;
            if (keccak256(err) != keccak256(expectedError) || expectedError.length == 0) mismatches++;
        }
    }

    /// @notice Time passes: anywhere from one second to three epochs, including exact boundaries.
    function warp(uint256 secondsSeed) external {
        uint256 delta;
        uint256 mode = secondsSeed % 4;
        uint256 now_ = vm.getBlockTimestamp();
        if (mode == 0) delta = epochSeconds - (now_ % epochSeconds); // exactly to the next boundary
        else if (mode == 1) delta = epochSeconds - (now_ % epochSeconds) - 1; // last second of this epoch
        else delta = _bound(secondsSeed >> 8, 1, 3 * epochSeconds);
        vm.warp(now_ + delta);
        _touch(votes.currentEpoch());
    }

    // ---------------------------------------------------------------------------------------------
    // Model helpers
    // ---------------------------------------------------------------------------------------------

    /// @dev Brute-force winner: most votes, lowest id on a tie; (0, 0) when the epoch has no votes.
    function modelLeader(uint256 epoch) public view returns (uint256 id, uint256 count) {
        for (uint256 i; i < destinationCount; ++i) {
            if (ghostVotes[epoch][i] > count) {
                id = i;
                count = ghostVotes[epoch][i];
            }
        }
    }

    function touchedCount() external view returns (uint256) {
        return touchedEpochs.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function routeCount() external view returns (uint256) {
        return ghostRouteEpochs.length;
    }

    function _touch(uint256 epoch) internal {
        if (!touched[epoch]) {
            touched[epoch] = true;
            touchedEpochs.push(epoch);
        }
    }
}

contract RoadTripVotesInvariantTest is Test {
    uint256 internal constant EPOCH_SECONDS = 86_400;
    uint256 internal constant DESTINATION_COUNT = 64;
    uint256 internal constant START = 1_800_000_000;

    RoadTripVotes internal votes;
    RoadTripVotesHandler internal handler;

    function setUp() public {
        vm.warp(START);
        votes = new RoadTripVotes(EPOCH_SECONDS, DESTINATION_COUNT);
        handler = new RoadTripVotesHandler(votes, 6);

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = RoadTripVotesHandler.vote.selector;
        selectors[1] = RoadTripVotesHandler.vote.selector; // voting twice as likely as other actions
        selectors[2] = RoadTripVotesHandler.revote.selector;
        selectors[3] = RoadTripVotesHandler.finalize.selector;
        selectors[4] = RoadTripVotesHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Every call succeeded or reverted with exactly the error the model predicted.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_everyCallMatchesModel() public view {
        assertEq(handler.mismatches(), 0, "a call disagreed with the model");
    }

    /// @dev Per epoch: votesFor matches the model for every id, they sum to totalVotes, and totalVotes equals the
    ///      number of wallets that hasVoted (one vote per wallet per epoch).
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_tallyConservation() public view {
        uint256 n = handler.touchedCount();
        for (uint256 e; e < n; ++e) {
            uint256 epoch = handler.touchedEpochs(e);
            uint256 sum;
            for (uint256 id; id < DESTINATION_COUNT; ++id) {
                uint256 v = votes.votesFor(epoch, id);
                assertEq(v, handler.ghostVotes(epoch, id), "votesFor");
                sum += v;
            }
            assertEq(votes.totalVotes(epoch), sum, "sum of votesFor != totalVotes");
            assertEq(votes.totalVotes(epoch), handler.ghostTotal(epoch), "totalVotes");

            uint256 voters;
            for (uint256 a; a < handler.actorCount(); ++a) {
                address actor = handler.actors(a);
                bool voted = votes.hasVoted(epoch, actor);
                assertEq(voted, handler.ghostVoted(epoch, actor), "hasVoted");
                (bool cast, uint256 choice) = votes.voteOf(epoch, actor);
                assertEq(cast, voted, "voteOf.cast");
                assertEq(choice, handler.ghostChoice(epoch, actor), "voteOf.destinationId");
                if (voted) voters++;
            }
            assertEq(votes.totalVotes(epoch), voters, "more votes than wallets that voted");
        }
    }

    /// @dev The incrementally kept leader always equals the brute-force argmax with lowest-id ties.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_leaderIsArgmaxLowestId() public view {
        uint256 n = handler.touchedCount();
        for (uint256 e; e < n; ++e) {
            uint256 epoch = handler.touchedEpochs(e);
            (uint256 id, uint256 count) = handler.modelLeader(epoch);
            (uint256 leader, uint256 leaderVotes) = votes.leaderOf(epoch);
            assertEq(leader, id, "leader id");
            assertEq(leaderVotes, count, "leader votes");
        }
    }

    /// @dev The route holds exactly one stop per finalized epoch, in finalization order, each with the epoch's
    ///      winner; only ended epochs with votes are ever finalized; unfinalized epochs have no winner.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_routeMatchesFinalizations() public view {
        uint256 len = votes.routeLength();
        assertEq(len, handler.routeCount(), "route length");
        RoadTripVotes.RouteStop[] memory all = votes.route();
        assertEq(all.length, len, "route() length");
        uint256 current = votes.currentEpoch();

        for (uint256 i; i < len; ++i) {
            RoadTripVotes.RouteStop memory stop = votes.routeAt(i);
            assertEq(stop.epoch, handler.ghostRouteEpochs(i), "route epoch");
            assertEq(stop.destinationId, handler.ghostRouteIds(i), "route destination");
            assertEq(all[i].epoch, stop.epoch, "route() vs routeAt epoch");
            assertEq(all[i].destinationId, stop.destinationId, "route() vs routeAt id");
            assertTrue(votes.isFinalized(stop.epoch), "route stop not finalized");
            assertEq(votes.winnerOf(stop.epoch), stop.destinationId, "winnerOf != route stop");
            assertLt(stop.epoch, current, "finalized epoch has not ended");
            assertGt(votes.totalVotes(stop.epoch), 0, "finalized epoch without votes");
            assertLt(stop.destinationId, DESTINATION_COUNT, "winner out of range");
            for (uint256 j; j < i; ++j) {
                assertTrue(all[j].epoch != stop.epoch, "epoch appended to route twice");
            }
        }

        uint256 n = handler.touchedCount();
        uint256 finalizedCount;
        for (uint256 e; e < n; ++e) {
            uint256 epoch = handler.touchedEpochs(e);
            bool fin = votes.isFinalized(epoch);
            assertEq(fin, handler.ghostFinalized(epoch), "isFinalized");
            if (fin) {
                finalizedCount++;
            } else {
                try votes.winnerOf(epoch) returns (uint256) {
                    revert("winnerOf returned for an unfinalized epoch");
                } catch {}
            }
        }
        assertEq(finalizedCount, len, "finalized epochs != route stops");
    }

    /// @dev The game holds no value: nothing the handler does can leave ETH in the contract.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_configurationFixedAndNoValue() public view {
        assertEq(votes.epochSeconds(), EPOCH_SECONDS);
        assertEq(votes.destinationCount(), DESTINATION_COUNT);
        assertEq(address(votes).balance, 0);
    }
}
