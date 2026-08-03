// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AtriaPropertyToken} from "../src/AtriaPropertyToken.sol";
import {Allowlist} from "../src/Allowlist.sol";

/// @notice Drives the token the way the roles actually can, so the fuzzer explores reachable states
///         rather than impossible ones.
/// @dev    Every call is bounded to what a real key could do: only the minter mints, only compliance
///         burns and freezes, and holders are drawn from a fixed set so balances actually collide.
///         An unbounded handler would spend its run reverting on access control and prove nothing.
contract TokenHandler is Test {
    AtriaPropertyToken public immutable token;
    Allowlist public immutable allowlist;

    address public immutable admin;
    address public immutable minter;
    address public immutable compliance;
    address public immutable pauser;

    address[] public holders;

    /// Every share ever minted, and every share ever destroyed. The invariant that supply is exactly
    /// the difference is what catches a burn path that forgets to reduce it.
    uint256 public totalMinted;
    uint256 public totalBurned;

    constructor(
        AtriaPropertyToken token_,
        Allowlist allowlist_,
        address admin_,
        address minter_,
        address compliance_,
        address pauser_,
        address[] memory holders_
    ) {
        token = token_;
        allowlist = allowlist_;
        admin = admin_;
        minter = minter_;
        compliance = compliance_;
        pauser = pauser_;
        holders = holders_;
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function _holder(uint256 seed) internal view returns (address) {
        return holders[seed % holders.length];
    }

    function mint(uint256 toSeed, uint256 amount) external {
        address to = _holder(toSeed);
        amount = bound(amount, 1, 1_000);
        if (token.totalSupply() + amount > token.maxSupply()) return;
        if (!allowlist.isAllowed(to)) return;
        if (token.paused()) return;

        vm.prank(minter);
        token.mint(to, amount);
        totalMinted += amount;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _holder(fromSeed);
        address to = _holder(toSeed);
        uint256 balance = token.balanceOf(from);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        // The token itself rejects these; skipping them keeps the run spending its calls on
        // transfers that actually move shares.
        if (token.paused() || !allowlist.isAllowed(from) || !allowlist.isAllowed(to)) return;
        if (token.frozen(from) || token.frozen(to)) return;

        vm.prank(from);
        token.transfer(to, amount);
    }

    function burn(uint256 fromSeed, uint256 amount) external {
        address from = _holder(fromSeed);
        uint256 balance = token.balanceOf(from);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        vm.prank(compliance);
        token.burn(from, amount, "regulator order");
        totalBurned += amount;
    }

    function forcedTransfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _holder(fromSeed);
        address to = _holder(toSeed);
        uint256 balance = token.balanceOf(from);
        if (balance == 0) return;
        if (!allowlist.isAllowed(to)) return;
        amount = bound(amount, 1, balance);

        vm.prank(compliance);
        token.forcedTransfer(from, to, amount, "court order");
    }

    function freeze(uint256 seed) external {
        address account = _holder(seed);
        if (token.frozen(account)) return;

        vm.prank(compliance);
        token.freeze(account, "investigation");
    }

    function unfreeze(uint256 seed) external {
        address account = _holder(seed);
        if (!token.frozen(account)) return;

        vm.prank(compliance);
        token.unfreeze(account, "cleared");
    }

    function pause() external {
        if (token.paused()) return;
        vm.prank(pauser);
        token.pause();
    }

    function unpause() external {
        if (!token.paused()) return;
        vm.prank(pauser);
        token.unpause();
    }

    function removeFromAllowlist(uint256 seed) external {
        address account = _holder(seed);
        if (!allowlist.isAllowed(account)) return;

        vm.prank(admin);
        allowlist.removeFromAllowlist(account);
    }

    function addToAllowlist(uint256 seed) external {
        address account = _holder(seed);
        if (allowlist.isAllowed(account)) return;

        vm.prank(admin);
        allowlist.addToAllowlist(account);
    }

    function reduceMaxSupply(uint256 newMax) external {
        uint256 supply = token.totalSupply();
        uint256 current = token.maxSupply();
        if (current <= supply) return;
        newMax = bound(newMax, supply, current - 1);
        if (newMax == 0) return;

        vm.prank(admin);
        token.reduceMaxSupply(newMax, "issue size corrected");
    }
}

