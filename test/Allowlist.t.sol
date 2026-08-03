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
        allowlist = new Allowlist();
        allowlist.setAgent(agent, true);
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

    function test_ownershipTransferDropsPreviousOwnerAgentRights() public {
        allowlist.transferOwnership(newOwner);

        assertEq(allowlist.owner(), newOwner);
        assertTrue(allowlist.agents(newOwner));
        assertFalse(allowlist.agents(owner));

        vm.expectRevert(Allowlist.NotAuthorized.selector);
        allowlist.addToAllowlist(investor);
    }

    function test_onlyOwnerSetsAgents() public {
        vm.prank(agent);
        vm.expectRevert(Allowlist.NotAuthorized.selector);
        allowlist.setAgent(outsider, true);
    }
}
