#!/usr/bin/env bash
set -euo pipefail

# Query active bonds for a wallet address via the MultiversX API (read-only).
#
# Usage:
#   ./interaction/query-address-bonds.sh <erd1...address>
#   ./interaction/query-address-bonds.sh erd1f02qxj7zcds358dlytw25ggtcwvuwd054c7mgk8hnnqwqq0hnp4sad5209
#
# Optional env overrides:
#   API_URL      (default: https://api.multiversx.com)
#   SC_ADDRESS   (default: mainnet life bonding contract)
#   TOKEN_DECIMALS (default: 18)

API_URL="${API_URL:-https://api.multiversx.com}"
SC_ADDRESS="${SC_ADDRESS:-erd1qqqqqqqqqqqqqpgq9yfa4vcmtmn55z0e5n84zphf2uuuxxw9c77qgqqwkn}" # mainnet life bonding contract
TOKEN_DECIMALS="${TOKEN_DECIMALS:-18}"

USER_ADDRESS="${1:-}"
if [[ -z "${USER_ADDRESS}" ]]; then
  echo "Usage: $0 <erd1...address>" >&2
  exit 1
fi

if ! command -v mxpy >/dev/null 2>&1; then
  echo "mxpy is required to encode the address argument." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to decode and format the response." >&2
  exit 1
fi

ADDRESS_HEX="$(mxpy wallet bech32 --decode "${USER_ADDRESS}")"

RESPONSE="$(curl -sf "${API_URL}/vm-values/query" \
  -H "Content-Type: application/json" \
  -d "{
    \"scAddress\": \"${SC_ADDRESS}\",
    \"funcName\": \"getAddressBonds\",
    \"args\": [\"${ADDRESS_HEX}\"]
  }")"

RESPONSE_JSON="${RESPONSE}" python3 - "${USER_ADDRESS}" "${SC_ADDRESS}" "${TOKEN_DECIMALS}" <<'PY'
import base64
import json
import os
import sys
from datetime import datetime, timezone

response = json.loads(os.environ["RESPONSE_JSON"])
user_address = sys.argv[1]
sc_address = sys.argv[2]
token_decimals = int(sys.argv[3])


def read_u64(buf, i):
    return int.from_bytes(buf[i : i + 8], "big"), i + 8


def read_token_id(buf, i):
    length = int.from_bytes(buf[i : i + 4], "big")
    i += 4
    value = buf[i : i + length].decode()
    return value, i + length


def read_biguint(buf, i):
    length = int.from_bytes(buf[i : i + 4], "big")
    i += 4
    if length == 0:
        return 0, i
    return int.from_bytes(buf[i : i + length], "big"), i + length


def format_amount(raw_amount):
    if raw_amount == 0:
        return "0"
    whole = raw_amount // (10**token_decimals)
    fraction = raw_amount % (10**token_decimals)
    if fraction == 0:
        return f"{whole:,}"
    text = f"{whole:,}.{fraction:0{token_decimals}d}".rstrip("0").rstrip(".")
    return text


def format_timestamp(ts):
    if ts == 0:
        return "-"
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")


def parse_bonds(data):
    bonds = []
    i = 0
    while i < len(data):
        bond_id, i = read_u64(data, i)
        i += 32  # ManagedAddress
        token_identifier, i = read_token_id(data, i)
        nonce, i = read_u64(data, i)
        lock_period, i = read_u64(data, i)
        bond_timestamp, i = read_u64(data, i)
        unbond_timestamp, i = read_u64(data, i)
        bond_amount, i = read_biguint(data, i)
        remaining_amount, i = read_biguint(data, i)
        bonds.append(
            {
                "bond_id": bond_id,
                "token_identifier": token_identifier,
                "nonce": nonce,
                "lock_period": lock_period,
                "bond_timestamp": bond_timestamp,
                "unbond_timestamp": unbond_timestamp,
                "bond_amount": bond_amount,
                "remaining_amount": remaining_amount,
            }
        )
    return bonds


code = response.get("code")
if code != "successful":
    print(json.dumps(response, indent=2))
    sys.exit(1)

return_data = response.get("data", {}).get("data", {}).get("returnData", [])
if not return_data:
    print(f"Address:  {user_address}")
    print(f"Contract: {sc_address}")
    print()
    print("No active bonds found.")
    sys.exit(0)

raw = base64.b64decode(return_data[0])
bonds = parse_bonds(raw)

print(f"Address:  {user_address}")
print(f"Contract: {sc_address}")
print(f"Active bonds: {len(bonds)}")
print()

headers = [
    "bond_id",
    "token_identifier",
    "nonce",
    "remaining",
    "bond_amount",
    "unbond_at",
    "lock_s",
]

rows = []
for bond in bonds:
    rows.append(
        [
            str(bond["bond_id"]),
            bond["token_identifier"],
            str(bond["nonce"]),
            format_amount(bond["remaining_amount"]),
            format_amount(bond["bond_amount"]),
            format_timestamp(bond["unbond_timestamp"]),
            str(bond["lock_period"]),
        ]
    )

widths = [len(h) for h in headers]
for row in rows:
    for idx, cell in enumerate(row):
        widths[idx] = max(widths[idx], len(cell))

def print_row(cells):
    print("  ".join(cell.ljust(widths[idx]) for idx, cell in enumerate(cells)))


print_row(headers)
print_row(["-" * w for w in widths])
for row in rows:
    print_row(row)

print()
print("Withdraw args per bond: <token_identifier> <nonce>")
print("Example:")
if bonds:
    example = bonds[0]
    print(
        f"  mxpy contract call {sc_address} --function withdraw "
        f"--arguments 0x{example['token_identifier'].encode().hex()} {example['nonce']}"
    )
PY
