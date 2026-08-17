# Chain verification — X Layer

Raw output of the §3.3 blocking verification and the §3.5 testnet probe.
Re-run with `scripts/verify-chain.sh`. This file is evidence; do not edit the
recorded responses by hand.

**Run at:** 2026-08-17T06:43:17Z
**Tooling:** foundry `cast` 1.7.1 (4072e487)

## Endpoints

| Network | RPC | `eth_chainId` | Decimal |
|---|---|---|---|
| X Layer mainnet | `https://rpc.xlayer.tech` | `0xc4` | 196 |
| X Layer mainnet (fallback) | `https://xlayerrpc.okx.com` | `0xc4` | 196 |
| X Layer testnet | `https://testrpc.xlayer.tech` | `0x7a0` | **1952** |

Note: the testnet chain id is **1952**, not 195. Chain id 195 is listed on
ChainList as X Layer Testnet (Deprecated). Use 1952 in `foundry.toml`, the
frontend chain config, and every deployment record. Rate limit on both networks
is 100 requests/second/IP, which constrains keeper polling frequency (§5.5).

**Mainnet block at verification:** `68179960`

---

## §3.3 Mainnet verification — all five calls

### 1. `getReserveDeficit(address)` on `Pool` — **PRESENT, does not revert**

```
$ cast call 0xE3F3Caefdd7180F884c01E57f65Df979Af84f116 \
    "getReserveDeficit(address)(uint256)" \
    0x779Ded0c9e1022225f8E0630b35a9b54bE713736 --rpc-url $XLAYER_RPC
0
```

The single blocking dependency is **resolved**. The function exists and returns
cleanly. Current deficit on USDT is `0` — no bad debt outstanding, which is the
expected healthy-state reading and the correct baseline for the trigger.

**Consequence:** the deficit trigger (§2.3 row 1) is buildable as specified. The
redemption-failure fallback is **not** needed as the primary trigger.

### 2. `POOL_REVISION()` — revision `11`

```
$ cast call 0xE3F3Caefdd7180F884c01E57f65Df979Af84f116 \
    "POOL_REVISION()(uint256)" --rpc-url $XLAYER_RPC
11
```

Consistent with Aave v3.3+, which is where `getReserveDeficit` was introduced.
Corroborates call 1.

Implementation address behind the proxy, read from the ERC-1967 implementation
slot `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`:

```
0x0000000000000000000000005bc7204274230a8f4778a35a58b776d16cf104b4
```

= `0x5Bc7204274230a8F4778a35A58B776D16CF104b4`, which **matches the `POOL_IMPL`
address recorded in §3.1**. The address book entry is confirmed on chain.

### 3. `getReserveData(address)` on `AaveProtocolDataProvider`

```
$ cast call 0x6C505C31714f14e8af2A03633EB2Cdfb4959138F \
    "getReserveData(address)" \
    0x779Ded0c9e1022225f8E0630b35a9b54bE713736 --rpc-url $XLAYER_RPC
0x0000000000000000000000000000000000000000000000000000000000000000
  00000000000000000000000000000000000000000000000000000000792b960b
  00000000000000000000000000000000000000000000000000002da8ab0b6e75
  0000000000000000000000000000000000000000000000000000000000000000
  00000000000000000000000000000000000000000000000b28b540ac34000000
  00000000000000000000000000000000000027860c47470189a9f1b5f0000000
  0000000000000000000000000000000000000b3b16542221baf7caf3a7000000
  0000000000000000000000000000000000000000000000000000000000000000
  0000000000000000000000000000000000000000000000000000000000000000
  0000000000000000000000000000000000000000033c04efeb13771a3b75ba09
  000000000000000000000000000000000000000000033e52ed599f31709fa200
  fc000000000000000000000000000000000000000000000000000000006a82ad84
```

(returned as a single unbroken hex string; wrapped here at 32-byte boundaries
for readability only)

Final word `0x6a82ad84` = `1786948996` = **2026-08-17T06:43:16Z**, the
`lastUpdateTimestamp`. That is the same second as the verification call, so the
reserve is not merely deployed — it is being actively transacted against.