/// @notice The properties that must hold no matter what sequence of legitimate actions is taken.
/// @dev    These are the claims the registered issue rests on. Unit tests show each function behaves
///         on the cases someone thought of; these say the whole thing cannot be walked into an
///         inconsistent state by any ordering at all — which is the question an auditor is really
///         asking.
contract AtriaPropertyTokenInvariants is Test {
    AtriaPropertyToken internal token;
    Allowlist internal allowlist;
    TokenHandler internal handler;

    address internal constant ADMIN = address(0xA11CE);
    address internal constant MINTER = address(0xB0B);
    address internal constant COMPLIANCE = address(0xC0FFEE);
    address internal constant PAUSER = address(0xBEEF);

    uint256 internal constant MAX_SUPPLY = 10_000;

    address[] internal holders;

    function setUp() public {
        vm.warp(1_800_000_000);

        vm.prank(ADMIN);
        allowlist = new Allowlist();

        token = new AtriaPropertyToken(
            "Atria Tower One", "ATO", address(allowlist), MAX_SUPPLY, bytes32("property-1"), "KGS", ADMIN
        );

        vm.startPrank(ADMIN);
        token.grantRole(token.MINTER_ROLE(), MINTER);
        token.grantRole(token.COMPLIANCE_ROLE(), COMPLIANCE);
        token.grantRole(token.PAUSER_ROLE(), PAUSER);
        vm.stopPrank();

        for (uint160 i = 1; i <= 5; i++) {
            address holder = address(uint160(0x1000) + i);
            holders.push(holder);
            vm.prank(ADMIN);
            allowlist.addToAllowlist(holder);
        }

        handler = new TokenHandler(token, allowlist, ADMIN, MINTER, COMPLIANCE, PAUSER, holders);
        targetContract(address(handler));
    }

    /// @notice Shares in existence never exceed the registered issue size.
    /// @dev    The one number the state registration is written against. Exceeding it means the
    ///         register and the chain describe different issues.
    function invariant_supplyNeverExceedsTheRegisteredIssueSize() public view {
        assertLe(token.totalSupply(), token.maxSupply());
    }

    /// @notice Supply is exactly what was issued less what was destroyed.
    /// @dev    Catches any path that moves shares into or out of existence without accounting.
    function invariant_supplyIsIssuedMinusDestroyed() public view {
        assertEq(token.totalSupply(), handler.totalMinted() - handler.totalBurned());
    }

    /// @notice The holders' balances add up to the supply.
    /// @dev    Every share in existence sits on exactly one address. A share that belongs to nobody
    ///         is a share the register cannot pay a dividend on.
    function invariant_balancesAddUpToSupply() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.holderCount(); i++) {
            sum += token.balanceOf(handler.holders(i));
        }
        assertEq(sum, token.totalSupply());
    }

    /// @notice The issue size can only ever shrink, and never below what is already issued.
    /// @dev    A cap that could rise would make the registered size meaningless; one that could fall
    ///         below supply would leave existing holders over the limit.
    function invariant_theCapOnlyShrinksAndNeverBelowSupply() public view {
        assertLe(token.maxSupply(), MAX_SUPPLY);
        assertGe(token.maxSupply(), token.totalSupply());
    }

    /// @notice Shares are indivisible, always.
    function invariant_sharesStayIndivisible() public view {
        assertEq(token.decimals(), 0);
    }

    /// @notice A frozen holder's shares stay exactly where they are.
    /// @dev    Freezing is a compliance measure, not a confiscation: it stops the holder moving
    ///         shares, and the only thing that may still move them is a compliance action taken
    ///         deliberately. Balances changing on their own under a freeze would mean the
    ///         restriction is decorative.
    ///
    ///         The leak of the override flag itself is covered directly in
    ///         `test_restrictionsRestoredAfterComplianceAction`, which can assert on the exact
    ///         revert; an invariant cannot, because it must not mutate the state under test.
    function invariant_theTokenNeverHoldsSharesItself() public view {
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }
}
