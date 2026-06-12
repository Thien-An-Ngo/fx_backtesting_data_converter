# Portfolio Trend Follower — Strategy & Testing Guide

Companion guide for `PortfolioTrendFollower.mq5`, a self-contained multi-symbol MT5 Expert
Advisor. No external indicators, no DLLs, no downloads required.

> **Honesty note up front:** the targets (positive every year for 10–15 years, max 10% annual
> drawdown, ~300 trades/year) describe an *excellent institutional-grade* track record. No EA can
> guarantee them. This system is *designed toward* those targets — diversified, volatility-
> normalized, hard-stopped, drawdown-capped — but trend following has multi-month flat and losing
> stretches, and any honest backtest will show losing periods. Anything that shows otherwise is
> curve-fit.

---

## 1. Strategy logic

**Core idea: medium-term trend following via Donchian breakout, regime-filtered, ATR-normalized.**

- **Entry:** the close of the last *completed* bar breaks above the highest high (long) or below
  the lowest low (short) of the previous `EntryChannel` bars (default 55, D1) — the classic
  Donchian/Turtle breakout.
- **Regime filter:** longs only above the 200-period EMA, shorts only below it. Optional ADX
  minimum (off by default).
- **Initial stop:** `3 × ATR(20)` from entry. Always placed with the order.
- **Exits:** (a) close beyond the opposite 20-bar Donchian channel, (b) chandelier trailing stop
  at `4 × ATR` from the highest high / lowest low since entry, (c) optional fixed ATR
  take-profit (off by default — trend systems need open-ended winners).
- **Sizing:** fixed-fractional — each trade risks `RiskPercent` (default 0.5%) of current equity
  over the stop distance, converted through the symbol's tick size/value (works identically for
  5-digit FX, JPY pairs, metals, oil, crypto).
- **Everything is computed on closed bars only** (shift ≥ 1). The current candle is never used.

**Why it should generalize across FX, metals, oil and crypto:**

