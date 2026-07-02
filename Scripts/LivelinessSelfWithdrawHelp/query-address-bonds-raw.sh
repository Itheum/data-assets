#!/usr/bin/env bash
set -euo pipefail

# Raw curl query for active bonds.
# Decoding returnData uses python3 when available (macOS/Linux usually have it).
#
# Usage:
#   ./interaction/query-address-bonds-raw.sh <wallet-pubkey-hex>
#
# The MultiversX vm-values/query API expects the wallet as hex (32-byte pubkey),
# not erd1... bech32. If you only have an erd1 address, get hex once with:
#   mxpy wallet bech32 --decode erd1youraddress...
#
# Optional env:
#   API_URL    (default: https://api.multiversx.com)
#   SC_ADDRESS (default: mainnet life bonding contract)

API_URL="${API_URL:-https://api.multiversx.com}"
SC_ADDRESS="${SC_ADDRESS:-erd1qqqqqqqqqqqqqpgq9yfa4vcmtmn55z0e5n84zphf2uuuxxw9c77qgqqwkn}" # mainnet life bonding contract

ADDR_HEX="${1:-}"
if [[ -z "${ADDR_HEX}" ]]; then
  echo "Usage: $0 <wallet-pubkey-hex>" >&2
  echo "Example: $0 4bd4034bc2c3611a1dbf22dcaa210bc399c735f4ae3db458f79cc0e001f7986b" >&2
  exit 1
fi

if [[ "${ADDR_HEX}" == erd1* ]]; then
  echo "Error: pass pubkey hex, not erd1 bech32." >&2
  echo "Run: mxpy wallet bech32 --decode ${ADDR_HEX}" >&2
  exit 1
fi

ADDR_HEX="${ADDR_HEX#0x}"

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required." >&2
  exit 1
fi

RESPONSE="$(curl -s "${API_URL}/vm-values/query" \
  -H "Content-Type: application/json" \
  -d "{
    \"scAddress\": \"${SC_ADDRESS}\",
    \"funcName\": \"getAddressBonds\",
    \"args\": [\"${ADDR_HEX}\"]
  }")"

printf '%s\n' "${RESPONSE}"

B64="$(printf '%s' "${RESPONSE}" | sed -n 's/.*"returnData":[[:space:]]*\[[[:space:]]*"\([^"]*\)".*/\1/p')"

if [[ -z "${B64}" ]]; then
  echo
  echo "No returnData found (no active bonds, or query failed)."
  exit 0
fi

echo
echo "Active bonds (token_identifier + nonce for withdraw):"
echo "token_identifier       nonce"
echo "--------------------   -----"

if command -v python3 >/dev/null 2>&1; then
  B64="${B64}" python3 <<'PY'
import base64
import os
import struct

data = base64.b64decode(os.environ["B64"])

def read_u64(buf, i):
    return struct.unpack_from(">Q", buf, i)[0], i + 8

def read_token(buf, i):
    (length,) = struct.unpack_from(">I", buf, i)
    i += 4
    value = buf[i : i + length].decode()
    return value, i + length

def read_biguint(buf, i):
    (length,) = struct.unpack_from(">I", buf, i)
    i += 4
    if length == 0:
        return 0, i
    return int.from_bytes(buf[i : i + length], "big"), i + length

i = 0
while i < len(data):
    _, i = read_u64(data, i)
    i += 32
    token, i = read_token(data, i)
    nonce, i = read_u64(data, i)
    i += 8 * 3
    _, i = read_biguint(data, i)
    _, i = read_biguint(data, i)
    print(f"{token:<20} {nonce}")
PY
else
  printf '%s' "${B64}" | base64 -d 2>/dev/null | strings | grep -E '^[A-Z0-9]+-[a-f0-9]+$' || true
  echo
  echo "Install python3 for nonce values, or use query-address-bonds.sh" >&2
fi