Configuration, decoded via `getReserveConfigurationData`:

| Field | Value |
|---|---|
| `decimals` | 6 |
| `ltv` | 7000 (70.00%) |
| `liquidationThreshold` | 7500 (75.00%) |
| `liquidationBonus` | 10750 (7.50% bonus) |
| `reserveFactor` | 1000 (10.00%) |
| `usageAsCollateralEnabled` | true |
| `borrowingEnabled` | true |
| `stableBorrowRateEnabled` | false |
| **`isActive`** | **true** |
| **`isFrozen`** | **false** |

Reserve is live, active, unfrozen, borrowable, and usable as collateral — the
conditions the cover product assumes.

### 4. aToken `totalSupply()` — real deposits exist

```
$ cast call 0xF356ae412dB5df43BD3a10746f7ad4e1C4De4297 \
    "totalSupply()(uint256)" --rpc-url $XLAYER_RPC
50202447313678
```

At 6 decimals = **50,202,447.313678 USDT** supplied. This is a real reserve with
real depositors, not an empty deployment. It is also the denominator for any
honest statement about what fraction of the reserve xCover could cover.

### 5. Oracle liveness — `getAssetPrice(address)`

```
$ cast call 0x91FC11136d5615575a0fC5981Ab5C0C54418E2C6 \
    "getAssetPrice(address)(uint256)" \
    0x779Ded0c9e1022225f8E0630b35a9b54bE713736 --rpc-url $XLAYER_RPC
99896524
```

Aave oracle base currency is 8 decimals, so **$0.99896524** per USDT — a live,
plausible, slightly-off-peg quote. The oracle responds and is not stale-zero.

The 10 bp deviation from $1.00 is itself worth noting: the depeg trigger
threshold (§2.3 row 3) must sit well outside normal oracle noise of this
magnitude, or it will fire on nothing. Feed this into the threshold derivation
in `bench/threshold-derivation.md`.

---

## §3.5 Testnet probe — Aave is **not** on X Layer testnet

```
$ cast chain-id --rpc-url https://testrpc.xlayer.tech
1952
$ cast block-number --rpc-url https://testrpc.xlayer.tech
38490185

$ cast code 0xE3F3Caefdd7180F884c01E57f65Df979Af84f116 --rpc-url $XLAYER_TESTNET_RPC
0x
$ cast code 0xdFf435BCcf782f11187D3a4454d96702eD78e092 --rpc-url $XLAYER_TESTNET_RPC
0x
```

Empty code at both the `POOL` and the `POOL_ADDRESSES_PROVIDER` addresses.
**Aave V3 is not deployed on X Layer testnet.** The prediction in §3.5 is
confirmed on chain.

**Consequences, binding on the build:**

1. `IYieldVenue` with a swappable implementation is **required**, not optional.
   `TestnetVenue` backs the testnet deployment; `AaveV3Venue` backs mainnet.
2. The eligibility gate (testnet during the hackathon, mainnet subsequently,
   order provable) is still satisfiable — the testnet deployment is a real
   deployment of the real xCover contracts, with only the yield venue differing.
3. `docs/deployments.md` must state the venue difference plainly rather than
   implying the testnet deployment has a live Aave integration behind it.
4. `AaveV3Venue` must expose no `induceDeficit`-style surface, and the config
   loader must throw when chain environment and venue implementation disagree
   (both are already in the §11 definition of done).

---

## Summary

| Check | Result |
|---|---|
| `getReserveDeficit` present and non-reverting | **Yes** — blocking dependency cleared |
| Pool revision consistent with v3.3+ | Yes — revision 11 |
| `POOL_IMPL` matches address book | Yes |
| USDT reserve active and unfrozen | Yes |
| Real deposits in the reserve | Yes — 50.2M USDT |
| Oracle live | Yes — $0.99896524 |
| Aave on X Layer testnet | **No** — `TestnetVenue` required |
| Testnet chain id | **1952**, not 195 |

No fallback trigger substitution is needed. Primary claim trigger proceeds as
specified.
