# Portfolio Hybrid Trader v2 — What Changed and Why

Companion to `PortfolioHybridTrader.mq5`. The general testing methodology (tester setup,
walk-forward, Monte Carlo, overfitting checks) is in `PortfolioTrendFollower_GUIDE.md` and applies
unchanged.

## Why v1 only produced ~34 trades in 5 years

Three throttles compounded:

1. **Signals were evaluated exactly at the D1 bar open = midnight rollover**, when spreads are at
   their daily maximum (especially on crosses like GBPNZD/EURNZD). If the spread filter blocked
   the entry at that moment, v1 **discarded the signal for the entire day**. On "every tick based
   on real ticks" modelling this silently killed most entries.
2. **Slow capital turnover + tight caps**: a 55-bar breakout with a 4×ATR trail holds positions
   for weeks–months. With `MaxPosTotal=10` and `MaxPortfolioRisk=4%`, the book saturated and new
   signals were rejected.
3. **Drawdown halts (3/5/8%) suppressed entries** for the rest of the day/week/month after
   ordinary equity noise on a saturated book.

Also worth checking on your side: the Journal line `Active symbols: N of M listed` — if your
broker matched only a handful of names (suffix mismatch, missing crypto/oil), the portfolio was
never actually 34 symbols. And note that 34 trades is far too small a sample to judge expectancy:
−7.8% over 34 trades is statistical noise either way.

## What v2 does differently

| Change | Effect |
|---|---|
| **Pending-signal execution**: signal computed once per closed bar, then *retries* execution during the bar until spread/session/news/caps pass (TTL default 4h) | Recovers the entries v1 dropped at rollover; better fills; still zero lookahead — only *when* we execute changes, never *what we know* |
| **Second module: trend-aligned RSI(2) pullback mean reversion** (buy dips above EMA-200, sell rallies below it; exit on RSI recovery or 8-bar time stop; hard 2.5×ATR stop) | Many short-duration trades (days, not months) → trade count up ~10×, fast slot recycling, high win rate stream that is complementary to breakout P&L → smoother equity |
| Faster breakout default (40-bar entry vs 55) | More TF signals |
| Looser structural caps: 20 total (10 TF + 12 MR), 6% portfolio risk, halts 4/6/8/15% | The book no longer chokes itself |
| **Per-currency exposure cap (4)** | Cuts correlated clusters (five AUD pairs trending together) → drawdown control by construction, not just by halts |
| Netting-account safety, opposite-direction blocking, per-module magics (base+0 TF, base+1 MR) | Clean accounting; you can split TF vs MR results by magic in the report |
| Per-module risk: TF 0.4%, MR 0.3% | More trades at lower per-trade risk ≈ similar portfolio volatility, smaller single-trade impact |

Expected order of magnitude with defaults on ~30 active symbols, D1, 5 years: **roughly 1,000–2,000
trades** (MR contributes most of the count, TF most of the tail profits). If you see far fewer,
check `Active symbols` first.

## Tuning levers

- **More trades:** lower `InpTF_EntryChannel` (40→30), raise `InpMR_BuyLevel`/lower
  `InpMR_SellLevel` (15/85 → 20/80), raise the module/total position caps, or run H4.
- **Higher profit:** profit scales with risk — raise `InpTF_RiskPercent`/`InpMR_RiskPercent`
  proportionally **after** the drawdown check below. Don't chase profit by loosening exits first.
- **Less drawdown:** lower the two risk inputs (drawdown scales ~linearly), lower
  `InpMaxPerCurrency` to 3, lower `InpMaxPortfolioRisk` to 4–5, set `InpDDAction=DD_CLOSE_ALL`.
- **More consistency:** keep both modules on — their P&L streams hedge each other's weak regime
  (breakout earns in trends, pullback earns in ranges). Check per-module results by filtering the
  report by magic (base+0 vs base+1) and only then adjust the weaker one's risk.

## Honest expectations

More trades make the statistics *meaningful*; they do not make profit automatic. The execution fix
removes a real, structural cost (rollover spreads) and the second module adds genuine
diversification — those are the two legitimate ways to improve consistency without curve-fitting.
Validate exactly as in the v1 guide: full-history run → parameter ±20% perturbation → walk-forward
→ cost stress. If the strategy only works at one parameter cell, discard that cell, not the test.
