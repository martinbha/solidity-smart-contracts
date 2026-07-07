// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AirdropToken} from "../../src/merkle/AirdropToken.sol";
import {MerkleDistributor} from "../../src/merkle/MerkleDistributor.sol";
import {MerkleTreeLib} from "../../src/merkle/MerkleTreeLib.sol";

contract MerkleDistributorTest is Test {
    uint256 internal constant RECIPIENT_COUNT = 8;
    uint256 internal constant CLAIM_WINDOW = 30 days;

    AirdropToken internal token;
    MerkleDistributor internal distributor;

    // Recipient i = vm.addr(KEY_BASE + i), so we can EIP-712-sign for them.
    uint256 internal constant KEY_BASE = 0xA11CE000;
    address[] internal accounts;
    uint256[] internal amounts;
    bytes32[] internal leaves;
    bytes32 internal root;

    address internal owner = makeAddr("owner");
    address internal relayer = makeAddr("relayer");
    uint256 internal totalAmount;

    function setUp() public {
        for (uint256 i = 0; i < RECIPIENT_COUNT; i++) {
            accounts.push(vm.addr(KEY_BASE + i));
            amounts.push((i + 1) * 100 ether);
            totalAmount += (i + 1) * 100 ether;
        }
        for (uint256 i = 0; i < RECIPIENT_COUNT; i++) {
            leaves.push(MerkleTreeLib.leaf(i, accounts[i], amounts[i]));
        }
        root = MerkleTreeLib.buildRoot(leaves);

        token = new AirdropToken(totalAmount);
        distributor =
            new MerkleDistributor(token, root, block.timestamp + CLAIM_WINDOW, owner);
        require(token.transfer(address(distributor), totalAmount), "funding failed");
    }

    function proofFor(uint256 index) internal view returns (bytes32[] memory) {
        // storage -> memory copy for the pure tree builder
        bytes32[] memory memLeaves = new bytes32[](leaves.length);
        for (uint256 i = 0; i < leaves.length; i++) {
            memLeaves[i] = leaves[i];
        }
        return MerkleTreeLib.buildProof(memLeaves, index);
    }

    // ─── claim() ────────────────────────────────────────────────────────────

    function test_ValidClaimTransfersAndMarksBitmap() public {
        assertFalse(distributor.isClaimed(3));

        vm.expectEmit();
        emit MerkleDistributor.Claimed(3, accounts[3], accounts[3], amounts[3]);
        vm.prank(relayer); // anyone can submit; tokens still go to the account
        distributor.claim(3, accounts[3], amounts[3], proofFor(3));

        assertEq(token.balanceOf(accounts[3]), amounts[3]);
        assertEq(token.balanceOf(relayer), 0);
        assertTrue(distributor.isClaimed(3));
    }

    function test_RevertWhen_ClaimedTwice() public {
        distributor.claim(0, accounts[0], amounts[0], proofFor(0));

        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.AlreadyClaimed.selector, 0));
        distributor.claim(0, accounts[0], amounts[0], proofFor(0));
    }

    function test_RevertWhen_WrongAmount() public {
        vm.expectRevert(MerkleDistributor.InvalidProof.selector);
        distributor.claim(0, accounts[0], amounts[0] + 1, proofFor(0));
    }

    function test_RevertWhen_WrongAccount() public {
        vm.expectRevert(MerkleDistributor.InvalidProof.selector);
        distributor.claim(0, accounts[1], amounts[0], proofFor(0));
    }

    function test_RevertWhen_ProofTruncated() public {
        bytes32[] memory proof = proofFor(0);
        bytes32[] memory truncated = new bytes32[](proof.length - 1);
        for (uint256 i = 0; i < truncated.length; i++) {
            truncated[i] = proof[i];
        }
        vm.expectRevert(MerkleDistributor.InvalidProof.selector);
        distributor.claim(0, accounts[0], amounts[0], truncated);
    }

    function test_RevertWhen_ProofForOtherLeaf() public {
        vm.expectRevert(MerkleDistributor.InvalidProof.selector);
        distributor.claim(1, accounts[1], amounts[1], proofFor(0));
    }

    function testFuzz_EveryLeafClaimsInAnyOrder(uint256 seed) public {
        // Claim all leaves in a fuzzed order; everyone must get exactly theirs.
        uint256[] memory order = new uint256[](RECIPIENT_COUNT);
        for (uint256 i = 0; i < RECIPIENT_COUNT; i++) {
            order[i] = i;
        }
        for (uint256 i = RECIPIENT_COUNT - 1; i > 0; i--) {
            uint256 j = uint256(keccak256(abi.encode(seed, i))) % (i + 1);
            (order[i], order[j]) = (order[j], order[i]);
        }

        for (uint256 i = 0; i < RECIPIENT_COUNT; i++) {
            uint256 idx = order[i];
            distributor.claim(idx, accounts[idx], amounts[idx], proofFor(idx));
        }
        for (uint256 i = 0; i < RECIPIENT_COUNT; i++) {
            assertEq(token.balanceOf(accounts[i]), amounts[i]);
        }
        assertEq(token.balanceOf(address(distributor)), 0);
    }

    // ─── claimTo() (EIP-712 redirect) ───────────────────────────────────────

    function test_ClaimToRedirectsWithValidSignature() public {
        address coldWallet = makeAddr("coldWallet");
        bytes32 digest = distributor.claimToDigest(2, accounts[2], amounts[2], coldWallet);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY_BASE + 2, digest);

        vm.prank(relayer);
        distributor.claimTo(
            2, accounts[2], amounts[2], coldWallet, proofFor(2), abi.encodePacked(r, s, v)
        );

        assertEq(token.balanceOf(coldWallet), amounts[2]);
        assertEq(token.balanceOf(accounts[2]), 0);
        assertTrue(distributor.isClaimed(2));
    }

    function test_RevertWhen_ClaimToSignedByWrongKey() public {
        address coldWallet = makeAddr("coldWallet");
        bytes32 digest = distributor.claimToDigest(2, accounts[2], amounts[2], coldWallet);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY_BASE + 3, digest); // not account 2

        vm.expectRevert(MerkleDistributor.InvalidSignature.selector);
        distributor.claimTo(
            2, accounts[2], amounts[2], coldWallet, proofFor(2), abi.encodePacked(r, s, v)
        );
    }

    function test_RevertWhen_ClaimToRecipientTampered() public {
        address coldWallet = makeAddr("coldWallet");
        address attacker = makeAddr("attacker");
        bytes32 digest = distributor.claimToDigest(2, accounts[2], amounts[2], coldWallet);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY_BASE + 2, digest);

        // Signature authorizes coldWallet; attacker swaps the recipient.
        vm.expectRevert(MerkleDistributor.InvalidSignature.selector);
        distributor.claimTo(
            2, accounts[2], amounts[2], attacker, proofFor(2), abi.encodePacked(r, s, v)
        );
    }

    function test_RevertWhen_ClaimToReplayed() public {
        address coldWallet = makeAddr("coldWallet");
        bytes32 digest = distributor.claimToDigest(2, accounts[2], amounts[2], coldWallet);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY_BASE + 2, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        distributor.claimTo(2, accounts[2], amounts[2], coldWallet, proofFor(2), sig);

        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.AlreadyClaimed.selector, 2));
        distributor.claimTo(2, accounts[2], amounts[2], coldWallet, proofFor(2), sig);
    }

    // ─── Deadline + clawback ────────────────────────────────────────────────

    function test_RevertWhen_ClaimAfterDeadline() public {
        vm.warp(block.timestamp + CLAIM_WINDOW + 1);
        vm.expectRevert(MerkleDistributor.ClaimWindowClosed.selector);
        distributor.claim(0, accounts[0], amounts[0], proofFor(0));
    }

    function test_RevertWhen_ClawbackBeforeDeadline() public {
        vm.expectRevert(MerkleDistributor.ClaimWindowStillOpen.selector);
        vm.prank(owner);
        distributor.clawback(owner);
    }

    function test_ClawbackReturnsUnclaimedAfterDeadline() public {
        distributor.claim(0, accounts[0], amounts[0], proofFor(0));
        vm.warp(block.timestamp + CLAIM_WINDOW + 1);

        vm.prank(owner);
        distributor.clawback(owner);

        assertEq(token.balanceOf(owner), totalAmount - amounts[0]);
        assertEq(token.balanceOf(address(distributor)), 0);
    }

    function test_RevertWhen_ClawbackByStranger() public {
        vm.warp(block.timestamp + CLAIM_WINDOW + 1);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, relayer)
        );
        vm.prank(relayer);
        distributor.clawback(relayer);
    }
}

