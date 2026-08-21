// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Allowlist} from "../src/Allowlist.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {AtriaPropertyToken} from "../src/AtriaPropertyToken.sol";

/// @title Deploy
/// @notice Deploys one issue: IdentityRegistry, Allowlist, then the property token, and hands
///         every privilege over to the configured key holders. The deployer keeps nothing.
///
/// @dev Order matters. The deployer temporarily holds DEFAULT_ADMIN_ROLE so it can grant the
///      operational roles in the same transaction batch, then grants admin to {ADMIN_ADDRESS} and
///      renounces its own. The allowlist needs no such dance: its owner and agent are constructor
///      arguments, so the deploying key never owns it at any point.
///
///      The role addresses are checked for separation BEFORE anything is broadcast — see
///      {_requireRoleSeparation}. Deploying with, say, one address as both minter and compliance
///      removes the property the whole design rests on, and finding that out afterwards means
///      rotating keys on a live chain.
///
///      Usage (testnet):
///        forge script script/Deploy.s.sol:Deploy --rpc-url bsc_testnet --account atria-deployer \
///          --broadcast --verify
contract Deploy is Script {
    /// @dev Grouped so the script stays under the stack limit without via-ir.
    struct Config {
        address admin;
        address minter;
        address compliance;
        address pauser;
        address oracle;
        address allowlistAgent;
        address existingAllowlist;
        address existingRegistry;
        string name;
        string symbol;
        string currency;
        uint256 maxSupply;
        bytes32 propertyId;
    }

    function run()
        external
        returns (IdentityRegistry registry, Allowlist allowlist, AtriaPropertyToken token)
    {
        Config memory cfg = _config();

        vm.startBroadcast();

        // The broadcaster, not `msg.sender`: it is the account that actually signs the deployment,
        // and it is the one that must end up holding nothing.
        (, address deployer,) = vm.readCallers();

        registry = cfg.existingRegistry == address(0)
            ? new IdentityRegistry(cfg.admin)
            : IdentityRegistry(cfg.existingRegistry);

        allowlist = _allowlist(cfg);
        token = _token(cfg, address(allowlist), deployer);

        vm.stopBroadcast();

        console2.log("chainId           ", block.chainid);
        console2.log("IdentityRegistry  ", address(registry));
        console2.log("Allowlist         ", address(allowlist));
        console2.log("AtriaPropertyToken", address(token));
        console2.log("Record these in Property.SetTokenContract, not in application configuration.");
    }

    function _config() internal view returns (Config memory cfg) {
        cfg.admin = vm.envAddress("ADMIN_ADDRESS");
        cfg.minter = vm.envAddress("MINTER_ADDRESS");
        cfg.compliance = vm.envAddress("COMPLIANCE_ADDRESS");
        cfg.pauser = vm.envAddress("PAUSER_ADDRESS");
        cfg.oracle = vm.envAddress("ORACLE_ADDRESS");
        cfg.allowlistAgent = vm.envAddress("ALLOWLIST_AGENT_ADDRESS");
        cfg.existingAllowlist = vm.envOr("ALLOWLIST_ADDRESS", address(0));
        cfg.existingRegistry = vm.envOr("IDENTITY_REGISTRY_ADDRESS", address(0));
        cfg.name = vm.envString("TOKEN_NAME");
        cfg.symbol = vm.envString("TOKEN_SYMBOL");
        cfg.currency = vm.envOr("COLLATERAL_CURRENCY", string("KGS"));
        // TOKEN_MAX_SUPPLY is a share count, the number the issue is registered for. Shares are
        // indivisible (`decimals()` is zero), so the cap IS that number — `totalSupply()` counts the
        // same unit and nothing is scaled. Multiplying here, as an earlier hundredths-based token
        // needed, would cap the issue at a hundred times its registered size.
        cfg.maxSupply = vm.envUint("TOKEN_MAX_SUPPLY");
        cfg.propertyId = vm.envOr("PROPERTY_ID", bytes32(0));

        _requireIssueIdentity(cfg.propertyId);
        _requireRoleSeparation(cfg);
    }

    /// @dev The whole point of the role split is that no single key can both create shares and take
    ///      them away. Nothing in the token enforces that — it is a property of who holds which role,
    ///      decided here. Passing the same address twice compiles, deploys, and quietly produces a
    ///      contract with the separation removed. CheckDeployment catches it, but only after the
    ///      deployment exists on a public chain under a set of keys that has to be rotated to undo.
    ///      Checking before `vm.startBroadcast` costs nothing and fails on the developer's machine.
    /// @dev Which issue this token represents is decided before it exists: the constructor stores it
    ///      immutably and rejects an empty value, so an unset PROPERTY_ID is not a setting to fix
    ///      afterwards but a second deployment — by which time the address may already be published.
    ///      The value comes from the backend as `propertyIdBytes32`
    ///      (`GET /api/v1/properties/{id}/token-contract`); converting the guid by hand invites the
    ///      one mistake this cannot recover from.
    function _requireIssueIdentity(bytes32 propertyId) internal pure {
        require(propertyId != bytes32(0), "PROPERTY_ID is unset (backend: propertyIdBytes32)");

        // A `Property.Id` is a 16-byte guid left-aligned in the word, so the lower half is zero. A
        // word that fails this is not an id from the database but something invented locally — a
        // hash, a hand-typed placeholder, `0x…01`. The backend refuses to bind such a contract, so
        // catching it here is the difference between a failed command and a wasted deployment.
        require(
            uint256(propertyId) & type(uint128).max == 0,
            "PROPERTY_ID is not a Property.Id (expected the guid left-aligned, zero-padded)"
        );
    }

    function _requireRoleSeparation(Config memory cfg) internal pure {
        require(cfg.admin != address(0), "ADMIN_ADDRESS is unset");
        require(cfg.minter != address(0), "MINTER_ADDRESS is unset");
        require(cfg.compliance != address(0), "COMPLIANCE_ADDRESS is unset");
        require(cfg.pauser != address(0), "PAUSER_ADDRESS is unset");
        require(cfg.oracle != address(0), "ORACLE_ADDRESS is unset");
        require(cfg.allowlistAgent != address(0), "ALLOWLIST_AGENT_ADDRESS is unset");

        // The pairing that matters: one key must never be able to mint and to burn/seize.
        require(cfg.minter != cfg.compliance, "MINTER_ADDRESS == COMPLIANCE_ADDRESS");

        // The admin multisig manages roles; holding an operational one as well means a single
        // compromise grants both the power and the ability to grant itself more.
        require(cfg.admin != cfg.minter, "ADMIN_ADDRESS == MINTER_ADDRESS");
        require(cfg.admin != cfg.compliance, "ADMIN_ADDRESS == COMPLIANCE_ADDRESS");

        // The oracle states what backs the issue; it must not also be able to move the shares.
        require(cfg.oracle != cfg.minter, "ORACLE_ADDRESS == MINTER_ADDRESS");
        require(cfg.oracle != cfg.compliance, "ORACLE_ADDRESS == COMPLIANCE_ADDRESS");

        // The backend's allowlist key is an online service key — the most exposed of the set.
        require(cfg.allowlistAgent != cfg.admin, "ALLOWLIST_AGENT_ADDRESS == ADMIN_ADDRESS");
        require(cfg.allowlistAgent != cfg.minter, "ALLOWLIST_AGENT_ADDRESS == MINTER_ADDRESS");
        require(cfg.allowlistAgent != cfg.compliance, "ALLOWLIST_AGENT_ADDRESS == COMPLIANCE_ADDRESS");

        require(cfg.maxSupply > 0, "TOKEN_MAX_SUPPLY is zero");
    }

    /// @dev Reuses an existing list when configured, otherwise deploys one, points it at the
    ///      backend gateway's service key and hands ownership to the admin multisig —
    ///      `transferOwnership` drops the deployer's agent rights on the way out.
    function _allowlist(Config memory cfg) internal returns (Allowlist allowlist) {
        if (cfg.existingAllowlist != address(0)) {
            // Reusing a list this script does not own: it cannot grant the backend gateway its agent
            // rights, and staying silent about that leaves the gateway unable to allowlist anyone —
            // which surfaces later as mints reverting for no visible reason. Say so here; the admin
            // multisig has to call setAgent itself.
            console2.log("NOTE reusing ALLOWLIST_ADDRESS - setAgent(ALLOWLIST_AGENT_ADDRESS) was NOT called.");
            console2.log("     The allowlist owner must grant it before any mint can succeed.");
            return Allowlist(cfg.existingAllowlist);
        }

        // Owner and agent are constructor arguments, so the deployer never owns the list at all —
        // there is no window between "deployed" and "handed over" for it to be otherwise.
        allowlist = new Allowlist(cfg.admin, cfg.allowlistAgent);
    }

    /// @dev The deployer holds DEFAULT_ADMIN_ROLE only long enough to grant the operational roles,
    ///      then passes admin to the multisig and renounces its own. It keeps nothing.
    function _token(Config memory cfg, address allowlist, address deployer)
        internal
        returns (AtriaPropertyToken token)
    {
        token = new AtriaPropertyToken(
            cfg.name, cfg.symbol, allowlist, cfg.maxSupply, cfg.propertyId, cfg.currency, deployer
        );

        token.grantRole(token.MINTER_ROLE(), cfg.minter);
        token.grantRole(token.COMPLIANCE_ROLE(), cfg.compliance);
        token.grantRole(token.PAUSER_ROLE(), cfg.pauser);
        token.grantRole(token.ORACLE_ROLE(), cfg.oracle);

        token.grantRole(token.DEFAULT_ADMIN_ROLE(), cfg.admin);
        token.renounceRole(token.DEFAULT_ADMIN_ROLE(), deployer);
    }
}
