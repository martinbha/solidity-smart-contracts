// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title Billboard (V1)
/// @notice An owner-controlled message board living behind a UUPS proxy.
///         All state is stored in the proxy; this contract is pure logic.
contract Billboard is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    // ─── Storage ────────────────────────────────────────────────────────────
    // Upgrade rule: future versions may APPEND variables below, but must
    // never reorder, remove, or retype the existing ones.
    string private _message; // slot 0

    // ─── Events ─────────────────────────────────────────────────────────────
    event MessageUpdated(string newMessage);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Lock the implementation contract itself so nobody can initialize
        // it directly — only the proxy's storage should ever be initialized.
        _disableInitializers();
    }

    /// @notice Replaces the constructor; runs once, in the proxy's storage.
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

    /// @dev UUPS upgrade gate: only the owner may point the proxy at new logic.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
