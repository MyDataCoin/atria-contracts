// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAllowlist} from "./interfaces/IAllowlist.sol";

/// @title AtriaPropertyToken
/// @notice RWA token representing indivisible shares in a single real-estate object (one issue,
///         one contract, one network). Derived from the Tessera reference `PermissionedToken`
///         and extended with the powers the draft Decree requires of an RWA token: suspending
///         operations, freezing an individual address, burning (partial and forced) and forced
///         transfer, plus intake of verified collateral data.
///
///         Deliberate differences from the reference token:
///           - `decimals = 2` — a share is divisible into hundredths, so an issue can be sized to
///             something real (57.55 shares for a 57.55 m² apartment) and an investor can hold a
///             part of one. Balances are integer minor units: 57.55 shares is 5755 units;
///           - a hard `maxSupply` cap matching the registered issue size, decreasable only when
///             part of the issue is annulled;
///           - role separation instead of a single `owner` — see below;
///           - pause / freeze / burn / forced transfer / collateral oracle.
///
///         Kept from the reference: the allowlist is checked on both sides of every transfer and
///         on every mint.
///
/// @dev Roles are separated on purpose. Compromising one key must not be enough to both create
///      shares and take them away from holders:
///        DEFAULT_ADMIN_ROLE — multisig. Manages roles, repoints the allowlist, reduces the cap.
///        MINTER_ROLE       — custody / issuance key. Mints shares to investors.
///        COMPLIANCE_ROLE   — compliance key. Freezes, burns, executes forced transfers.
///        PAUSER_ROLE       — suspends and resumes operations.
///        ORACLE_ROLE       — reports verified collateral data.
///
///      Compliance actions (freeze/burn/forced transfer) intentionally keep working while the
///      token is paused and against frozen accounts: a regulator's order arrives precisely in
///      those states. They are gated by role and always emit a reason code.
contract AtriaPropertyToken is ERC20, AccessControl, Pausable {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    /// @notice Upper bound on {CollateralReport.uri}, so one report cannot cost an unbounded amount
    ///         of gas to write or to read back.
    uint256 public constant MAX_COLLATERAL_URI_LENGTH = 512;

    /// @notice Verified collateral data reported by the oracle (draft Decree, §16).
    struct CollateralReport {
        bytes32 dataHash; // hash of the underlying collateral document package
        uint256 valuation; // appraised value, in minor units of {collateralCurrency}
        uint64 valuedAt; // appraisal date (unix seconds)
        uint64 reportedAt; // when the report landed on-chain
        string uri; // pointer to the off-chain report
    }

    /// @notice `Property.Id` from the backend, so the issue is identifiable on-chain. Immutable:
    ///         which issue a contract represents is decided at deployment and never afterwards.
    bytes32 public immutable propertyId;

    /// @notice ISO code of the currency {CollateralReport.valuation} is denominated in.
    string public collateralCurrency;

    /// @notice Hard cap on total supply — the registered issue size, in minor units (hundredths of a
    ///         share), the same unit as {totalSupply} and every balance. 1 000 000 shares is
    ///         100 000 000 here. The deployment script converts from shares.
    uint256 public maxSupply;

    /// @notice Transfer-restriction registry consulted on every mint and transfer.
    IAllowlist public allowlist;

    /// @notice Addresses blocked by compliance. A frozen address can neither send nor receive.
    mapping(address => bool) public frozen;

    /// @notice Latest verified collateral data.
    CollateralReport public collateral;

    /// @dev Set only for the duration of a compliance action, letting it bypass the pause and
    ///      freeze checks in {_update}. Never exposed; no external call happens while it is set.
    bool private _complianceOverride;

    event AllowlistChanged(address indexed allowlist);
    event AddressFrozen(address indexed account, bytes32 reason);
    event AddressUnfrozen(address indexed account, bytes32 reason);
    event ComplianceBurn(address indexed from, uint256 amount, bytes32 reason);
    event ForcedTransfer(address indexed from, address indexed to, uint256 amount, bytes32 reason);
    event MaxSupplyReduced(uint256 previousMaxSupply, uint256 newMaxSupply, bytes32 reason);
    event CollateralReported(bytes32 indexed dataHash, uint256 valuation, uint64 valuedAt, string uri);

    error NotAllowed(address account);
    error AccountFrozen(address account);
    error SupplyCapExceeded(uint256 requested, uint256 available);
    error InvalidMaxSupply();
    error InvalidPropertyId();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidCollateralReport();

    /// @param name_               token name
    /// @param symbol_             token symbol
    /// @param allowlist_          transfer-restriction registry
    /// @param maxSupply_          registered issue size, in minor units (see {maxSupply})
    /// @param propertyId_         backend `Property.Id`
    /// @param collateralCurrency_ ISO code the collateral valuation is denominated in
    /// @param admin               DEFAULT_ADMIN_ROLE holder — a multisig, not the deployer EOA.
    ///                            Operational roles are granted by the admin afterwards, so no
    ///                            single key ever holds mint and compliance rights at once.
    constructor(
        string memory name_,
        string memory symbol_,
        address allowlist_,
        uint256 maxSupply_,
        bytes32 propertyId_,
        string memory collateralCurrency_,
        address admin
    ) ERC20(name_, symbol_) {
        if (allowlist_ == address(0) || admin == address(0)) revert ZeroAddress();
        if (maxSupply_ == 0) revert InvalidMaxSupply();
        // A token that does not name its issue is an anonymous ERC-20 the backend can only claim
        // belongs to a property. The value is immutable, so a deployment that leaves it empty cannot
        // be repaired — it can only be replaced, and by then the address may already be published.
        if (propertyId_ == bytes32(0)) revert InvalidPropertyId();

        allowlist = IAllowlist(allowlist_);
        maxSupply = maxSupply_;
        propertyId = propertyId_;
        collateralCurrency = collateralCurrency_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        emit AllowlistChanged(allowlist_);
    }

    /// @notice A share is divisible into hundredths: the smallest tradable unit is 0.01 of a share.
    ///         This is deliberately NOT the ERC-20 default of 18 — the backend registry stores
    ///         holdings as decimals with the same scale (`TokenAmount.Scale`), and the two must
    ///         agree exactly or the register and the chain describe different holdings.
    function decimals() public pure override returns (uint8) {
        return 2;
    }

    /// @notice Shares still issuable under the registered issue size.
    function remainingSupply() external view returns (uint256) {
        return maxSupply - totalSupply();
    }

    // ── Issuance ─────────────────────────────────────────────────────────────

    /// @notice Issue shares to an investor's address after their application is confirmed.
    /// @dev Reverts unless `to` is allowlisted — the address must be whitelisted first, which is
    ///      why the backend always runs AllowlistAdd before TokenAllocation.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (amount == 0) revert ZeroAmount();
        uint256 available = maxSupply - totalSupply();
        if (amount > available) revert SupplyCapExceeded(amount, available);
        _mint(to, amount);
    }

    // ── Suspension ───────────────────────────────────────────────────────────

    /// @notice Suspend all ordinary operations (draft Decree, ch. 8). Compliance actions continue.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resume operations.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ── Compliance ───────────────────────────────────────────────────────────

    /// @notice Block an individual holder. Frozen addresses can neither send nor receive.
    function freeze(address account, bytes32 reason) external onlyRole(COMPLIANCE_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        frozen[account] = true;
        emit AddressFrozen(account, reason);
    }

    /// @notice Unblock a holder.
    function unfreeze(address account, bytes32 reason) external onlyRole(COMPLIANCE_ROLE) {
        // Symmetric with {freeze}: an unfreeze of the zero address is a mistake in the caller, and
        // silently emitting an event for it puts a meaningless entry in the compliance record.
        if (account == address(0)) revert ZeroAddress();
        frozen[account] = false;
        emit AddressUnfrozen(account, reason);
    }

    /// @notice Burn shares held by an address — partial or in full.
    /// @dev Covers the 14-day right of withdrawal (§44), redemption, annulment of part of the
    ///      issue (ch. 11) and withdrawal from circulation when an issue is declared invalid (§73).
    ///      Works while paused and against frozen accounts by design.
    function burn(address from, uint256 amount, bytes32 reason) external onlyRole(COMPLIANCE_ROLE) {
        if (amount == 0) revert ZeroAmount();
        _complianceOverride = true;
        _burn(from, amount);
        _complianceOverride = false;
        emit ComplianceBurn(from, amount, reason);
    }

    /// @notice Move shares between addresses without the holder's signature.
    /// @dev Enforcement of court decisions and recovery proceedings. The destination must still be
    ///      allowlisted, so the holder registry never gains an unknown address; the pause and the
    ///      freeze flag are bypassed.
    function forcedTransfer(address from, address to, uint256 amount, bytes32 reason)
        external
        onlyRole(COMPLIANCE_ROLE)
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (!allowlist.isAllowed(to)) revert NotAllowed(to);
        // A frozen destination would receive shares it can never move — the enforcement succeeds on
        // paper and strands the property. If the destination genuinely has to be a frozen address,
        // unfreeze it first, which leaves a reason code in the record for why.
        if (frozen[to]) revert AccountFrozen(to);

        _complianceOverride = true;
        _transfer(from, to, amount);
        _complianceOverride = false;

        emit ForcedTransfer(from, to, amount, reason);
    }

    // ── Collateral oracle ────────────────────────────────────────────────────

    /// @notice Deliver verified collateral data into the contract (draft Decree, §16).
    function reportCollateral(bytes32 dataHash, uint256 valuation, uint64 valuedAt, string calldata uri)
        external
        onlyRole(ORACLE_ROLE)
    {
        // This is the figure a regulator reads off the chain as what backs the issue, so it has to
        // be a figure rather than whatever the caller happened to pass. An empty hash points at no
        // document, a zero valuation states the property is worth nothing, and an appraisal dated in
        // the future was not performed.
        if (dataHash == bytes32(0)) revert InvalidCollateralReport();
        if (valuation == 0) revert InvalidCollateralReport();
        if (valuedAt == 0 || valuedAt > block.timestamp) revert InvalidCollateralReport();
        if (bytes(uri).length > MAX_COLLATERAL_URI_LENGTH) revert InvalidCollateralReport();

        collateral = CollateralReport({
            dataHash: dataHash,
            valuation: valuation,
            valuedAt: valuedAt,
            reportedAt: uint64(block.timestamp),
            uri: uri
        });
        emit CollateralReported(dataHash, valuation, valuedAt, uri);
    }

    // ── Admin ────────────────────────────────────────────────────────────────

    /// @notice Repoint to a new restriction registry (e.g. migrating compliance providers).
    function setAllowlist(address allowlist_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (allowlist_ == address(0)) revert ZeroAddress();
        allowlist = IAllowlist(allowlist_);
        emit AllowlistChanged(allowlist_);
    }

    /// @notice Lower the issue size after part of the issue is annulled.
    /// @dev Only ever decreases, and never below what is already outstanding, so the cap keeps
    ///      matching the registered issue and the collateral behind it.
    function reduceMaxSupply(uint256 newMaxSupply, bytes32 reason) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMaxSupply >= maxSupply || newMaxSupply < totalSupply()) revert InvalidMaxSupply();
        uint256 previous = maxSupply;
        maxSupply = newMaxSupply;
        emit MaxSupplyReduced(previous, newMaxSupply, reason);
    }

    // ── Transfer restrictions ────────────────────────────────────────────────

    /// @dev Single choke point for every balance change: mint, transfer and burn all route here.
    ///      Ordinary movements require both parties to be allowlisted, unfrozen and the token to
    ///      be unpaused. A compliance action skips all three: the address it acts on has usually
    ///      just been removed from the allowlist or frozen, which is exactly why compliance is
    ///      acting. What such an action still has to satisfy is enforced by the calling function —
    ///      {forcedTransfer} checks the destination against the allowlist itself.
    function _update(address from, address to, uint256 value) internal override {
        if (!_complianceOverride) {
            _requireNotPaused();

            if (from != address(0)) {
                if (!allowlist.isAllowed(from)) revert NotAllowed(from);
                if (frozen[from]) revert AccountFrozen(from);
            }
            if (to != address(0)) {
                if (!allowlist.isAllowed(to)) revert NotAllowed(to);
                if (frozen[to]) revert AccountFrozen(to);
            }
        }

        super._update(from, to, value);
    }
}
