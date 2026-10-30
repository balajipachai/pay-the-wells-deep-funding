// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeepFunding} from "../src/DeepFunding.sol";

/// @notice Runs the engine's real, committed output (data/) through the contract, end to end:
///         every sample judgment goes on-chain, the Solidity digest must equal the TypeScript digest,
///         and every allocation is claimed with the engine's own Merkle proof.
contract EngineCrossCheckTest is Test {
    string internal result;
    string internal judgmentsJson;
    DeepFunding internal fund;
    address[] internal jurors;
    uint256 internal pot;
    uint256 internal deadline;

    function _deploy() internal {
        result = vm.readFile("data/result.json");
        judgmentsJson = vm.readFile("data/judgments.json");
        pot = vm.parseUint(vm.parseJsonString(result, ".pot"));
        jurors = vm.parseJsonAddressArray(result, ".jurors");
        deadline = block.timestamp + 1 days;
        address at = vm.parseJsonAddress(result, ".contract");
        deployCodeTo(
            "DeepFunding.sol:DeepFunding",
            abi.encode(jurors, vm.parseJsonBytes32(result, ".graphHash"), uint16(16), deadline, uint256(3 days), uint256(0.1 ether), makeAddr("sink")),
            at
        );
        fund = DeepFunding(at);
        address sponsor = makeAddr("sponsor");
        vm.deal(sponsor, pot);
        vm.prank(sponsor);
        fund.fundPot{value: pot}();
    }

    function _submitAll() internal {
        uint256 count = vm.parseJsonUint(result, ".judgmentCount");
        for (uint256 i = 0; i < count; i++) {
            string memory k = string.concat("$[", vm.toString(i), "]");
            DeepFunding.Judgment[] memory one = new DeepFunding.Judgment[](1);
            one[0] = DeepFunding.Judgment(
                uint16(vm.parseJsonUint(judgmentsJson, string.concat(k, ".parent"))),
                uint16(vm.parseJsonUint(judgmentsJson, string.concat(k, ".a"))),
                uint16(vm.parseJsonUint(judgmentsJson, string.concat(k, ".b"))),
                uint8(vm.parseJsonUint(judgmentsJson, string.concat(k, ".outcome")))
            );
            vm.prank(vm.parseJsonAddress(judgmentsJson, string.concat(k, ".juror")));
            fund.submitJudgments(one);
        }
        assertEq(fund.judgmentCount(), count);
    }

    function _claimAll() internal returns (uint256 paid) {
        uint256 n = vm.parseJsonKeys(result, ".proofs").length;
        for (uint256 i = 0; i < n; i++) {
            string memory k = string.concat(".allocations[", vm.toString(i), "]");
            address recipient = vm.parseJsonAddress(result, string.concat(k, ".recipient"));
            uint256 amount = vm.parseUint(vm.parseJsonString(result, string.concat(k, ".amount")));
            fund.claim(recipient, amount, vm.parseJsonBytes32Array(result, string.concat('.proofs["', vm.toString(recipient), '"]')));
            assertEq(recipient.balance, amount);
            paid += amount;
        }
    }

    function test_sampleResultSurvivesTheWholeContractLifecycle() public {
        _deploy();
        _submitAll();
        assertEq(fund.judgmentsDigest(), vm.parseJsonBytes32(result, ".judgmentsDigest"), "Solidity and TypeScript digests agree");

        vm.warp(deadline + 1);
        vm.prank(jurors[0]);
        fund.propose(vm.parseJsonBytes32(result, ".root"));
        vm.warp(block.timestamp + 3 days);
        fund.finalize();

        assertEq(_claimAll(), pot, "every wei of the pot reached a recipient");
        assertEq(address(fund).balance, 0);
    }
}
