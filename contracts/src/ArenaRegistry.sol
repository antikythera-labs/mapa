// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ArenaRegistry
/// @notice Registry of AI trading agents that compete in MAPA. Each agent is staked in USDC.
///         Stake is locked while the agent is active and refundable after `INACTIVITY_WINDOW`
///         with no reported activity from `activityReporter` (typically BetMarket).
contract ArenaRegistry is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct AgentInfo {
        address agent; // on-chain trader identity (EOA controlled by off-chain LLM, or contract)
        address owner; // pays stake and is allowed to withdraw it
        string name;
        uint256 stake;
        uint64 registeredAt;
        uint64 lastActiveAt;
        bool active;
    }

    uint256 public constant INACTIVITY_WINDOW = 7 days;

    IERC20 public immutable usdc;
    uint256 public immutable stakeAmount;

    /// @notice Permissioned caller (BetMarket) authorised to refresh `lastActiveAt`.
    address public activityReporter;
    uint256 public nextAgentId = 1;

    mapping(uint256 agentId => AgentInfo) private _agents;
    mapping(address agent => uint256 agentId) public agentIdOf;

    event AgentRegistered(
        uint256 indexed agentId, address indexed agent, address indexed owner, string name, uint256 stake
    );
    event StakeWithdrawn(uint256 indexed agentId, address indexed owner, uint256 amount);
    event ActivityRecorded(uint256 indexed agentId, uint256 timestamp);
    event ActivityReporterSet(address indexed previous, address indexed next);

    error ZeroAddress();
    error AlreadyRegistered(address agent);
    error UnknownAgent(uint256 agentId);
    error NotAgentOwner();
    error NotActivityReporter();
    error AgentInactive();
    error NotInactiveYet(uint256 unlocksAt);

    constructor(IERC20 usdc_, uint256 stakeAmount_, address initialOwner) Ownable(initialOwner) {
        // Ownable already rejects initialOwner == address(0) via OwnableInvalidOwner.
        if (address(usdc_) == address(0)) revert ZeroAddress();
        usdc = usdc_;
        stakeAmount = stakeAmount_;
    }

    function setActivityReporter(address reporter) external onlyOwner {
        emit ActivityReporterSet(activityReporter, reporter);
        activityReporter = reporter;
    }

    /// @notice Register a new agent. `msg.sender` pays the stake; `owner_` controls future withdrawal.
    function registerAgent(address agent, string calldata name, address owner_)
        external
        nonReentrant
        returns (uint256 agentId)
    {
        if (agent == address(0) || owner_ == address(0)) revert ZeroAddress();
        if (agentIdOf[agent] != 0) revert AlreadyRegistered(agent);

        agentId = nextAgentId++;
        agentIdOf[agent] = agentId;

        _agents[agentId] = AgentInfo({
            agent: agent,
            owner: owner_,
            name: name,
            stake: stakeAmount,
            registeredAt: uint64(block.timestamp),
            lastActiveAt: uint64(block.timestamp),
            active: true
        });

        usdc.safeTransferFrom(msg.sender, address(this), stakeAmount);

        emit AgentRegistered(agentId, agent, owner_, name, stakeAmount);
    }

    /// @notice Refresh `lastActiveAt` for an agent. BetMarket calls this on match participation.
    function notifyActivity(uint256 agentId) external {
        if (msg.sender != activityReporter) revert NotActivityReporter();
        AgentInfo storage a = _agents[agentId];
        if (a.agent == address(0)) revert UnknownAgent(agentId);
        if (!a.active) revert AgentInactive();
        a.lastActiveAt = uint64(block.timestamp);
        emit ActivityRecorded(agentId, block.timestamp);
    }

    /// @notice Withdraw stake after `INACTIVITY_WINDOW` of no reported activity. One-shot — agent becomes inactive.
    function withdrawStake(uint256 agentId) external nonReentrant {
        AgentInfo storage a = _agents[agentId];
        if (a.agent == address(0)) revert UnknownAgent(agentId);
        if (msg.sender != a.owner) revert NotAgentOwner();
        if (!a.active) revert AgentInactive();

        uint256 unlocksAt = uint256(a.lastActiveAt) + INACTIVITY_WINDOW;
        if (block.timestamp < unlocksAt) revert NotInactiveYet(unlocksAt);

        uint256 amount = a.stake;
        a.stake = 0;
        a.active = false;

        usdc.safeTransfer(a.owner, amount);

        emit StakeWithdrawn(agentId, a.owner, amount);
    }

    function getAgent(uint256 agentId) external view returns (AgentInfo memory) {
        return _agents[agentId];
    }

    function isActive(uint256 agentId) external view returns (bool) {
        return _agents[agentId].active;
    }
}
