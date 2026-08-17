// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title XLayerAddresses
/// @notice Aave V3 addresses on X Layer mainnet (chain id 196), confirmed on
///         chain at block 68179960. See docs/chain-verification.md for the raw
///         responses behind every entry here.
/// @dev These are mainnet-only. Aave V3 is not deployed on X Layer testnet
///      (chain id 1952) — empty code at both POOL and POOL_ADDRESSES_PROVIDER —
///      so the testnet deployment runs TestnetVenue instead. Never reference
///      this library from a code path that can execute on testnet.
library XLayerAddresses {
    uint256 internal constant CHAIN_ID_MAINNET = 196;
    uint256 internal constant CHAIN_ID_TESTNET = 1952;

    // --- Aave V3 core ---
    address internal constant POOL = 0xE3F3Caefdd7180F884c01E57f65Df979Af84f116;
    address internal constant POOL_ADDRESSES_PROVIDER = 0xdFf435BCcf782f11187D3a4454d96702eD78e092;
    address internal constant POOL_CONFIGURATOR = 0x1408b48B6A610948f04813EA6b2F438A6BBAd2f2;
    address internal constant ORACLE = 0x91FC11136d5615575a0fC5981Ab5C0C54418E2C6;
    address internal constant DATA_PROVIDER = 0x6C505C31714f14e8af2A03633EB2Cdfb4959138F;
    address internal constant POOL_IMPL = 0x5Bc7204274230a8F4778a35A58B776D16CF104b4;
    address internal constant UI_POOL_DATA_PROVIDER = 0xc851e6147dcE6A469CC33BE3121b6B2D4CaD2763;
    address internal constant RISK_STEWARD = 0x7D0219C7037819B3F5d73E235C595189C3F8c224;

    // --- The covered reserve. Launch covers USDT only (spec 3.2). ---
    address internal constant USDT = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address internal constant USDT_A_TOKEN = 0xF356ae412dB5df43BD3a10746f7ad4e1C4De4297;
    address internal constant USDT_V_TOKEN = 0x04837866D0cb0cd2D8F60fBCa83B4a24b3a7c8ac;
    address internal constant USDT_ORACLE = 0x7ec7E5497EAf312FE82F8307D05eb0E5f0f157D3;

    uint8 internal constant USDT_DECIMALS = 6;

    /// @notice Aave prices assets in a base currency with 8 decimals.
    uint256 internal constant ORACLE_PRICE_UNIT = 1e8;

    /// @notice Pool revision observed on chain. getReserveDeficit was introduced
    ///         in Aave v3.3; revision 11 is consistent with that and the call
    ///         returns cleanly, so the deficit trigger is buildable as specified.
    uint256 internal constant EXPECTED_POOL_REVISION = 11;
}
