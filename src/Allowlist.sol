// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IAllowlist} from "./interfaces/IAllowlist.sol";

/// @title Allowlist
/// @notice Minimal address allowlist / transfer-restriction registry. An owner and a set of
///         agents maintain the set of allowed addresses; a permissioned token queries
///         `isAllowed(address)` before permitting transfers. This is the reference contract the
///         Tessera `EvmAllowlistGateway` drives by default (add/remove-pair style), and the
///         function names match the gateway's defaults — no configuration needed.
///
/// @dev    Ported from Tessera `chains/evm/contracts/Allowlist.sol` with minimal changes:
///         the pragma is pinned and the contract now explicitly implements {IAllowlist}.
///         Holds NO identity data — only a set of addresses. Identity verification and the
///         decision to allow/revoke happen off-chain in ATRIA/Tessera; this contract reflects it.
contract Allowlist is IAllowlist {
    address public owner;
    mapping(address => bool) public agents; // addresses permitted to modify the list
    mapping(address => bool) private _allowed;

    event Allowed(address indexed account);
    event Disallowed(address indexed account);
    event AgentSet(address indexed agent, bool enabled);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotAuthorized();
    error ZeroAddress();

    modifier onlyAgent() {
        if (msg.sender != owner && !agents[msg.sender]) revert NotAuthorized();
        _;
    }

    constructor() {
        owner = msg.sender;
        agents[msg.sender] = true;
        emit OwnershipTransferred(address(0), msg.sender);
        emit AgentSet(msg.sender, true);
    }

    /// @notice Allow an address. Agent-gated. Idempotent.
    function addToAllowlist(address account) external onlyAgent {
        if (account == address(0)) revert ZeroAddress();
        _allowed[account] = true;
        emit Allowed(account);
    }

    /// @notice Disallow an address. Agent-gated. Idempotent.
    function removeFromAllowlist(address account) external onlyAgent {
        _allowed[account] = false;
        emit Disallowed(account);
    }

    /// @notice True if the address is currently allowed.
    function isAllowed(address account) external view returns (bool) {
        return _allowed[account];
    }

    /// @notice Grant/revoke an agent (e.g. the backend gateway's signing account). Owner-only.
    function setAgent(address agent, bool enabled) external {
        if (msg.sender != owner) revert NotAuthorized();
        agents[agent] = enabled;
        emit AgentSet(agent, enabled);
    }

    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotAuthorized();
        if (newOwner == address(0)) revert ZeroAddress();
        address previous = owner;
        emit OwnershipTransferred(previous, newOwner);
        // Revoke the outgoing owner's agent rights so a handover doesn't silently retain them.
        if (agents[previous]) {
            agents[previous] = false;
            emit AgentSet(previous, false);
        }
        owner = newOwner;
        agents[newOwner] = true;
        emit AgentSet(newOwner, true);
    }
}
