// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Allowlist} from "../src/Allowlist.sol";

contract AllowlistTest is Test {
    Allowlist internal allowlist;

    address internal owner = address(this);
    address internal agent = makeAddr("agent");
    address internal outsider = makeAddr("outsider");
    address internal investor = makeAddr("investor");
    address internal newOwner = makeAddr("newOwner");

    function setUp() public {
        // Owner and the backend agent are set at construction — the deploying key never owns the
        // list, so there is no window in which it does.
        allowlist = new Allowlist(owner, agent);
    }

    function test_agentCanAddAndRemove() public {
        vm.startPrank(agent);
        allowlist.addToAllowlist(investor);
        assertTrue(allowlist.isAllowed(investor));

        allowlist.removeFromAllowlist(investor);
        assertFalse(allowlist.isAllowed(investor));
        vm.stopPrank();
    }

    function test_outsiderCannotModify() public {
        vm.prank(outsider);
        vm.expectRevert(Allowlist.NotAuthorized.selector);
        allowlist.addToAllowlist(investor);
    }

    function test_revokedAgentCannotModify() public {
        allowlist.setAgent(agent, false);

        vm.prank(agent);
        vm.expectRevert(Allowlist.NotAuthorized.selector);
        allowlist.addToAllowlist(investor);
    }

    function test_zeroAddressCannotBeAllowed() public {
        vm.expectRevert(Allowlist.ZeroAddress.selector);
        allowlist.addToAllowlist(address(0));
    }

    function test_ownershipTransferIsTwoStepAndDropsPreviousOwnerAgentRights() public {
        allowlist.transferOwnership(newOwner);

        // Step 1 changes nothing but the nomination: control of this list is control of every
        // transfer the token permits, so it does not move to an address that has not proved it can
        // act. A mistyped address is still recoverable at this point.
        assertEq(allowlist.pendingOwner(), newOwner);
        assertEq(allowlist.owner(), owner);
        assertTrue(allowlist.agents(owner));

        // Nobody but the nominee can complete it.
        vm.prank(outsider);
        vm.expectRevert(Allowlist.NotAuthorized.selector);
        allowlist.acceptOwnership();

        vm.prank(newOwner);
        allowlist.acceptOwnership();

        assertEq(allowlist.owner(), newOwner);
        assertEq(allowlist.pendingOwner(), address(0));
        assertTrue(allowlist.agents(newOwner));
        assertFalse(allowlist.agents(owner));

        vm.expectRevert(Allowlist.NotAuthorized.selector);
        allowlist.addToAllowlist(investor);
    }

    function test_pendingOwnershipCanBeCancelled() public {
        allowlist.transferOwnership(newOwner);
        allowlist.transferOwnership(address(0));

        assertEq(allowlist.pendingOwner(), address(0));

        // The former nominee cannot claim a handover that was called off.
        vm.prank(newOwner);
        vm.expectRevert(Allowlist.NotAuthorized.selector);
        allowlist.acceptOwnership();

        assertEq(allowlist.owner(), owner);
    }

    function test_constructorSeatsTheOwnerAndAgentDirectly() public view {
        assertEq(allowlist.owner(), owner);
        assertTrue(allowlist.agents(owner));
        assertTrue(allowlist.agents(agent));
        assertEq(allowlist.pendingOwner(), address(0));
    }

    function test_ownerCannotBeZero() public {
        vm.expectRevert(Allowlist.ZeroAddress.selector);
        new Allowlist(address(0), agent);
    }

    function test_onlyOwnerSetsAgents() public {
        vm.prank(agent);
        vm.expectRevert(Allowlist.NotAuthorized.selector);
        allowlist.setAgent(outsider, true);
    }
}
