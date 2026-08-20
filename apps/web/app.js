/* global ethers */

const RAY = 10n ** 27n;
const CHAIN_ID = 196n;
const ZERO = "0x0000000000000000000000000000000000000000";

const ABI = {
  asset: ["function decimals() view returns (uint8)", "function balanceOf(address) view returns (uint256)", "function allowance(address,address) view returns (uint256)", "function approve(address,uint256) returns (bool)"],
  pool: [
    "function capital() view returns (uint256)", "function outstandingCover() view returns (uint256)", "function freeCapital() view returns (uint256)",
    "function totalShares() view returns (uint256)", "function sharesOf(address) view returns (uint256)",
    "function depositCapital(uint256) returns (uint256)", "function withdrawCapital(uint256) returns (uint256)",
  ],
  registry: [
    "function quotedCount() view returns (uint256)", "function declinedCount() view returns (uint256)", "function decisionCount() view returns (uint256)",
    "function recordDecision((address reserve,uint256 coverAmount,uint256 premiumRateRay,uint64 validUntilBlock,bool declined,bytes32 decisionHash,string engineVersion,uint256 nonce),bytes) returns (bytes32)",
  ],
  vault: [
    "function totalAssets() view returns (uint256)",
    "function positions(address) view returns (uint256 policyId,uint256 shares,uint256 coverAmount,uint256 premiumRateRay,uint64 openedAtBlock)",
    "function depositCovered(uint256,address,bytes32,uint64) returns (uint256 shares,uint256 policyId)",
    "function exit() returns (uint256 assetsReturned,uint256 premiumPaid)",
  ],
  venue: [
    "function venueName() view returns (string)", "function hasYieldSource() view returns (bool)",
    "function observeReserve(address,address) view returns (uint256 deficit,uint256 price,uint256 redeemableLiquidity,uint256 totalSupplied)",
  ],
  resolver: ["function recordObservation(address,address) returns (uint256)"],
};

const state = {
  deployment: null,
  health: null,
  provider: null,
  browserProvider: null,
  signer: null,
  account: null,
  decimals: 6,
  contracts: null,
  decision: null,
  decisionRecorded: false,
};

const $ = (id) => document.getElementById(id);
const setText = (id, value) => { $(id).textContent = value; };
const short = (address) => address ? `${address.slice(0, 6)}…${address.slice(-4)}` : "-";
const units = (value) => `${Number(ethers.formatUnits(value ?? 0n, state.decimals)).toLocaleString(undefined, { maximumFractionDigits: 4 })} USDT`;
const integer = (value) => BigInt(value ?? 0).toLocaleString();
const explorer = (address) => `https://www.oklink.com/x-layer/address/${address}`;

function setStatus(message, kind = "") {
  const element = $("status");
  element.textContent = message;
  element.className = `status ${kind}`;
}

function errorMessage(error) {
  const text = error?.shortMessage || error?.reason || error?.message || String(error);
  return text.replace(/^execution reverted: /i, "").slice(0, 320);
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function formatRate(rate) {
  if (!rate || BigInt(rate) === 0n) return "0 per block";
  return `${ethers.formatUnits(rate, 27)} per block`;
}

async function api(path, options) {
  const response = await fetch(path, options);
  let value = {};
  try {
    value = await response.json();
  } catch {
    value = {};
  }
  if (!response.ok) throw new Error(value.error || `HTTP ${response.status}`);
  return value;
}

function makeContracts(provider) {
  const d = state.deployment;
  return {
    asset: new ethers.Contract(d.asset, ABI.asset, provider),
    pool: new ethers.Contract(d.coverPool, ABI.pool, provider),
    registry: new ethers.Contract(d.pricingRegistry, ABI.registry, provider),
    vault: new ethers.Contract(d.xCoverVault, ABI.vault, provider),
    venue: new ethers.Contract(d.venue, ABI.venue, provider),
    resolver: new ethers.Contract(d.claimResolver, ABI.resolver, provider),
  };
}

async function ensureChain() {
  if (!window.ethereum) throw new Error("No browser wallet found. Install a wallet such as MetaMask.");
  const current = await state.browserProvider.getNetwork();
  if (current.chainId === CHAIN_ID) return;
  const chainId = `0x${CHAIN_ID.toString(16)}`;
  try {
    await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId }] });
  } catch (error) {
    if (error?.code !== 4902) throw error;
    await window.ethereum.request({
      method: "wallet_addEthereumChain",
      params: [{
        chainId,
        chainName: "X Layer Mainnet",
        nativeCurrency: { name: "OKB", symbol: "OKB", decimals: 18 },
        rpcUrls: [state.deployment.rpcUrl],
        blockExplorerUrls: ["https://www.oklink.com/x-layer"],
      }],
    });
  }
}

