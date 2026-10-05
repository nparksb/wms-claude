# Why WineCo replenishment orders keep getting cancelled

## Short answer

No one cancels them by hand. A scheduled background job checks every open replenishment order and cancels it automatically when either of these is true:

1. **The pick face counts as full:** the stock already in the pick location is at or above its **upper bound**.
2. **There's no usable source:** the source pallet is gone, or it sits in a location that isn't used for replenishment.

## Why this becomes a loop

A replenishment order can only bring the pick face up to its upper bound. It is not sized to the actual demand.

Example, **PG25**:

| | Units |
|---|---|
| Open demand | 179 |
| Pick-face upper bound | 84 |
| Shortfall the pick face can never cover | 95 |

Once the pick face reaches 84, the job treats it as full and cancels the open order, even though 95 units of demand are still unmet. So:

- the SKU never leaves the replenishment monitor,
- the system keeps creating orders and then cancelling them,
- and the shortage never clears.

## Scale

Across WineCo, about **55% of replenishment orders end up cancelled**. **None** of those cancellations came from an operator. The system cancelled all of them.

## Why this is a product decision

Right now the system assumes demand always fits in one pick face. To fix that, someone has to decide what should happen when demand is bigger than what the pick face can hold. Options include:

- **Send more than one pallet:** allow several orders, or a larger order, when demand is higher than the upper bound.
- **Use an overflow location:** stage the extra stock next to the pick face.
- **Raise the upper bound** for high-velocity SKUs such as PG25.
- **Change the cancel rule:** don't count a pick face as full while open demand is still higher than what's on hand.

Each option changes how the warehouse operates, not just the code. That's why this needs a product decision rather than a bug fix.

## Still to confirm

We have not yet broken down the cancelled orders by rule (pick face full vs. no usable source). That breakdown will show how much of the 55% comes from the demand-vs-upper-bound problem described here.
