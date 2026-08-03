// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IAllowlist
/// @notice Minimal transfer-restriction interface the token queries before moving shares.
///         Deliberately identical to the Tessera reference `Allowlist` surface so any
///         restriction contract exposing `isAllowed` (ERC-3643/T-REX module included) fits.
interface IAllowlist {
    function isAllowed(address account) external view returns (bool);
}
