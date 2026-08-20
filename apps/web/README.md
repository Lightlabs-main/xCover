# xCover web app

xCover is an AI pricing agent for Aave V3 depositor cover on X Layer. It reads
live reserve evidence, returns a signed cover decision, and gives depositors one
place to open a covered USDT position while capital providers underwrite the
pool behind it.

The dashboard reads the shared reserve, requests a signed cover price, records
the decision, and guides the wallet through the covered deposit or exit.

For the complete AI, Aave V3, underwriting, policy, premium, and claim flow,
read [`docs/project-guide.md`](../../docs/project-guide.md).

The public page introduces xCover. Select **Open dashboard** to use the wallet
and transaction controls.

## What people can do

- add USDT to the shared pool and receive pool shares;
- withdraw pool shares when the capital is available;
- request a live price for a covered USDT deposit;
- record the signed price in the registry;
- approve USDT and open a covered position;
- read and exit the current wallet position; and
- publish a fresh reserve reading.

Every action is sent through the connected wallet. The page reads balances,
reserve data, prices, and position state from X Layer.

## Run the app

Run the pricing service so it serves both the API and this page:

```bash
pnpm --filter @xcover/pricing-agent build
HOST=127.0.0.1 PORT=8787 pnpm --filter @xcover/pricing-agent start
```

Open `http://127.0.0.1:8787/` and select **Open dashboard**. The wallet must be
connected to X Layer mainnet.

## Transaction order

To add pool funds:

1. connect a wallet;
2. approve USDT for the pool; and
3. add the selected amount.

To open a covered deposit:

1. request a price;
2. record the signed price;
3. approve USDT for the vault; and
4. open the covered deposit.

The dashboard keeps the final deposit action disabled until a valid price has
been recorded. A declined price cannot open a covered position.

## Files

- `index.html`: public landing page and transaction dashboard markup;
- `styles.css`: visual system and responsive layout; and
- `app.js`: wallet connection, live reads, price requests, and transactions.