async function requireSigner() {
  if (!state.browserProvider || !state.account) throw new Error("Connect a wallet first.");
  await ensureChain();
  state.signer = await state.browserProvider.getSigner();
  state.account = await state.signer.getAddress();
  return state.signer;
}

async function transact(label, callback) {
  try {
    setStatus(`${label}: confirm the transaction in your wallet…`);
    const transaction = await callback();
    setStatus(`${label}: waiting for ${transaction.hash.slice(0, 10)}…`);
    await transaction.wait();
    setStatus(`${label}: confirmed.`, "success");
    await refresh();
    return transaction;
  } catch (error) {
    setStatus(`${label} failed: ${errorMessage(error)}`, "error");
    throw error;
  }
}

async function connect() {
  try {
    if (!window.ethereum) throw new Error("No browser wallet found.");
    state.browserProvider = new ethers.BrowserProvider(window.ethereum);
    await state.browserProvider.send("eth_requestAccounts", []);
    await ensureChain();
    state.signer = await state.browserProvider.getSigner();
    state.account = await state.signer.getAddress();
    setText("walletState", short(state.account));
    $("connectButton").textContent = "Wallet connected";
    setStatus(`Connected ${state.account}.`, "success");
    await refresh();
  } catch (error) {
    setStatus(`Wallet connection failed: ${errorMessage(error)}`, "error");
  }
}

async function refresh() {
  if (!state.provider || !state.contracts) return;
  try {
    const { asset, pool, registry, vault, venue } = state.contracts;
    const block = await state.provider.getBlockNumber();
    const [decimals, capital, outstanding, freeCapital, totalShares, vaultAssets, quoted, declined, decisions, observation, venueName, hasYield] = await Promise.all([
      asset.decimals(), pool.capital(), pool.outstandingCover(), pool.freeCapital(), pool.totalShares(), vault.totalAssets(),
      registry.quotedCount(), registry.declinedCount(), registry.decisionCount(), venue.observeReserve(state.deployment.asset, state.deployment.aToken || ZERO),
      venue.venueName(), venue.hasYieldSource(),
    ]);
    state.decimals = Number(decimals);
    setText("blockLabel", integer(block));
    setText("capital", units(capital));
    setText("freeCapital", units(freeCapital));
    setText("outstanding", units(outstanding));
    setText("vaultAssets", units(vaultAssets));
    setText("liquidity", units(observation[2]));
    setText("oraclePrice", `$${ethers.formatUnits(observation[1], 8)}`);
    setText("deficit", units(observation[0]));
    setText("supplied", units(observation[3]));
    setText("deficitKeeper", units(observation[0]));
    setText("suppliedKeeper", units(observation[3]));
    setText("quotedCount", integer(quoted));
    setText("declinedCount", integer(declined));
    setText("decisionCount", integer(decisions));
    setText("totalShares", units(totalShares));
    setText("networkLabel", `X Layer mainnet · ${venueName}${hasYield ? " · Aave V3" : " · custody"}`);
    if (state.account) {
      const balance = await asset.balanceOf(state.account);
      setText("balanceLabel", `USDT balance ${units(balance)}`);
      const position = await vault.positions(state.account);
      renderPosition(position);
    } else {
      setText("balanceLabel", "USDT balance -");
      setText("positionState", "No wallet");
      setText("positionDetails", "Connect a wallet to read your position.");
      $("exitButton").disabled = true;
    }
  } catch (error) {
    setStatus(`Live chain refresh failed: ${errorMessage(error)}`, "error");
  }
}

