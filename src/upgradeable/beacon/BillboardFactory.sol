// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {BeaconBillboard} from "./BeaconBillboard.sol";

/// @title BillboardFactory
/// @notice Mints BeaconProxy billboards on demand and owns the shared beacon,
///         so the whole fleet upgrades with a single transaction.
///
///         Trust model: whoever calls createBillboard owns that instance's
///         state (its message), but the factory owner controls the LOGIC of
///         every instance via upgradeFleet — the fundamental beacon tradeoff.
///
///         Instances are deployed with CREATE2, so an instance's address can
///         be predicted before it exists. The effective salt binds the
///         creator's address, so nobody can front-run an address you predicted
///         for yourself.
contract BillboardFactory is Ownable {
    /// @notice The shared beacon every instance reads its implementation from.
    ///         Owned by this factory; upgraded only through upgradeFleet.
    UpgradeableBeacon public immutable beacon;

    address[] private _allBillboards;

    event BillboardCreated(address indexed billboard, address indexed owner, bytes32 salt);
    event FleetUpgraded(address indexed newImplementation, uint256 fleetSize);

    constructor(address initialImplementation, address initialOwner) Ownable(initialOwner) {
        beacon = new UpgradeableBeacon(initialImplementation, address(this));
    }

    /// @notice Deploys a new billboard instance; the caller becomes its owner.
    /// @param salt Caller-chosen salt for the deterministic address. The same
    ///        (creator, salt, initialMessage) triple can only be used once.
    function createBillboard(string memory initialMessage, bytes32 salt)
        external
        returns (address billboard)
    {
        billboard = address(
            new BeaconProxy{salt: _instanceSalt(msg.sender, salt)}(
                address(beacon),
                abi.encodeCall(BeaconBillboard.initialize, (msg.sender, initialMessage))
            )
        );
        _allBillboards.push(billboard);
        emit BillboardCreated(billboard, msg.sender, salt);
    }

    /// @notice One transaction, every instance — past and future — now runs
    ///         newImplementation.
    function upgradeFleet(address newImplementation) external onlyOwner {
        beacon.upgradeTo(newImplementation);
        emit FleetUpgraded(newImplementation, _allBillboards.length);
    }

    /// @notice Address a createBillboard(initialMessage, salt) call from
    ///         `creator` will deploy to. Depends on the init message because
    ///         it is part of the proxy's constructor args.
    function predictBillboardAddress(address creator, bytes32 salt, string memory initialMessage)
        external
        view
        returns (address)
    {
        bytes memory initCode = abi.encodePacked(
            type(BeaconProxy).creationCode,
            abi.encode(
                address(beacon), abi.encodeCall(BeaconBillboard.initialize, (creator, initialMessage))
            )
        );
        return Create2.computeAddress(_instanceSalt(creator, salt), keccak256(initCode));
    }

    function allBillboards() external view returns (address[] memory) {
        return _allBillboards;
    }

    function billboardCount() external view returns (uint256) {
        return _allBillboards.length;
    }

    function billboardAt(uint256 index) external view returns (address) {
        return _allBillboards[index];
    }

    /// @dev Binding msg.sender into the salt means two creators can use the
    ///      same salt, and a predicted address can only be claimed by the
    ///      creator it was predicted for.
    function _instanceSalt(address creator, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(creator, salt));
    }
}
