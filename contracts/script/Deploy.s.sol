// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MockUSDC } from "../src/MockUSDC.sol";
import { MockReputation } from "../src/MockReputation.sol";
import { ArenaRegistry } from "../src/ArenaRegistry.sol";
import { OddsOracle } from "../src/OddsOracle.sol";
import { BetMarket } from "../src/BetMarket.sol";
import { ERC8004ReputationAdapter } from "../src/ERC8004ReputationAdapter.sol";
import { IReputation } from "../src/interfaces/IReputation.sol";
import { IAlloraConsumer } from "../src/interfaces/IAlloraConsumer.sol";
import { IERC8004Reputation } from "../src/interfaces/IERC8004Reputation.sol";

/// @notice One-shot deploy of the full MAPA stack.
///         Sepolia (5003) → deploys MockUSDC, real ERC-8004 reputation read from env.
///         Mainnet (5000) → uses canonical USDC (0x09Bc4E0D…) and mainnet ERC-8004 from env.
///         Run: `forge script script/Deploy.s.sol --rpc-url mantle_sepolia --broadcast --verify`.
contract Deploy is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 5003;
    uint256 internal constant MAINNET_CHAIN_ID = 5000;
    uint256 internal constant STAKE_AMOUNT = 10 * 10 ** 6; // 10 USDC at 6 decimals

    struct Deployment {
        address usdc;
        address reputation;
        address registry;
        address oddsOracle;
        address betMarket;
        address adapter;
    }

    function run() external returns (Deployment memory d) {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address oracle = vm.addr(vm.envUint("ORACLE_PRIVATE_KEY"));
        address judge = vm.addr(vm.envUint("JUDGE_PRIVATE_KEY"));
        uint256 alloraTopicId = vm.envOr("ALLORA_TOPIC_ID", uint256(1));

        IERC8004Reputation erc8004;
        IERC20 usdcToken;
        bool needsMockUsdc;

        if (block.chainid == SEPOLIA_CHAIN_ID) {
            erc8004 = IERC8004Reputation(vm.envAddress("ERC_8004_REPUTATION_SEPOLIA"));
            needsMockUsdc = true; // no canonical USDC on Sepolia
        } else if (block.chainid == MAINNET_CHAIN_ID) {
            erc8004 = IERC8004Reputation(vm.envAddress("ERC_8004_REPUTATION_MAINNET"));
            usdcToken = IERC20(vm.envAddress("USDC_ADDRESS_MAINNET"));
        } else {
            revert("Deploy: unsupported chain");
        }

        console2.log("=============== MAPA DEPLOY ===============");
        console2.log("Chain ID:    ", block.chainid);
        console2.log("Deployer:    ", deployer);
        console2.log("Oracle:      ", oracle);
        console2.log("Judge:       ", judge);
        console2.log("ERC-8004:    ", address(erc8004));
        console2.log("Allora topic:", alloraTopicId);
        console2.log("===========================================");

        vm.startBroadcast(deployerPk);

        if (needsMockUsdc) {
            MockUSDC m = new MockUSDC();
            usdcToken = IERC20(address(m));
            d.usdc = address(m);
        } else {
            d.usdc = address(usdcToken);
        }

        MockReputation reputation = new MockReputation(deployer);
        d.reputation = address(reputation);

        ArenaRegistry registry = new ArenaRegistry(usdcToken, STAKE_AMOUNT, deployer);
        d.registry = address(registry);

        OddsOracle oddsOracle =
            new OddsOracle(IReputation(address(reputation)), IAlloraConsumer(address(0)), alloraTopicId, deployer);
        d.oddsOracle = address(oddsOracle);

        BetMarket betMarket = new BetMarket(usdcToken, registry, oracle, deployer, deployer);
        d.betMarket = address(betMarket);

        ERC8004ReputationAdapter adapter = new ERC8004ReputationAdapter(erc8004, judge, deployer);
        d.adapter = address(adapter);

        // Wire BetMarket as the only authorised activity reporter on the registry.
        registry.setActivityReporter(address(betMarket));

        vm.stopBroadcast();

        console2.log("=============== DEPLOYED ADDRESSES ===============");
        console2.log("MockUSDC / USDC:        ", d.usdc);
        console2.log("MockReputation:         ", d.reputation);
        console2.log("ArenaRegistry:          ", d.registry);
        console2.log("OddsOracle:             ", d.oddsOracle);
        console2.log("BetMarket:              ", d.betMarket);
        console2.log("ERC8004Adapter:         ", d.adapter);
        console2.log("==================================================");
        console2.log("Wired: registry.activityReporter = BetMarket");
        console2.log("Next: paste addresses into .env.local + README 'Deployed Addresses'");
    }
}
