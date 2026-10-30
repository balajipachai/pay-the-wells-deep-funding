// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title DeepFunding
/// @notice Pays a thank-you pot down a dependency graph, with weights that come from a jury and a result
///         anyone can recompute and dispute before anyone is paid.
///
/// @dev Why no single party can steer the outcome:
///      - There is no owner and no admin function. The deployer has no powers after deployment.
///      - The jurors are fixed in the constructor, before any judgment exists, so nobody can pick jurors
///        after seeing how they judge.
///      - Every judgment a juror submits is recorded, chained into `judgmentsDigest`, and counted by one
///        public rule; a juror's answer for a pair counts once, so one juror cannot stuff the count.
///      - A proposal commits to the on-chain digest, so the proposer cannot choose which judgments count.
///        The graph is fixed by `graphHash`.
///      - The weighting itself is too big for a transaction (hundreds of packages, cycles), so it runs
///        offchain, deterministically: anyone re-runs `npm run reproduce` against the chain and gets the
///        same root, or finds a mismatch and disputes.
///      - Disputes are decided by a majority of jurors, and the juror who made the proposal cannot vote on
///        disputes against it. The proposer never resolves their own dispute.
///      - After `finalize()` the root can never change.
///
///      Lifecycle: Judging (jurors judge, anyone funds the pot) -> AwaitingProposal -> Challengeable (dispute
///      window) -> [Disputed until resolved] -> ReadyToFinalize -> Finalized, after which each recipient claims.
contract DeepFunding is ReentrancyGuard {
    struct Judgment {
        uint16 parent; // the package whose dependencies are compared; a or b == parent means "its own work"
        uint16 a;
        uint16 b;
        uint8 outcome; // 0: a mattered more, 1: b mattered more, 2: about equal
    }

    struct Proposal {
        address proposer;
        bytes32 root;
        uint256 pot;
        uint256 proposedAt;
        uint256 openDisputes;
    }

    enum DisputeStatus {
        Open,
        Accepted, // jurors agreed the proposal was wrong; it was discarded
        Rejected, // jurors agreed the proposal was right; the bond is forfeited
        Withdrawn // the proposal it was raised against was discarded by another dispute; bond returned
    }

    struct Dispute {
        address challenger;
        uint256 proposalId;
        uint256 bond;
        DisputeStatus status;
        uint256 yes; // votes that the proposal is wrong
        uint256 no; // votes that the proposal is right
        bytes32 reason;
    }

    enum Phase {
        Judging,
        AwaitingProposal,
        Challengeable,
        Disputed,
        ReadyToFinalize,
        Finalized
    }

    uint256 public constant MAX_JURORS = 255;

    bytes32 public immutable graphHash;
    uint16 public immutable packageCount;
    uint256 public immutable judgmentDeadline;
    uint256 public immutable disputeWindow;
    uint256 public immutable disputeBond;
    address public immutable bondSink;
    /// @notice Votes needed to decide a dispute: a strict majority of all jurors.
    uint256 public immutable quorum;

    address[] private _jurors;
    mapping(address => bool) public isJuror;

    uint256 public pot;
    bytes32 public judgmentsDigest;
    uint256 public judgmentCount;
    mapping(bytes32 => bool) private _answered;

    Proposal public proposal;
    uint256 public proposalId;
    bool public finalized;

    uint256 public disputeCount;
    mapping(uint256 => Dispute) public disputes;
    mapping(uint256 => mapping(address => bool)) private _voted;
    mapping(address => uint256) public credits;

    mapping(address => bool) public claimed;
    uint256 public totalClaimed;

    event PotFunded(address indexed funder, uint256 amount, uint256 pot);
    event JudgmentSubmitted(address indexed juror, uint16 parent, uint16 a, uint16 b, uint8 outcome);
    event Proposed(uint256 indexed proposalId, address indexed proposer, bytes32 root, uint256 pot, bytes32 judgmentsDigest);
    event DisputeRaised(uint256 indexed disputeId, uint256 indexed proposalId, address indexed challenger, bytes32 reason);
    event DisputeVote(uint256 indexed disputeId, address indexed juror, bool proposalWrong);
    event DisputeAccepted(uint256 indexed disputeId, uint256 indexed proposalId);
    event DisputeRejected(uint256 indexed disputeId, uint256 indexed proposalId);
    event Finalized(uint256 indexed proposalId, bytes32 root, uint256 pot);
    event Claimed(address indexed recipient, uint256 amount);

    error InvalidSetup();
    error NotJuror();
    error JudgingClosed();
    error JudgingNotClosed();
    error InvalidJudgment();
    error DuplicateJudgment();
    error AlreadyFinalized();
    error ProposalExists();
    error NoProposal();
    error EmptyRoot();
    error NoJudgments();
    error ZeroValue();
    error WindowClosed();
    error WindowOpen();
    error WrongBond();
    error UnknownDispute();
    error DisputeNotOpen();
    error StaleDispute();
    error ProposerCannotVote();
    error AlreadyVoted();
    error OpenDisputes();
    error NotFinalized();
    error AlreadyClaimed();
    error InvalidProof();
    error ExceedsPot();
    error NothingToWithdraw();
    error TransferFailed();

    modifier onlyJuror() {
        if (!isJuror[msg.sender]) revert NotJuror();
        _;
    }

    constructor(
        address[] memory jurors_,
        bytes32 graphHash_,
        uint16 packageCount_,
        uint256 judgmentDeadline_,
        uint256 disputeWindow_,
        uint256 disputeBond_,
        address bondSink_
    ) {
        uint256 n = jurors_.length;
        // Round timing is measured in minutes to days; validator timestamp drift of seconds is acceptable.
        // slither-disable-next-line timestamp
        if (n < 3 || n > MAX_JURORS || packageCount_ < 2 || disputeWindow_ == 0 || bondSink_ == address(0) || judgmentDeadline_ <= block.timestamp) {
            revert InvalidSetup();
        }
        for (uint256 i = 0; i < n; i++) {
            address j = jurors_[i];
            if (j == address(0) || isJuror[j]) revert InvalidSetup();
            isJuror[j] = true;
            _jurors.push(j);
        }
        graphHash = graphHash_;
        packageCount = packageCount_;
        judgmentDeadline = judgmentDeadline_;
        disputeWindow = disputeWindow_;
        disputeBond = disputeBond_;
        bondSink = bondSink_;
        quorum = n / 2 + 1;
    }

    // ------------------------------------------------------------------ funding and judging

    /// @notice Add ETH to the pot. Open to anyone until judging closes. There is no way to take it back out.
    function fundPot() external payable {
        if (msg.value == 0) revert ZeroValue();
        // slither-disable-next-line timestamp
        if (block.timestamp > judgmentDeadline) revert JudgingClosed();
        pot += msg.value;
        emit PotFunded(msg.sender, msg.value, pot);
    }

    /// @notice Registered jurors submit pairwise judgments until the deadline. A juror's answer for a given
    ///         pair under a given parent can be given once. Each judgment is chained into `judgmentsDigest`.
    function submitJudgments(Judgment[] calldata js) external onlyJuror {
        // slither-disable-next-line timestamp
        if (block.timestamp > judgmentDeadline) revert JudgingClosed();
        bytes32 digest = judgmentsDigest;
        for (uint256 i = 0; i < js.length; i++) {
            Judgment calldata j = js[i];
            if (j.a == j.b || j.parent >= packageCount || j.a >= packageCount || j.b >= packageCount || j.outcome > 2) {
                revert InvalidJudgment();
            }
            (uint16 lo, uint16 hi) = j.a < j.b ? (j.a, j.b) : (j.b, j.a);
            bytes32 key = keccak256(abi.encode(msg.sender, j.parent, lo, hi));
            if (_answered[key]) revert DuplicateJudgment();
            _answered[key] = true;

            digest = keccak256(abi.encode(digest, msg.sender, j.parent, j.a, j.b, j.outcome));
            emit JudgmentSubmitted(msg.sender, j.parent, j.a, j.b, j.outcome);
        }
        judgmentsDigest = digest;
        judgmentCount += js.length;
    }

    // ------------------------------------------------------------------ proposing a result

    /// @notice A juror publishes the result of running the engine on the on-chain judgments. It commits to the
    ///         pot and to `judgmentsDigest` as they stand now, so which judgments count is not the proposer's call.
    function propose(bytes32 root) external onlyJuror {
        if (finalized) revert AlreadyFinalized();
        // slither-disable-next-line timestamp
        if (block.timestamp <= judgmentDeadline) revert JudgingNotClosed();
        if (proposal.proposedAt != 0) revert ProposalExists();
        if (root == bytes32(0)) revert EmptyRoot();
        if (judgmentCount == 0) revert NoJudgments();

        proposal = Proposal({proposer: msg.sender, root: root, pot: pot, proposedAt: block.timestamp, openDisputes: 0});
        emit Proposed(proposalId, msg.sender, root, pot, judgmentsDigest);
    }

    // ------------------------------------------------------------------ disputes

    /// @notice Challenge the live proposal during the window, posting the bond. While any dispute is open
    ///         the proposal cannot be finalized. `reason` is a hash of the challenger's written case.
    function dispute(bytes32 reason) external payable returns (uint256 id) {
        if (finalized) revert AlreadyFinalized();
        // proposedAt == 0 is the "no live proposal" sentinel, not a comparison on a balance.
        // slither-disable-next-line incorrect-equality
        if (proposal.proposedAt == 0) revert NoProposal();
        // slither-disable-next-line timestamp
        if (block.timestamp >= proposal.proposedAt + disputeWindow) revert WindowClosed();
        if (msg.value != disputeBond) revert WrongBond();

        id = ++disputeCount;
        disputes[id] = Dispute({
            challenger: msg.sender,
            proposalId: proposalId,
            bond: msg.value,
            status: DisputeStatus.Open,
            yes: 0,
            no: 0,
            reason: reason
        });
        proposal.openDisputes += 1;
        emit DisputeRaised(id, proposalId, msg.sender, reason);
    }

    /// @notice A juror votes on a dispute. The juror who proposed the result cannot vote on disputes against it.
    ///         Reaching `quorum` either way decides it: if the proposal is wrong it is discarded and a juror
    ///         can propose a corrected root; if it is right the challenger's bond goes to `bondSink`.
    function voteOnDispute(uint256 id, bool proposalWrong) external onlyJuror {
        if (finalized) revert AlreadyFinalized();
        Dispute storage d = disputes[id];
        if (d.challenger == address(0)) revert UnknownDispute();
        if (d.status != DisputeStatus.Open) revert DisputeNotOpen();
        if (d.proposalId != proposalId || proposal.proposedAt == 0) revert StaleDispute();
        if (msg.sender == proposal.proposer) revert ProposerCannotVote();
        if (_voted[id][msg.sender]) revert AlreadyVoted();
        _voted[id][msg.sender] = true;

        if (proposalWrong) d.yes += 1;
        else d.no += 1;
        emit DisputeVote(id, msg.sender, proposalWrong);

        if (d.yes >= quorum) {
            d.status = DisputeStatus.Accepted;
            credits[d.challenger] += d.bond;
            emit DisputeAccepted(id, proposalId);
            // The proposal is discarded. Every other dispute raised against it is now stale and its bond
            // can be reclaimed. A new proposal may be made straight away.
            delete proposal;
            proposalId += 1;
        } else if (d.no >= quorum) {
            d.status = DisputeStatus.Rejected;
            credits[bondSink] += d.bond;
            proposal.openDisputes -= 1;
            emit DisputeRejected(id, proposalId);
        }
    }

    /// @notice Get a bond back when the proposal it was raised against has been discarded.
    function reclaimStaleBond(uint256 id) external {
        Dispute storage d = disputes[id];
        if (d.challenger == address(0)) revert UnknownDispute();
        if (d.status != DisputeStatus.Open) revert DisputeNotOpen();
        // This compares proposal ids (and the zero sentinel), not times: a dispute is stale once its proposal is gone.
        // slither-disable-next-line timestamp
        if (d.proposalId == proposalId && proposal.proposedAt != 0) revert DisputeNotOpen();
        d.status = DisputeStatus.Withdrawn;
        credits[d.challenger] += d.bond;
    }

    /// @notice Pull any bond credited to the caller (returned bond, or the sink's forfeits).
    function withdrawCredit() external nonReentrant {
        uint256 amount = credits[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        credits[msg.sender] = 0;
        // .call so a smart-wallet can receive; the credit is already zeroed and nonReentrant guards.
        // slither-disable-next-line low-level-calls
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ------------------------------------------------------------------ finalizing and paying

    /// @notice Lock the result. Anyone can call it, once the dispute window has closed with no dispute open.
    function finalize() external {
        if (finalized) revert AlreadyFinalized();
        // proposedAt == 0 is the "no live proposal" sentinel, not a comparison on a balance.
        // slither-disable-next-line incorrect-equality
        if (proposal.proposedAt == 0) revert NoProposal();
        // slither-disable-next-line timestamp
        if (block.timestamp < proposal.proposedAt + disputeWindow) revert WindowOpen();
        if (proposal.openDisputes != 0) revert OpenDisputes();
        finalized = true;
        emit Finalized(proposalId, proposal.root, proposal.pot);
    }

    /// @notice Pay `recipient` the amount committed for them in the finalized root. Callable once per
    ///         recipient by anyone; the ETH goes to `recipient` only.
    function claim(address recipient, uint256 amount, bytes32[] calldata proof) external nonReentrant {
        if (!finalized) revert NotFinalized();
        if (claimed[recipient]) revert AlreadyClaimed();
        // Double hash with this contract's address in the preimage: a leaf cannot pass as an inner node,
        // and a tree built for another deployment cannot be replayed here.
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(address(this), recipient, amount))));
        if (!MerkleProof.verifyCalldata(proof, proposal.root, leaf)) revert InvalidProof();
        // Even a root that over-promises can never pay out more than the pot.
        if (totalClaimed + amount > proposal.pot) revert ExceedsPot();

        claimed[recipient] = true; // effect before interaction
        totalClaimed += amount;
        emit Claimed(recipient, amount);

        // Paying an arbitrary address is the point of claim(): the recipient and amount were just verified
        // against the finalized Merkle root, and `claimed` is already set. .call so a smart wallet can receive.
        // slither-disable-next-line arbitrary-send-eth,low-level-calls
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ------------------------------------------------------------------ views

    function jurorList() external view returns (address[] memory) {
        return _jurors;
    }

    function phase() external view returns (Phase) {
        if (finalized) return Phase.Finalized;
        // slither-disable-next-line timestamp
        if (block.timestamp <= judgmentDeadline) return Phase.Judging;
        // proposedAt == 0 is the "no live proposal" sentinel, not a comparison on a balance.
        // slither-disable-next-line incorrect-equality
        if (proposal.proposedAt == 0) return Phase.AwaitingProposal;
        // slither-disable-next-line timestamp
        if (block.timestamp < proposal.proposedAt + disputeWindow) return Phase.Challengeable;
        if (proposal.openDisputes != 0) return Phase.Disputed;
        return Phase.ReadyToFinalize;
    }

    function hasVoted(uint256 id, address juror) external view returns (bool) {
        return _voted[id][juror];
    }
}
