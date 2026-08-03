// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Allowlist} from "../src/Allowlist.sol";
import {AtriaPropertyToken} from "../src/AtriaPropertyToken.sol";

/// @title CheckDeployment
/// @notice Reads a deployed set back from the chain and asserts the key layout, so a deployment is
///         confirmed against network state rather than against the deploy script's own log.
///         Read-only: it broadcasts nothing.
///
/// @dev Run after every deployment, testnet and mainnet:
///        TOKEN_ADDRESS=0x... forge script script/CheckDeployment.s.sol:CheckDeployment \
///          --rpc-url bsc_testnet
contract CheckDeployment is Script {
    function run() external view {
        AtriaPropertyToken token = AtriaPropertyToken(vm.envAddress("TOKEN_ADDRESS"));
        Allowlist allowlist = Allowlist(address(token.allowlist()));

        address admin = vm.envAddress("ADMIN_ADDRESS");
        address minter = vm.envAddress("MINTER_ADDRESS");
        address compliance = vm.envAddress("COMPLIANCE_ADDRESS");
        address pauser = vm.envAddress("PAUSER_ADDRESS");
        address oracle = vm.envAddress("ORACLE_ADDRESS");
        address agent = vm.envAddress("ALLOWLIST_AGENT_ADDRESS");
        address deployer = vm.envOr("DEPLOYER_ADDRESS", address(0));

        _check("decimals == 0", token.decimals() == 0);
        _check("maxSupply == TOKEN_MAX_SUPPLY", token.maxSupply() == vm.envUint("TOKEN_MAX_SUPPLY"));
        _check("propertyId matches", token.propertyId() == vm.envBytes32("PROPERTY_ID"));

        _check("admin holds DEFAULT_ADMIN_ROLE", token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
        _check("minter holds MINTER_ROLE", token.hasRole(token.MINTER_ROLE(), minter));
        _check("compliance holds COMPLIANCE_ROLE", token.hasRole(token.COMPLIANCE_ROLE(), compliance));
        _check("pauser holds PAUSER_ROLE", token.hasRole(token.PAUSER_ROLE(), pauser));
        _check("oracle holds ORACLE_ROLE", token.hasRole(token.ORACLE_ROLE(), oracle));

        // The separation is the point: no key may both create shares and take them away.
        _check("minter has no compliance rights", !token.hasRole(token.COMPLIANCE_ROLE(), minter));
        _check("compliance cannot mint", !token.hasRole(token.MINTER_ROLE(), compliance));
        _check("admin cannot mint", !token.hasRole(token.MINTER_ROLE(), admin));
        _check("admin has no compliance rights", !token.hasRole(token.COMPLIANCE_ROLE(), admin));

        _check("allowlist owned by admin", allowlist.owner() == admin);
        _check("backend agent can maintain the allowlist", allowlist.agents(agent));

        if (deployer != address(0)) {
            _check("deployer holds no admin role", !token.hasRole(token.DEFAULT_ADMIN_ROLE(), deployer));
            _check("deployer holds no minter role", !token.hasRole(token.MINTER_ROLE(), deployer));
            _check("deployer holds no compliance role", !token.hasRole(token.COMPLIANCE_ROLE(), deployer));
            _check("deployer holds no pauser role", !token.hasRole(token.PAUSER_ROLE(), deployer));
            _check("deployer holds no oracle role", !token.hasRole(token.ORACLE_ROLE(), deployer));
            _check("deployer is not an allowlist agent", !allowlist.agents(deployer));
        } else {
            console2.log("skipped   deployer checks (set DEPLOYER_ADDRESS to run them)");
        }

        console2.log("");
        console2.log("token     ", address(token));
        console2.log("allowlist ", address(allowlist));
        console2.log("supply    ", token.totalSupply(), "of", token.maxSupply());
        console2.log("paused    ", token.paused());
    }

    function _check(string memory what, bool ok) internal pure {
        console2.log(ok ? "ok        " : "FAILED    ", what);
        require(ok, what);
    }
}
