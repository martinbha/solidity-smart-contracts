// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title SVGRenderer
/// @notice Pure seed -> traits -> SVG pipeline for ChainCanvas. Nothing here
///         touches storage: the token contract stores only a 32-byte seed and
///         this library deterministically re-derives the traits and redraws
///         the art on every call, so rendering costs gas only when a caller
///         pays for it (off-chain `eth_call` renders are free).
///
/// @dev All SVG attributes use single quotes so the markup can never collide
///      with the double-quoted JSON envelope the token contract wraps it in,
///      even if a consumer embeds the SVG un-encoded.
///
///      Trait weights (documented here, enforced in traitsFromSeed):
///        palette  seed byte 0  % 5      -> uniform 20% each
///        shape    seed byte 1  % 3      -> uniform ~33% each
///        stroke   seed byte 2  % 3      -> uniform ~33% each
///        aurora   seed bytes 3+ % 10000 -> 200 bps (~2% rare glow ring)
library SVGRenderer {
    using Strings for uint256;

    struct Traits {
        uint8 palette; // 0..4, index into the palette table
        uint8 shape; // 0 Orbits, 1 Shards, 2 Tides
        uint8 stroke; // 0 None, 1 Fine, 2 Dashed
        bool aurora; // rare glow ring, ~2%
    }

    uint256 internal constant AURORA_BPS = 200;

    /// @notice Derive the full trait set from a seed. Pure and total: every
    ///         uint256 maps to a valid trait combination.
    function traitsFromSeed(uint256 seed) internal pure returns (Traits memory t) {
        // Casts cannot truncate: each value is reduced mod 5 or 3 first.
        // forge-lint: disable-start(unsafe-typecast)
        t.palette = uint8(seed % 5);
        t.shape = uint8((seed >> 8) % 3);
        t.stroke = uint8((seed >> 16) % 3);
        // forge-lint: disable-end(unsafe-typecast)
        t.aurora = (seed >> 24) % 10_000 < AURORA_BPS;
    }

    /// @notice Render the full SVG for a seed. `ageBlocks` is how many blocks
    ///         the token has existed; it drives the growing age ring, so the
    ///         same piece slowly changes as the chain advances.
    function render(uint256 seed, uint256 ageBlocks) internal pure returns (string memory) {
        Traits memory t = traitsFromSeed(seed);
        (string memory bg, string memory accentA, string memory accentB) = palette(t.palette);
        string memory strokeAttr = _strokeAttr(t.stroke, accentB);

        string memory shapes;
        if (t.shape == 0) shapes = _orbits(seed, accentA, accentB, strokeAttr);
        else if (t.shape == 1) shapes = _shards(seed, accentA, accentB, strokeAttr);
        else shapes = _tides(seed, accentA, accentB, strokeAttr);

        return string(
            abi.encodePacked(
                "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 350 350'>",
                "<rect width='350' height='350' fill='",
                bg,
                "'/>",
                shapes,
                t.aurora ? _auroraRing(accentB) : "",
                _ageRing(ageBlocks, accentA),
                "</svg>"
            )
        );
    }

    /// @notice Background and two accent colors for a palette index.
    function palette(uint8 id) internal pure returns (string memory bg, string memory a, string memory b) {
        if (id == 0) return ("#0b1026", "#5b8cff", "#b388ff"); // Midnight
        if (id == 1) return ("#2b1b3d", "#ff8e6e", "#ffd166"); // Dawn
        if (id == 2) return ("#10261b", "#58d68d", "#d4efdf"); // Meadow
        if (id == 3) return ("#1f0f0a", "#ff6b35", "#ffd23f"); // Ember
        return ("#0e1c26", "#7fdbff", "#e0f7fa"); // Glacier
    }

    function paletteName(uint8 id) internal pure returns (string memory) {
        if (id == 0) return "Midnight";
        if (id == 1) return "Dawn";
        if (id == 2) return "Meadow";
        if (id == 3) return "Ember";
        return "Glacier";
    }

    function shapeName(uint8 id) internal pure returns (string memory) {
        if (id == 0) return "Orbits";
        if (id == 1) return "Shards";
        return "Tides";
    }

    function strokeName(uint8 id) internal pure returns (string memory) {
        if (id == 0) return "None";
        if (id == 1) return "Fine";
        return "Dashed";
    }

    /// @dev Three translucent circles whose centers and radii come straight
    ///      from seed bytes, alternating the two accent colors.
    function _orbits(uint256 seed, string memory accentA, string memory accentB, string memory strokeAttr)
        private
        pure
        returns (string memory out)
    {
        for (uint256 i = 0; i < 3; i++) {
            uint256 cx = 60 + _scale(_byteAt(seed, 4 + 3 * i), 230);
            uint256 cy = 60 + _scale(_byteAt(seed, 5 + 3 * i), 230);
            uint256 r = 28 + _scale(_byteAt(seed, 6 + 3 * i), 80);
            out = string(
                abi.encodePacked(
                    out,
                    "<circle cx='",
                    cx.toString(),
                    "' cy='",
                    cy.toString(),
                    "' r='",
                    r.toString(),
                    "' fill='",
                    i % 2 == 0 ? accentA : accentB,
                    "' fill-opacity='0.55'",
                    strokeAttr,
                    "/>"
                )
            );
        }
    }

    /// @dev Three translucent triangles; all nine vertices come from seed
    ///      bytes scaled onto the canvas.
    function _shards(uint256 seed, string memory accentA, string memory accentB, string memory strokeAttr)
        private
        pure
        returns (string memory out)
    {
        for (uint256 i = 0; i < 3; i++) {
            string memory points;
            for (uint256 p = 0; p < 3; p++) {
                uint256 x = _scale(_byteAt(seed, 4 + 6 * i + 2 * p), 350);
                uint256 y = _scale(_byteAt(seed, 5 + 6 * i + 2 * p), 350);
                points = string(abi.encodePacked(points, p == 0 ? "" : " ", x.toString(), ",", y.toString()));
            }
            out = string(
                abi.encodePacked(
                    out,
                    "<polygon points='",
                    points,
                    "' fill='",
                    i % 2 == 0 ? accentA : accentB,
                    "' fill-opacity='0.5'",
                    strokeAttr,
                    "/>"
                )
            );
        }
    }

    /// @dev Three filled wave bands: a cubic curve across the canvas closed
    ///      down to the bottom edge, stacked with translucency.
    function _tides(uint256 seed, string memory accentA, string memory accentB, string memory strokeAttr)
        private
        pure
        returns (string memory out)
    {
        for (uint256 i = 0; i < 3; i++) {
            uint256 y = 40 + _scale(_byteAt(seed, 4 + 2 * i), 240);
            uint256 lift = _byteAt(seed, 5 + 2 * i) % 30;
            out = string(
                abi.encodePacked(
                    out,
                    "<path d='M0 ",
                    y.toString(),
                    " C 87 ",
                    (y - lift).toString(),
                    ", 262 ",
                    (y + lift).toString(),
                    ", 350 ",
                    y.toString(),
                    " L350 350 L0 350 Z' fill='",
                    i % 2 == 0 ? accentA : accentB,
                    "' fill-opacity='0.45'",
                    strokeAttr,
                    "/>"
                )
            );
        }
    }

    /// @dev The ~2% rare trait: a bright full-canvas glow ring.
    function _auroraRing(string memory color) private pure returns (string memory) {
        return string(
            abi.encodePacked(
                "<circle cx='175' cy='175' r='165' fill='none' stroke='",
                color,
                "' stroke-width='5' stroke-opacity='0.85'/>"
            )
        );
    }

    /// @dev The chain-state-responsive element: a ring that grows one pixel
    ///      of radius per two blocks of token age, saturating at r=160 after
    ///      280 blocks. Rendering is a view, so the piece visibly ages
    ///      without anyone paying gas.
    function _ageRing(uint256 ageBlocks, string memory color) private pure returns (string memory) {
        uint256 r = 20 + (ageBlocks >= 280 ? 140 : ageBlocks / 2);
        return string(
            abi.encodePacked(
                "<circle cx='175' cy='175' r='",
                r.toString(),
                "' fill='none' stroke='",
                color,
                "' stroke-width='2' stroke-opacity='0.6'/>"
            )
        );
    }

    function _strokeAttr(uint8 style, string memory color) private pure returns (string memory) {
        if (style == 0) return " stroke='none'";
        if (style == 1) return string(abi.encodePacked(" stroke='", color, "' stroke-width='3'"));
        return string(abi.encodePacked(" stroke='", color, "' stroke-width='3' stroke-dasharray='6 4'"));
    }

    function _byteAt(uint256 seed, uint256 i) private pure returns (uint256) {
        return (seed >> ((i % 32) * 8)) & 0xff;
    }

    /// @dev Map a byte (0..255) onto 0..max-1 without modulo clustering.
    function _scale(uint256 value, uint256 max) private pure returns (uint256) {
        return (value * max) / 256;
    }
}
