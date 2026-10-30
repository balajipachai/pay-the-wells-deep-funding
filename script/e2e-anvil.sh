#!/usr/bin/env bash
# The whole lifecycle on a local chain, with assertions. One command: script/e2e-anvil.sh
#
# deploy -> jurors submit all 125 sample judgments on-chain -> recompute the result purely from chain data
# (it must be byte-identical to the committed data/result.json) -> a juror proposes the root -> someone
# disputes and the jurors reject it -> window closes -> finalize -> every recipient claims -> pot fully paid.
#
# The sample's jurors are anvil accounts 0-4 and the sample's contract address is the address anvil's first
# deploy gets, which is why a local run can reproduce the committed result exactly. Pass --keep to leave the
# chain running on :8548 (for the frontend).
set -euo pipefail
cd "$(dirname "$0")/.."
PORT=8548; RPC=http://127.0.0.1:$PORT; KEEP=${1:-}
anvil --port $PORT --silent >/tmp/anvil-deepfunding.log 2>&1 & ANVIL=$!
[ "$KEEP" = "--keep" ] || trap 'kill $ANVIL 2>/dev/null' EXIT
for _ in $(seq 1 40); do cast chain-id --rpc-url $RPC >/dev/null 2>&1 && break; sleep 0.25; done

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "  ok: $*"; }
J0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
CHALLENGER=0x976EA74026E726554dB657fA54763abd0C3a0aa9
SINK=0xa0Ee7A142d267C1f36714E4a8F75612F20a79720
STRANGER=0x14dC79964da2C08b23698B3D3cc7Ca32193d9955
POT=$(python3 -c "import json;print(json.load(open('data/config.json'))['pot'])")

echo "== deploy"
export DEPLOYER=$J0 JURORS=$(python3 -c "import json;print(','.join(json.load(open('data/config.json'))['jurors']))")
export GRAPH_HASH=$(node engine/src/cli.ts graph-hash) PACKAGE_COUNT=16 JUDGING_SECONDS=3600 DISPUTE_WINDOW_SECONDS=86400
export DISPUTE_BOND_WEI=100000000000000000 BOND_SINK=$SINK POT_WEI=$POT FOUNDRY_BROADCAST=cache/e2e-broadcast
forge script script/Deploy.s.sol --rpc-url $RPC --unlocked --sender $J0 --broadcast >/dev/null
C=$(python3 -c "import json;print(json.load(open('cache/e2e-broadcast/Deploy.s.sol/31337/run-latest.json'))['transactions'][0]['contractAddress'])")
EXPECT=$(python3 -c "import json;print(json.load(open('data/config.json'))['contract'])")
[ "$(echo "$C" | tr A-F a-f)" = "$(echo "$EXPECT" | tr A-F a-f)" ] || fail "deployed at $C, but the sample result was built for $EXPECT"
ok "deployed at $C (the address the committed sample result was built for); pot $(cast call $C 'pot()(uint256)' --rpc-url $RPC | cut -d' ' -f1) wei"

echo "== jurors submit the sample judgments"
python3 - <<'PY' > /tmp/e2e-batches.txt
import json
js = json.load(open('data/judgments.json'))
by = {}
for j in js: by.setdefault(j['juror'], []).append(j)
for juror, rows in by.items():
    for i in range(0, len(rows), 40):
        print(juror, "[" + ",".join(f'({r["parent"]},{r["a"]},{r["b"]},{r["outcome"]})' for r in rows[i:i+40]) + "]")
PY
while read -r juror batch; do
  cast send $C "submitJudgments((uint16,uint16,uint16,uint8)[])" "$batch" --from $juror --unlocked --rpc-url $RPC >/dev/null
done < /tmp/e2e-batches.txt
N=$(cast call $C 'judgmentCount()(uint256)' --rpc-url $RPC | cut -d' ' -f1)
[ "$N" = "$(python3 -c "import json;print(len(json.load(open('data/judgments.json'))))")" ] || fail "judgment count $N"
ok "$N judgments on-chain"
cast send $C "submitJudgments((uint16,uint16,uint16,uint8)[])" "[(0,0,1,0)]" --from $STRANGER --unlocked --rpc-url $RPC >/dev/null 2>&1 && fail "a non-juror was able to submit"
ok "a non-juror is refused"

echo "== close judging; recompute the result from chain data only"
cast rpc evm_increaseTime 3700 --rpc-url $RPC >/dev/null; cast rpc evm_mine --rpc-url $RPC >/dev/null
node engine/src/cli.ts compute --rpc $RPC --contract $C --from-block 0 --out result.chain.json >/dev/null
cmp data/result.json data/result.chain.json || fail "chain-derived result differs from the committed result"
ok "result recomputed from the chain is byte-identical to data/result.json"
ROOT=$(python3 -c "import json;print(json.load(open('data/result.json'))['root'])")

