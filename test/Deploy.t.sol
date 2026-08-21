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
    /// @dev The shape the backend hands over as `propertyIdBytes32`: a `Property.Id` guid
    ///      left-aligned in the word and zero-padded on the right.
    bytes32 internal constant PROPERTY_ID =
        0x3f8d90012b4c4d6e8a10c0ffee00123400000000000000000000000000000000;

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

    /// @notice Deploying without the issue id has to fail on the developer's machine: afterwards the
    ///         address may already be published, and the id can only be changed by deploying again.
    /// @notice Deploying without the issue id has to fail on the developer's machine: afterwards the
    ///         address may already be published, and the id can only be changed by deploying again.
    /// @dev Exercised through the harness rather than by emptying `PROPERTY_ID` in the environment —
    ///      the environment belongs to the process, so a test that empties it fails whichever test
    ///      runs next instead of this one.
    function test_deployRefusesAnEmptyPropertyId() public {
        DeployHarness harness = new DeployHarness();

        harness.requireIssueIdentity(PROPERTY_ID);

        vm.expectRevert(bytes("PROPERTY_ID is unset (backend: propertyIdBytes32)"));
        harness.requireIssueIdentity(bytes32(0));
    }

    /// @notice The placeholder that is not zero is the one that gets deployed: `0x…01`, or a hash of
    ///         something convenient. Neither is an id the backend can bind the contract by.
    function test_deployRefusesAWordThatIsNotAPropertyId() public {
        DeployHarness harness = new DeployHarness();

        vm.expectRevert(
            bytes("PROPERTY_ID is not a Property.Id (expected the guid left-aligned, zero-padded)")
        );
        harness.requireIssueIdentity(bytes32(uint256(1)));

        vm.expectRevert(
            bytes("PROPERTY_ID is not a Property.Id (expected the guid left-aligned, zero-padded)")
        );
        harness.requireIssueIdentity(keccak256("property-testnet-1"));
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
        assertEq(token.decimals(), 2);
        // TOKEN_MAX_SUPPLY is a share count; the cap is compared against a minor-unit total supply.
        assertEq(token.maxSupply(), MAX_SUPPLY * 100);
        assertEq(token.maxSupply(), MAX_SUPPLY * 10 ** token.decimals());
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

/// @dev Reaches the script's pre-broadcast checks without going through the environment.
contract DeployHarness is Deploy {
    function requireIssueIdentity(bytes32 propertyId) external pure {
        _requireIssueIdentity(propertyId);
    }
}
