// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RoadTripVotes} from "../src/RoadTripVotes.sol";

/// @dev Edge cases and properties not covered by `RoadTripVotes.t.sol`: epoch boundaries, extreme
///      configurations, order independence of the tally and failure paths that must leave no trace.
contract RoadTripVotesEdgeTest is Test {
    uint256 internal constant EPOCH_SECONDS = 86_400;
    uint256 internal constant DESTINATION_COUNT = 64;
    uint256 internal constant START = 1_800_000_000 - (1_800_000_000 % 86_400);

    RoadTripVotes internal votes;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    event Finalized(
        uint256 indexed epoch, uint256 indexed destinationId, uint256 votes, uint256 totalVotes, uint256 routeIndex
    );

    function setUp() public {
        vm.warp(START);
        votes = new RoadTripVotes(EPOCH_SECONDS, DESTINATION_COUNT);
    }

    function _vote(RoadTripVotes target, address who, uint256 id) internal {
        vm.prank(who);
        target.vote(id);
    }

    function _voter(uint256 i) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("edge-voter", i)))));
    }

    // ---------------------------------------------------------------------------------------------
    // Epoch boundaries
    // ---------------------------------------------------------------------------------------------

    function test_voteAtExactEpochEnd_landsInNextEpoch() public {
        uint256 epoch = votes.currentEpoch();
        _vote(votes, alice, 1);
        vm.warp(votes.epochEnd(epoch));
        // Voting for `epoch` is closed; the same wallet votes again in the new epoch.
        _vote(votes, alice, 2);
        assertEq(votes.totalVotes(epoch), 1);
        assertEq(votes.totalVotes(epoch + 1), 1);
        assertEq(votes.votesFor(epoch + 1, 2), 1);
        votes.finalize(epoch);
        assertEq(votes.winnerOf(epoch), 1);
    }

    function test_voteAtLastSecond_countsForClosingEpoch() public {
        uint256 epoch = votes.currentEpoch();
        vm.warp(votes.epochEnd(epoch) - 1);
        _vote(votes, alice, 9);
        assertEq(votes.votesFor(epoch, 9), 1);
        vm.warp(votes.epochEnd(epoch));
        votes.finalize(epoch);
        assertEq(votes.winnerOf(epoch), 9);
    }

    function test_epochZero_canBeVotedAndFinalized() public {
        vm.warp(0);
        RoadTripVotes fresh = new RoadTripVotes(EPOCH_SECONDS, DESTINATION_COUNT);
        _vote(fresh, alice, 4);
        assertEq(fresh.totalVotes(0), 1);
        vm.expectRevert(abi.encodeWithSelector(RoadTripVotes.EpochNotEnded.selector, 0, 0));
        fresh.finalize(0);
        vm.warp(EPOCH_SECONDS);
        fresh.finalize(0);
        assertEq(fresh.winnerOf(0), 4);
        assertEq(fresh.routeAt(0).epoch, 0);
    }

    function test_epochWithNoVotes_staysUnfinalizableForever() public {
        uint256 epoch = votes.currentEpoch();
        vm.warp(START + 10 * EPOCH_SECONDS);
        // Late voters cannot reach a closed epoch: their vote lands in the current one.
        _vote(votes, alice, 3);
        assertEq(votes.totalVotes(epoch), 0);
        vm.expectRevert(abi.encodeWithSelector(RoadTripVotes.NoVotes.selector, epoch));
        votes.finalize(epoch);
        vm.expectRevert(abi.encodeWithSelector(RoadTripVotes.NotFinalized.selector, epoch));
        votes.winnerOf(epoch);
        assertEq(votes.routeLength(), 0);
    }

    function test_finalize_failedAttemptsLeaveNoTrace() public {
        uint256 epoch = votes.currentEpoch();
        _vote(votes, alice, 7);
        vm.expectRevert(abi.encodeWithSelector(RoadTripVotes.EpochNotEnded.selector, epoch, epoch));
        votes.finalize(epoch);
        assertFalse(votes.isFinalized(epoch));
        assertEq(votes.routeLength(), 0);
        // The early attempt does not block the real one.
        vm.warp(votes.epochEnd(epoch));
        votes.finalize(epoch);
        assertEq(votes.routeLength(), 1);
    }

    function test_finalize_maxEpochRevertsNotEnded() public {
        uint256 current = votes.currentEpoch();
        vm.expectRevert(abi.encodeWithSelector(RoadTripVotes.EpochNotEnded.selector, type(uint256).max, current));
        votes.finalize(type(uint256).max);
    }

    function testFuzz_epochBoundsAreContiguous(uint256 epoch, uint256 epochSeconds) public {
        epochSeconds = bound(epochSeconds, 1, type(uint64).max);
        epoch = bound(epoch, 0, type(uint128).max);
        RoadTripVotes fresh = new RoadTripVotes(epochSeconds, DESTINATION_COUNT);
        assertEq(fresh.epochEnd(epoch), fresh.epochStart(epoch + 1));
        assertEq(fresh.epochEnd(epoch) - fresh.epochStart(epoch), epochSeconds);
    }

    function testFuzz_voteGoesToEpochContainingTimestamp(uint256 timestamp, uint256 id) public {
        timestamp = bound(timestamp, 0, type(uint64).max);
        id = bound(id, 0, DESTINATION_COUNT - 1);
        vm.warp(timestamp);
        _vote(votes, alice, id);
        uint256 epoch = timestamp / EPOCH_SECONDS;
        assertTrue(votes.hasVoted(epoch, alice));
        assertEq(votes.votesFor(epoch, id), 1);
        assertLe(votes.epochStart(epoch), timestamp);
        assertLt(timestamp, votes.epochEnd(epoch));
    }

    // ---------------------------------------------------------------------------------------------
    // Extreme configurations
    // ---------------------------------------------------------------------------------------------

    function test_singleDestination_onlyIdZero() public {
        RoadTripVotes one = new RoadTripVotes(EPOCH_SECONDS, 1);
        vm.expectRevert(abi.encodeWithSelector(RoadTripVotes.InvalidDestination.selector, 1, 1));
        _vote(one, alice, 1);
        _vote(one, alice, 0);
        uint256 epoch = one.currentEpoch();
        vm.warp(one.epochEnd(epoch));
        one.finalize(epoch);
        assertEq(one.winnerOf(epoch), 0);
    }

    function test_oneSecondEpochs() public {
        RoadTripVotes fast = new RoadTripVotes(1, DESTINATION_COUNT);
        uint256 epoch = fast.currentEpoch();
        assertEq(epoch, START);
        _vote(fast, alice, 5);
        vm.warp(START + 1);
        _vote(fast, alice, 6);
        fast.finalize(epoch);
        vm.warp(START + 2);
        fast.finalize(epoch + 1);
        assertEq(fast.winnerOf(epoch), 5);
        assertEq(fast.winnerOf(epoch + 1), 6);
    }

    function test_maxDestinationCount_boundaryIds() public {
        RoadTripVotes wide = new RoadTripVotes(EPOCH_SECONDS, type(uint256).max);
        _vote(wide, alice, type(uint256).max - 1);
        vm.expectRevert(
            abi.encodeWithSelector(RoadTripVotes.InvalidDestination.selector, type(uint256).max, type(uint256).max)
        );
        _vote(wide, bob, type(uint256).max);
        _vote(wide, bob, 0); // 1:1 tie, lowest id leads
        (uint256 leader,) = wide.leaderOf(wide.currentEpoch());
        assertEq(leader, 0);
    }

    function test_constructor_revertsWhenBothZero() public {
        // epochSeconds is checked first.
        vm.expectRevert(RoadTripVotes.ZeroEpochSeconds.selector);
        new RoadTripVotes(0, 0);
    }

    function test_constructor_rejectsEthValue() public {
        // Non-payable constructor: the launch sends zero ETH and any value must revert.
        vm.deal(address(this), 1 ether);
        bytes memory init = abi.encodePacked(type(RoadTripVotes).creationCode, abi.encode(EPOCH_SECONDS, 64));
        address created;
        assembly ("memory-safe") {
            created := create(1, add(init, 32), mload(init))
        }
        assertEq(created, address(0));
    }

    // ---------------------------------------------------------------------------------------------
    // Tie handling and order independence
    // ---------------------------------------------------------------------------------------------

    function test_tie_highIdReachesCountFirstButLowIdWins() public {
        uint256 epoch = votes.currentEpoch();
        _vote(votes, alice, 50);
        _vote(votes, bob, 50);
        _vote(votes, carol, 2);
        _vote(votes, dave, 2); // 2:2, the lower id takes the lead on equalising
        (uint256 leader, uint256 leaderVotes) = votes.leaderOf(epoch);
        assertEq(leader, 2);
        assertEq(leaderVotes, 2);
        vm.warp(votes.epochEnd(epoch));
        vm.expectEmit(true, true, true, true, address(votes));
        emit Finalized(epoch, 2, 2, 4, 0);
        votes.finalize(epoch);
    }

    function test_tie_threeWayGoesToLowest() public {
        uint256 epoch = votes.currentEpoch();
        _vote(votes, alice, 33);
        _vote(votes, bob, 63);
        _vote(votes, carol, 12);
        vm.warp(votes.epochEnd(epoch));
        votes.finalize(epoch);
        assertEq(votes.winnerOf(epoch), 12);
    }

    function test_idZeroWinsTieAgainstEarlierLeader() public {
        // Leader 0 starts as the default slot value; a real vote for 0 must still compete correctly.
        uint256 epoch = votes.currentEpoch();
        _vote(votes, alice, 5);
        _vote(votes, bob, 0);
        (uint256 leader, uint256 leaderVotes) = votes.leaderOf(epoch);
        assertEq(leader, 0);
        assertEq(leaderVotes, 1);
    }

    function test_idZeroDoesNotWinWithoutVotes() public {
        uint256 epoch = votes.currentEpoch();
        _vote(votes, alice, 63);
        vm.warp(votes.epochEnd(epoch));
        votes.finalize(epoch);
        assertEq(votes.winnerOf(epoch), 63, "an unvoted id 0 must not win by default");
    }

    /// @dev The winner depends only on the multiset of votes, not on the order they arrive in.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_winnerIndependentOfVoteOrder(uint8[] memory rawIds, uint8 small) public {
        uint256 n = bound(rawIds.length, 1, 40);
        uint256 range = bound(small, 1, DESTINATION_COUNT); // small ranges force ties
        RoadTripVotes forward = new RoadTripVotes(EPOCH_SECONDS, DESTINATION_COUNT);
        RoadTripVotes backward = new RoadTripVotes(EPOCH_SECONDS, DESTINATION_COUNT);
        RoadTripVotes interleaved = new RoadTripVotes(EPOCH_SECONDS, DESTINATION_COUNT);
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = i < rawIds.length ? uint256(rawIds[i]) % range : i % range;
        }
        for (uint256 i; i < n; ++i) {
            _vote(forward, _voter(i), ids[i]);
            _vote(backward, _voter(i), ids[n - 1 - i]);
        }
        // Evens then odds.
        for (uint256 i; i < n; i += 2) {
            _vote(interleaved, _voter(i), ids[i]);
        }
        for (uint256 i = 1; i < n; i += 2) {
            _vote(interleaved, _voter(i), ids[i]);
        }
        uint256 epoch = forward.currentEpoch();
        (uint256 l1, uint256 v1) = forward.leaderOf(epoch);
        (uint256 l2, uint256 v2) = backward.leaderOf(epoch);
        (uint256 l3, uint256 v3) = interleaved.leaderOf(epoch);
        assertEq(l1, l2, "forward vs backward leader");
        assertEq(l1, l3, "forward vs interleaved leader");
        assertEq(v1, v2);
        assertEq(v1, v3);
        assertEq(v1, forward.votesFor(epoch, l1), "leaderVotes != votesFor(leader)");
        for (uint256 id; id < range; ++id) {
            uint256 c = forward.votesFor(epoch, id);
            assertLe(c, v1, "an id has more votes than the leader");
            if (c == v1) assertGe(id, l1, "a lower id ties the leader");
        }
    }

    /// @dev A rejected vote, for whatever reason, changes nothing.
    function testFuzz_rejectedVoteChangesNothing(uint256 firstId, uint256 secondId) public {
        firstId = bound(firstId, 0, DESTINATION_COUNT - 1);
        uint256 epoch = votes.currentEpoch();
        _vote(votes, alice, firstId);
        (uint256 leaderBefore, uint256 leaderVotesBefore) = votes.leaderOf(epoch);
        uint256 secondBefore = secondId < DESTINATION_COUNT ? votes.votesFor(epoch, secondId) : 0;

        vm.prank(alice);
        vm.expectRevert(); // AlreadyVoted or InvalidDestination
        votes.vote(secondId);

        (bool cast, uint256 choice) = votes.voteOf(epoch, alice);
        assertTrue(cast);
        assertEq(choice, firstId);
        assertEq(votes.totalVotes(epoch), 1);
        (uint256 leaderAfter, uint256 leaderVotesAfter) = votes.leaderOf(epoch);
        assertEq(leaderAfter, leaderBefore);
        assertEq(leaderVotesAfter, leaderVotesBefore);
        if (secondId < DESTINATION_COUNT) assertEq(votes.votesFor(epoch, secondId), secondBefore);
    }

    // ---------------------------------------------------------------------------------------------
    // Finalization is sealed
    // ---------------------------------------------------------------------------------------------

    function test_finalizedTallyIsFrozen() public {
        uint256 epoch = votes.currentEpoch();
        _vote(votes, alice, 8);
        vm.warp(votes.epochEnd(epoch));
        votes.finalize(epoch);
        // Many votes after finalization only reach the new epoch.
        for (uint256 i; i < 20; ++i) {
            _vote(votes, _voter(i), 9);
        }
        assertEq(votes.totalVotes(epoch), 1);
        assertEq(votes.votesFor(epoch, 9), 0);
        (uint256 leader, uint256 leaderVotes) = votes.leaderOf(epoch);
        assertEq(leader, 8);
        assertEq(leaderVotes, 1);
        assertEq(votes.winnerOf(epoch), 8);
        vm.expectRevert(abi.encodeWithSelector(RoadTripVotes.AlreadyFinalized.selector, epoch));
        votes.finalize(epoch);
    }

    function test_finalize_routeIndexIncrementsInEvents() public {
        uint256 e0 = votes.currentEpoch();
        _vote(votes, alice, 1);
        vm.warp(votes.epochEnd(e0));
        _vote(votes, alice, 2);
        _vote(votes, bob, 3);
        vm.warp(votes.epochEnd(e0 + 1));

        vm.expectEmit(true, true, true, true, address(votes));
        emit Finalized(e0 + 1, 2, 1, 2, 0);
        votes.finalize(e0 + 1);
        vm.expectEmit(true, true, true, true, address(votes));
        emit Finalized(e0, 1, 1, 1, 1);
        votes.finalize(e0);
    }

    function test_finalize_fromContractCaller() public {
        uint256 epoch = votes.currentEpoch();
        _vote(votes, alice, 11);
        vm.warp(votes.epochEnd(epoch));
        Finalizer f = new Finalizer();
        f.run(votes, epoch);
        assertEq(votes.winnerOf(epoch), 11);
    }

    function test_unknownSelectorReverts() public {
        (bool ok,) = address(votes).call(abi.encodeWithSignature("setEpochSeconds(uint256)", 1));
        assertFalse(ok);
        (ok,) = address(votes).call(abi.encodeWithSignature("upgradeTo(address)", alice));
        assertFalse(ok);
        (ok,) = address(votes).call(hex"deadbeef");
        assertFalse(ok);
    }
}

contract Finalizer {
    function run(RoadTripVotes votes, uint256 epoch) external {
        votes.finalize(epoch);
    }
}