function renderPosition(position) {
  const policyId = BigInt(position.policyId ?? position[0]);
  const open = policyId !== 0n;
  setText("positionState", open ? `Policy #${policyId}` : "No open position");
  $("exitButton").disabled = !open;
  if (!open) {
    setText("positionDetails", "No open covered position for this wallet.");
    return;
  }
  const shares = position.shares ?? position[1];
  const coverAmount = position.coverAmount ?? position[2];
  const premiumRate = position.premiumRateRay ?? position[3];
  const openedAt = position.openedAtBlock ?? position[4];
  $("positionDetails").innerHTML = `<strong>Policy #${policyId}</strong><br>Covered amount: <strong>${units(coverAmount)}</strong><br>Vault shares: <strong>${units(shares)}</strong><br>Premium: <strong>${formatRate(premiumRate)}</strong><br>Opened at block: <strong>${integer(openedAt)}</strong>`;
}

function amountFrom(id) {
  const raw = $(id).value.trim();
  const label = id === "coveredAmount" ? "Covered" : id === "withdrawShares" ? "Withdrawal" : "Capital";
  if (!raw || !/^\d+(\.\d+)?$/.test(raw)) throw new Error(`${label} amount must be a positive number.`);
  try {
    const amount = ethers.parseUnits(raw, state.decimals);
    if (amount <= 0n) throw new Error(`${label} amount must be greater than zero.`);
    return amount;
  } catch (error) {
    throw new Error(error?.message?.includes("greater than zero") ? error.message : `${label} amount has too many decimal places.`);
  }
}

async function approveAsset(spender, amount, label) {
  const signer = await requireSigner();
  const asset = new ethers.Contract(state.deployment.asset, ABI.asset, signer);
  return transact(label, () => asset.approve(spender, amount));
}

async function depositCapital() {
  const amount = amountFrom("capitalAmount");
  const signer = await requireSigner();
  const pool = new ethers.Contract(state.deployment.coverPool, ABI.pool, signer);
  return transact("Capital deposit", () => pool.depositCapital(amount));
}

async function withdrawCapital() {
  const shares = amountFrom("withdrawShares");
  const signer = await requireSigner();
  const pool = new ethers.Contract(state.deployment.coverPool, ABI.pool, signer);
  return transact("Capital withdrawal", () => pool.withdrawCapital(shares));
}

async function requestQuote() {
  try {
    const amount = amountFrom("coveredAmount");
    setStatus("Getting a live price…");
    const result = await api("/decision", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ coverAmount: amount.toString() }) });
    state.decision = result;
    state.decisionRecorded = false;
    const decision = result.decision;
    const declined = decision.declined;
    const document = result.canonicalJson ? JSON.parse(result.canonicalJson) : result.document;
    const reasons = document?.gate?.reasons || document?.declineReason || [];
    const reasonText = Array.isArray(reasons) ? reasons.join(", ") : reasons;
    const resultElement = $("quoteResult");
    resultElement.className = `quote-result ${declined ? "decline" : "quote"}`;
    resultElement.innerHTML = `<strong>${declined ? "PRICE DECLINED" : "PRICE READY"}</strong><br>${declined ? `Reason: ${escapeHtml(reasonText || "not supplied")}` : `Premium: ${formatRate(decision.premiumRateRay)}<br>Valid through block ${integer(decision.validUntilBlock)}`}<br><span>Signed pricing decision from xCover</span>`;
    $("recordDecisionButton").disabled = false;
    $("approveCoveredButton").disabled = declined;
    $("depositCoveredButton").disabled = true;
    setStatus(declined ? "This covered deposit was declined; no deposit was attempted." : "Price received. Record it before depositing.", declined ? "error" : "success");
  } catch (error) {
    setStatus(`Quote request failed: ${errorMessage(error)}`, "error");
  }
}

async function recordDecision() {
  try {
    if (!state.decision) throw new Error("Request a decision first.");
    const signer = await requireSigner();
    const registry = new ethers.Contract(state.deployment.pricingRegistry, ABI.registry, signer);
    const d = state.decision.decision;
    await transact("Record decision", () => registry.recordDecision({
      reserve: d.reserve, coverAmount: d.coverAmount, premiumRateRay: d.premiumRateRay, validUntilBlock: d.validUntilBlock,
      declined: d.declined, decisionHash: d.decisionHash, engineVersion: d.engineVersion, nonce: d.nonce,
    }, state.decision.signature));
    state.decisionRecorded = true;
    $("recordDecisionButton").disabled = true;
    $("depositCoveredButton").disabled = Boolean(d.declined);
  } catch (error) {
    setStatus(`Recording decision failed: ${errorMessage(error)}`, "error");
  }
}

