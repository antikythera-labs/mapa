// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import { ArenaRegistry } from "../src/ArenaRegistry.sol";
import { MockUSDC } from "../src/MockUSDC.sol";

contract ArenaRegistryTest is Test {
    ArenaRegistry internal registry;
    MockUSDC internal usdc;

    address internal admin = address(0xAD);
    address internal reporter = address(0xBE7);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal agentAddr = address(0xA9E47);

    uint256 internal constant STAKE = 10 * 10 ** 6; // 10 USDC

    event AgentRegistered(
        uint256 indexed agentId, address indexed agent, address indexed owner, string name, uint256 stake
    );
    event StakeWithdrawn(uint256 indexed agentId, address indexed owner, uint256 amount);
    event ActivityRecorded(uint256 indexed agentId, uint256 timestamp);
    event ActivityReporterSet(address indexed previous, address indexed next);

    function setUp() public {
        usdc = new MockUSDC();
        registry = new ArenaRegistry(IERC20(address(usdc)), STAKE, admin);

        usdc.mint(alice, 100 * 10 ** 6);
        usdc.mint(bob, 100 * 10 ** 6);
    }

    function _register(address caller, address agent_, string memory name, address agentOwner)
        internal
        returns (uint256 id)
    {
        vm.prank(caller);
        usdc.approve(address(registry), STAKE);
        vm.prank(caller);
        id = registry.registerAgent(agent_, name, agentOwner);
    }

    // ------------------------- constructor -------------------------

    function test_ConstructorStoresImmutables() public view {
        assertEq(address(registry.usdc()), address(usdc));
        assertEq(registry.stakeAmount(), STAKE);
        assertEq(registry.owner(), admin);
        assertEq(registry.nextAgentId(), 1);
    }

    function test_ConstructorRevertsOnZeroUSDC() public {
        vm.expectRevert(ArenaRegistry.ZeroAddress.selector);
        new ArenaRegistry(IERC20(address(0)), STAKE, admin);
    }

    function test_ConstructorRevertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new ArenaRegistry(IERC20(address(usdc)), STAKE, address(0));
    }

    // ------------------------- registerAgent -------------------------

    function test_RegisterAgentHappyPath() public {
        vm.prank(alice);
        usdc.approve(address(registry), STAKE);

        vm.expectEmit(true, true, true, true, address(registry));
        emit AgentRegistered(1, agentAddr, alice, "claude-sonnet-quant", STAKE);

        vm.prank(alice);
        uint256 id = registry.registerAgent(agentAddr, "claude-sonnet-quant", alice);

        assertEq(id, 1);
        assertEq(registry.nextAgentId(), 2);
        assertEq(registry.agentIdOf(agentAddr), 1);
        assertEq(usdc.balanceOf(address(registry)), STAKE);
        assertEq(usdc.balanceOf(alice), 100 * 10 ** 6 - STAKE);

        ArenaRegistry.AgentInfo memory info = registry.getAgent(1);
        assertEq(info.agent, agentAddr);
        assertEq(info.owner, alice);
        assertEq(info.name, "claude-sonnet-quant");
        assertEq(info.stake, STAKE);
        assertEq(info.registeredAt, block.timestamp);
        assertEq(info.lastActiveAt, block.timestamp);
        assertTrue(info.active);
    }

    function test_RegisterAgentAllowsSponsorPayingForExternalOwner() public {
        // alice pays the stake, bob is recorded as owner — sponsor flow
        vm.prank(alice);
        usdc.approve(address(registry), STAKE);
        vm.prank(alice);
        uint256 id = registry.registerAgent(agentAddr, "bob-agent", bob);

        assertEq(registry.getAgent(id).owner, bob);
        assertEq(usdc.balanceOf(alice), 100 * 10 ** 6 - STAKE);
    }

    function test_RegisterAgentIncrementsIds() public {
        _register(alice, address(0x1), "a1", alice);
        _register(bob, address(0x2), "a2", bob);
        _register(alice, address(0x3), "a3", alice);

        assertEq(registry.agentIdOf(address(0x1)), 1);
        assertEq(registry.agentIdOf(address(0x2)), 2);
        assertEq(registry.agentIdOf(address(0x3)), 3);
        assertEq(registry.nextAgentId(), 4);
    }

    function test_RegisterAgentRevertsOnDuplicateAgent() public {
        _register(alice, agentAddr, "first", alice);

        vm.prank(bob);
        usdc.approve(address(registry), STAKE);
        vm.expectRevert(abi.encodeWithSelector(ArenaRegistry.AlreadyRegistered.selector, agentAddr));
        vm.prank(bob);
        registry.registerAgent(agentAddr, "second", bob);
    }

    function test_RegisterAgentRevertsOnZeroAgentAddress() public {
        vm.expectRevert(ArenaRegistry.ZeroAddress.selector);
        vm.prank(alice);
        registry.registerAgent(address(0), "x", alice);
    }

    function test_RegisterAgentRevertsOnZeroOwner() public {
        vm.expectRevert(ArenaRegistry.ZeroAddress.selector);
        vm.prank(alice);
        registry.registerAgent(agentAddr, "x", address(0));
    }

    function test_RegisterAgentRevertsWithoutAllowance() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(registry), 0, STAKE)
        );
        vm.prank(alice);
        registry.registerAgent(agentAddr, "x", alice);
    }

    function test_RegisterAgentRevertsWithoutBalance() public {
        address poor = address(0xDEAD);
        vm.prank(poor);
        usdc.approve(address(registry), STAKE);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, poor, 0, STAKE));
        vm.prank(poor);
        registry.registerAgent(agentAddr, "x", poor);
    }

    // ------------------------- setActivityReporter -------------------------

    function test_SetActivityReporterByOwner() public {
        vm.expectEmit(true, true, false, true, address(registry));
        emit ActivityReporterSet(address(0), reporter);

        vm.prank(admin);
        registry.setActivityReporter(reporter);
        assertEq(registry.activityReporter(), reporter);
    }

    function test_SetActivityReporterRevertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        registry.setActivityReporter(reporter);
    }

    // ------------------------- notifyActivity -------------------------

    function test_NotifyActivityUpdatesLastActiveAt() public {
        uint256 id = _register(alice, agentAddr, "x", alice);
        vm.prank(admin);
        registry.setActivityReporter(reporter);

        vm.warp(block.timestamp + 3 days);

        vm.expectEmit(true, false, false, true, address(registry));
        emit ActivityRecorded(id, block.timestamp);
        vm.prank(reporter);
        registry.notifyActivity(id);

        assertEq(registry.getAgent(id).lastActiveAt, block.timestamp);
    }

    function test_NotifyActivityRevertsForNonReporter() public {
        uint256 id = _register(alice, agentAddr, "x", alice);

        vm.expectRevert(ArenaRegistry.NotActivityReporter.selector);
        vm.prank(alice);
        registry.notifyActivity(id);
    }

    function test_NotifyActivityRevertsForUnknownAgent() public {
        vm.prank(admin);
        registry.setActivityReporter(reporter);

        vm.expectRevert(abi.encodeWithSelector(ArenaRegistry.UnknownAgent.selector, uint256(999)));
        vm.prank(reporter);
        registry.notifyActivity(999);
    }

    function test_NotifyActivityRevertsAfterWithdraw() public {
        uint256 id = _register(alice, agentAddr, "x", alice);
        vm.prank(admin);
        registry.setActivityReporter(reporter);

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(alice);
        registry.withdrawStake(id);

        vm.expectRevert(ArenaRegistry.AgentInactive.selector);
        vm.prank(reporter);
        registry.notifyActivity(id);
    }

    // ------------------------- withdrawStake -------------------------

    function test_WithdrawStakeRevertsBeforeWindow() public {
        uint256 id = _register(alice, agentAddr, "x", alice);

        uint256 unlocksAt = block.timestamp + 7 days;
        vm.warp(block.timestamp + 7 days - 1);

        vm.expectRevert(abi.encodeWithSelector(ArenaRegistry.NotInactiveYet.selector, unlocksAt));
        vm.prank(alice);
        registry.withdrawStake(id);
    }

    function test_WithdrawStakeRevertsForNonOwner() public {
        uint256 id = _register(alice, agentAddr, "x", alice);
        vm.warp(block.timestamp + 7 days + 1);

        vm.expectRevert(ArenaRegistry.NotAgentOwner.selector);
        vm.prank(bob);
        registry.withdrawStake(id);
    }

    function test_WithdrawStakeRevertsOnUnknownAgent() public {
        vm.expectRevert(abi.encodeWithSelector(ArenaRegistry.UnknownAgent.selector, uint256(42)));
        vm.prank(alice);
        registry.withdrawStake(42);
    }

    function test_WithdrawStakeHappyPath() public {
        uint256 id = _register(alice, agentAddr, "x", alice);
        uint256 aliceBalBefore = usdc.balanceOf(alice);

        vm.warp(block.timestamp + 7 days + 1);

        vm.expectEmit(true, true, false, true, address(registry));
        emit StakeWithdrawn(id, alice, STAKE);
        vm.prank(alice);
        registry.withdrawStake(id);

        assertEq(usdc.balanceOf(alice), aliceBalBefore + STAKE);
        assertEq(usdc.balanceOf(address(registry)), 0);

        ArenaRegistry.AgentInfo memory info = registry.getAgent(id);
        assertEq(info.stake, 0);
        assertFalse(info.active);
        assertFalse(registry.isActive(id));
    }

    function test_WithdrawStakeRefreshExtendsDeadline() public {
        uint256 id = _register(alice, agentAddr, "x", alice);
        vm.prank(admin);
        registry.setActivityReporter(reporter);

        // 6 days in, reporter pings — clock resets
        vm.warp(block.timestamp + 6 days);
        vm.prank(reporter);
        registry.notifyActivity(id);

        // 6 more days (12 since registration) — still inside the new window
        vm.warp(block.timestamp + 6 days);
        uint256 unlocksAt = registry.getAgent(id).lastActiveAt + 7 days;
        vm.expectRevert(abi.encodeWithSelector(ArenaRegistry.NotInactiveYet.selector, unlocksAt));
        vm.prank(alice);
        registry.withdrawStake(id);

        // jump past the refreshed deadline
        vm.warp(unlocksAt + 1);
        vm.prank(alice);
        registry.withdrawStake(id);
        assertEq(usdc.balanceOf(address(registry)), 0);
    }

    function test_WithdrawStakeRevertsOnDoubleWithdraw() public {
        uint256 id = _register(alice, agentAddr, "x", alice);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(alice);
        registry.withdrawStake(id);

        vm.expectRevert(ArenaRegistry.AgentInactive.selector);
        vm.prank(alice);
        registry.withdrawStake(id);
    }
}