1. Trend following is the most documented, longest-lived anomaly across asset classes
   (managed-futures literature: Moskowitz/Ooi/Pedersen "Time Series Momentum", AQR's "A Century
   of Trend Following"). It exploits behavioral under-reaction and herding that are not specific
   to any one market.
2. The system is **price-only** and **volatility-normalized**: ATR converts every decision
   (stop, trail, size, spread cap, volatility floor) into the symbol's own volatility units, so
   the *same* parameters mean the same thing on EURUSD at 1.08 and BTCUSD at 100,000.
3. **One parameter set for all symbols** is itself an anti-curve-fitting device: the edge must be
   cross-sectional, not symbol-specific.
4. The profit engine is a few large winners paying for many small stopped-out losers (positive
   skew). Diversification across ~34 weakly-correlated symbols smooths the equity curve and is
   what makes a single-digit drawdown target *plausible* (not guaranteed).

**What it deliberately does NOT do:** no martingale, no grid, no averaging down, no recovery
multiplication, no hidden risk scaling, no repainting indicators, no current-bar peeking, no
symbol-specific tweaks.

---

## 2. Inputs

| Group | Input | Default | Meaning |
|---|---|---|---|
| General | `InpMagic` | 772045 | Magic number |
| | `InpSymbols` | 34 symbols | Comma-separated list; unknown names are skipped with a log entry |
| | `InpSymbolSuffix` | "" | Broker suffix, e.g. `.a`, `m`, `.pro` |
| | `InpTimeframe` | D1 | Working timeframe |
| | `InpVerboseLog` / `InpShowDashboard` | false / true | Diagnostics |
| Signal | `InpEntryChannel` | 55 | Breakout lookback (bars) |
| | `InpExitChannel` / `InpUseChannelExit` | 20 / true | Opposite-channel exit |
| | `InpATRPeriod` | 20 | ATR period |
| | `InpUseTrendFilter` / `InpTrendEMA` | true / 200 | EMA regime filter |
| | `InpADXPeriod` / `InpADXMin` | 14 / 0 | ADX filter (0 = off) |
| | `InpAllowLong` / `InpAllowShort` | true / true | Direction switches |
| Risk | `InpRiskPercent` | 0.5 | % equity risked per trade |
| | `InpSL_ATR` / `InpTP_ATR` | 3.0 / 0 | Initial SL / optional TP (× ATR) |
| | `InpTrail_ATR` | 4.0 | Chandelier trail (× ATR, 0 = off) |
| | `InpBreakEvenTrigATR` / `InpBreakEvenLockATR` | 0 / 0.2 | Break-even (0 = off) |
| | `InpMaxPosPerSymbol` / `InpMaxPosTotal` | 1 / 10 | Position caps |
| | `InpMaxPortfolioRisk` | 4.0 | Cap on summed open risk (% equity) |
| | `InpMinLotRiskFactor` | 1.5 | Skip trade if min lot risks > 1.5× intended |
| | `InpSlippagePoints` | 30 | Max deviation for market orders |
| Protection | `InpMaxDailyDD` / `InpMaxWeeklyDD` / `InpMaxMonthlyDD` | 3 / 5 / 8 | % drawdown from period equity peak → halt entries |
| | `InpDDAction` | HALT_ONLY | Or CLOSE_ALL on limit |
| | `InpEmergencyDD` | 12 | % below all-time equity peak → close all + halt |
| | `InpEmergencyPermanent` | false | If false, emergency halt lifts at next month start |
| Filters | `InpMaxSpreadATR` | 0.15 | Spread must be < 15% of ATR |
| | `InpMaxSpreadPoints` | 0 | Absolute spread cap (0 = off) |
| | `InpMinATRPct` / `InpMaxATRPct` | 0.10 / 0 | Volatility floor/ceiling (ATR as % of price) |
| | `InpUseSessionFilter` + hours | false | Entry session window (server time) |
| | `InpTradeSunday` … `InpTradeSaturday` | Mon–Fri true | Day-of-week entry switches (enable Sat/Sun for crypto if desired) |
| News | `InpUseNewsFilter` | false | Built-in calendar blackout (live/demo only — the MT5 tester has no calendar) |
| | `InpNewsBeforeMin` / `InpNewsAfterMin` | 60 / 30 | Blackout window around high-impact events |

## 3. Recommended defaults

Ship defaults are the recommended starting point: D1, 55/20 channels, ATR 20, EMA 200, 0.5% risk,
3×ATR stop, 4×ATR trail, 10 max positions, 4% max open risk, 3/5/8% period drawdown halts, 12%
emergency stop. With ~34 symbols this is designed to produce roughly 150–400 portfolio
trades/year depending on regime (≈300 in typical years). More trades: lower `InpEntryChannel`
(e.g. 40) or run H4. Fewer/higher-quality: raise it (80–100) or set `InpADXMin` 15–20.

## 4. Recommended timeframe

**D1.** Daily bars have the best noise-to-signal ratio for breakouts, the lowest cost drag
(spread is tiny relative to a daily ATR) and 15+ years of decent data. H4 is the acceptable
alternative (use `EntryChannel` ≈ 100–120 to keep a similar horizon, and expect more trades and
more cost sensitivity). Below H4, spread/slippage eat this style of edge.

## 5. Strategy Tester method

1. MT5 → View → **Strategy Tester** (Ctrl+R).
2. Expert: `PortfolioTrendFollower`. Symbol: **EURUSD** (chart symbol is only a host — the EA
   trades the whole `InpSymbols` list internally). Period: **D1**.
3. Modelling: **"Every tick based on real ticks"** for final validation; **"1 minute OHLC"** for
   exploration (good compromise). **Never use "Open prices only"** — it is unreliable for
   multi-symbol EAs.
4. Dates: as far back as your broker has data (try 2010 → today; crypto typically only
   2017/2018+, which the EA handles — symbols simply don't trade before their data starts).
5. Deposit ≥ 10,000 (USD), leverage 1:30 or higher. Forward: "No" for the first full run.
6. Enable ticks/profile **Visual mode off** for speed. Run.

## 6. Exact multi-symbol backtesting instructions

1. Make sure every symbol you list exists in **View → Symbols** for your broker and has history.
   Tester pulls data for non-chart symbols automatically the first time the EA touches them — the
   first run may pause while downloading; subsequent runs are fast.
2. Adjust `InpSymbols` / `InpSymbolSuffix` to your broker's naming (e.g. `EURUSD.a`,
   `XTIUSD` vs `USOIL`, `WTI`, `BRENT` vs `UKOIL`). Unknown names are skipped and logged in the
   tester **Journal** — check it after the first run.
3. Watch the **Journal/Experts** tabs: the EA logs `Active symbols: N of M listed` at start.
4. The report's deal list shows all symbols mixed; right-click → report → open XML/HTML to filter
   per symbol if needed.
5. For costs: pick a **real-spread** broker account; "Every tick based on real ticks" uses the
   recorded spread. Add commission via the tester's symbol settings if your live account charges
   it (or mentally deduct ~0.5–1 pip/trade equivalent).

## 7. Optimization instructions (deliberately minimal)

- Optimize **at most 2–3 parameters at a time**, portfolio-wide, never per symbol:
  - `InpEntryChannel`: 30…90 step 10
  - `InpTrail_ATR`: 3…6 step 0.5
  - `InpSL_ATR`: 2…4 step 0.5
  - (optionally `InpTrendEMA`: 100…300 step 50, `InpADXMin`: 0…30 step 5)
- Criterion: **Custom max** — the EA's `OnTester()` returns *net profit / max equity drawdown*.
- Use **genetic** optimization, "1 minute OHLC" modelling, then re-verify the chosen set with
  "every tick based on real ticks".
- You are looking for a **plateau, not a peak**: a wide region of parameters that all perform
  decently. If only one cell shines, it's noise — discard it.
- Do **not** optimize `InpRiskPercent` for profit; it only scales the curve. Set it from the
  drawdown procedure in §14.

## 8. Walk-forward testing

1. In the tester set **Forward: 1/3** (or 1/2). MT5 optimizes on the first part and replays the
   best sets on the unseen forward part. Compare backtest vs forward columns — forward results
   should be the same order of magnitude (expect some degradation; >60–70% collapse = overfit).
2. Manual rolling version (stronger): optimize 2010–2015 → test 2016; slide one year and repeat
   until today; chain the out-of-sample years into one equity curve. That chained OOS curve is
   your realistic expectation.

## 9. Robustness testing

- **Parameter perturbation:** rerun with every key parameter ±20% (Entry 44/66, SL 2.4/3.6,
  Trail 3.2/4.8, EMA 160/240). A robust system stays profitable, just less pretty.
- **Symbol subsets:** FX-only, no-crypto, no-metals, random half of the list. The edge should not
  live in one or two symbols.
- **Cost stress:** rerun with doubled/tripled spread (tester → symbol settings → custom spread)
  and with execution **Delay** set to random instead of zero.
- **Data source stress:** test on a second broker's data (or build custom symbols from external
  data — e.g. data prepared with this repository's converter — and rerun). Results should be
  similar, not identical.
- **Timeframe shift:** if D1 works but H4 and W1 are catastrophic, be suspicious.

## 10. Monte Carlo testing

MT5 has no built-in Monte Carlo, so: run the backtest → right-click results → **Report → HTML/XML**
→ export the deal list → in Python/Excel (or QuantAnalyzer/MT5-MonteCarlo tools):

1. Resample the per-trade P&L (bootstrap with replacement, 5–10k runs) and reshuffle trade order.
2. Look at the distribution of max drawdown and CAGR. Plan around the **95th-percentile
   drawdown**, which is typically 1.5–2× the single backtest's drawdown.
3. Optionally randomize entries by ±1 bar and skip 10% of trades at random — results should
   degrade smoothly, not collapse.

## 11. Testing for overfitting

- Few parameters (this EA's signal has ~5 that matter) and **one set across 34 symbols** is the
  first defense.
- In-sample vs out-of-sample degradation < ~30–40% (walk-forward, §8).
- Parameter heatmap shows plateaus (§7).
- Trade count is large (thousands over 10–15y portfolio-wide) → statistically meaningful.
- The strategy has a *reason* to work (trend persistence) rather than a pattern mined from data.
- Red flags: any need for per-symbol settings, profit concentrated in one year/symbol, results
  that die when spread is doubled.

## 12. Verifying that nothing repaints

- By construction: signals use only **closed bars** (`CopyRates`/`CopyBuffer` from shift 1), and
  ATR/EMA/ADX/Donchian values of a *closed* bar never change afterwards. The EA never reads
  bar 0.
- To verify empirically: (a) run the same backtest twice — results must be byte-identical;
  (b) enable `InpVerboseLog`, note logged signal values (ATR/channel/close) at trade time, then
  scroll the chart back later and compare with the Data Window — they must match; (c) in the
  visual tester, watch that entries always occur on the bar *after* the breakout close.

## 13. Interpreting the results

- **Max equity drawdown %** vs CAGR: a CAGR/maxDD ratio ≥ 0.5–1.0 is good for trend following.
- **Profit factor:** 1.15–1.45 is realistic for diversified trend following; >2 over thousands of
  trades usually means a testing artifact.
- **Win rate 30–45% with avg win ≫ avg loss is *normal* and healthy** for this style — don't
  "fix" it.
- Check the **yearly breakdown**: expect some flat/negative years (2012–2014-style trend droughts
  hit every trend follower). Judge the worst 2-year window, not the best.
- Check trades/year ≈ your target; check that no single symbol dominates profit; check the
  longest drawdown *duration* (can be many months — that is the real psychological cost).

## 14. Keeping annual drawdown under 10%

Drawdown scales almost linearly with per-trade risk:

1. Run the full-history backtest at `InpRiskPercent = 0.5`.
2. Note max equity drawdown `DD_bt` (%). Compute `risk_new = 0.5 × (10 / DD_bt) × 0.7` — the 0.7
   is a safety factor because the future is worse than the backtest (Monte Carlo, §10).
3. Also tighten the structural caps: `InpMaxPosTotal` (10 → 8) and `InpMaxPortfolioRisk`
   (4 → 3) cut correlated-cluster risk (e.g. several AUD pairs trending together).
4. The period halts (3/5/8%) plus the 12% emergency stop hard-bound the damage *within* each
   period; set `InpDDAction = DD_CLOSE_ALL` for the strictest interpretation.
5. Re-run and confirm; remember a backtest max-DD of ~6–7% is the practical target if you want
   live max-DD ≤ 10%.

## 15. Known limitations (read this)

- **No guaranteed profitability.** Trend following has multi-month/multi-year weak regimes; a
  losing year is possible and historically normal. "Profitable every year for 15 years with
  <10% DD" is a stretch goal even for professional CTAs.
- **~300 trades/year is regime-dependent** — quiet years produce fewer breakouts.
- **Crypto and oil history in MT5 is short and broker-dependent** (often <10y, variable quality);
  the 10–15y statistics are really driven by the FX+metals core.
- **Swaps and commissions matter** for multi-week holds; test with your broker's real symbol
  settings (triple-swap Wednesdays, oil/crypto financing can be heavy).
- **News filter works live only** — the MT5 Strategy Tester has no economic-calendar data, so
  backtests run with it effectively off (the EA handles this automatically).
- **Drawdown-halt state is in-memory**: after an EA restart mid-period, period peaks re-anchor to
  current equity (slightly more permissive until the next period starts).
- **No cross-correlation netting**: currency-cluster risk is only bounded by the position/risk
  caps, not by a correlation model.
- **Multi-symbol tester fidelity**: non-chart symbols are modelled from their own data, but
  ultra-precise intrabar sequencing across symbols is approximate; D1 closed-bar logic minimizes
  the impact.
- **Execution**: some market-execution brokers ignore the deviation (slippage) parameter; live
  fills will differ slightly from the tester.
- **Equity halts trade tail-risk for opportunity cost**: a halt can park you in cash right before
  the recovery. That is the price of the drawdown cap.