/// @notice Larger-tree coverage: a 100-leaf tree where a fuzzed subset claims.
contract MerkleDistributorLargeTreeTest is Test {
    uint256 internal constant LEAF_COUNT = 100;

    AirdropToken internal token;
    MerkleDistributor internal distributor;
    bytes32[] internal leaves;
    address[] internal accounts;
    uint256[] internal amounts;

    function setUp() public {
        uint256 total;
        for (uint256 i = 0; i < LEAF_COUNT; i++) {
            accounts.push(address(uint160(uint256(keccak256(abi.encode("holder", i))))));
            amounts.push((i + 1) * 1 ether);
            total += (i + 1) * 1 ether;
            leaves.push(MerkleTreeLib.leaf(i, accounts[i], amounts[i]));
        }
        token = new AirdropToken(total);
        distributor = new MerkleDistributor(
            token, MerkleTreeLib.buildRoot(leaves), block.timestamp + 30 days, address(this)
        );
        require(token.transfer(address(distributor), total), "funding failed");
    }

    function testFuzz_RandomSubsetClaims(uint256 seed) public {
        bytes32[] memory memLeaves = new bytes32[](LEAF_COUNT);
        for (uint256 i = 0; i < LEAF_COUNT; i++) {
            memLeaves[i] = leaves[i];
        }

        for (uint256 i = 0; i < LEAF_COUNT; i++) {
            if (uint256(keccak256(abi.encode(seed, i))) % 2 == 0) continue;
            distributor.claim(i, accounts[i], amounts[i], MerkleTreeLib.buildProof(memLeaves, i));
            assertEq(token.balanceOf(accounts[i]), amounts[i]);
            assertTrue(distributor.isClaimed(i));
        }
    }
}

