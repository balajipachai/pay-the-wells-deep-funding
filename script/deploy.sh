#!/usr/bin/env bash
# Deploys DeepFunding to Sepolia, verifies the source, and confirms the deployment landed.
# Reads .env: SEPOLIA_RPC_URL, DEPLOYER, JURORS, BOND_SINK, JUDGING_SECONDS, DISPUTE_WINDOW_SECONDS,
# DISPUTE_BOND_WEI, optional POT_WEI, ETHERSCAN_API_KEY, KEYSTORE_ACCOUNT (default: deployer).
# The signer is a Foundry keystore (`cast wallet import`). No private key is read from any file.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; [ -f .env ] && . ./.env; set +a
for v in SEPOLIA_RPC_URL DEPLOYER JURORS BOND_SINK JUDGING_SECONDS DISPUTE_WINDOW_SECONDS DISPUTE_BOND_WEI; do
  [ -n "${!v:-}" ] || { echo "error: $v is not set (add it to .env)" >&2; exit 1; }
done
ACCOUNT="${KEYSTORE_ACCOUNT:-deployer}"; CHAIN_ID=11155111
[ "$(cast chain-id --rpc-url "$SEPOLIA_RPC_URL")" = "$CHAIN_ID" ] || { echo "error: RPC is not Sepolia" >&2; exit 1; }

# The graph the round is about is fixed at deployment by its hash; the engine computes it from data/graph.json.
export GRAPH_HASH=$(node engine/src/cli.ts graph-hash)
export PACKAGE_COUNT=$(python3 -c "import json;print(len(json.load(open('data/graph.json'))['packages']))")

verify_args=(--verify --verifier sourcify)
[ -n "${ETHERSCAN_API_KEY:-}" ] && verify_args=(--verify --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY")

# --skip-simulation takes gas estimates from the node: forge's local estimate is far below what Sepolia
# charges for contract creation, so a deployment sized by it ran out of gas on-chain and deployed nothing.
forge script script/Deploy.s.sol \
  --rpc-url "$SEPOLIA_RPC_URL" --account "$ACCOUNT" --sender "$DEPLOYER" \
  --broadcast --skip-simulation --slow "${verify_args[@]}"

RECORD="broadcast/Deploy.s.sol/$CHAIN_ID/run-latest.json"
read -r ADDRESS TX < <(python3 -c "
import json
t=json.load(open('$RECORD'))['transactions'][0]
print(t['contractAddress'], t['hash'])")
STATUS=$(cast receipt "$TX" status --rpc-url "$SEPOLIA_RPC_URL" || true)
CODE=$(cast code "$ADDRESS" --rpc-url "$SEPOLIA_RPC_URL")
if [[ "$STATUS" != "true" && "$STATUS" != 1* && "$STATUS" != *success* ]] || [ "$CODE" = "0x" ]; then
  echo "DEPLOY FAILED: tx $TX status='$STATUS', no code at $ADDRESS. Do not record this address." >&2; exit 1
fi
[ "$(cast call "$ADDRESS" 'graphHash()(bytes32)' --rpc-url "$SEPOLIA_RPC_URL")" = "$GRAPH_HASH" ] || { echo "graphHash on-chain differs from data/graph.json" >&2; exit 1; }
BLOCK=$(cast receipt "$TX" blockNumber --rpc-url "$SEPOLIA_RPC_URL")
printf '{\n  "address": "%s",\n  "chainId": %s,\n  "deployBlock": %s\n}\n' "$ADDRESS" "$CHAIN_ID" "$BLOCK" > frontend/deployment.json

echo
echo "Deployed DeepFunding at $ADDRESS (block $BLOCK)"
echo "  pot:             $(cast call "$ADDRESS" 'pot()(uint256)' --rpc-url "$SEPOLIA_RPC_URL") wei"
echo "  jurors:          $(cast call "$ADDRESS" 'jurorList()(address[])' --rpc-url "$SEPOLIA_RPC_URL")"
echo "  judging closes:  $(cast call "$ADDRESS" 'judgmentDeadline()(uint256)' --rpc-url "$SEPOLIA_RPC_URL")"
echo "  https://sepolia.etherscan.io/address/$ADDRESS"
echo "Wrote frontend/deployment.json. Next: jurors run script/submit-judgments.sh, then script/propose.sh after judging closes."
