#!/usr/bin/env bash
# After judging closes, a juror recomputes the result from the chain and proposes its root.
# Usage: script/propose.sh [keystore-account]. Anyone can verify afterwards with: npm --prefix engine run reproduce -- --rpc <url> --contract <addr>
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; [ -f .env ] && . ./.env; set +a
ACCOUNT="${1:-${KEYSTORE_ACCOUNT:-deployer}}"
CONTRACT=$(python3 -c "import json;print(json.load(open('frontend/deployment.json'))['address'])")
node engine/src/cli.ts compute --rpc "$SEPOLIA_RPC_URL" --contract "$CONTRACT" --publish
ROOT=$(python3 -c "import json;print(json.load(open('data/result.chain.json'))['root'])")
echo "proposing root $ROOT"
cast send "$CONTRACT" "propose(bytes32)" "$ROOT" --rpc-url "$SEPOLIA_RPC_URL" --account "$ACCOUNT"
echo "proposed. The dispute window is now open: $(cast call "$CONTRACT" 'disputeWindow()(uint256)' --rpc-url "$SEPOLIA_RPC_URL") seconds."