// ─── Gas: bitmap vs naive mapping bookkeeping ───────────────────────────────

contract BitmapBookkeeping {
    mapping(uint256 => uint256) private words;

    function set(uint256 index) external {
        // forge-lint: disable-next-line(incorrect-shift)
        words[index / 256] |= 1 << (index % 256); // intentional bit-mask shift
    }
}

contract NaiveBookkeeping {
    mapping(uint256 => bool) private claimed;

    function set(uint256 index) external {
        claimed[index] = true;
    }
}

/// @notice Locks in WHY the distributor uses a bitmap. Run with -vv for numbers.
contract ClaimBookkeepingGasTest is Test {
    function test_GasComparison_BitmapVsMapping() public {
        BitmapBookkeeping bitmap = new BitmapBookkeeping();
        NaiveBookkeeping naive = new NaiveBookkeeping();
        uint256 n = 256; // one full bitmap word's worth of claims

        uint256 before = gasleft();
        for (uint256 i = 0; i < n; i++) {
            bitmap.set(i);
        }
        uint256 bitmapGas = before - gasleft();

        before = gasleft();
        for (uint256 i = 0; i < n; i++) {
            naive.set(i);
        }
        uint256 naiveGas = before - gasleft();

        emit log_named_uint("bitmap bookkeeping gas (256 claims)", bitmapGas);
        emit log_named_uint("mapping bookkeeping gas (256 claims)", naiveGas);
        emit log_named_uint("saved per claim", (naiveGas - bitmapGas) / n);

        assertLt(bitmapGas, naiveGas);
    }
}
