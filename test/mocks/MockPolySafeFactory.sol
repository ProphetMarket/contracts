// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockPolySafeFactory
/// @notice Minimal mock that satisfies the IPolySafeFactory interface used by the CTF Exchange.
///         Returns a fixed masterCopy address for PolySafeLib address derivation.
contract MockPolySafeFactory {
    address public masterCopy;

    constructor(address _masterCopy) {
        masterCopy = _masterCopy;
    }
}
