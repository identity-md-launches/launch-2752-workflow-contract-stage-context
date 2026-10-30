// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {RoadTripVotes} from "../src/RoadTripVotes.sol";

/// @title DeployRoadTripVotes
/// @notice Reviewable deployment script for `RoadTripVotes`. The IMD launch deploys the contract through
///         its factory from the built bytecode with the constructor arguments listed in launch.json, so this
///         script is a rehearsal and a reference for the exact values; it is not what launches the contract.
/// @dev    Configuration is given as constants and function arguments, never read from the environment, so
///         tests can call `deploy` directly and run in parallel with an empty environment.
contract DeployRoadTripVotes is Script {
    /// @notice One epoch is 24 hours (the brief's `epochSeconds`).
    uint256 public constant EPOCH_SECONDS = 86_400;

    /// @notice 64 destinations, ids 0 to 63 (the brief's `destinationCount`).
    uint256 public constant DESTINATION_COUNT = 64;

    /// @notice Deploys with the game's canonical configuration under a broadcast.
    function run() external returns (RoadTripVotes votes) {
        vm.startBroadcast();
        votes = deploy(EPOCH_SECONDS, DESTINATION_COUNT);
        vm.stopBroadcast();
    }

    /// @notice Deploys a `RoadTripVotes` with explicit configuration. Called by tests directly.
    function deploy(uint256 epochSeconds, uint256 destinationCount) public returns (RoadTripVotes votes) {
        votes = new RoadTripVotes(epochSeconds, destinationCount);
    }
}
