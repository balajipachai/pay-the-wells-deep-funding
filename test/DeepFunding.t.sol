// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeepFunding} from "../src/DeepFunding.sol";

/// @dev Sorted-pair Merkle tree matching OpenZeppelin's MerkleProof (an unpaired node is promoted).
library TestMerkle {
    function _pair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            bytes32[] memory next = new bytes32[]((level.length + 1) / 2);
            for (uint256 i = 0; i < next.length; i++) {
                next[i] = (2 * i + 1 < level.length) ? _pair(level[2 * i], level[2 * i + 1]) : level[2 * i];
            }
            level = next;
        }
        return level[0];
    }

    function proof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory out) {
        out = new bytes32[](32);
        uint256 n;
        bytes32[] memory level = leaves;
        uint256 idx = index;
        while (level.length > 1) {
            uint256 sib = idx ^ 1;
            if (sib < level.length) out[n++] = level[sib];
            bytes32[] memory next = new bytes32[]((level.length + 1) / 2);
            for (uint256 i = 0; i < next.length; i++) {
                next[i] = (2 * i + 1 < level.length) ? _pair(level[2 * i], level[2 * i + 1]) : level[2 * i];
            }
            level = next;
            idx /= 2;
        }
        assembly {
            mstore(out, n)
        }
    }
}

contract ReentrantClaimer {
    DeepFunding public fund;
    uint256 public amount;
    bytes32[] public proof;
    uint256 public attempts;
    bool public reenterSucceeded;

    function set(DeepFunding f, uint256 a, bytes32[] memory p) external {
        fund = f;
        amount = a;
        proof = p;
    }

    receive() external payable {
        attempts++;
        if (attempts < 3) {
            try fund.claim(address(this), amount, proof) {
                reenterSucceeded = true;
            } catch {}
        }
    }
}

