// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title BeaconBillboard (V1)
/// @notice Beacon-proxied variant of Billboard. Unlike the UUPS version, this
///         implementation carries NO upgrade logic at all — every BeaconProxy
///         instance asks the shared UpgradeableBeacon (owned by the factory)
///         where its logic lives. Each instance keeps its own storage: its own
///         owner, its own message.
contract BeaconBillboard is Initializable, OwnableUpgradeable {
    // ─── Storage ────────────────────────────────────────────────────────────
    // Upgrade rule: future versions may APPEND variables below, but must
    // never reorder, remove, or retype the existing ones.
    string private _message; // slot 0

    // ─── Events ─────────────────────────────────────────────────────────────
    event MessageUpdated(string newMessage);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Runs once per instance, in that BeaconProxy's own storage.
    function initialize(address initialOwner, string memory initialMessage) public initializer {
        __Ownable_init(initialOwner);
        _message = initialMessage;
        emit MessageUpdated(initialMessage);
    }

    function setMessage(string memory newMessage) external virtual onlyOwner {
        _message = newMessage;
        emit MessageUpdated(newMessage);
    }

    function message() external view returns (string memory) {
        return _message;
    }

    function version() external pure virtual returns (string memory) {
        return "1";
    }
}
