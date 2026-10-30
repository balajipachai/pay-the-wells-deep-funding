// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {DeepFunding} from "../src/DeepFunding.sol";

/// @notice Deploys the contract and funds the pot, in one broadcast. Inputs come from the environment
///         (see `.env.example`). The signer comes from the CLI (`--account <keystore> --sender <address>`),
///         so no key is read from any file. The deployer gets no powers: the contract has no owner.
contract Deploy is Script {
    function run() external returns (DeepFunding fund) {
        address deployer = vm.envAddress("DEPLOYER");
        address[] memory jurors = vm.envAddress("JURORS", ",");
        bytes32 graphHash = vm.envBytes32("GRAPH_HASH");
        uint16 packageCount = uint16(vm.envUint("PACKAGE_COUNT"));
        uint256 judgmentDeadline = block.timestamp + vm.envUint("JUDGING_SECONDS");
        uint256 disputeWindow = vm.envUint("DISPUTE_WINDOW_SECONDS");
        uint256 bond = vm.envUint("DISPUTE_BOND_WEI");
        address bondSink = vm.envAddress("BOND_SINK");
        uint256 potWei = vm.envOr("POT_WEI", uint256(0));

        vm.startBroadcast(deployer);
        fund = new DeepFunding(jurors, graphHash, packageCount, judgmentDeadline, disputeWindow, bond, bondSink);
        if (potWei > 0) fund.fundPot{value: potWei}();
        vm.stopBroadcast();

        console.log("DeepFunding deployed at", address(fund));
        console.log("judging closes", judgmentDeadline);
    }
}
