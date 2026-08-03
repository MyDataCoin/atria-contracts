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
///      renounces its own. Allowlist ownership moves the same way — `transferOwnership` also drops
///      the outgoing owner's agent rights.
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

    function run() external {
        Config memory cfg = _config();

        vm.startBroadcast();

        IdentityRegistry registry = cfg.existingRegistry == address(0)
            ? new IdentityRegistry(cfg.admin)
            : IdentityRegistry(cfg.existingRegistry);

        Allowlist allowlist = _allowlist(cfg);
        AtriaPropertyToken token = _token(cfg, address(allowlist));

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
        cfg.maxSupply = vm.envUint("TOKEN_MAX_SUPPLY");
        cfg.propertyId = vm.envBytes32("PROPERTY_ID");
    }

    /// @dev Reuses an existing list when configured, otherwise deploys one, points it at the
    ///      backend gateway's service key and hands ownership to the admin multisig —
    ///      `transferOwnership` drops the deployer's agent rights on the way out.
    function _allowlist(Config memory cfg) internal returns (Allowlist allowlist) {
        if (cfg.existingAllowlist != address(0)) return Allowlist(cfg.existingAllowlist);

        allowlist = new Allowlist();
        allowlist.setAgent(cfg.allowlistAgent, true);
        allowlist.transferOwnership(cfg.admin);
    }

    /// @dev The deployer holds DEFAULT_ADMIN_ROLE only long enough to grant the operational roles,
    ///      then passes admin to the multisig and renounces its own. It keeps nothing.
    function _token(Config memory cfg, address allowlist) internal returns (AtriaPropertyToken token) {
        address deployer = msg.sender;

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
