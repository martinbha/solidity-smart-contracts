// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {PermitToken} from "../../src/signatures/PermitToken.sol";
import {MinimalForwarder} from "../../src/signatures/MinimalForwarder.sol";
import {GaslessVault} from "../../src/signatures/GaslessVault.sol";

/// @dev A forwarder that appends whatever sender it is told to — the attack
///      ERC-2771 warns about. It never verifies a signature; a target that
///      trusts it lets any caller impersonate anyone.
contract MaliciousForwarder {
    function impersonate(address target, bytes calldata data, address victim) external {
        (bool ok, bytes memory ret) = target.call(abi.encodePacked(data, victim));
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

contract GaslessTest is Test {
    // secp256k1 group order: valid private keys live in [1, N-1].
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    PermitToken internal token;
    MinimalForwarder internal forwarder;
    GaslessVault internal vault;

    uint256 internal userKey = 0xA11CE;
    address internal user;
    address internal relayer = makeAddr("relayer");
    address internal spender = makeAddr("spender");

    uint256 internal deadline;

    function setUp() public {
        user = vm.addr(userKey);
        token = new PermitToken();
        forwarder = new MinimalForwarder();
        vault = new GaslessVault(IERC20(address(token)), address(forwarder));

        token.mint(user, 1000 ether);
        deadline = block.timestamp + 1 days;

        // The whole point: the user signs but never pays — no ETH, ever.
        assertEq(user.balance, 0);
    }

    // ---------------------------------------------------------------- helpers

    function _permitDigest(address owner, address to, uint256 value, uint256 nonce, uint256 deadline_)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                token.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, to, value, nonce, deadline_))
            )
        );
    }

    function _signPermit(uint256 key, address to, uint256 value) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        address owner = vm.addr(key);
        return vm.sign(key, _permitDigest(owner, to, value, token.nonces(owner), deadline));
    }

    function _request(address from, address to, bytes memory data)
        internal
        view
        returns (MinimalForwarder.ForwardRequest memory)
    {
        return MinimalForwarder.ForwardRequest({
            from: from, to: to, value: 0, gas: 300_000, nonce: forwarder.nonces(from), data: data
        });
    }

    function _signRequest(uint256 key, MinimalForwarder.ForwardRequest memory req)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, forwarder.requestHash(req));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Signs a permit for the vault plus the forward request wrapping
    ///      `depositWithPermit` — the fully gasless deposit bundle.
    function _gaslessDepositBundle(uint256 key, uint256 amount)
        internal
        view
        returns (MinimalForwarder.ForwardRequest memory req, bytes memory sig)
    {
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(key, address(vault), amount);
        bytes memory data = abi.encodeCall(GaslessVault.depositWithPermit, (amount, deadline, v, r, s));
        req = _request(vm.addr(key), address(vault), data);
        sig = _signRequest(key, req);
    }

    // ------------------------------------------------------------ EIP-2612 permit

    function test_permitSetsAllowanceFromSignature() public {
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(userKey, spender, 500 ether);

        // Anyone can submit the signed permit; the owner sends no transaction.
        vm.prank(makeAddr("submitter"));
        token.permit(user, spender, 500 ether, deadline, v, r, s);

        assertEq(token.allowance(user, spender), 500 ether);
        assertEq(token.nonces(user), 1);
    }

    function test_permitRejectsWrongSigner() public {
        uint256 wrongKey = 0xBAD;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(wrongKey, _permitDigest(user, spender, 500 ether, token.nonces(user), deadline));

        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, vm.addr(wrongKey), user));
        token.permit(user, spender, 500 ether, deadline, v, r, s);
    }

    function test_permitRejectsExpiredDeadline() public {
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(userKey, spender, 500 ether);

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(user, spender, 500 ether, deadline, v, r, s);
    }

    function test_permitRejectsReplayedNonce() public {
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(userKey, spender, 500 ether);
        token.permit(user, spender, 500 ether, deadline, v, r, s);

        // Replaying recomputes the digest with the bumped nonce, so the old
        // signature recovers some other (non-owner) signer and is rejected.
        address recovered = ecrecover(_permitDigest(user, spender, 500 ether, token.nonces(user), deadline), v, r, s);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, recovered, user));
        token.permit(user, spender, 500 ether, deadline, v, r, s);
    }

    function test_permitAndTransferFromComposeInOneTransaction() public {
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(userKey, spender, 500 ether);

        // The approve-then-spend dance collapses: the spender submits the
        // owner's signed approval and spends it in the same transaction.
        vm.startPrank(spender);
        token.permit(user, spender, 500 ether, deadline, v, r, s);
        token.transferFrom(user, spender, 500 ether);
        vm.stopPrank();

        assertEq(token.balanceOf(spender), 500 ether);
        assertEq(token.balanceOf(user), 500 ether);
        assertEq(token.allowance(user, spender), 0);
    }

    // -------------------------------------------------------- ERC-2771 forwarding

    function test_forwardedCallTargetSeesSignerNotRelayer() public {
        vm.prank(user);
        token.approve(address(vault), 100 ether);

        MinimalForwarder.ForwardRequest memory req =
            _request(user, address(vault), abi.encodeCall(GaslessVault.deposit, (100 ether)));
        bytes memory sig = _signRequest(userKey, req);
        assertTrue(forwarder.verify(req, sig));

        vm.prank(relayer);
        (bool success,) = forwarder.execute(req, sig);

        assertTrue(success);
        // The vault credited the signer, not the relayer who paid the gas.
        assertEq(vault.balances(user), 100 ether);
        assertEq(vault.balances(relayer), 0);
        assertEq(forwarder.nonces(user), 1);
    }

    function test_tamperedRequestFailsVerification() public {
        MinimalForwarder.ForwardRequest memory req =
            _request(user, address(vault), abi.encodeCall(GaslessVault.deposit, (100 ether)));
        bytes memory sig = _signRequest(userKey, req);

        MinimalForwarder.ForwardRequest memory tampered = req;
        tampered.to = makeAddr("otherTarget");
        assertFalse(forwarder.verify(tampered, sig));

        tampered = req;
        tampered.data = abi.encodeCall(GaslessVault.deposit, (999 ether));
        assertFalse(forwarder.verify(tampered, sig));

        tampered = req;
        tampered.value = 1 ether;
        assertFalse(forwarder.verify(tampered, sig));

        vm.expectRevert(MinimalForwarder.InvalidRequest.selector);
        forwarder.execute(tampered, sig);
    }

    function test_replayedForwardRequestReverts() public {
        vm.prank(user);
        token.approve(address(vault), 200 ether);

        MinimalForwarder.ForwardRequest memory req =
            _request(user, address(vault), abi.encodeCall(GaslessVault.deposit, (100 ether)));
        bytes memory sig = _signRequest(userKey, req);

        vm.prank(relayer);
        forwarder.execute(req, sig);

        // Same signed request again: the nonce moved on, verification fails.
        assertFalse(forwarder.verify(req, sig));
        vm.prank(relayer);
        vm.expectRevert(MinimalForwarder.InvalidRequest.selector);
        forwarder.execute(req, sig);
    }

    function test_executeRequiresExactValue() public {
        MinimalForwarder.ForwardRequest memory req =
            _request(user, address(vault), abi.encodeCall(GaslessVault.deposit, (100 ether)));
        req.value = 1 ether;
        bytes memory sig = _signRequest(userKey, req);

        vm.expectRevert(abi.encodeWithSelector(MinimalForwarder.ValueMismatch.selector, 1 ether, 0));
        forwarder.execute(req, sig);
    }

    // --------------------------------------------------------- spoofing resistance

    function test_directCallerCannotSpoofWithForgedSuffix() public {
        address attacker = makeAddr("attacker");
        token.mint(attacker, 100 ether);
        vm.startPrank(attacker);
        token.approve(address(vault), 100 ether);

        // Hand-craft an ERC-2771-style call: deposit calldata with the
        // victim's address appended. The vault must ignore the suffix — the
        // caller is not the trusted forwarder — and treat the attacker as
        // the sender.
        (bool ok,) = address(vault).call(abi.encodePacked(abi.encodeCall(GaslessVault.deposit, (100 ether)), user));
        vm.stopPrank();

        assertTrue(ok);
        assertEq(vault.balances(attacker), 100 ether);
        assertEq(vault.balances(user), 0);
    }

    function test_untrustedForwarderIsJustACaller() public {
        // A perfectly honest forwarder the vault does not trust: its suffix
        // is ignored and the vault sees the forwarder contract itself, which
        // has no allowance — the deposit fails, nothing is credited.
        MinimalForwarder stranger = new MinimalForwarder();
        vm.prank(user);
        token.approve(address(vault), 100 ether);

        MinimalForwarder.ForwardRequest memory req = MinimalForwarder.ForwardRequest({
            from: user,
            to: address(vault),
            value: 0,
            gas: 300_000,
            nonce: stranger.nonces(user),
            data: abi.encodeCall(GaslessVault.deposit, (100 ether))
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userKey, stranger.requestHash(req));

        // Signed for the stranger's domain: the trusted forwarder rejects it…
        vm.prank(relayer);
        vm.expectRevert(MinimalForwarder.InvalidRequest.selector);
        forwarder.execute(req, abi.encodePacked(r, s, v));

        // …and through the stranger the vault sees the stranger contract
        // itself (no allowance), so the inner deposit fails.
        vm.prank(relayer);
        (bool success,) = stranger.execute(req, abi.encodePacked(r, s, v));
        assertFalse(success);

        assertEq(vault.balances(user), 0);
        assertEq(vault.balances(address(stranger)), 0);
    }

    function test_trustingAMaliciousForwarderIsCatastrophic() public {
        // A vault misconfigured to trust an attacker-controlled forwarder:
        // the suffix is unauthenticated data, so the attacker impersonates
        // any depositor at will and walks off with their balance.
        MaliciousForwarder evil = new MaliciousForwarder();
        GaslessVault trap = new GaslessVault(IERC20(address(token)), address(evil));

        vm.startPrank(user);
        token.approve(address(trap), 100 ether);
        trap.deposit(100 ether);
        vm.stopPrank();

        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);
        evil.impersonate(address(trap), abi.encodeCall(GaslessVault.transfer, (attacker, 100 ether)), user);
        trap.withdraw(100 ether);
        vm.stopPrank();

        assertEq(trap.balances(user), 0);
        assertEq(token.balanceOf(attacker), 100 ether);
    }

    // ------------------------------------------------- fully gasless deposit

    function test_gaslessDepositWithPermitEndToEnd() public {
        // Two signatures, zero transactions, zero ETH from the user: the
        // permit replaces approve, the forwarded call replaces deposit.
        (MinimalForwarder.ForwardRequest memory req, bytes memory sig) = _gaslessDepositBundle(userKey, 250 ether);

        vm.prank(relayer);
        (bool success,) = forwarder.execute(req, sig);

        assertTrue(success);
        assertEq(vault.balances(user), 250 ether);
        assertEq(token.balanceOf(address(vault)), 250 ether);
        assertEq(user.balance, 0); // still never held ETH
        assertEq(token.nonces(user), 1); // permit consumed
        assertEq(forwarder.nonces(user), 1); // request consumed
    }

    function test_gaslessWithdrawReturnsTokensToSigner() public {
        (MinimalForwarder.ForwardRequest memory req, bytes memory sig) = _gaslessDepositBundle(userKey, 250 ether);
        vm.prank(relayer);
        forwarder.execute(req, sig);

        MinimalForwarder.ForwardRequest memory wReq =
            _request(user, address(vault), abi.encodeCall(GaslessVault.withdraw, (250 ether)));
        vm.prank(relayer);
        (bool success,) = forwarder.execute(wReq, _signRequest(userKey, wReq));

        assertTrue(success);
        assertEq(vault.balances(user), 0);
        assertEq(token.balanceOf(user), 1000 ether);
        assertEq(user.balance, 0);
    }

    // ------------------------------------------------------------------- fuzz

    /// @dev Whatever the signer and amount, a relayed gasless deposit always
    ///      credits the signer — never the relayer, never the suffix-forger.
    function testFuzz_gaslessDepositAlwaysCreditsSigner(uint256 keySeed, uint256 amount) public {
        uint256 key = bound(keySeed, 1, SECP256K1_N - 1);
        amount = bound(amount, 1, type(uint128).max);
        address signer = vm.addr(key);
        vm.assume(signer != user); // `user` is pre-funded in setUp

        token.mint(signer, amount);
        (MinimalForwarder.ForwardRequest memory req, bytes memory sig) = _gaslessDepositBundle(key, amount);

        vm.prank(relayer);
        (bool success,) = forwarder.execute(req, sig);

        assertTrue(success);
        assertEq(vault.balances(signer), amount);
        assertEq(vault.balances(relayer), 0);
        assertEq(token.balanceOf(signer), 0);
        assertEq(signer.balance, 0);
    }
}