contract DeepFundingTest is Test {
    DeepFunding internal fund;

    address[] internal jurors;
    address internal sink = makeAddr("bond-sink");
    address internal challenger = makeAddr("challenger");
    address internal sponsor = makeAddr("sponsor");
    address internal stranger = makeAddr("stranger");
    address internal pune = makeAddr("pune-dev");
    address internal kavya = makeAddr("kavya");
    address internal wallet = makeAddr("wallet-wrapper");

    bytes32 internal constant GRAPH = keccak256("the graph");
    uint256 internal constant POT = 10 ether;
    uint256 internal constant BOND = 0.1 ether;
    uint256 internal constant WINDOW = 3 days;
    uint256 internal deadline;

    // the committed result: 5 / 3 / 2 ETH
    address[3] internal who;
    uint256[3] internal amt = [uint256(5 ether), 3 ether, 2 ether];
    bytes32[] internal leaves;
    bytes32 internal root;

    function setUp() public {
        for (uint256 i = 0; i < 5; i++) {
            jurors.push(makeAddr(string.concat("juror", vm.toString(i))));
        }
        deadline = block.timestamp + 1 days;
        fund = new DeepFunding(jurors, GRAPH, 16, deadline, WINDOW, BOND, sink);
        who = [pune, kavya, wallet];
        _buildTree(address(fund));

        vm.deal(sponsor, 100 ether);
        vm.deal(challenger, 100 ether);
        vm.prank(sponsor);
        fund.fundPot{value: POT}();
    }

    // ---------------------------------------------------------------- helpers

    function _buildTree(address c) internal {
        delete leaves;
        for (uint256 i = 0; i < 3; i++) {
            leaves.push(keccak256(bytes.concat(keccak256(abi.encode(c, who[i], amt[i])))));
        }
        root = TestMerkle.root(leaves);
    }

    function _judge(address j, uint16 parent, uint16 a, uint16 b, uint8 outcome) internal {
        DeepFunding.Judgment[] memory js = new DeepFunding.Judgment[](1);
        js[0] = DeepFunding.Judgment(parent, a, b, outcome);
        vm.prank(j);
        fund.submitJudgments(js);
    }

    function _someJudgments() internal {
        _judge(jurors[0], 0, 0, 1, 0);
        _judge(jurors[1], 0, 1, 0, 0);
        _judge(jurors[2], 1, 1, 5, 2);
    }

    function _closeJudging() internal {
        vm.warp(deadline + 1);
    }

    function _propose() internal returns (uint256 at) {
        _someJudgments();
        _closeJudging();
        vm.prank(jurors[0]);
        fund.propose(root);
        at = block.timestamp;
    }

    function _finalize() internal {
        _propose();
        vm.warp(block.timestamp + WINDOW);
        fund.finalize();
    }

    function _raise() internal returns (uint256 id) {
        vm.prank(challenger);
        id = fund.dispute{value: BOND}(keccak256("the root is wrong"));
    }

    function _vote(uint256 id, uint256 from, uint256 to, bool wrong) internal {
        for (uint256 i = from; i < to; i++) {
            vm.prank(jurors[i]);
            fund.voteOnDispute(id, wrong);
        }
    }

    // ---------------------------------------------------------------- rubric 1: claims against an onchain commitment

    function test_rubric1_claimPaysExactlyTheCommittedAmount() public {
        _finalize();
        uint256 before = pune.balance;
        fund.claim(pune, 5 ether, TestMerkle.proof(leaves, 0));
        assertEq(pune.balance, before + 5 ether);
        assertEq(fund.totalClaimed(), 5 ether);
    }

    function test_rubric1_callerSuppliedAmountIsNotTrusted() public {
        _finalize();
        bytes32[] memory p = TestMerkle.proof(leaves, 0);
        vm.expectRevert(DeepFunding.InvalidProof.selector);
        fund.claim(pune, 6 ether, p);
        vm.expectRevert(DeepFunding.InvalidProof.selector);
        fund.claim(stranger, 5 ether, p);
    }

    function test_rubric1_aTreeBuiltForAnotherDeploymentDoesNotVerify() public {
        _finalize();
        DeepFunding other = new DeepFunding(jurors, GRAPH, 16, block.timestamp + 1 days, WINDOW, BOND, sink);
        bytes32[] memory p = TestMerkle.proof(leaves, 0); // proof for `fund`
        _buildTree(address(other));
        // a root built for `other` can't be claimed against `fund`: its own leaf differs
        vm.expectRevert(DeepFunding.InvalidProof.selector);
        fund.claim(pune, 5 ether, TestMerkle.proof(leaves, 0));
        assertEq(p.length, 2);
    }

    function test_rubric1_noClaimBeforeFinalize() public {
        _propose();
        vm.expectRevert(DeepFunding.NotFinalized.selector);
        fund.claim(pune, 5 ether, TestMerkle.proof(leaves, 0));
    }

    function test_everyoneCanBePaidAndNothingIsLeft() public {
        _finalize();
        for (uint256 i = 0; i < 3; i++) fund.claim(who[i], amt[i], TestMerkle.proof(leaves, i));
        assertEq(fund.totalClaimed(), POT);
        assertEq(address(fund).balance, 0);
    }

    // ---------------------------------------------------------------- rubric 2: not before the dispute window closes

    function test_rubric2_finalizeRevertsUntilWindowCloses() public {
        uint256 at = _propose();
        vm.expectRevert(DeepFunding.WindowOpen.selector);
        fund.finalize();

        vm.warp(at + WINDOW - 1);
        vm.expectRevert(DeepFunding.WindowOpen.selector);
        fund.finalize();

        vm.warp(at + WINDOW);
        fund.finalize();
        assertTrue(fund.finalized());
    }

    function test_rubric2_noOneCanFinalizeEarly_notEvenTheProposer() public {
        _propose();
        vm.prank(jurors[0]);
        vm.expectRevert(DeepFunding.WindowOpen.selector);
        fund.finalize();
        vm.prank(address(this)); // the deployer has no special power either
        vm.expectRevert(DeepFunding.WindowOpen.selector);
        fund.finalize();
    }

    function test_rubric2_cannotFinalizeWithoutAProposal() public {
        _closeJudging();
        vm.expectRevert(DeepFunding.NoProposal.selector);
        fund.finalize();
    }

    // ---------------------------------------------------------------- rubric 3: only registered jurors judge

    function test_rubric3_onlyRegisteredJurorsCanSubmitJudgments() public {
        DeepFunding.Judgment[] memory js = new DeepFunding.Judgment[](1);
        js[0] = DeepFunding.Judgment(0, 0, 1, 0);
        vm.prank(stranger);
        vm.expectRevert(DeepFunding.NotJuror.selector);
        fund.submitJudgments(js);
        vm.prank(sponsor);
        vm.expectRevert(DeepFunding.NotJuror.selector);
        fund.submitJudgments(js);

        vm.prank(jurors[0]);
        fund.submitJudgments(js);
        assertEq(fund.judgmentCount(), 1);
    }

    function test_rubric3_judgmentsAfterTheDeadlineAreRejected() public {
        _closeJudging();
        DeepFunding.Judgment[] memory js = new DeepFunding.Judgment[](1);
        js[0] = DeepFunding.Judgment(0, 0, 1, 0);
        vm.prank(jurors[0]);
        vm.expectRevert(DeepFunding.JudgingClosed.selector);
        fund.submitJudgments(js);
    }

    function test_rubric3_oneJurorCannotStuffAPair() public {
        _judge(jurors[0], 0, 0, 1, 0);
        DeepFunding.Judgment[] memory same = new DeepFunding.Judgment[](1);
        same[0] = DeepFunding.Judgment(0, 0, 1, 0);
        vm.prank(jurors[0]);
        vm.expectRevert(DeepFunding.DuplicateJudgment.selector);
        fund.submitJudgments(same);

        DeepFunding.Judgment[] memory flipped = new DeepFunding.Judgment[](1);
        flipped[0] = DeepFunding.Judgment(0, 1, 0, 1); // same pair, written the other way round
        vm.prank(jurors[0]);
        vm.expectRevert(DeepFunding.DuplicateJudgment.selector);
        fund.submitJudgments(flipped);

        _judge(jurors[1], 0, 0, 1, 1); // a different juror answering the same pair is welcome
        assertEq(fund.judgmentCount(), 2);
    }

    function test_rubric3_malformedJudgmentsRevert() public {
        DeepFunding.Judgment[] memory js = new DeepFunding.Judgment[](1);
        js[0] = DeepFunding.Judgment(0, 3, 3, 0); // a == b
        vm.prank(jurors[0]);
        vm.expectRevert(DeepFunding.InvalidJudgment.selector);
        fund.submitJudgments(js);
        js[0] = DeepFunding.Judgment(16, 0, 1, 0); // parent out of range
        vm.prank(jurors[0]);
        vm.expectRevert(DeepFunding.InvalidJudgment.selector);
        fund.submitJudgments(js);
        js[0] = DeepFunding.Judgment(0, 0, 16, 0); // item out of range
        vm.prank(jurors[0]);
        vm.expectRevert(DeepFunding.InvalidJudgment.selector);
        fund.submitJudgments(js);
        js[0] = DeepFunding.Judgment(0, 0, 1, 3); // bad outcome
        vm.prank(jurors[0]);
        vm.expectRevert(DeepFunding.InvalidJudgment.selector);
        fund.submitJudgments(js);
    }

    function test_rubric3_jurorsAreFixedBeforeAnyJudgmentExists() public view {
        assertEq(fund.jurorList().length, 5);
        assertFalse(fund.isJuror(stranger));
        assertEq(fund.quorum(), 3);
    }

    function test_setupRejectsBadJurySets() public {
        address[] memory two = new address[](2);
        two[0] = jurors[0];
        two[1] = jurors[1];
        vm.expectRevert(DeepFunding.InvalidSetup.selector);
        new DeepFunding(two, GRAPH, 16, deadline, WINDOW, BOND, sink);

        address[] memory dup = new address[](3);
        dup[0] = jurors[0];
        dup[1] = jurors[1];
        dup[2] = jurors[0];
        vm.expectRevert(DeepFunding.InvalidSetup.selector);
        new DeepFunding(dup, GRAPH, 16, deadline, WINDOW, BOND, sink);

        vm.expectRevert(DeepFunding.InvalidSetup.selector);
        new DeepFunding(jurors, GRAPH, 16, block.timestamp, WINDOW, BOND, sink);
        vm.expectRevert(DeepFunding.InvalidSetup.selector);
        new DeepFunding(jurors, GRAPH, 16, deadline, 0, BOND, sink);
        vm.expectRevert(DeepFunding.InvalidSetup.selector);
        new DeepFunding(jurors, GRAPH, 16, deadline, WINDOW, BOND, address(0));
    }

    function test_digestChainsEveryJudgmentInOrder() public {
        _judge(jurors[0], 0, 0, 1, 0);
        _judge(jurors[1], 2, 2, 7, 1);
        bytes32 d = keccak256(abi.encode(bytes32(0), jurors[0], uint16(0), uint16(0), uint16(1), uint8(0)));
        d = keccak256(abi.encode(d, jurors[1], uint16(2), uint16(2), uint16(7), uint8(1)));
        assertEq(fund.judgmentsDigest(), d);
    }

    function test_proposalCannotOutrunJudging() public {
        _someJudgments();
        vm.prank(jurors[0]);
        vm.expectRevert(DeepFunding.JudgingNotClosed.selector);
        fund.propose(root);
    }

    function test_onlyJurorsPropose_andNeedJudgments() public {
        _closeJudging();
        vm.prank(stranger);
        vm.expectRevert(DeepFunding.NotJuror.selector);
        fund.propose(root);
        vm.prank(jurors[0]);
        vm.expectRevert(DeepFunding.NoJudgments.selector);
        fund.propose(root);
    }

    // ---------------------------------------------------------------- rubric 4: an open dispute blocks finalization

    function test_rubric4_openDisputeBlocksFinalize() public {
        uint256 at = _propose();
        _raise();
        vm.warp(at + WINDOW);
        vm.expectRevert(DeepFunding.OpenDisputes.selector);
        fund.finalize();
        assertEq(uint8(fund.phase()), uint8(DeepFunding.Phase.Disputed));
    }

    function test_rubric4_acceptedDisputeDiscardsTheProposal() public {
        uint256 at = _propose();
        uint256 id = _raise();
        _vote(id, 1, 4, true); // three jurors, none of them the proposer, agree it is wrong

        (, bytes32 liveRoot,, uint256 proposedAt,) = fund.proposal();
        assertEq(liveRoot, bytes32(0));
        assertEq(proposedAt, 0);
        vm.warp(at + WINDOW);
        vm.expectRevert(DeepFunding.NoProposal.selector);
        fund.finalize();

        // the bond comes back, and a corrected proposal can follow straight away
        uint256 before = challenger.balance;
        vm.prank(challenger);
        fund.withdrawCredit();
        assertEq(challenger.balance, before + BOND);
        vm.prank(jurors[1]);
        fund.propose(root);
        assertEq(fund.proposalId(), 1);
    }

    function test_rubric4_rejectedDisputeUnblocksFinalizeAndForfeitsTheBond() public {
        uint256 at = _propose();
        uint256 id = _raise();
        _vote(id, 1, 4, false);

        vm.warp(at + WINDOW);
        fund.finalize();
        assertTrue(fund.finalized());
        vm.prank(sink);
        fund.withdrawCredit();
        assertEq(sink.balance, BOND);
    }

    function test_rubric4_severalOpenDisputesAllHaveToBeResolved() public {
        uint256 at = _propose();
        uint256 a = _raise();
        uint256 b = _raise();
        _vote(a, 1, 4, false);
        vm.warp(at + WINDOW);
        vm.expectRevert(DeepFunding.OpenDisputes.selector);
        fund.finalize();
        _vote(b, 1, 4, false);
        fund.finalize();
        assertTrue(fund.finalized());
    }

    function test_rubric4_disputeOnlyDuringTheWindow() public {
        uint256 at = _propose();
        vm.warp(at + WINDOW);
        vm.prank(challenger);
        vm.expectRevert(DeepFunding.WindowClosed.selector);
        fund.dispute{value: BOND}(bytes32(0));
    }

    function test_rubric4_disputeNeedsTheExactBondAndALiveProposal() public {
        vm.prank(challenger);
        vm.expectRevert(DeepFunding.NoProposal.selector);
        fund.dispute{value: BOND}(bytes32(0));
        _propose();
        vm.prank(challenger);
        vm.expectRevert(DeepFunding.WrongBond.selector);
        fund.dispute{value: BOND - 1}(bytes32(0));
        vm.prank(challenger);
        vm.expectRevert(DeepFunding.WrongBond.selector);
        fund.dispute{value: 0}(bytes32(0));
    }

    // ---------------------------------------------------------------- brief traps: dispute theatre

    function test_trap_theProposerCannotResolveOrVoteOnDisputesAgainstTheirOwnResult() public {
        _propose(); // proposed by jurors[0]
        uint256 id = _raise();
        vm.prank(jurors[0]);
        vm.expectRevert(DeepFunding.ProposerCannotVote.selector);
        fund.voteOnDispute(id, false);
    }

    function test_trap_aDisputeCanBeDecidedWithoutTheProposer() public {
        _propose();
        uint256 id = _raise();
        // the four other jurors are enough to reach the quorum of three
        _vote(id, 1, 4, true);
        (,, , DeepFunding.DisputeStatus status,,,) = fund.disputes(id);
        assertEq(uint8(status), uint8(DeepFunding.DisputeStatus.Accepted));
    }

    function test_trap_nonJurorsCannotVote_andNobodyVotesTwice() public {
        _propose();
        uint256 id = _raise();
        vm.prank(stranger);
        vm.expectRevert(DeepFunding.NotJuror.selector);
        fund.voteOnDispute(id, false);
        vm.prank(jurors[1]);
        fund.voteOnDispute(id, true);
        vm.prank(jurors[1]);
        vm.expectRevert(DeepFunding.AlreadyVoted.selector);
        fund.voteOnDispute(id, true);
    }

    function test_trap_aMinorityOfJurorsCannotDecide() public {
        _propose();
        uint256 id = _raise();
        _vote(id, 1, 3, true); // two of the three needed
        (,, , DeepFunding.DisputeStatus status,,,) = fund.disputes(id);
        assertEq(uint8(status), uint8(DeepFunding.DisputeStatus.Open));
    }

    function test_staleDisputeBondsCanBeReclaimedAfterADiscard() public {
        _propose();
        uint256 a = _raise();
        uint256 b = _raise();
        _vote(a, 1, 4, true); // discards the proposal, which makes dispute b stale

        vm.prank(jurors[1]);
        vm.expectRevert(DeepFunding.StaleDispute.selector);
        fund.voteOnDispute(b, true);

        fund.reclaimStaleBond(b);
        vm.prank(challenger);
        fund.withdrawCredit();
        vm.expectRevert(DeepFunding.DisputeNotOpen.selector);
        fund.reclaimStaleBond(b);
    }

    function test_cannotReclaimTheBondOfALiveDispute() public {
        _propose();
        uint256 id = _raise();
        vm.expectRevert(DeepFunding.DisputeNotOpen.selector);
        fund.reclaimStaleBond(id);
    }

    function test_unknownDisputeReverts() public {
        _propose();
        vm.prank(jurors[1]);
        vm.expectRevert(DeepFunding.UnknownDispute.selector);
        fund.voteOnDispute(99, true);
    }

    function test_aSecondProposalCannotStackOnALiveOne() public {
        _propose();
        vm.prank(jurors[1]);
        vm.expectRevert(DeepFunding.ProposalExists.selector);
        fund.propose(keccak256("another"));
    }

    // ---------------------------------------------------------------- rubric 7: claimed is set before the transfer

    function test_rubric7_aRecipientCanClaimOnlyOnce() public {
        _finalize();
        fund.claim(pune, 5 ether, TestMerkle.proof(leaves, 0));
        vm.expectRevert(DeepFunding.AlreadyClaimed.selector);
        fund.claim(pune, 5 ether, TestMerkle.proof(leaves, 0));
    }

    function test_rubric7_reentrantRecipientCannotClaimTwice() public {
        ReentrantClaimer evil = new ReentrantClaimer();
        // build a fresh round whose committed result pays the attacker 5 ETH
        DeepFunding f = new DeepFunding(jurors, GRAPH, 16, block.timestamp + 1 days, WINDOW, BOND, sink);
        who = [address(evil), kavya, wallet];
        _buildTree(address(f));
        vm.prank(sponsor);
        f.fundPot{value: POT}();
        vm.prank(jurors[0]);
        DeepFunding.Judgment[] memory js = new DeepFunding.Judgment[](1);
        js[0] = DeepFunding.Judgment(0, 0, 1, 0);
        f.submitJudgments(js);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(jurors[0]);
        f.propose(root);
        vm.warp(block.timestamp + WINDOW);
        f.finalize();
        evil.set(f, 5 ether, TestMerkle.proof(leaves, 0));

        f.claim(address(evil), 5 ether, TestMerkle.proof(leaves, 0));

        assertGt(evil.attempts(), 0, "attacker never re-entered");
        assertFalse(evil.reenterSucceeded());
        assertEq(address(evil).balance, 5 ether);
        assertEq(f.totalClaimed(), 5 ether);
    }

    function test_claimCanNeverPayMoreThanThePot() public {
        // a root that promises 12 ETH out of a 10 ETH pot
        uint256[3] memory over = [uint256(12 ether), 0, 0];
        bytes32[] memory ls = new bytes32[](1);
        ls[0] = keccak256(bytes.concat(keccak256(abi.encode(address(fund), pune, over[0]))));
        bytes32 badRoot = TestMerkle.root(ls);
        _someJudgments();
        _closeJudging();
        vm.prank(jurors[0]);
        fund.propose(badRoot);
        vm.warp(block.timestamp + WINDOW);
        fund.finalize();
        vm.expectRevert(DeepFunding.ExceedsPot.selector);
        fund.claim(pune, 12 ether, TestMerkle.proof(ls, 0));
    }

    // ---------------------------------------------------------------- rubric 8: immutable once finalized

    function test_rubric8_nothingChangesTheResultOnceFinalized() public {
        _finalize();
        (, bytes32 rootBefore, uint256 potBefore,,) = fund.proposal();

        vm.prank(jurors[1]);
        vm.expectRevert(DeepFunding.AlreadyFinalized.selector);
        fund.propose(keccak256("a different root"));

        vm.prank(challenger);
        vm.expectRevert(DeepFunding.AlreadyFinalized.selector);
        fund.dispute{value: BOND}(bytes32(0));

        vm.prank(jurors[2]);
        vm.expectRevert(DeepFunding.AlreadyFinalized.selector);
        fund.voteOnDispute(1, true);

        vm.expectRevert(DeepFunding.AlreadyFinalized.selector);
        fund.finalize();

        DeepFunding.Judgment[] memory js = new DeepFunding.Judgment[](1);
        js[0] = DeepFunding.Judgment(0, 0, 2, 0);
        vm.prank(jurors[0]);
        vm.expectRevert(DeepFunding.JudgingClosed.selector);
        fund.submitJudgments(js);

        vm.prank(sponsor);
        vm.expectRevert(DeepFunding.JudgingClosed.selector);
        fund.fundPot{value: 1 ether}();

        (, bytes32 rootAfter, uint256 potAfter,,) = fund.proposal();
        assertEq(rootAfter, rootBefore);
        assertEq(potAfter, potBefore);
        assertEq(uint8(fund.phase()), uint8(DeepFunding.Phase.Finalized));
    }

    // ---------------------------------------------------------------- the pot and the phases

    function test_potCannotBeFundedAfterJudgingCloses_andHasNoWayOut() public {
        _closeJudging();
        vm.prank(sponsor);
        vm.expectRevert(DeepFunding.JudgingClosed.selector);
        fund.fundPot{value: 1 ether}();
        vm.expectRevert(DeepFunding.ZeroValue.selector);
        fund.fundPot{value: 0}();
        // the contract exposes no function that sends the pot anywhere except `claim`
        assertEq(address(fund).balance, POT);
    }

    function test_proposalSnapshotsThePot() public {
        _propose();
        (,, uint256 snapshot,,) = fund.proposal();
        assertEq(snapshot, POT);
    }

    function test_phaseWalksTheWholeLifecycle() public {
        assertEq(uint8(fund.phase()), uint8(DeepFunding.Phase.Judging));
        _someJudgments();
        _closeJudging();
        assertEq(uint8(fund.phase()), uint8(DeepFunding.Phase.AwaitingProposal));
        vm.prank(jurors[0]);
        fund.propose(root);
        assertEq(uint8(fund.phase()), uint8(DeepFunding.Phase.Challengeable));
        vm.warp(block.timestamp + WINDOW);
        assertEq(uint8(fund.phase()), uint8(DeepFunding.Phase.ReadyToFinalize));
        fund.finalize();
        assertEq(uint8(fund.phase()), uint8(DeepFunding.Phase.Finalized));
    }

    function test_withdrawCreditNeedsACredit() public {
        vm.prank(stranger);
        vm.expectRevert(DeepFunding.NothingToWithdraw.selector);
        fund.withdrawCredit();
    }
}
