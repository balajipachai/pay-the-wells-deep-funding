# Rubric map

Every check the repo is graded on, where it is satisfied, and the test that proves it.
Run `forge test` and `npm --prefix engine test`; every row below must pass.
Contract: `src/DeepFunding.sol`. Engine: `engine/src/`.

| # | Pts | Check | Where | Test |
|---|----:|-------|-------|------|
| 1 | 15 | Claims are paid against an onchain commitment | `claim`: `MerkleProof.verifyCalldata(proof, proposal.root, leaf)` where the leaf is `keccak256(keccak256(abi.encode(address(this), recipient, amount)))` | `test_rubric1_claimPaysExactlyTheCommittedAmount`, `test_rubric1_callerSuppliedAmountIsNotTrusted`, `test_rubric1_aTreeBuiltForAnotherDeploymentDoesNotVerify`, `EngineCrossCheckTest` |
| 2 | 12 | Results can't go live before the dispute window closes | `finalize`: reverts unless `block.timestamp >= proposal.proposedAt + disputeWindow` | `test_rubric2_finalizeRevertsUntilWindowCloses`, `test_rubric2_noOneCanFinalizeEarly_notEvenTheProposer` |
| 3 | 10 | Judgments only from registered jurors | `submitJudgments` is `onlyJuror` (`msg.sender` check against the constructor's list); the engine also drops judgments from anyone not on the juror list | `test_rubric3_onlyRegisteredJurorsCanSubmitJudgments`, `test_rubric3_oneJurorCannotStuffAPair`, engine: `judgments from outside the jury ... are not counted` |
| 4 | 8 | An open dispute blocks finalization | `finalize`: reverts while `proposal.openDisputes != 0`; an accepted dispute deletes the proposal | `test_rubric4_openDisputeBlocksFinalize`, `test_rubric4_acceptedDisputeDiscardsTheProposal`, `test_rubric4_severalOpenDisputesAllHaveToBeResolved` |
| 5 | 8 | Graph traversal terminates on cycles | `engine/src/graph.ts`: `reachable`, `depths`, `findCycles` all track visited nodes; `engine/src/allocate.ts`: `propagate` has a hard cap, `MAX_ROUNDS`, and throws if it is hit | engine: `value that circles a cycle terminates ...`, `a tight cycle with a heavily skewed jury still terminates` |
| 6 | 8 | Allocation asserts the payouts conserve the pot exactly | `engine/src/allocate.ts`: `toAmounts` and `assertConserved` throw unless the sum equals the pot (rounding is shared by largest remainder, so there is no dust recipient); `result.ts` asserts again after merging payout addresses | engine: `payouts add up to the pot exactly`, `awkward pots still add up exactly`, `the conservation check aborts when the total is off` |
| 7 | 6 | Claimed marker written before the transfer | `claim`: `claimed[recipient] = true` before `.call`, plus `nonReentrant` | `test_rubric7_aRecipientCanClaimOnlyOnce`, `test_rubric7_reentrantRecipientCannotClaimTwice` |
| 8 | 6 | The committed result is immutable after finalization | `propose`, `dispute`, `voteOnDispute`, `finalize` all revert `AlreadyFinalized`; `submitJudgments` and `fundPot` are closed by the deadline; no setter exists | `test_rubric8_nothingChangesTheResultOnceFinalized` |
| 9 | 4 | The sample dependency graph contains a cycle | `data/graph.json`: `eth-rpc (8) -> abi-codec (9) -> eth-rpc (8)` | engine: `sample graph is at least three levels deep and contains a cycle` |
| 10 | 3 | No credentials in tracked files | keystore signing only; `.env` is git-ignored; `.env.example` has no values | `git grep -nE '0x[0-9a-fA-F]{64}'` finds only Merkle proofs, digests and hashes |

## Brief-level traps

| Trap | Defence | Test |
|------|---------|------|
| The splitter in disguise (dependencies of dependencies get nothing) | Value flows through every level until it settles | engine: `dependencies of dependencies are paid, all the way down` |
| The trusted spreadsheet (weights typed in, judgments ignored) | Keep-shares and splits are derived only from judgments; there is no weights file | engine: `keep-shares come from the jury`, `changing a single judgment changes the published root` |
| Dispute theatre (only the proposer can resolve a dispute) | A juror majority decides; the proposer can't vote on disputes against their own proposal; no owner exists | `test_trap_theProposerCannotResolveOrVoteOnDisputesAgainstTheirOwnResult`, `test_trap_aDisputeCanBeDecidedWithoutTheProposer`, `test_trap_aMinorityOfJurorsCannotDecide` |
| Choosing jurors after seeing judgments | Jurors are fixed in the constructor | `test_rubric3_jurorsAreFixedBeforeAnyJudgmentExists` |
| Picking which judgments count | The proposal commits to the on-chain digest; one public counting rule | `test_digestChainsEveryJudgmentInOrder`, engine: `the order judgments arrived in does not change the payouts` |
| A single juror steering | One answer per juror per pair | `test_rubric3_oneJurorCannotStuffAPair` |
| Reproducibility | `npm --prefix engine run reproduce` recomputes the result and compares it byte for byte; with `--rpc/--contract` it reads everything from the chain | engine: `the published sample reproduces its committed result byte for byte`; `script/e2e-anvil.sh` |
| Pinning the sample to its expected output | `data/result.json` is the committed expected output | same test |
