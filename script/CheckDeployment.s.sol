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
        // Every check runs, then one require at the end. Reverting on the FIRST failure hid every
        // check behind it: a stale `decimals == 0` (the token has had 2 decimals since the scale
        // change) meant the role-separation and deployer-holds-nothing assertions below never ran,
        // and the runbook step that is supposed to prove them silently proved nothing.
        bool ok = true;

        AtriaPropertyToken token = AtriaPropertyToken(vm.envAddress("TOKEN_ADDRESS"));
        Allowlist allowlist = Allowlist(address(token.allowlist()));

        address admin = vm.envAddress("ADMIN_ADDRESS");
        address minter = vm.envAddress("MINTER_ADDRESS");
        address compliance = vm.envAddress("COMPLIANCE_ADDRESS");
        address pauser = vm.envAddress("PAUSER_ADDRESS");
        address oracle = vm.envAddress("ORACLE_ADDRESS");
        address agent = vm.envAddress("ALLOWLIST_AGENT_ADDRESS");
        address deployer = vm.envOr("DEPLOYER_ADDRESS", address(0));

        ok = _check("decimals == 2", token.decimals() == 2) && ok;
        // TOKEN_MAX_SUPPLY is in shares, `maxSupply` in minor units — see Deploy._config.
        ok = _check(
            "maxSupply == TOKEN_MAX_SUPPLY",
            token.maxSupply() == vm.envUint("TOKEN_MAX_SUPPLY") * 10 ** token.decimals()
        ) && ok;
        ok = _check("propertyId matches", token.propertyId() == vm.envBytes32("PROPERTY_ID")) && ok;

        ok = _check("admin holds DEFAULT_ADMIN_ROLE", token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin)) && ok;
        ok = _check("minter holds MINTER_ROLE", token.hasRole(token.MINTER_ROLE(), minter)) && ok;
        ok = _check("compliance holds COMPLIANCE_ROLE", token.hasRole(token.COMPLIANCE_ROLE(), compliance))
            && ok;
        ok = _check("pauser holds PAUSER_ROLE", token.hasRole(token.PAUSER_ROLE(), pauser)) && ok;
        ok = _check("oracle holds ORACLE_ROLE", token.hasRole(token.ORACLE_ROLE(), oracle)) && ok;

        // The separation is the point: no key may both create shares and take them away.
        ok = _check("minter has no compliance rights", !token.hasRole(token.COMPLIANCE_ROLE(), minter)) && ok;
        ok = _check("compliance cannot mint", !token.hasRole(token.MINTER_ROLE(), compliance)) && ok;
        ok = _check("admin cannot mint", !token.hasRole(token.MINTER_ROLE(), admin)) && ok;
        ok = _check("admin has no compliance rights", !token.hasRole(token.COMPLIANCE_ROLE(), admin)) && ok;

        ok = _check("allowlist owned by admin", allowlist.owner() == admin) && ok;
        ok = _check("backend agent can maintain the allowlist", allowlist.agents(agent)) && ok;

        if (deployer != address(0)) {
            ok = _check("deployer holds no admin role", !token.hasRole(token.DEFAULT_ADMIN_ROLE(), deployer))
                && ok;
            ok = _check("deployer holds no minter role", !token.hasRole(token.MINTER_ROLE(), deployer)) && ok;
            ok = _check(
                    "deployer holds no compliance role", !token.hasRole(token.COMPLIANCE_ROLE(), deployer)
                ) && ok;
            ok = _check("deployer holds no pauser role", !token.hasRole(token.PAUSER_ROLE(), deployer)) && ok;
            ok = _check("deployer holds no oracle role", !token.hasRole(token.ORACLE_ROLE(), deployer)) && ok;
            ok = _check("deployer is not an allowlist agent", !allowlist.agents(deployer)) && ok;
        } else {
            console2.log("skipped   deployer checks (set DEPLOYER_ADDRESS to run them)");
        }

        console2.log("");
        console2.log("token     ", address(token));
        console2.log("allowlist ", address(allowlist));
        console2.log("supply    ", token.totalSupply(), "of", token.maxSupply());
        console2.log("paused    ", token.paused());

        require(ok, "deployment checks failed: see the FAILED lines above");
    }

    /// @dev Logs the outcome and returns it, so the caller can run every check and fail once at
    ///      the end with the full picture rather than at the first red line.
    function _check(string memory what, bool passed) internal pure returns (bool) {
        console2.log(passed ? "ok        " : "FAILED    ", what);
        return passed;
    }
}
