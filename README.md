# tokenized-euler-loop
A leveraged ERC-4626 vault built on top of Euler Vault Kit (EVK), integrating with existing Euler EVault markets for collateral, borrowing, and optional flash loans.

The vault accepts a collateral asset (e.g., WETH) and maintains a leveraged position by borrowing a debt asset (e.g., USDC) from Euler EVault markets, swapping via a Uniswap V3-style router, and re-depositing collateral into Euler EVaults.

The vault actively rebalances the position to keep exposure close to a configured target leverage. Deposits (and keeper/operator-triggered rebalances) adjust the amount of collateral and debt so the overall position stays levered rather than drifting toward unlevered.

Conceptually, this ERC-4626 vault “sits alongside” Euler EVaults: user funds are wrapped into shares, but the leveraged position itself is expressed inside Euler’s EVault markets (collateral deposited in `cEVault`, debt accounted in `dEVault`, and flash liquidity from `fEVault`).

In a real deployment, this vault does not create its own markets. Instead, it is configured to point to already-deployed Euler EVaults for collateral (`cEVault`), borrowing (`dEVault`), and flash loans (`fEVault`).
