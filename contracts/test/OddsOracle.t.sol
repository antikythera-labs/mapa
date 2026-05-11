// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { OddsOracle } from "../src/OddsOracle.sol";
import { MockReputation } from "../src/MockReputation.sol";
import { IReputation } from "../src/interfaces/IReputation.sol";
import { IAlloraConsumer } from "../src/interfaces/IAlloraConsumer.sol";

contract MockAllora is IAlloraConsumer {
    int256 public nextInference;
    bool public shouldRevert;

    function setInference(int256 v) external {
        nextInference = v;
    }

    function setRevert(bool v) external {
        shouldRevert = v;
    }

    function getInferenceByTopicId(uint256) external view returns (int256, uint256) {
        if (shouldRevert) revert("allora down");
        return (nextInference, block.timestamp);
    }
}

contract OddsOracleTest is Test {
    OddsOracle internal oracle;
    MockReputation internal rep;
    MockAllora internal allora;

    address internal admin = address(0xAD);
    address internal stranger = address(0xBAD);

    event AlloraConfigSet(address indexed consumer, uint256 topicId);

    function setUp() public {
        rep = new MockReputation(admin);
        allora = new MockAllora();
        oracle = new OddsOracle(IReputation(address(rep)), IAlloraConsumer(address(0)), 1, admin);
    }

    function _setElo(uint256 id, uint256 elo) internal {
        vm.prank(admin);
        rep.setElo(id, elo);
    }

    // ─────────────────────────── constructor ───────────────────────────

    function test_ConstructorStoresState() public view {
        assertEq(address(oracle.reputation()), address(rep));
        assertEq(address(oracle.allora()), address(0));
        assertEq(oracle.alloraTopicId(), 1);
        assertEq(oracle.owner(), admin);
        assertEq(oracle.ODDS_SCALE(), 1e6);
    }

    function test_ConstructorRevertsOnZeroReputation() public {
        vm.expectRevert(OddsOracle.ZeroAddress.selector);
        new OddsOracle(IReputation(address(0)), IAlloraConsumer(address(0)), 1, admin);
    }

    function test_ConstructorAcceptsZeroAllora() public {
        OddsOracle o = new OddsOracle(IReputation(address(rep)), IAlloraConsumer(address(0)), 1, admin);
        assertEq(address(o.allora()), address(0));
    }

    // ─────────────────────────── getOdds (pure Elo) ───────────────────────────

    function test_OddsEqualAgentsFiftyFifty() public {
        _setElo(1, 1500);
        _setElo(2, 1500);
        (uint256 oddsA, uint256 oddsB) = oracle.getOdds(1, 2);
        assertEq(oddsA, 500_000);
        assertEq(oddsB, 500_000);
        assertEq(oddsA + oddsB, 1e6);
    }

    function test_OddsAgentAStrongerBy200() public {
        _setElo(1, 1700);
        _setElo(2, 1500);
        (uint256 oddsA, uint256 oddsB) = oracle.getOdds(1, 2);
        assertEq(oddsA, 760_000); // 76.00% from table
        assertEq(oddsB, 240_000);
    }

    function test_OddsAgentBStrongerBy200() public {
        _setElo(1, 1500);
        _setElo(2, 1700);
        (uint256 oddsA, uint256 oddsB) = oracle.getOdds(1, 2);
        assertEq(oddsA, 240_000);
        assertEq(oddsB, 760_000);
    }

    function test_OddsClampAtPlus800() public {
        _setElo(1, 3000);
        _setElo(2, 1000);
        (uint256 oddsA, uint256 oddsB) = oracle.getOdds(1, 2);
        assertEq(oddsA, 990_000); // capped
        assertEq(oddsB, 10_000);
    }

    function test_OddsClampAtMinus800() public {
        _setElo(1, 1000);
        _setElo(2, 3000);
        (uint256 oddsA, uint256 oddsB) = oracle.getOdds(1, 2);
        assertEq(oddsA, 10_000);
        assertEq(oddsB, 990_000);
    }

    function test_OddsDefaultsToDefaultEloForUnseededAgent() public {
        _setElo(1, 1700);
        // agent 2 has no Elo set → defaults to 1500 → diff 200 → 76/24
        (uint256 oddsA, uint256 oddsB) = oracle.getOdds(1, 2);
        assertEq(oddsA, 760_000);
        assertEq(oddsB, 240_000);
    }

    function test_OddsBothUnseededFiftyFifty() public view {
        (uint256 oddsA, uint256 oddsB) = oracle.getOdds(1, 2);
        assertEq(oddsA, 500_000);
        assertEq(oddsB, 500_000);
    }

    function test_OddsTableMatchesEloFormula() public {
        // Verify all 9 table values match the documented Elo expected-score curve.
        uint256[9] memory expectedA = [
            uint256(500_000),
            uint256(640_000),
            uint256(760_000),
            uint256(849_000),
            uint256(909_000),
            uint256(946_000),
            uint256(969_000),
            uint256(983_000),
            uint256(990_000)
        ];
        for (uint256 i = 0; i < 9; i++) {
            _setElo(1, 1500 + (i * 100));
            _setElo(2, 1500);
            (uint256 oddsA, uint256 oddsB) = oracle.getOdds(1, 2);
            assertEq(oddsA, expectedA[i]);
            assertEq(oddsA + oddsB, 1e6);
        }
    }

    function testFuzz_OddsSumToScale(uint16 eloA, uint16 eloB) public {
        _setElo(1, uint256(eloA));
        _setElo(2, uint256(eloB));
        (uint256 oddsA, uint256 oddsB) = oracle.getOdds(1, 2);
        assertEq(oddsA + oddsB, 1e6);
        assertLe(oddsA, 1e6);
        assertLe(oddsB, 1e6);
    }

    // ─────────────────────────── Allora skew ───────────────────────────

    function _wireAllora() internal {
        vm.prank(admin);
        oracle.setAlloraConfig(allora, 1);
    }

    function test_AlloraPositiveSkewsTowardA() public {
        _setElo(1, 1500);
        _setElo(2, 1500);
        _wireAllora();
        allora.setInference(42);

        (uint256 oddsA, uint256 oddsB) = oracle.getOdds(1, 2);
        // 5000 bps + 100 skew = 5100 → 51% → 510_000
        assertEq(oddsA, 510_000);
        assertEq(oddsB, 490_000);
    }

    function test_AlloraNegativeSkewsTowardB() public {
        _setElo(1, 1500);
        _setElo(2, 1500);
        _wireAllora();
        allora.setInference(-7);

        (uint256 oddsA, uint256 oddsB) = oracle.getOdds(1, 2);
        assertEq(oddsA, 490_000);
        assertEq(oddsB, 510_000);
    }

    function test_AlloraZeroInferenceNoSkew() public {
        _setElo(1, 1500);
        _setElo(2, 1500);
        _wireAllora();
        allora.setInference(0);

        (uint256 oddsA,) = oracle.getOdds(1, 2);
        assertEq(oddsA, 500_000);
    }

    function test_AlloraRevertFallsBackToPureElo() public {
        _setElo(1, 1700);
        _setElo(2, 1500);
        _wireAllora();
        allora.setRevert(true);

        (uint256 oddsA, uint256 oddsB) = oracle.getOdds(1, 2);
        assertEq(oddsA, 760_000);
        assertEq(oddsB, 240_000);
    }

    function test_AlloraSkewClampsAtCeil() public {
        // pure Elo at +800 already at 9900; skew +100 would overflow → clamp to 9900
        _setElo(1, 3000);
        _setElo(2, 1500);
        _wireAllora();
        allora.setInference(42);

        (uint256 oddsA,) = oracle.getOdds(1, 2);
        assertEq(oddsA, 990_000); // unchanged after clamp
    }

    function test_AlloraSkewClampsAtFloor() public {
        // pure Elo at -800 already at 100; skew -100 would underflow → clamp to 100
        _setElo(1, 1500);
        _setElo(2, 3000);
        _wireAllora();
        allora.setInference(-1);

        (uint256 oddsA,) = oracle.getOdds(1, 2);
        assertEq(oddsA, 10_000); // 100 bps clamped
    }

    // ─────────────────────────── setAlloraConfig ───────────────────────────

    function test_SetAlloraConfigByOwner() public {
        vm.expectEmit(true, false, false, true, address(oracle));
        emit AlloraConfigSet(address(allora), 3);

        vm.prank(admin);
        oracle.setAlloraConfig(allora, 3);
        assertEq(address(oracle.allora()), address(allora));
        assertEq(oracle.alloraTopicId(), 3);
    }

    function test_SetAlloraConfigCanUnsetByZero() public {
        _wireAllora();
        vm.prank(admin);
        oracle.setAlloraConfig(IAlloraConsumer(address(0)), 0);
        assertEq(address(oracle.allora()), address(0));
    }

    function test_SetAlloraConfigRevertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        oracle.setAlloraConfig(allora, 1);
    }
}
