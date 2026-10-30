# Pay the Wells You Drank From

After an event, a thank-you pot flows down the open-source packages the event app was built on, all the way down the
dependency tree. A small jury decides the weights, the result is published so that anyone can re-run it, and nobody is
paid until a dispute window has closed. The maintainer never has the power to change the numbers.

See [`RUBRIC.md`](RUBRIC.md) for a check-by-check map from the grading rubric to code and tests.

## Run it yourself

```sh
cd engine && npm install
npm run reproduce        # recompute the sample result from the published graph and judgments
npm test                 # 23 engine tests
cd .. && forge test      # 40 contract tests
script/e2e-anvil.sh      # the entire lifecycle on a local chain, with assertions
```

`npm run reproduce` prints `PASS` when re-running `data/graph.json` and `data/judgments.json` gives exactly the committed
`data/result.json`, and `FAIL` otherwise. Against a live round, the same command reads the graph commitment, every judgment
and the pot straight from the contract, so nothing depends on trusting the repo's files:

```sh
node engine/src/cli.ts reproduce --rpc <sepolia rpc url> --contract <address>
```

## How the weights are made

The sample is Kavya's event app and the 15 packages it stands on (16 in all): five levels (0 to 4) (`devcon-event-app -> wallet-connect-wrapper ->
eth-rpc -> http-client -> url-parse`), with one dependency cycle (`eth-rpc` and `abi-codec` depend on each other).

1. **Questions.** For each package that has dependencies, jurors answer pairwise questions among *the package itself and
   each of its dependencies*: "for `wallet-connect-wrapper`, which mattered more, `eth-rpc` or `i18n-core`?", including
   "the package's own work" as one of the options. `node engine/src/cli.ts ballot` prints the full list.
2. **Weights.** A Bradley–Terry model turns each package's answers into weights. A win over a strong rival counts for more
   than a win over a weak one, and uneven coverage still gives one consistent scale, which plain win-counting can't do. A
   weak prior (a half win each way for every pair) keeps weights positive when an item never won, and makes unjudged items
   come out equal. It is fitted in exact BigInt fixed point with a fixed iteration count, so every machine gets the same bits.
3. **Keep-share comes from the jury too.** A package's own weight is how much of what reaches it stays with it; the rest is
   split among its dependencies in proportion to theirs. Nobody types in a keep-share.
4. **Flow.** The pot starts at the app. Round by round, each package keeps its share and passes the rest down. Value that
   goes round a cycle shrinks every time (every package keeps a positive share) and floors to zero in finitely many rounds.
   The loop also has a hard cap and aborts if it is hit. Graph reachability, depth and cycle detection use visited sets.
5. **Rounding.** Rounding stays inside the system, and wei are shared by largest remainder, so payouts equal the pot
   exactly. There is no dust recipient, and the code throws if the total is off by one wei.
6. **Commitment.** A Merkle tree over `(recipient, amount)` leaves, double-hashed, with the contract's address in the leaf.

Sample output, 10 ETH pot: the app keeps about 33.5%, `qr-ticketing` (the solo developer in Pune) gets 9.9%, and the
deepest package, `url-parse`, gets 0.3%. Every package reachable from the app is paid.

## The contract

`src/DeepFunding.sol` has no owner and no admin function.

| Phase | What happens |
|-------|--------------|
| Judging | Jurors (fixed at deploy) submit judgments; anyone funds the pot. |
| Awaiting proposal | A juror runs the engine on the on-chain judgments and proposes the root. |
| Challenge window | Anyone can dispute with a bond. |
| Disputed | While any dispute is open, nothing can be finalized. Jurors vote; a majority decides. |
| Ready / Finalized | After the window with no open dispute, anyone locks the result in. It can't change again. |
| Claims | Each recipient claims their committed amount once, proven against the root. |

Why nobody can steer it:

- **Jurors are fixed in the constructor**, before any judgment exists, so they can't be picked after seeing how they judge.
- **Every judgment is recorded and chained into `judgmentsDigest`**, and a proposal commits to that digest, so the proposer
  can't choose which judgments count. A juror's answer for a pair counts once, so a single juror can't stuff the count.
- **The weighting is off-chain** because it is too much work for one transaction. It is deterministic, so a stranger can
  re-run it, compare roots, and dispute a mismatch.
- **The proposer can't resolve their own dispute.** A strict majority of all jurors decides, and the juror who proposed
  can't vote on disputes against their own proposal. A discarded proposal can be replaced by another juror's.
- **Bond payouts are pull-based** so a reverting recipient can't block a decision.
- **A root can never pay out more than the pot**, even if a bad root were somehow committed.

## Frontend

`frontend/index.html` is the view a maintainer opens. Pick your package (or connect the wallet that is its payout address)
and it shows your amount, then **why you got it**: which package passed you how much, what share of what reaches that
package the jury's answers sent to you (with the win/loss/equal tally behind it), how much you keep and what you pass on.
It checks in your browser that your allocation is a leaf of the published root and that this root is the one committed
on-chain. **Disputing** is explained step by step, with the exact command to re-run it and a button to raise a dispute
with the bond. After finalization it shows a claim button, or "already claimed".

It runs without a deployment too, showing the sample. Serve it with `cd frontend && python3 -m http.server 8000`.

## Deploy (Sepolia)

The signer is a Foundry keystore (`cast wallet import deployer --interactive`), never a file in this repo. Copy `.env.example`
to `.env` and fill it in, then:

```sh
script/deploy.sh                          # deploy, fund the pot, verify, confirm; writes frontend/deployment.json
node engine/src/cli.ts ballot > ballot.json   # each juror fills in "outcome", then:
script/submit-judgments.sh ballot.json <juror keystore>
script/propose.sh <juror keystore>        # after judging closes: recompute from the chain, propose the root
cast send <addr> "finalize()" ...         # after the dispute window, anyone can
```

`deploy.sh` uses `--skip-simulation` because forge's local gas estimate is far below what Sepolia charges for contract
creation; a transaction sized by it ran out of gas on-chain and deployed nothing. The script checks the receipt, the code and
the on-chain `graphHash` before it reports success.

### Deployed address

| Network | Address |
|---------|---------|
| Sepolia | _pending deployment_ |

## Verification performed

| Layer | Result |
|-------|--------|
| `forge test` | 40 tests pass, including the engine's real output run through the contract (Solidity and TypeScript digests agree; every allocation claimed with the engine's proofs) |
| `npm test` (engine) | 23 tests: sample pinned byte for byte, conservation, cycles, multi-level payout, jury-derived keep-shares, order independence, BT analytic check |
| Slither | 0 findings; accepted notes are suppressed inline with a reason |
| `script/e2e-anvil.sh` | Full lifecycle on a local chain: 125 judgments on-chain, result recomputed from chain data alone is byte-identical to `data/result.json`, a dispute rejected by the jury, finalize, 16 recipients paid exactly once, nothing left in the contract |
| Browser | The page was driven through sample mode, the dispute window (raising a dispute through the page) and the finalized/claimed state |