echo "== propose, then a challenge the jurors reject"
cast send $C "propose(bytes32)" $ROOT --from $J0 --unlocked --rpc-url $RPC >/dev/null
node engine/src/cli.ts reproduce --rpc $RPC --contract $C --from-block 0 | grep -q PASS || fail "reproduce did not pass against the proposal"
ok "node engine/src/cli.ts reproduce --rpc ... passes against the proposed root"
cast send $C "finalize()" --from $STRANGER --unlocked --rpc-url $RPC >/dev/null 2>&1 && fail "finalized before the dispute window closed"
ok "finalize refused while the window is open"
cast send $C "dispute(bytes32)" $(cast keccak "i think it is wrong") --value 0.1ether --from $CHALLENGER --unlocked --rpc-url $RPC >/dev/null
cast send $C "finalize()" --from $STRANGER --unlocked --rpc-url $RPC >/dev/null 2>&1 && fail "finalized with a dispute open"
JURORS_ARR=($(python3 -c "import json;print(' '.join(json.load(open('data/config.json'))['jurors']))"))
cast send $C "voteOnDispute(uint256,bool)" 1 false --from ${JURORS_ARR[0]} --unlocked --rpc-url $RPC >/dev/null 2>&1 && fail "the proposer was allowed to vote on a dispute against their own proposal"
ok "the proposer cannot vote on the dispute against their own result"
for i in 1 2 3; do cast send $C "voteOnDispute(uint256,bool)" 1 false --from ${JURORS_ARR[$i]} --unlocked --rpc-url $RPC >/dev/null; done
[ "$(cast call $C 'credits(address)(uint256)' $SINK --rpc-url $RPC | cut -d' ' -f1)" = "100000000000000000" ] || fail "forfeited bond not credited to the sink"
ok "jurors rejected the dispute; the bond was forfeited to the sink"

if [ "${STOP_AFTER:-}" = "propose" ]; then
  echo "stopped after the dispute (STOP_AFTER=propose). contract $C"; [ "$KEEP" = "--keep" ] && echo "anvil left running on $RPC (pid $ANVIL)"; exit 0
fi

echo "== window closes; finalize; everyone claims"
cast rpc evm_increaseTime 90000 --rpc-url $RPC >/dev/null; cast rpc evm_mine --rpc-url $RPC >/dev/null
cast send $C "finalize()" --from $STRANGER --unlocked --rpc-url $RPC >/dev/null
[ "$(cast call $C 'finalized()(bool)' --rpc-url $RPC)" = "true" ] || fail "not finalized"
ok "finalized by an arbitrary caller"
cast send $C "propose(bytes32)" 0x$(printf 'ab%.0s' $(seq 32)) --from ${JURORS_ARR[1]} --unlocked --rpc-url $RPC >/dev/null 2>&1 && fail "the result was changed after finalization"
ok "the result cannot be changed after finalization"
python3 - <<'PY' > /tmp/e2e-claims.txt
import json
r = json.load(open('data/result.json'))
for a in r['allocations']:
    print(a['recipient'], a['amount'], "[" + ",".join(r['proofs'][a['recipient']]) + "]")
PY
claims=0
while read -r recipient amount proof; do
  before=$(cast balance $recipient --rpc-url $RPC)
  cast send $C "claim(address,uint256,bytes32[])" $recipient $amount "$proof" --from $STRANGER --unlocked --rpc-url $RPC >/dev/null
  [ "$(python3 -c "print($(cast balance $recipient --rpc-url $RPC)-$before)")" = "$amount" ] || fail "$recipient did not receive $amount"
  cast send $C "claim(address,uint256,bytes32[])" $recipient $amount "$proof" --from $STRANGER --unlocked --rpc-url $RPC >/dev/null 2>&1 && fail "$recipient claimed twice"
  claims=$((claims+1))
done < /tmp/e2e-claims.txt
ok "$claims recipients each received exactly their committed amount, once"
[ "$(cast call $C 'totalClaimed()(uint256)' --rpc-url $RPC | cut -d' ' -f1)" = "$POT" ] || fail "claimed total != pot"
cast send $C "withdrawCredit()" --from $SINK --unlocked --rpc-url $RPC >/dev/null
[ "$(cast balance $C --rpc-url $RPC)" = "0" ] || fail "funds left in the contract"
ok "the pot was paid out in full and the contract holds nothing"
rm -f data/result.chain.json
echo "E2E PASSED"
[ "$KEEP" = "--keep" ] && { echo "anvil left running on $RPC (pid $ANVIL); contract $C"; }
exit 0
