// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";

/// @title IdentityRegistryTest
/// @notice Covers the registry's ownership model, with the DID-squatting finding of the 2026-08-04
///         review pinned so it cannot come back.
contract IdentityRegistryTest is Test {
    IdentityRegistry internal registry;

    address internal authority = makeAddr("authority");
    address internal newAuthority = makeAddr("newAuthority");
    address internal outsider = makeAddr("outsider");

    // The rightful controller of the DID and an attacker who wants it.
    uint256 internal victimKey = 0xA11CE;
    uint256 internal attackerKey = 0xBAD;
    address internal victim;
    address internal attacker;

    bytes32 internal constant DID_HASH = keccak256("did:atria:investor-42");
    bytes32 internal constant ROOT = keccak256("attestation-root-v1");

    function setUp() public {
        victim = vm.addr(victimKey);
        attacker = vm.addr(attackerKey);
        registry = new IdentityRegistry(authority);
    }

    // ── The finding ──────────────────────────────────────────────────────────

    /// @notice C-1: a stranger must not be able to claim someone else's DID.
    /// @dev The previous revision let anyone call registerDid. A controller signature was believed
    ///      to prevent squatting, but it only proves the named key signed the payload — it says
    ///      nothing about that key's relation to the DID. An attacker generated a keypair, signed
    ///      over a victim's didHash and registered first; since `exists` is permanent and there was
    ///      no reassignment, the victim was locked out for good and the registry served the
    ///      attacker's root from then on.
    function test_strangerCannotRegisterSomeoneElsesDid() public {
        bytes memory attackerSignature = _sign(attackerKey, DID_HASH, ROOT);

        vm.prank(attacker);
        vm.expectRevert(IdentityRegistry.NotAuthority.selector);
        registry.registerDid(DID_HASH, ROOT, attacker, attackerSignature);

        (bool exists,,,,,) = registry.getAnchor(DID_HASH);
        assertFalse(exists, "an unauthorised caller must not be able to create an anchor");
    }

    /// @notice The authority may register, and the controller still has to have consented.
    function test_authorityRegistersWithTheControllersConsent() public {
        vm.prank(authority);
        registry.registerDid(DID_HASH, ROOT, victim, _sign(victimKey, DID_HASH, ROOT));

        (bool exists, address owner, bytes32 root, uint64 epoch,,) = registry.getAnchor(DID_HASH);
        assertTrue(exists);
        assertEq(owner, victim);
        assertEq(root, ROOT);
        assertEq(epoch, 0);
    }

    /// @notice The authority cannot bind a DID to a key that never agreed to hold it.
    function test_authorityCannotAnchorToANonConsentingKey() public {
        // A signature by the attacker's key, but naming the victim as controller.
        vm.prank(authority);
        vm.expectRevert(IdentityRegistry.InvalidSignature.selector);
        registry.registerDid(DID_HASH, ROOT, victim, _sign(attackerKey, DID_HASH, ROOT));
    }

    /// @notice C-1 recovery path: a stranded anchor can be moved to a new controller.
    function test_anchorCanBeReassignedToARecoveredController() public {
        vm.prank(authority);
        registry.registerDid(DID_HASH, ROOT, victim, _sign(victimKey, DID_HASH, ROOT));

        // The controller loses their key; a new one is issued.
        uint256 replacementKey = 0xC0FFEE;
        address replacement = vm.addr(replacementKey);

        vm.prank(authority);
        registry.reassignAnchor(DID_HASH, replacement, _sign(replacementKey, DID_HASH, ROOT));

        (, address owner,, uint64 epoch,,) = registry.getAnchor(DID_HASH);
        assertEq(owner, replacement, "the anchor moves to the recovered controller");
        assertEq(epoch, 1, "presentations made under the old controller are no longer current");

        // The old controller can no longer publish roots.
        vm.prank(victim);
        vm.expectRevert(IdentityRegistry.NotOwner.selector);
        registry.updateRoot(DID_HASH, bytes32(uint256(2)));

        // The new one can.
        vm.prank(replacement);
        registry.updateRoot(DID_HASH, bytes32(uint256(2)));
    }

    function test_reassignIsAuthorityGatedAndNeedsTheNewControllersSignature() public {
        vm.prank(authority);
        registry.registerDid(DID_HASH, ROOT, victim, _sign(victimKey, DID_HASH, ROOT));

        vm.prank(outsider);
        vm.expectRevert(IdentityRegistry.NotAuthority.selector);
        registry.reassignAnchor(DID_HASH, attacker, _sign(attackerKey, DID_HASH, ROOT));

        // Right caller, but a signature from the wrong key.
        vm.prank(authority);
        vm.expectRevert(IdentityRegistry.InvalidSignature.selector);
        registry.reassignAnchor(DID_HASH, attacker, _sign(victimKey, DID_HASH, ROOT));
    }

    function test_reassignRejectsAnUnknownDid() public {
        vm.prank(authority);
        vm.expectRevert(IdentityRegistry.NotRegistered.selector);
        registry.reassignAnchor(DID_HASH, attacker, _sign(attackerKey, DID_HASH, ROOT));
    }

    // ── Ownership handover (M-8) ─────────────────────────────────────────────

    /// @notice The authority is the only role that can register or recover anything, so it does not
    ///         move to an address that has not proved it can act.
    function test_authorityHandoverIsTwoStep() public {
        vm.prank(authority);
        registry.transferAuthority(newAuthority);

        assertEq(registry.authority(), authority, "step 1 nominates, it does not hand over");
        assertEq(registry.pendingAuthority(), newAuthority);

        vm.prank(outsider);
        vm.expectRevert(IdentityRegistry.NotAuthority.selector);
        registry.acceptAuthority();

        vm.prank(newAuthority);
        registry.acceptAuthority();

        assertEq(registry.authority(), newAuthority);
        assertEq(registry.pendingAuthority(), address(0));
    }

    function test_pendingAuthorityCanBeCancelled() public {
        vm.startPrank(authority);
        registry.transferAuthority(newAuthority);
        registry.transferAuthority(address(0));
        vm.stopPrank();

        vm.prank(newAuthority);
        vm.expectRevert(IdentityRegistry.NotAuthority.selector);
        registry.acceptAuthority();

        assertEq(registry.authority(), authority);
    }

    // ── Issuer registry (S-11) ───────────────────────────────────────────────

    /// @notice Deactivation emits its own event, so an indexer watching for registrations cannot
    ///         read a revocation as one.
    function test_deactivationEmitsItsOwnEvent() public {
        bytes32 issuer = keccak256("did:atria:issuer");

        vm.startPrank(authority);
        registry.registerIssuer(issuer, bytes32(uint256(1)), "https://schema.atria.kg/v1");

        vm.expectEmit(true, false, false, true);
        emit IdentityRegistry.IssuerDeactivated(issuer);
        registry.deactivateIssuer(issuer);
        vm.stopPrank();

        (,, bool active,,) = registry.getIssuer(issuer);
        assertFalse(active);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    /// @dev Builds the EIP-191 personal-sign signature the registry expects.
    function _sign(uint256 key, bytes32 didHash, bytes32 root) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(didHash, root, block.chainid, address(registry)));
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
