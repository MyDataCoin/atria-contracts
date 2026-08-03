// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Allowlist} from "../src/Allowlist.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {AtriaPropertyToken} from "../src/AtriaPropertyToken.sol";

/// @notice Rehearses the testnet deployment (task A4) in the EVM, so the key layout is verified
///         before any key touches a live network. The one thing that must hold afterwards: the
///         deployer keeps nothing.
contract DeployTest is Test {
    address internal admin = makeAddr("adminMultisig");
    address internal minter = makeAddr("minterCustody");
    address internal compliance = makeAddr("complianceKey");
    address internal pauser = makeAddr("pauserKey");
    address internal oracle = makeAddr("oracleKey");
    address internal agent = makeAddr("backendAllowlistAgent");

    uint256 internal constant MAX_SUPPLY = 250_000;
    bytes32 internal constant PROPERTY_ID = keccak256("property-testnet-1");

    IdentityRegistry internal registry;
    Allowlist internal allowlist;
    AtriaPropertyToken internal token;
    address internal deployer;

    function setUp() public {
        vm.setEnv("ADMIN_ADDRESS", vm.toString(admin));
        vm.setEnv("MINTER_ADDRESS", vm.toString(minter));
        vm.setEnv("COMPLIANCE_ADDRESS", vm.toString(compliance));
        vm.setEnv("PAUSER_ADDRESS", vm.toString(pauser));
        vm.setEnv("ORACLE_ADDRESS", vm.toString(oracle));
        vm.setEnv("ALLOWLIST_AGENT_ADDRESS", vm.toString(agent));
        vm.setEnv("TOKEN_NAME", "ATRIA Property Test");
        vm.setEnv("TOKEN_SYMBOL", "ATRP-T1");
        vm.setEnv("TOKEN_MAX_SUPPLY", vm.toString(MAX_SUPPLY));
        vm.setEnv("PROPERTY_ID", vm.toString(PROPERTY_ID));
        vm.setEnv("COLLATERAL_CURRENCY", "KGS");
        vm.setEnv("ALLOWLIST_ADDRESS", vm.toString(address(0)));
        vm.setEnv("IDENTITY_REGISTRY_ADDRESS", vm.toString(address(0)));

        // The script broadcasts as forge-std's default sender; pranking around a broadcast is
        // not allowed, so that address stands in for the deployer key.
        deployer = DEFAULT_SENDER;
        (registry, allowlist, token) = new Deploy().run();
    }

    function test_deployerKeepsNothing() public view {
        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(token.hasRole(token.MINTER_ROLE(), deployer));
        assertFalse(token.hasRole(token.COMPLIANCE_ROLE(), deployer));
        assertFalse(token.hasRole(token.PAUSER_ROLE(), deployer));
        assertFalse(token.hasRole(token.ORACLE_ROLE(), deployer));

        assertFalse(allowlist.agents(deployer));
        assertTrue(allowlist.owner() != deployer);
        assertTrue(registry.authority() != deployer);
    }

    function test_rolesLandOnTheirOwnKeys() public view {
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(token.hasRole(token.MINTER_ROLE(), minter));
        assertTrue(token.hasRole(token.COMPLIANCE_ROLE(), compliance));
        assertTrue(token.hasRole(token.PAUSER_ROLE(), pauser));
        assertTrue(token.hasRole(token.ORACLE_ROLE(), oracle));

        // No key holds two of the powers that must stay apart.
        assertFalse(token.hasRole(token.COMPLIANCE_ROLE(), minter));
        assertFalse(token.hasRole(token.MINTER_ROLE(), compliance));
        assertFalse(token.hasRole(token.MINTER_ROLE(), admin));
        assertFalse(token.hasRole(token.COMPLIANCE_ROLE(), admin));
    }

    function test_allowlistOwnedByAdminAndDrivenByBackendAgent() public view {
        assertEq(allowlist.owner(), admin);
        assertTrue(allowlist.agents(agent));
        assertTrue(allowlist.agents(admin));
    }

    function test_identityRegistryAuthorityIsAdmin() public view {
        assertEq(registry.authority(), admin);
    }

    function test_tokenParametersMatchTheIssue() public view {
        assertEq(token.name(), "ATRIA Property Test");
        assertEq(token.symbol(), "ATRP-T1");
        assertEq(token.decimals(), 0);
        assertEq(token.maxSupply(), MAX_SUPPLY);
        assertEq(token.totalSupply(), 0);
        assertEq(token.propertyId(), PROPERTY_ID);
        assertEq(token.collateralCurrency(), "KGS");
        assertEq(address(token.allowlist()), address(allowlist));
    }

    /// @dev End-to-end rehearsal of the live sequence: allowlist first, then mint.
    function test_backendAgentCanAllowlistAndMinterCanThenMint() public {
        address investor = makeAddr("investor");

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(AtriaPropertyToken.NotAllowed.selector, investor));
        token.mint(investor, 5);

        vm.prank(agent);
        allowlist.addToAllowlist(investor);

        vm.prank(minter);
        token.mint(investor, 5);
        assertEq(token.balanceOf(investor), 5);
    }

    function test_existingAllowlistIsReusedInsteadOfRedeployed() public {
        vm.setEnv("ALLOWLIST_ADDRESS", vm.toString(address(allowlist)));
        vm.setEnv("IDENTITY_REGISTRY_ADDRESS", vm.toString(address(registry)));

        (IdentityRegistry registry2, Allowlist allowlist2, AtriaPropertyToken token2) = new Deploy().run();

        assertEq(address(allowlist2), address(allowlist));
        assertEq(address(registry2), address(registry));
        assertTrue(address(token2) != address(token));
    }
}