async function depositCovered() {
  try {
    if (!state.decision || state.decision.decision.declined) throw new Error("There is no live quote to deposit against.");
    if (!state.decisionRecorded) throw new Error("Record the signed decision first.");
    const amount = amountFrom("coveredAmount");
    const term = BigInt($("termBlocks").value.trim());
    if (term <= 0n) throw new Error("Term must be greater than zero blocks.");
    const signer = await requireSigner();
    const vault = new ethers.Contract(state.deployment.xCoverVault, ABI.vault, signer);
    await transact("Covered deposit", () => vault.depositCovered(amount, state.account, state.decision.quoteHash, term));
    setStatus("Covered position opened. Your position is now active.", "success");
  } catch (error) {
    setStatus(`Covered deposit failed: ${errorMessage(error)}`, "error");
  }
}

async function exitPosition() {
  try {
    const signer = await requireSigner();
    const vault = new ethers.Contract(state.deployment.xCoverVault, ABI.vault, signer);
    await transact("Exit position", () => vault.exit());
  } catch (error) {
    setStatus(`Exit failed: ${errorMessage(error)}`, "error");
  }
}

async function recordObservation() {
  try {
    const signer = await requireSigner();
    const resolver = new ethers.Contract(state.deployment.claimResolver, ABI.resolver, signer);
    await transact("Record observation", () => resolver.recordObservation(state.deployment.asset, state.deployment.aToken || ZERO));
  } catch (error) {
    setStatus(`Observation failed: ${errorMessage(error)}`, "error");
  }
}

async function boot() {
  try {
    state.deployment = await api("/deployment");
    state.health = await api("/health");
    state.provider = new ethers.JsonRpcProvider(
      `${window.location.origin}/rpc`,
      Number(state.deployment.chainId),
      { batchMaxCount: 1, batchStallTime: 0 },
    );
    state.contracts = makeContracts(state.provider);
    setText("agentLabel", "AI pricing live");
    $("explorerLink").href = explorer(state.deployment.xCoverVault);
    await refresh();
    setStatus("Live mainnet state loaded. Connect a wallet to transact.", "success");
  } catch (error) {
    setStatus(`Dashboard could not start: ${errorMessage(error)}`, "error");
  }
}

function openDashboard(event) {
  event?.preventDefault();
  const dashboard = $("dashboardApp");
  dashboard.hidden = false;
  dashboard.scrollIntoView({ behavior: "smooth", block: "start" });
}

$("connectButton").addEventListener("click", connect);
$("refreshButton").addEventListener("click", refresh);
$("approveCapitalButton").addEventListener("click", async () => { try { await approveAsset(state.deployment.coverPool, amountFrom("capitalAmount"), "Capital approval"); } catch {} });
$("depositCapitalButton").addEventListener("click", async () => { try { await depositCapital(); } catch {} });
$("withdrawCapitalButton").addEventListener("click", async () => { try { await withdrawCapital(); } catch {} });
$("quoteButton").addEventListener("click", requestQuote);
$("recordDecisionButton").addEventListener("click", recordDecision);
$("approveCoveredButton").addEventListener("click", async () => { try { await approveAsset(state.deployment.xCoverVault, amountFrom("coveredAmount"), "Covered deposit approval"); } catch {} });
$("depositCoveredButton").addEventListener("click", depositCovered);
$("exitButton").addEventListener("click", exitPosition);
$("observeButton").addEventListener("click", recordObservation);
document.querySelectorAll("[data-open-dashboard]").forEach((element) => element.addEventListener("click", openDashboard));
if (window.location.hash === "#dashboard") openDashboard();

if (window.ethereum) {
  window.ethereum.on?.("accountsChanged", () => connect());
  window.ethereum.on?.("chainChanged", () => refresh());
}

boot();
