// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RoadTripVotes} from "../src/RoadTripVotes.sol";
import {DeployRoadTripVotes} from "../script/DeployRoadTripVotes.s.sol";

contract RoadTripVotesTest is Test {
    uint256 internal constant EPOCH_SECONDS = 86_400;
    uint256 internal constant DESTINATION_COUNT = 64;
    /// @dev A realistic, non-zero starting time: 2027-01-19 00:00:00 UTC (a multiple of 86 400).
    uint256 internal constant START = 1_800_000_000 - (1_800_000_000 % 86_400);

    RoadTripVotes internal votes;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    event Voted(uint256 indexed epoch, address indexed voter, uint256 indexed destinationId);
    event Finalized(
        uint256 indexed epoch, uint256 indexed destinationId, uint256 votes, uint256 totalVotes, uint256 routeIndex
    );

    function setUp() public {
        vm.warp(START);
        votes = new RoadTripVotes(EPOCH_SECONDS, DESTINATION_COUNT);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _vote(address who, uint256 id) internal {
        vm.prank(who);
        votes.vote(id);
    }

    function _nextEpoch() internal {
        vm.warp(vm.getBlockTimestamp() + EPOCH_SECONDS);
    }

    // ---------------------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------------------

    function test_constructor_storesConfiguration() public view {
        assertEq(votes.epochSeconds(), EPOCH_SECONDS);
        assertEq(votes.destinationCount(), DESTINATION_COUNT);
        assertEq(votes.routeLength(), 0);
    }

    function test_constructor_revertsOnZeroEpochSeconds() public {
        vm.expectRevert(RoadTripVotes.ZeroEpochSeconds.selector);
        new RoadTripVotes(0, DESTINATION_COUNT);
    }

    function test_constructor_revertsOnZeroDestinationCount() public {
        vm.expectRevert(RoadTripVotes.ZeroDestinationCount.selector);
        new RoadTripVotes(EPOCH_SECONDS, 0);
    }

    function test_constructor_worksOnEmptyChainAtTimestampZero() public {
        // The launch rehearses constructors on an empty chain; nothing in ours depends on other code or time.
        vm.warp(0);
        RoadTripVotes fresh = new RoadTripVotes(EPOCH_SECONDS, DESTINATION_COUNT);
        assertEq(fresh.currentEpoch(), 0);
        assertEq(address(fresh).code.length > 0, true);
    }

    function test_hasNoOwner() public {
        // No owner, admin or upgrade path: the common owner selectors are not implemented.
        (bool ok,) = address(votes).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "owner() must not exist");
        (ok,) = address(votes).call(abi.encodeWithSignature("transferOwnership(address)", alice));
        assertFalse(ok, "transferOwnership must not exist");
    }

    function test_rejectsEth() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(votes).call{value: 1 wei}("");
        assertFalse(ok, "contract must not accept ETH");
        assertEq(address(votes).balance, 0);
    }

    function test_deployScript_usesCanonicalConfiguration() public {
        DeployRoadTripVotes deployer = new DeployRoadTripVotes();
        RoadTripVotes deployed = deployer.deploy(deployer.EPOCH_SECONDS(), deployer.DESTINATION_COUNT());
        assertEq(deployed.epochSeconds(), 86_400);
        assertEq(deployed.destinationCount(), 64);
    }

    // ---------------------------------------------------------------------------------------------
    // Epoch arithmetic
    // ---------------------------------------------------------------------------------------------

    function test_currentEpoch_isAbsoluteAndAdvancesWithTime() public {
        uint256 epoch = START / EPOCH_SECONDS;
        assertEq(votes.currentEpoch(), epoch);
        assertEq(votes.epochStart(epoch), START);
        assertEq(votes.epochEnd(epoch), START + EPOCH_SECONDS);

        vm.warp(START + EPOCH_SECONDS - 1);
        assertEq(votes.currentEpoch(), epoch, "last second still same epoch");

        vm.warp(START + EPOCH_SECONDS);
        assertEq(votes.currentEpoch(), epoch + 1, "first second of next epoch");
    }

    function testFuzz_currentEpoch_matchesTimestampDivision(uint64 timestamp, uint32 epochSeconds) public {
        epochSeconds = uint32(bound(epochSeconds, 1, type(uint32).max));
        RoadTripVotes fresh = new RoadTripVotes(epochSeconds, DESTINATION_COUNT);
        vm.warp(timestamp);
        assertEq(fresh.currentEpoch(), uint256(timestamp) / epochSeconds);
        uint256 epoch = fresh.currentEpoch();
        assertLe(fresh.epochStart(epoch), timestamp);
        assertGt(fresh.epochEnd(epoch), timestamp);
    }

    // ---------------------------------------------------------------------------------------------
    // Voting: success
    // ---------------------------------------------------------------------------------------------

    function test_vote_recordsBallotAndEmits() public {
        uint256 epoch = votes.currentEpoch();

        vm.expectEmit(true, true, true, true, address(votes));
        emit Voted(epoch, alice, 7);
        _vote(alice, 7);

        assertEq(votes.votesFor(epoch, 7), 1);
        assertEq(votes.totalVotes(epoch), 1);
        assertTrue(votes.hasVoted(epoch, alice));
        (bool cast, uint256 id) = votes.voteOf(epoch, alice);
        assertTrue(cast);
        assertEq(id, 7);
        (uint256 leader, uint256 leaderVotes) = votes.leaderOf(epoch);
        assertEq(leader, 7);
        assertEq(leaderVotes, 1);
    }

    function test_vote_idZeroIsDistinguishableFromNoVote() public {
        uint256 epoch = votes.currentEpoch();
        assertFalse(votes.hasVoted(epoch, alice));
        (bool cast, uint256 id) = votes.voteOf(epoch, alice);
        assertFalse(cast);
        assertEq(id, 0);

        _vote(alice, 0);
        assertTrue(votes.hasVoted(epoch, alice));
        (cast, id) = votes.voteOf(epoch, alice);
        assertTrue(cast);
        assertEq(id, 0);
        assertEq(votes.votesFor(epoch, 0), 1);
    }

    function test_vote_boundaryIdsAccepted() public {
        _vote(alice, 0);
        _vote(bob, DESTINATION_COUNT - 1);
        uint256 epoch = votes.currentEpoch();
        assertEq(votes.votesFor(epoch, 0), 1);
        assertEq(votes.votesFor(epoch, DESTINATION_COUNT - 1), 1);
    }

    function test_vote_manyWalletsSameDestinationAccumulate() public {
        _vote(alice, 3);
        _vote(bob, 3);
        _vote(carol, 3);
        uint256 epoch = votes.currentEpoch();
        assertEq(votes.votesFor(epoch, 3), 3);
        assertEq(votes.totalVotes(epoch), 3);
    }

    function test_vote_sameWalletCanVoteAgainNextEpoch() public {
        uint256 first = votes.currentEpoch();
        _vote(alice, 1);
        _nextEpoch();
        uint256 second = votes.currentEpoch();
        assertEq(second, first + 1);

        _vote(alice, 2);
        assertTrue(votes.hasVoted(first, alice));
        assertTrue(votes.hasVoted(second, alice));
        assertEq(votes.votesFor(first, 1), 1);
        assertEq(votes.votesFor(second, 2), 1);
        assertEq(votes.votesFor(second, 1), 0, "votes do not carry over");
    }

    function test_vote_isolatedPerEpoch() public {
        uint256 first = votes.currentEpoch();
        _vote(alice, 5);
        _nextEpoch();
        assertEq(votes.totalVotes(first + 1), 0);
        assertFalse(votes.hasVoted(first + 1, alice));
        (uint256 leader, uint256 leaderVotes) = votes.leaderOf(first + 1);
        assertEq(leader, 0);
        assertEq(leaderVotes, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Voting: failure
    // ---------------------------------------------------------------------------------------------

    function test_vote_revertsOnIdEqualToCount() public {
        vm.expectRevert(
            abi.encodeWithSelector(RoadTripVotes.InvalidDestination.selector, DESTINATION_COUNT, DESTINATION_COUNT)
        );
        _vote(alice, DESTINATION_COUNT);
    }

    function test_vote_revertsOnHugeId() public {
        vm.expectRevert(
            abi.encodeWithSelector(RoadTripVotes.InvalidDestination.selector, type(uint256).max, DESTINATION_COUNT)
        );
        _vote(alice, type(uint256).max);
    }

    function testFuzz_vote_revertsOnAnyOutOfRangeId(uint256 id) public {
        id = bound(id, DESTINATION_COUNT, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(RoadTripVotes.InvalidDestination.selector, id, DESTINATION_COUNT));
        _vote(alice, id);
        assertFalse(votes.hasVoted(votes.currentEpoch(), alice));
    }

    function testFuzz_vote_acceptsAnyInRangeId(uint256 id) public {
        id = bound(id, 0, DESTINATION_COUNT - 1);
        _vote(alice, id);
        uint256 epoch = votes.currentEpoch();
        assertEq(votes.votesFor(epoch, id), 1);
        (, uint256 chosen) = votes.voteOf(epoch, alice);
        assertEq(chosen, id);
    }

    function test_vote_revertsOnSecondVoteSameEpoch() public {
        uint256 epoch = votes.currentEpoch();
        _vote(alice, 1);
        vm.expectRevert(abi.encodeWithSelector(RoadTripVotes.AlreadyVoted.selector, epoch, alice));
        _vote(alice, 1);
        // Also rejected when trying to switch destination.
        vm.expectRevert(abi.encodeWithSelector(RoadTripVotes.AlreadyVoted.selector, epoch, alice));
        _vote(alice, 2);
        assertEq(votes.totalVotes(epoch), 1);
        assertEq(votes.votesFor(epoch, 2), 0);
    }

    function test_vote_revertsOnSecondVoteAtLastSecondOfEpoch() public {
        uint256 epoch = votes.currentEpoch();
        _vote(alice, 1);
        vm.warp(START + EPOCH_SECONDS - 1);
        vm.expectRevert(abi.encodeWithSelector(RoadTripVotes.AlreadyVoted.selector, epoch, alice));
        _vote(alice, 1);
    }

    function test_vote_fromContractCallerIsPerAddress() public {
        // Votes are per wallet address; a contract caller is a distinct wallet too.
        Voter proxy = new Voter(votes);
        proxy.cast(4);
        _vote(alice, 4);
        uint256 epoch = votes.currentEpoch();
        assertEq(votes.votesFor(epoch, 4), 2);
        assertTrue(votes.hasVoted(epoch, address(proxy)));
        vm.expectRevert(abi.encodeWithSelector(RoadTripVotes.AlreadyVoted.selector, epoch, address(proxy)));
        proxy.cast(5);
    }

    // ---------------------------------------------------------------------------------------------
    // Winner selection
    // ---------------------------------------------------------------------------------------------

    function test_leader_mostVotesWins() public {
        _vote(alice, 9);
        _vote(bob, 2);
        _vote(carol, 9);
        (uint256 leader, uint256 leaderVotes) = votes.leaderOf(votes.currentEpoch());
        assertEq(leader, 9);
        assertEq(leaderVotes, 2);
    }

    function test_leader_tieGoesToLowestId_lowVotedSecond() public {
        _vote(alice, 40);
        _vote(bob, 3); // ties 1:1, lower id takes the lead
        (uint256 leader,) = votes.leaderOf(votes.currentEpoch());
        assertEq(leader, 3);
    }

    function test_leader_tieGoesToLowestId_lowVotedFirst() public {
        _vote(alice, 3);
        _vote(bob, 40); // ties 1:1, higher id does not take the lead
        (uint256 leader,) = votes.leaderOf(votes.currentEpoch());
        assertEq(leader, 3);
    }

    function test_leader_higherIdOvertakesWithStrictlyMoreVotes() public {
        _vote(alice, 3);
        _vote(bob, 40);
        _vote(carol, 40);
        (uint256 leader, uint256 leaderVotes) = votes.leaderOf(votes.currentEpoch());
        assertEq(leader, 40);
        assertEq(leaderVotes, 2);
    }

    /// @dev The incrementally tracked leader must always equal the brute-force argmax with lowest-id ties.
    function testFuzz_leader_matchesBruteForce(uint8[] memory rawIds) public {
        vm.assume(rawIds.length > 0 && rawIds.length <= 64);
        uint256 epoch = votes.currentEpoch();
        uint256[] memory counts = new uint256[](DESTINATION_COUNT);
        for (uint256 i; i < rawIds.length; ++i) {
            uint256 id = uint256(rawIds[i]) % DESTINATION_COUNT;
            address voter = address(uint160(0x1000 + i));
            _vote(voter, id);
            counts[id] += 1;
        }
        uint256 expected;
        uint256 expectedVotes;
        for (uint256 id; id < DESTINATION_COUNT; ++id) {
            if (counts[id] > expectedVotes) {
                expected = id;
                expectedVotes = counts[id];
            }
            assertEq(votes.votesFor(epoch, id), counts[id]);
        }
        (uint256 leader, uint256 leaderVotes) = votes.leaderOf(epoch);
        assertEq(leader, expected, "leader");
        assertEq(leaderVotes, expectedVotes, "leader votes");
        assertEq(votes.totalVotes(epoch), rawIds.length);

        _nextEpoch();
        votes.finalize(epoch);
        assertEq(votes.winnerOf(epoch), expected);
    }

    // ---------------------------------------------------------------------------------------------
    // Finalization: success
    // ---------------------------------------------------------------------------------------------

    function test_finalize_recordsWinnerAndAppendsRoute() public {
        uint256 epoch = votes.currentEpoch();
        _vote(alice, 12);
        _vote(bob, 12);
        _vote(carol, 1);
        _nextEpoch();

        vm.expectEmit(true, true, true, true, address(votes));
        emit Finalized(epoch, 12, 2, 3, 0);
        votes.finalize(epoch);

        assertTrue(votes.isFinalized(epoch));
        assertEq(votes.winnerOf(epoch), 12);
        assertEq(votes.routeLength(), 1);
        RoadTripVotes.RouteStop memory stop = votes.routeAt(0);
        assertEq(stop.epoch, epoch);
        assertEq(stop.destinationId, 12);
        RoadTripVotes.RouteStop[] memory all = votes.route();
        assertEq(all.length, 1);
        assertEq(all[0].destinationId, 12);
    }

    function test_finalize_callableByAnyone() public {
        uint256 epoch = votes.currentEpoch();
        _vote(alice, 2);
        _nextEpoch();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        votes.finalize(epoch);
        assertEq(votes.winnerOf(epoch), 2);
    }

    function test_finalize_exactlyAtEpochEnd() public {
        uint256 epoch = votes.currentEpoch();
        _vote(alice, 2);
        vm.warp(votes.epochEnd(epoch));
        votes.finalize(epoch);
        assertEq(votes.winnerOf(epoch), 2);
    }

    function test_finalize_longAfterEpochEnd() public {
        uint256 epoch = votes.currentEpoch();
        _vote(alice, 2);
        vm.warp(START + 365 * EPOCH_SECONDS);
        votes.finalize(epoch);
        assertEq(votes.winnerOf(epoch), 2);
    }

    function test_finalize_outOfOrderBuildsRouteInFinalizationOrder() public {
        uint256 e0 = votes.currentEpoch();
        _vote(alice, 10);
        _nextEpoch();
        _vote(alice, 20);
        _nextEpoch();
        _vote(alice, 30);
        _nextEpoch();

        votes.finalize(e0 + 2);
        votes.finalize(e0);
        votes.finalize(e0 + 1);

        assertEq(votes.routeLength(), 3);
        assertEq(votes.routeAt(0).destinationId, 30);
        assertEq(votes.routeAt(1).destinationId, 10);
        assertEq(votes.routeAt(2).destinationId, 20);
        assertEq(votes.routeAt(0).epoch, e0 + 2);
        assertEq(votes.routeAt(1).epoch, e0);
        assertEq(votes.routeAt(2).epoch, e0 + 1);
    }

    function test_finalize_emptyEpochsCanBeSkipped() public {
        uint256 e0 = votes.currentEpoch();
        _vote(alice, 10);
        _nextEpoch(); // e0 + 1: nobody votes
        _nextEpoch();
        _vote(bob, 20);
        _nextEpoch();

        votes.finalize(e0);
        vm.expectRevert(abi.encodeWithSelector(RoadTripVotes.NoVotes.selector, e0 + 1));
        votes.finalize(e0 + 1);
        votes.finalize(e0 + 2);

        assertEq(votes.routeLength(), 2);
        assertEq(votes.routeAt(1).destinationId, 20);
        assertFalse(votes.isFinalized(e0 + 1));
    }

    function test_finalize_laterVotesDoNotChangeRecordedWinner() public {
        uint256 epoch = votes.currentEpoch();
        _vote(alice, 5);
        _nextEpoch();
        votes.finalize(epoch);
        // Voting now lands in the new epoch and cannot touch the old tally.
        _vote(bob, 6);
        _vote(carol, 6);
        assertEq(votes.winnerOf(epoch), 5);
        assertEq(votes.votesFor(epoch, 6), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Finalization: failure
    // ---------------------------------------------------------------------------------------------

    function test_finalize_revertsForCurrentEpoch() public {
        uint256 epoch = votes.currentEpoch();
        _vote(alice, 1);
        vm.expectRevert(abi.encodeWithSelector(RoadTripVotes.EpochNotEnded.selector, epoch, epoch));
        votes.finalize(epoch);
    }

    function test_finalize_revertsAtLastSecondOfEpoch() public {
        uint256 epoch = votes.currentEpoch();
        _vote(alice, 1);
        vm.warp(START + EPOCH_SECONDS - 1);
        vm.expectRevert(abi.encodeWithSelector(RoadTripVotes.EpochNotEnded.selector, epoch, epoch));
        votes.finalize(epoch);
    }

    function test_finalize_revertsForFutureEpoch() public {
        uint256 epoch = votes.currentEpoch();
        vm.expectRevert(abi.encodeWithSelector(RoadTripVotes.EpochNotEnded.selector, epoch + 5, epoch));
        votes.finalize(epoch + 5);
    }

    function test_finalize_revertsWhenNoVotes() public {
        uint256 epoch = votes.currentEpoch();
        _nextEpoch();
        vm.expectRevert(abi.encodeWithSelector(RoadTripVotes.NoVotes.selector, epoch));
        votes.finalize(epoch);
        assertFalse(votes.isFinalized(epoch));
        assertEq(votes.routeLength(), 0);
    }

    function test_finalize_revertsWhenAlreadyFinalized() public {
        uint256 epoch = votes.currentEpoch();
        _vote(alice, 1);
        _nextEpoch();
        votes.finalize(epoch);
        vm.expectRevert(abi.encodeWithSelector(RoadTripVotes.AlreadyFinalized.selector, epoch));
        votes.finalize(epoch);
        assertEq(votes.routeLength(), 1, "winner recorded exactly once");
    }

    function testFuzz_finalize_revertsForAnyUnendedEpoch(uint256 epoch) public {
        uint256 current = votes.currentEpoch();
        epoch = bound(epoch, current, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(RoadTripVotes.EpochNotEnded.selector, epoch, current));
        votes.finalize(epoch);
    }

    // ---------------------------------------------------------------------------------------------
    // Views: failure
    // ---------------------------------------------------------------------------------------------

    function test_winnerOf_revertsUntilFinalized() public {
        uint256 epoch = votes.currentEpoch();
        _vote(alice, 1);
        vm.expectRevert(abi.encodeWithSelector(RoadTripVotes.NotFinalized.selector, epoch));
        votes.winnerOf(epoch);
        _nextEpoch();
        vm.expectRevert(abi.encodeWithSelector(RoadTripVotes.NotFinalized.selector, epoch));
        votes.winnerOf(epoch);
        votes.finalize(epoch);
        assertEq(votes.winnerOf(epoch), 1);
    }

    function test_routeAt_revertsOutOfRange() public {
        vm.expectRevert(abi.encodeWithSelector(RoadTripVotes.RouteIndexOutOfRange.selector, 0, 0));
        votes.routeAt(0);
        _vote(alice, 1);
        uint256 epoch = votes.currentEpoch();
        _nextEpoch();
        votes.finalize(epoch);
        vm.expectRevert(abi.encodeWithSelector(RoadTripVotes.RouteIndexOutOfRange.selector, 1, 1));
        votes.routeAt(1);
    }

    // ---------------------------------------------------------------------------------------------
    // Multi-epoch scenario
    // ---------------------------------------------------------------------------------------------

    function test_scenario_threeDaysOfPlay() public {
        uint256 e0 = votes.currentEpoch();

        // Day 1: 12 wins 2:1.
        _vote(alice, 12);
        _vote(bob, 12);
        _vote(carol, 1);
        _nextEpoch();
        votes.finalize(e0);

        // Day 2: tie between 50 and 7; 7 wins by lowest id.
        _vote(alice, 50);
        _vote(bob, 7);
        _nextEpoch();
        votes.finalize(e0 + 1);

        // Day 3: single vote.
        _vote(carol, 63);
        _nextEpoch();
        votes.finalize(e0 + 2);

        assertEq(votes.winnerOf(e0), 12);
        assertEq(votes.winnerOf(e0 + 1), 7);
        assertEq(votes.winnerOf(e0 + 2), 63);
        RoadTripVotes.RouteStop[] memory all = votes.route();
        assertEq(all.length, 3);
        assertEq(all[0].destinationId, 12);
        assertEq(all[1].destinationId, 7);
        assertEq(all[2].destinationId, 63);

        // Navigator data: alice matched day 1, bob matched days 1 and 2, carol matched day 3.
        (, uint256 a0) = votes.voteOf(e0, alice);
        (, uint256 b1) = votes.voteOf(e0 + 1, bob);
        (, uint256 c2) = votes.voteOf(e0 + 2, carol);
        assertEq(a0, votes.winnerOf(e0));
        assertEq(b1, votes.winnerOf(e0 + 1));
        assertEq(c2, votes.winnerOf(e0 + 2));
    }

    function testFuzz_configuration_anyPositiveValuesWork(uint32 epochSeconds, uint16 destinationCount) public {
        epochSeconds = uint32(bound(epochSeconds, 1, type(uint32).max));
        destinationCount = uint16(bound(destinationCount, 1, type(uint16).max));
        RoadTripVotes fresh = new RoadTripVotes(epochSeconds, destinationCount);
        uint256 epoch = fresh.currentEpoch();
        uint256 last = uint256(destinationCount) - 1;

        vm.prank(alice);
        fresh.vote(last);
        vm.expectRevert(
            abi.encodeWithSelector(RoadTripVotes.InvalidDestination.selector, destinationCount, destinationCount)
        );
        vm.prank(bob);
        fresh.vote(destinationCount);

        vm.warp(vm.getBlockTimestamp() + epochSeconds);
        assertEq(fresh.currentEpoch(), epoch + 1);
        fresh.finalize(epoch);
        assertEq(fresh.winnerOf(epoch), last);
    }
}

/// @dev A contract wallet, to show voting is per calling address with no EOA assumption.
contract Voter {
    RoadTripVotes private immutable votes;

    constructor(RoadTripVotes votes_) {
        votes = votes_;
    }

    function cast(uint256 id) external {
        votes.vote(id);
    }
}
