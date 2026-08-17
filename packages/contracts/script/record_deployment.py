#!/usr/bin/env python3
"""Merge a broadcast artifact into a deployment record.

`DeployBase._writeRecord` writes the addresses, block number and timestamp from inside the EVM.
It cannot write transaction hashes, because a script does not know the hashes of the transactions
it is producing. Those live in Foundry's broadcast artifact, so this reads them from there and
merges them in, keyed by the address they created.

SPEC 3.5 requires the record to carry addresses, deployment transaction hashes, block numbers and
timestamps, so that the testnet-before-mainnet order is provable rather than asserted. This exists
so producing that record is one reproducible command and not a hand-edit nobody can check.

Usage:
    python3 script/record_deployment.py xlayer-testnet DeployTestnet.s.sol 1952
"""

import json
import sys
from pathlib import Path

EXPLORERS = {
    196: "https://www.oklink.com/x-layer",
    1952: "https://www.oklink.com/x-layer-testnet",
}


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__)
        return 2

    network, script_name, chain_id = sys.argv[1], sys.argv[2], int(sys.argv[3])
    root = Path(__file__).resolve().parents[3]
    record_path = root / "deployments" / f"{network}.json"
    broadcast_path = (
        root / "packages/contracts/broadcast" / script_name / str(chain_id) / "run-latest.json"
    )

    if not record_path.exists():
        print(f"no deployment record at {record_path} — broadcast the deploy script first")
        return 1
    if not broadcast_path.exists():
        print(f"no broadcast artifact at {broadcast_path}")
        return 1

    record = json.loads(record_path.read_text())
    broadcast = json.loads(broadcast_path.read_text())

    # The first transaction that creates a given address is its deployment; later ones to the same
    # address are the role grants, which are not what we are recording here.
    creations: dict[str, str] = {}
    for tx in broadcast["transactions"]:
        if tx.get("transactionType") != "CREATE":
            continue
        addr = (tx.get("contractAddress") or "").lower()
        if addr and addr not in creations:
            creations[addr] = tx["hash"]

    explorer = EXPLORERS.get(chain_id)
    tx_hashes: dict[str, str] = {}
    explorer_urls: dict[str, str] = {}

    for key, value in record.items():
        if not (isinstance(value, str) and value.startswith("0x") and len(value) == 42):
            continue
        addr = value.lower()
        if addr in creations:
            tx_hashes[key] = creations[addr]
        if explorer:
            explorer_urls[key] = f"{explorer}/address/{value}"

    record["deploymentTxHashes"] = tx_hashes
    record["deployerAddress"] = broadcast["transactions"][0]["transaction"]["from"]
    if explorer:
        record["explorer"] = explorer_urls

    missing = [k for k in ("coverPool", "coverPolicy", "xCoverVault") if k not in tx_hashes]
    if missing:
        print(f"WARNING: no creation transaction found for {missing}")

    record_path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
    print(f"merged {len(tx_hashes)} deployment transaction hashes into {record_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
