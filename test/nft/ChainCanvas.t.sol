// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ChainCanvas} from "../../src/nft/ChainCanvas.sol";
import {SVGRenderer} from "../../src/nft/SVGRenderer.sol";

contract ChainCanvasTest is Test {
    using stdJson for string;

    ChainCanvas internal canvas;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant PRICE = 0.001 ether;

    function setUp() public {
        canvas = new ChainCanvas();
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        // Give the derived seeds some prevrandao entropy to mix in.
        vm.prevrandao(bytes32(uint256(0xC0FFEE)));
    }

    function _mintAs(address minter) internal returns (uint256 id) {
        vm.prank(minter);
        id = canvas.mint{value: PRICE}();
    }

    // ------------------------------------------------------------------ mint

    function test_MintStoresSeedAndCollectsPrice() public {
        uint256 id = _mintAs(alice);

        assertEq(id, 1);
        assertEq(canvas.ownerOf(id), alice);
        assertGt(canvas.seedOf(id), 0);
        assertEq(canvas.ageOf(id), 0);
        assertEq(address(canvas).balance, PRICE);
    }

    function test_MintRevertsOnWrongPrice() public {
        vm.expectRevert(abi.encodeWithSelector(ChainCanvas.WrongMintPrice.selector, PRICE - 1, PRICE));
        vm.prank(alice);
        canvas.mint{value: PRICE - 1}();

        vm.expectRevert(abi.encodeWithSelector(ChainCanvas.WrongMintPrice.selector, PRICE + 1, PRICE));
        vm.prank(alice);
        canvas.mint{value: PRICE + 1}();
    }

    function test_WithdrawSendsFeesToOwner() public {
        _mintAs(alice);
        _mintAs(bob);

        uint256 before = address(this).balance;
        canvas.withdraw();
        assertEq(address(this).balance - before, 2 * PRICE);
        assertEq(address(canvas).balance, 0);
    }

    function test_WithdrawRevertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        canvas.withdraw();
    }

    /// @dev Only the seed and mint block are stored, so mint gas must be
    ///      near-constant no matter what the art looks like.
    function test_MintGasNearConstant() public {
        vm.prank(alice);
        uint256 before1 = gasleft();
        canvas.mint{value: PRICE}();
        uint256 gas1 = before1 - gasleft();

        vm.prank(bob);
        uint256 before2 = gasleft();
        canvas.mint{value: PRICE}();
        uint256 gas2 = before2 - gasleft();

        uint256 delta = gas1 > gas2 ? gas1 - gas2 : gas2 - gas1;
        assertLt(delta, 10_000, "mint gas should not depend on the seed");
    }

    // ------------------------------------------------------------- token URI

    function test_TokenURIIsWellFormedDataURI() public {
        uint256 id = _mintAs(alice);

        string memory uri = canvas.tokenURI(id);
        assertTrue(_startsWith(uri, "data:application/json;base64,"), "wrong URI prefix");

        // The pre-encoding JSON must parse and carry the right fields; the
        // base64 body is just an encoding of exactly this string.
        string memory json = canvas.tokenJSON(id);
        assertEq(json.readString(".name"), "Chain Canvas #1");
        assertTrue(_startsWith(json.readString(".image"), "data:image/svg+xml;base64,"), "wrong image prefix");
        assertEq(json.readString(".attributes[0].trait_type"), "Palette");
        assertEq(json.readString(".attributes[4].trait_type"), "Age (blocks)");
        assertEq(json.readUint(".attributes[4].value"), 0); // age at mint block
    }

    function test_TokenURINonexistentReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 99));
        canvas.tokenURI(99);
    }

    function test_RenderingIsDeterministic() public {
        uint256 id = _mintAs(alice);

        assertEq(canvas.tokenURI(id), canvas.tokenURI(id));

        uint256 seed = canvas.seedOf(id);
        assertEq(SVGRenderer.render(seed, 7), SVGRenderer.render(seed, 7));
    }

    function test_ArtChangesWithAgeButTraitsDoNot() public {
        uint256 id = _mintAs(alice);
        string memory jsonAtMint = canvas.tokenJSON(id);
        SVGRenderer.Traits memory traitsAtMint = canvas.traitsOf(id);

        vm.roll(block.number + 100);

        string memory jsonLater = canvas.tokenJSON(id);
        assertEq(jsonLater.readUint(".attributes[4].value"), 100);
        assertTrue(keccak256(bytes(jsonAtMint)) != keccak256(bytes(jsonLater)), "art should age");

        SVGRenderer.Traits memory traitsLater = canvas.traitsOf(id);
        assertEq(traitsAtMint.palette, traitsLater.palette);
        assertEq(traitsAtMint.shape, traitsLater.shape);
        assertEq(traitsAtMint.stroke, traitsLater.stroke);
        assertEq(traitsAtMint.aurora, traitsLater.aurora);
    }

    // ---------------------------------------------------------------- seeds

    function testFuzz_MintBatchHasNoSeedCollisions(address minter) public {
        vm.assume(minter.code.length == 0 && minter != address(0));
        vm.deal(minter, 1 ether);

        uint256[] memory seeds = new uint256[](20);
        for (uint256 i = 0; i < 20; i++) {
            vm.prank(minter);
            uint256 id = canvas.mint{value: PRICE}();
            seeds[i] = canvas.seedOf(id);
        }

        for (uint256 i = 0; i < 20; i++) {
            for (uint256 j = i + 1; j < 20; j++) {
                assertTrue(seeds[i] != seeds[j], "seed collision");
            }
        }
    }

    function test_DifferentMintersGetDifferentSeeds() public {
        uint256 idA = _mintAs(alice);
        uint256 idB = _mintAs(bob);
        assertTrue(canvas.seedOf(idA) != canvas.seedOf(idB));
    }

    // ------------------------------------------------------------- renderer

    /// @dev The renderer promises single-quoted attributes only: a double
    ///      quote anywhere in the SVG could break the JSON envelope if a
    ///      consumer inlines the image un-encoded.
    function testFuzz_SvgContainsNoDoubleQuotes(uint256 seed, uint256 age) public pure {
        age = _bound(age, 0, 10_000_000);
        bytes memory svg = bytes(SVGRenderer.render(seed, age));
        for (uint256 i = 0; i < svg.length; i++) {
            assertTrue(svg[i] != '"', "double quote in SVG");
        }
    }

    function testFuzz_RenderedSvgIsWellFormed(uint256 seed) public pure {
        string memory svg = SVGRenderer.render(seed, 42);
        assertTrue(_startsWith(svg, "<svg xmlns="), "missing svg open tag");
        assertTrue(_endsWith(svg, "</svg>"), "missing svg close tag");
    }

    /// @dev Every uint256 must map to a valid trait combination.
    function testFuzz_TraitsAlwaysInRange(uint256 seed) public pure {
        SVGRenderer.Traits memory t = SVGRenderer.traitsFromSeed(seed);
        assertLt(t.palette, 5);
        assertLt(t.shape, 3);
        assertLt(t.stroke, 3);
    }

    /// @dev Over 2000 uniformly random seeds the ~2% aurora trait should
    ///      appear roughly 40 times; use loose bounds (0.5%..4.5%) so the
    ///      test never flakes while still catching a mis-set weight.
    function test_AuroraDistributionRoughlyTwoPercent() public pure {
        uint256 hits;
        for (uint256 i = 0; i < 2000; i++) {
            uint256 seed = uint256(keccak256(abi.encodePacked("aurora", i)));
            if (SVGRenderer.traitsFromSeed(seed).aurora) hits++;
        }
        assertGt(hits, 10, "aurora far too rare");
        assertLt(hits, 90, "aurora far too common");
    }

    // ---------------------------------------------------------------- utils

    function _startsWith(string memory str, string memory prefix) internal pure returns (bool) {
        bytes memory s = bytes(str);
        bytes memory p = bytes(prefix);
        if (s.length < p.length) return false;
        for (uint256 i = 0; i < p.length; i++) {
            if (s[i] != p[i]) return false;
        }
        return true;
    }

    function _endsWith(string memory str, string memory suffix) internal pure returns (bool) {
        bytes memory s = bytes(str);
        bytes memory p = bytes(suffix);
        if (s.length < p.length) return false;
        for (uint256 i = 0; i < p.length; i++) {
            if (s[s.length - p.length + i] != p[i]) return false;
        }
        return true;
    }

    /// @dev Receive the withdraw() payout in test_WithdrawSendsFeesToOwner.
    receive() external payable {}
}
