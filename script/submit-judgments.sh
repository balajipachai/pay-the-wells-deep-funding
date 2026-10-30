#!/usr/bin/env bash
# A juror submits their answers on-chain. Usage: script/submit-judgments.sh <answers.json> [keystore-account]
# answers.json is the output of `node engine/src/cli.ts ballot` with every "outcome" filled in
# (0 = the first mattered more, 1 = the second mattered more, 2 = about equal). Unanswered pairs are skipped.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; [ -f .env ] && . ./.env; set +a
ANSWERS="${1:?usage: submit-judgments.sh <answers.json> [keystore-account]}"; ACCOUNT="${2:-${KEYSTORE_ACCOUNT:-deployer}}"
CONTRACT=$(python3 -c "import json;print(json.load(open('frontend/deployment.json'))['address'])")
python3 - "$ANSWERS" <<'PY' > /tmp/judgment-batches.txt
import json, sys
rows = [r for r in json.load(open(sys.argv[1])) if r.get("outcome") in (0, 1, 2)]
for i in range(0, len(rows), 25):
    print("[" + ",".join(f'({r["parent"]},{r["a"]},{r["b"]},{r["outcome"]})' for r in rows[i:i+25]) + "]")
PY
n=0; while read -r batch; do
  n=$((n+1)); echo "batch $n"
  cast send "$CONTRACT" "submitJudgments((uint16,uint16,uint16,uint8)[])" "$batch" --rpc-url "$SEPOLIA_RPC_URL" --account "$ACCOUNT"
done < /tmp/judgment-batches.txt
echo "submitted $n batch(es); on-chain judgment count: $(cast call "$CONTRACT" 'judgmentCount()(uint256)' --rpc-url "$SEPOLIA_RPC_URL")"
