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

    /// @notice Address nominated to take over as {owner}; takes effect only on {acceptOwnership}.
    address public pendingOwner;

    mapping(address => bool) public agents; // addresses permitted to modify the list
    mapping(address => bool) private _allowed;

    event Allowed(address indexed account);
    event Disallowed(address indexed account);
    event AgentSet(address indexed agent, bool enabled);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed currentOwner, address indexed pendingOwner);

    error NotAuthorized();
    error ZeroAddress();

    modifier onlyAgent() {
        if (msg.sender != owner && !agents[msg.sender]) revert NotAuthorized();
        _;
    }

    /// @notice Deploys the list already owned by `owner_`, with `agent_` able to maintain it.
    /// @dev Ownership is a constructor argument rather than `msg.sender` so the deploying key never
    ///      owns the list, not even for the rest of the transaction. The alternative — deploy to
    ///      self, then hand over — cannot work now that handover is two-step: the admin multisig
    ///      would have to countersign, leaving the deployer as owner in the meantime and making
    ///      "the deployer keeps nothing" false for however long that takes.
    /// @param owner_ address that owns the list (the admin multisig).
    /// @param agent_ address permitted to maintain it (the backend gateway's service key). Pass the
    ///        zero address to grant none.
    constructor(address owner_, address agent_) {
        if (owner_ == address(0)) revert ZeroAddress();

        owner = owner_;
        agents[owner_] = true;
        emit OwnershipTransferred(address(0), owner_);
        emit AgentSet(owner_, true);

        if (agent_ != address(0)) {
            agents[agent_] = true;
            emit AgentSet(agent_, true);
        }
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

    /// @notice Step 1 of 2: nominate a new owner. Nothing changes until they accept.
    /// @dev Two steps because ownership of this list is effectively control of every transfer the
    ///      token permits. Handing it to an address in one call means a typo, or an address whose key
    ///      exists on some other chain, permanently strands the list: no further agents, no further
    ///      handovers. Making the recipient act proves the address is real and controlled first.
    ///      Pass the zero address to cancel a pending handover.
    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotAuthorized();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Step 2 of 2: the nominated address takes ownership.
    /// @dev The outgoing owner's agent rights are dropped here, so a handover cannot silently leave
    ///      the previous holder able to keep editing the list.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner || msg.sender == address(0)) revert NotAuthorized();

        address previous = owner;
        emit OwnershipTransferred(previous, msg.sender);

        if (agents[previous]) {
            agents[previous] = false;
            emit AgentSet(previous, false);
        }

        owner = msg.sender;
        pendingOwner = address(0);
        agents[msg.sender] = true;
        emit AgentSet(msg.sender, true);
    }
}
