// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Pair} from "./Pair.sol";

/// @title PairFactory
/// @notice Deploys exactly one canonical `Pair` per unordered token pair, at
///         an address anyone can compute in advance.
///
/// @dev Two properties do the work here:
///
///      Sorting. `(A, B)` and `(B, A)` are the same market, so tokens are
///      sorted before hashing. Without that the factory would happily deploy
///      two pools for one pair and split its liquidity.
///
///      CREATE2. The salt is the sorted pair, so the address is a pure
///      function of `(factory, tokenA, tokenB)` and the pair's init code.
///      That is why `Pair` takes no constructor arguments: constructor args
///      are appended to init code, which would make the hash depend on the
///      tokens and force callers to reconstruct the bytecode to compute an
///      address. Instead the factory deploys and then calls `initialize`.
///      Integrators can hard-code a pool address before it exists.
contract PairFactory {
    /// @notice pair lookup, symmetric: both orderings map to the same pair.
    mapping(address tokenA => mapping(address tokenB => address pair)) public getPair;

    /// @notice Every pair ever deployed, in creation order.
    address[] public allPairs;

    error IdenticalTokens();
    error ZeroAddressToken();
    error PairExists(address pair);

    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 pairCount);

    /// @notice Deploys the pair for `tokenA`/`tokenB`.
    /// @return pair The newly deployed pool.
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        if (tokenA == tokenB) revert IdenticalTokens();
        (address token0, address token1) = _sort(tokenA, tokenB);
        if (token0 == address(0)) revert ZeroAddressToken();

        address existing = getPair[token0][token1];
        if (existing != address(0)) revert PairExists(existing);

        pair = address(new Pair{salt: _salt(token0, token1)}());
        Pair(pair).initialize(token0, token1);

        // Both directions, so callers never have to sort.
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);

        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    /// @notice The address `createPair` will produce, computable before the
    ///         pair exists.
    function computePairAddress(address tokenA, address tokenB) public view returns (address) {
        if (tokenA == tokenB) revert IdenticalTokens();
        (address token0, address token1) = _sort(tokenA, tokenB);
        if (token0 == address(0)) revert ZeroAddressToken();

        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), _salt(token0, token1), keccak256(type(Pair).creationCode))
        );
        return address(uint160(uint256(hash)));
    }

    /// @notice Number of pairs deployed by this factory.
    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function _sort(address tokenA, address tokenB) internal pure returns (address, address) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function _salt(address token0, address token1) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(token0, token1));
    }
}
