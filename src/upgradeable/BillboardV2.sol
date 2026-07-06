// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title Billboard (V2)
/// @notice Adds edit tracking on top of V1. Deployed as a fresh implementation
///         and swapped in via upgradeToAndCall; the proxy's existing _message
///         survives because the storage layout below only APPENDS to V1's.
contract BillboardV2 is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    // ─── Storage ────────────────────────────────────────────────────────────
    // V1 layout — must match Billboard exactly, same order, same types.
    string private _message; // slot 0 (inherited state, already populated)

    // V2 additions — appended only. These slots were zero before the upgrade,
    // so counters naturally start at 0 and addresses at address(0).
    uint256 private _updateCount; // slot 1
    address private _lastEditor; // slot 2

    // ─── Events ─────────────────────────────────────────────────────────────
    event MessageUpdated(string newMessage);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
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

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
