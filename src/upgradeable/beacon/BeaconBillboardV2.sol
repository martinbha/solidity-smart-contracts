// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title BeaconBillboard (V2)
/// @notice Adds edit tracking. A single beacon.upgradeTo(thisImplementation)
///         flips EVERY instance in the fleet to this logic at once — no
///         per-instance transactions. Existing instances keep their state
///         (layout below only APPENDS to V1's); instances created after the
///         upgrade initialize directly against V2, which is why initialize()
///         must remain present here.
contract BeaconBillboardV2 is Initializable, OwnableUpgradeable {
    // ─── Storage ────────────────────────────────────────────────────────────
    // V1 layout — must match BeaconBillboard exactly, same order, same types.
    string private _message; // slot 0 (already populated on upgraded instances)

    // V2 additions — appended only. Zero on freshly upgraded instances.
    uint256 private _updateCount; // slot 1
    address private _lastEditor; // slot 2

    // ─── Events ─────────────────────────────────────────────────────────────
    event MessageUpdated(string newMessage);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Still needed post-upgrade: instances the factory creates after
    ///         the fleet upgrade initialize against this implementation.
    function initialize(address initialOwner, string memory initialMessage) public initializer {
        __Ownable_init(initialOwner);
        _message = initialMessage;
        emit MessageUpdated(initialMessage);
    }

    function setMessage(string memory newMessage) external virtual onlyOwner {
        _message = newMessage;
        _updateCount += 1;
        _lastEditor = msg.sender;
        emit MessageUpdated(newMessage);
    }

    function message() external view returns (string memory) {
        return _message;
    }

    function updateCount() external view returns (uint256) {
        return _updateCount;
    }

    function lastEditor() external view returns (address) {
        return _lastEditor;
    }

    function version() external pure virtual returns (string memory) {
        return "2";
    }
}
