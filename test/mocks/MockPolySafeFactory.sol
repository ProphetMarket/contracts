// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PolySafeLib} from "exchange/libraries/PolySafeLib.sol";

/// @title MockPolySafeFactory
/// @notice Minimal mock that satisfies the IPolySafeFactory interface used by the CTF Exchange.
///         Returns a fixed masterCopy address for PolySafeLib address derivation.
///         proxyCreationCode() is derived from PolySafeLib.getContractBytecode() so the
///         deploy script's H-03 assertion works without duplicating the hex constant.
contract MockPolySafeFactory {
    address public masterCopy;

    constructor(address _masterCopy) {
        masterCopy = _masterCopy;
    }

    /// @dev Returns the proxy creation code by stripping the appended singleton address
    ///      from PolySafeLib.getContractBytecode(). This keeps the mock in sync with
    ///      PolySafeLib automatically — no hardcoded bytecode to maintain.
    function proxyCreationCode() public view returns (bytes memory) {
        bytes memory full = PolySafeLib.getContractBytecode(masterCopy);
        // getContractBytecode = abi.encodePacked(proxyCreationCode, abi.encode(masterCopy))
        // abi.encode(address) is always 32 bytes, so strip the last 32 bytes.
        uint256 creationLen = full.length - 32;
        bytes memory code = new bytes(creationLen);
        for (uint256 i = 0; i < creationLen; i++) {
            code[i] = full[i];
        }
        return code;
    }
}
