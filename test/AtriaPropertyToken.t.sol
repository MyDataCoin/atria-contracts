// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Allowlist} from "../src/Allowlist.sol";
import {AtriaPropertyToken} from "../src/AtriaPropertyToken.sol";

contract AtriaPropertyTokenTest is Test {
    Allowlist internal allowlist;
    AtriaPropertyToken internal token;

    address internal admin = makeAddr("admin");
    address internal minter = makeAddr("minter");
    address internal compliance = makeAddr("compliance");
    address internal pauser = makeAddr("pauser");
    address internal oracle = makeAddr("oracle");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal outsider = makeAddr("outsider");
    address internal issuer = makeAddr("issuer");

    uint256 internal constant MAX_SUPPLY = 1_000;
    bytes32 internal constant PROPERTY_ID = keccak256("property-1");
    bytes32 internal constant REASON = bytes32("court-order-42");

    function setUp() public {
        allowlist = new Allowlist();
        token = new AtriaPropertyToken(
            "ATRIA Property Test", "ATRP-T1", address(allowlist), MAX_SUPPLY, PROPERTY_ID, "KGS", admin
        );

        vm.startPrank(admin);
        token.grantRole(token.MINTER_ROLE(), minter);
        token.grantRole(token.COMPLIANCE_ROLE(), compliance);
        token.grantRole(token.PAUSER_ROLE(), pauser);
        token.grantRole(token.ORACLE_ROLE(), oracle);
        vm.stopPrank();

        allowlist.addToAllowlist(alice);
        allowlist.addToAllowlist(bob);
        allowlist.addToAllowlist(issuer);
    }

    function _mint(address to, uint256 amount) internal {
        vm.prank(minter);
        token.mint(to, amount);
    }

    // ── Indivisibility ───────────────────────────────────────────────────────

    function test_decimalsIsZero() public view {
        assertEq(token.decimals(), 0);
    }

    /// @dev With decimals = 0 the smallest representable amount is one whole share: a "half share"
    ///      has no on-chain representation at all, and 1 unit is exactly 1 share.
    function test_oneUnitIsOneWholeShare() public {
        _mint(alice, 1);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.totalSupply(), 1);
    }

    // ── Allowlist ────────────────────────────────────────────────────────────

    function test_mintToNonAllowlistedReverts() public {
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(AtriaPropertyToken.NotAllowed.selector, outsider));
        token.mint(outsider, 10);
    }

    function test_transferToNonAllowlistedReverts() public {
        _mint(alice, 10);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AtriaPropertyToken.NotAllowed.selector, outsider));
        token.transfer(outsider, 1);
    }

    function test_transferFromDelistedSenderReverts() public {
        _mint(alice, 10);
        allowlist.removeFromAllowlist(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AtriaPropertyToken.NotAllowed.selector, alice));
        token.transfer(bob, 1);
    }

    function test_transferBetweenAllowlistedSucceeds() public {
        _mint(alice, 10);
        vm.prank(alice);
        token.transfer(bob, 4);

        assertEq(token.balanceOf(alice), 6);
        assertEq(token.balanceOf(bob), 4);
    }

    // ── Supply cap ───────────────────────────────────────────────────────────

    function test_mintAboveIssueSizeReverts() public {
        _mint(alice, MAX_SUPPLY - 1);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(AtriaPropertyToken.SupplyCapExceeded.selector, 2, 1));
        token.mint(alice, 2);
    }

    function test_remainingSupplyTracksMints() public {
        _mint(alice, 250);
        assertEq(token.remainingSupply(), MAX_SUPPLY - 250);
    }

    function test_reduceMaxSupplyOnlyDecreasesAndNeverBelowOutstanding() public {
        _mint(alice, 400);

        vm.prank(admin);
        token.reduceMaxSupply(500, REASON);
        assertEq(token.maxSupply(), 500);

        vm.prank(admin);
        vm.expectRevert(AtriaPropertyToken.InvalidMaxSupply.selector);
        token.reduceMaxSupply(600, REASON);

        vm.prank(admin);
        vm.expectRevert(AtriaPropertyToken.InvalidMaxSupply.selector);
        token.reduceMaxSupply(399, REASON);
    }

    // ── Freeze ───────────────────────────────────────────────────────────────

    function test_freezeBlocksOutgoingAndIncomingTransfers() public {
        _mint(alice, 10);
        _mint(bob, 10);

        vm.prank(compliance);
        token.freeze(alice, REASON);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AtriaPropertyToken.AccountFrozen.selector, alice));
        token.transfer(bob, 1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AtriaPropertyToken.AccountFrozen.selector, alice));
        token.transfer(alice, 1);
    }

    function test_unfreezeRestoresTransfers() public {
        _mint(alice, 10);

        vm.startPrank(compliance);
        token.freeze(alice, REASON);
        token.unfreeze(alice, REASON);
        vm.stopPrank();

        vm.prank(alice);
        token.transfer(bob, 1);
        assertEq(token.balanceOf(bob), 1);
    }

    // ── Pause ────────────────────────────────────────────────────────────────

    function test_pauseBlocksTransfersAndMints() public {
        _mint(alice, 10);

        vm.prank(pauser);
        token.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.transfer(bob, 1);

        vm.prank(minter);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.mint(alice, 1);
    }

    function test_unpauseResumesOperations() public {
        _mint(alice, 10);

        vm.prank(pauser);
        token.pause();
        vm.prank(pauser);
        token.unpause();

        vm.prank(alice);
        token.transfer(bob, 1);
        assertEq(token.balanceOf(bob), 1);
    }

    // ── Compliance powers ────────────────────────────────────────────────────

    function test_burnReducesSupply() public {
        _mint(alice, 10);

        vm.prank(compliance);
        token.burn(alice, 4, REASON);

        assertEq(token.balanceOf(alice), 6);
        assertEq(token.totalSupply(), 6);
    }

    /// @dev The 14-day withdrawal and §73 invalidation both burn from an address that has already
    ///      been frozen or delisted — the compliance path must not depend on either.
    function test_burnWorksWhilePausedFrozenAndDelisted() public {
        _mint(alice, 10);

        vm.prank(compliance);
        token.freeze(alice, REASON);
        allowlist.removeFromAllowlist(alice);
        vm.prank(pauser);
        token.pause();

        vm.prank(compliance);
        token.burn(alice, 10, REASON);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), 0);
    }

    function test_forcedTransferMovesSharesWithoutHolderSignature() public {
        _mint(alice, 10);

        vm.prank(compliance);
        token.freeze(alice, REASON);
        vm.prank(pauser);
        token.pause();

        vm.prank(compliance);
        token.forcedTransfer(alice, issuer, 10, REASON);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(issuer), 10);
    }

    function test_forcedTransferToNonAllowlistedReverts() public {
        _mint(alice, 10);

        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(AtriaPropertyToken.NotAllowed.selector, outsider));
        token.forcedTransfer(alice, outsider, 1, REASON);
    }

    function test_burnMoreThanBalanceReverts() public {
        _mint(alice, 5);

        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 5, 6));
        token.burn(alice, 6, REASON);
    }

    /// @dev The override flag must not leak past a compliance action.
    function test_restrictionsRestoredAfterComplianceAction() public {
        _mint(alice, 10);

        vm.prank(pauser);
        token.pause();
        vm.prank(compliance);
        token.burn(alice, 1, REASON);

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.transfer(bob, 1);
    }

    // ── Role separation ──────────────────────────────────────────────────────

    function test_minterCannotBurnFreezeOrPause() public {
        _mint(alice, 10);

        vm.startPrank(minter);
        _expectMissingRole(minter, token.COMPLIANCE_ROLE());
        token.burn(alice, 1, REASON);

        _expectMissingRole(minter, token.COMPLIANCE_ROLE());
        token.freeze(alice, REASON);

        _expectMissingRole(minter, token.PAUSER_ROLE());
        token.pause();
        vm.stopPrank();
    }

    function test_complianceCannotMint() public {
        bytes32 role = token.MINTER_ROLE();

        _expectMissingRole(compliance, role);
        vm.prank(compliance);
        token.mint(alice, 1);
    }

    function test_pauserCannotMintOrBurn() public {
        _mint(alice, 10);

        vm.startPrank(pauser);
        _expectMissingRole(pauser, token.MINTER_ROLE());
        token.mint(alice, 1);

        _expectMissingRole(pauser, token.COMPLIANCE_ROLE());
        token.burn(alice, 1, REASON);
        vm.stopPrank();
    }

    function test_adminCannotMintOrBurnWithoutOperationalRoles() public {
        _mint(alice, 10);

        vm.startPrank(admin);
        _expectMissingRole(admin, token.MINTER_ROLE());
        token.mint(alice, 1);

        _expectMissingRole(admin, token.COMPLIANCE_ROLE());
        token.burn(alice, 1, REASON);
        vm.stopPrank();
    }

    function test_onlyAdminManagesAllowlistPointerAndRoles() public {
        Allowlist other = new Allowlist();
        bytes32 role = token.DEFAULT_ADMIN_ROLE();

        _expectMissingRole(compliance, role);
        vm.prank(compliance);
        token.setAllowlist(address(other));

        vm.prank(admin);
        token.setAllowlist(address(other));
        assertEq(address(token.allowlist()), address(other));
    }

    function test_outsiderCannotReportCollateral() public {
        bytes32 role = token.ORACLE_ROLE();

        _expectMissingRole(outsider, role);
        vm.prank(outsider);
        token.reportCollateral(keccak256("doc"), 1, uint64(block.timestamp), "ipfs://doc");
    }

    // ── Collateral oracle ────────────────────────────────────────────────────

    function test_reportCollateralStoresLatestReport() public {
        vm.warp(1_800_000_000);
        uint64 valuedAt = uint64(block.timestamp) - 1 days;

        vm.prank(oracle);
        token.reportCollateral(keccak256("appraisal-2026-08"), 125_000_000, valuedAt, "ipfs://appraisal");

        (bytes32 dataHash, uint256 valuation, uint64 storedValuedAt, uint64 reportedAt, string memory uri) =
            token.collateral();

        assertEq(dataHash, keccak256("appraisal-2026-08"));
        assertEq(valuation, 125_000_000);
        assertEq(storedValuedAt, valuedAt);
        assertEq(reportedAt, uint64(block.timestamp));
        assertEq(uri, "ipfs://appraisal");
    }

    // ── Metadata ─────────────────────────────────────────────────────────────

    function test_propertyIdAndCurrencyAreExposed() public view {
        assertEq(token.propertyId(), PROPERTY_ID);
        assertEq(token.collateralCurrency(), "KGS");
    }

    function _expectMissingRole(address account, bytes32 role) internal {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, role)
        );
    }
}
