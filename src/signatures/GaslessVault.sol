// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title GaslessVault
/// @notice Token vault whose every entry point identifies the caller via
///         ERC-2771 `_msgSender()` instead of raw `msg.sender`. Called
///         directly it behaves like any vault; called through the trusted
///         forwarder it credits the *signer* of the forwarded request, so a
///         user with zero ETH can deposit, transfer, and withdraw while a
///         relayer pays the gas.
///
/// @dev The trusted-forwarder model, and why it is all-or-nothing:
///
///      - ERC-2771 smuggles the real sender as a 20-byte calldata suffix.
///        `_msgSender()` only honors that suffix when `msg.sender` is the
///        trusted forwarder — the one contract known to write the suffix
///        honestly, only after verifying the user's signature. Any other
///        caller appending 20 bytes is just calling with longer calldata and
///        remains `msg.sender` itself; there is nothing to spoof.
///      - The flip side: the suffix is *unauthenticated data* vouched for
///        solely by the forwarder's identity. Trusting a forwarder that does
///        not verify signatures (or that an attacker controls) hands every
///        balance in the vault to whoever can drive it — the "signer" becomes
///        whatever 20 bytes the caller chooses to append. Choosing the
///        trusted forwarder is a security decision equal to holding the keys.
///      - The forwarder address is immutable here for exactly that reason: a
///        mutable trusted forwarder is a rug waiting for a compromised admin.
///
///      `depositWithPermit` composes both signature tricks: the EIP-2612
///      permit replaces the approve transaction and the ERC-2771 relay
///      replaces the deposit transaction, so onboarding costs the user zero
///      ETH and zero transactions — two signatures and nothing else.
contract GaslessVault is ERC2771Context {
    using SafeERC20 for IERC20;

    /// @notice The ERC20 (with EIP-2612 permit) this vault holds.
    IERC20 public immutable asset;

    /// @notice Internal balance per depositor.
    mapping(address => uint256) public balances;

    event Deposited(address indexed account, uint256 amount);
    event Transferred(address indexed from, address indexed to, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);

    error ZeroAmount();
    error InvalidRecipient();
    error InsufficientBalance(uint256 requested, uint256 available);

    constructor(IERC20 asset_, address trustedForwarder_) ERC2771Context(trustedForwarder_) {
        asset = asset_;
    }

    /// @notice Deposits `amount` tokens from the caller (the original signer
    ///         when called via the trusted forwarder). Requires a prior
    ///         allowance — see `depositWithPermit` to skip that transaction.
    function deposit(uint256 amount) external {
        _deposit(_msgSender(), amount);
    }

    /// @notice Deposits `amount` using an EIP-2612 permit signed by the
    ///         caller, so no separate approve transaction is ever sent.
    /// @dev The permit call is wrapped in try/catch: permits are consumed
    ///      from a public mempool, so a front-runner can submit the inner
    ///      `permit` alone first and make ours revert with a used nonce. The
    ///      allowance is set either way — proceed to the pull, which is the
    ///      real authorization check. (See "ERC-2612 permit front-running".)
    function depositWithPermit(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external {
        address account = _msgSender();
        try IERC20Permit(address(asset)).permit(account, address(this), amount, deadline, v, r, s) {} catch {}
        _deposit(account, amount);
    }

    /// @notice Moves `amount` of the caller's internal balance to `to`.
    ///         This is the kind of authority ERC-2771 spoofing steals: whoever
    ///         `_msgSender()` resolves to spends the balance.
    /// @dev Rejects a zero recipient: no caller can ever resolve to
    ///      `address(0)` (the forwarder rejects a zero recovered signer), so
    ///      a balance moved there would be stranded forever.
    function transfer(address to, uint256 amount) external {
        if (to == address(0)) revert InvalidRecipient();
        address account = _msgSender();
        _debit(account, amount);
        balances[to] += amount;
        emit Transferred(account, to, amount);
    }

    /// @notice Withdraws `amount` tokens back to the caller.
    function withdraw(uint256 amount) external {
        address account = _msgSender();
        _debit(account, amount);
        asset.safeTransfer(account, amount);
        emit Withdrawn(account, amount);
    }

    function _deposit(address account, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        asset.safeTransferFrom(account, address(this), amount);
        balances[account] += amount;
        emit Deposited(account, amount);
    }

    function _debit(address account, uint256 amount) internal {
        uint256 available = balances[account];
        if (amount > available) revert InsufficientBalance(amount, available);
        balances[account] = available - amount;
    }
}
