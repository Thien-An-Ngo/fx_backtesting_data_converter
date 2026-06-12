//+------------------------------------------------------------------+
//|                                        PortfolioHybridTrader.mq5 |
//|     Multi-symbol portfolio EA: trend breakout + mean reversion   |
//|                                                                  |
//|  Version 2 of PortfolioTrendFollower. Changes that matter:      |
//|                                                                  |
//|  1) TWO complementary modules instead of one:                   |
//|     - TF: Donchian breakout trend following (big, rare winners) |
//|     - MR: trend-aligned RSI(2) pullback mean reversion (many    |
//|       short trades, high win rate, smooths the equity curve)    |
//|     Modules are independently switchable and separately capped. |
//|                                                                  |
//|  2) PENDING-SIGNAL EXECUTION: v1 evaluated signals exactly at   |
//|     the D1 bar open (= midnight rollover, the widest spreads of |
//|     the day) and discarded the signal for the whole bar if the  |
//|     spread filter blocked it. v2 keeps a signal pending and     |
//|     retries execution during the bar until spread/session/news  |
//|     filters pass or the signal expires (InpSignalTTLMin).       |
//|     Signals are still computed ONLY from closed bars - the      |
//|     pending mechanism changes WHEN we execute, never WHAT we    |
//|     know. No lookahead, no repainting.                          |
//|                                                                  |
//|  3) Per-currency exposure cap (limits correlated USD/JPY/AUD    |
//|     clusters), per-module position caps, netting-account        |
//|     safety, opposite-direction blocking.                        |
//|                                                                  |
//|  No martingale, no grid, no averaging down. Every position has  |
//|  a hard stop-loss from the start. Indicators: native iATR/iMA/  |
//|  iRSI + internally computed Donchian channels. Nothing external.|
//|                                                                  |
//|  Attach to ONE chart (recommended EURUSD D1). The EA trades     |
//|  every symbol in InpSymbols.                                    |
//+------------------------------------------------------------------+
#property copyright   "2026"
#property link        "https://www.mql5.com"
#property version     "2.00"
#property description "Hybrid multi-symbol portfolio EA: Donchian breakout trend module +"
#property description "trend-aligned RSI(2) pullback module, ATR-normalized risk, portfolio caps."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum ENUM_DD_ACTION
  {
   DD_HALT_ONLY = 0,   // Halt new entries only
   DD_CLOSE_ALL = 1    // Halt entries and close all positions
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== General ==="
input long            InpMagic            = 772100;        // Magic number base (TF = +0, MR = +1)
input string          InpSymbols          = "AUDCAD,AUDCHF,AUDJPY,AUDNZD,AUDUSD,CADCHF,CADJPY,CHFJPY,EURAUD,EURCAD,EURCHF,EURGBP,EURJPY,EURNZD,EURUSD,GBPAUD,GBPCAD,GBPCHF,GBPJPY,GBPNZD,GBPUSD,NZDCAD,NZDCHF,NZDJPY,NZDUSD,USDCAD,USDCHF,USDJPY,XAUUSD,XAGUSD,USOIL,UKOIL,BTCUSD,ETHUSD"; // Symbol list (comma separated)
input string          InpSymbolSuffix     = "";             // Broker symbol suffix (e.g. ".a", "m")
input ENUM_TIMEFRAMES InpTimeframe        = PERIOD_D1;      // Working timeframe
input bool            InpVerboseLog       = false;          // Verbose logging
input bool            InpShowDashboard    = true;           // Show chart Comment() dashboard

input group "=== Modules ==="
input bool            InpUseTrendModule   = true;           // Enable trend-following module (TF)
input bool            InpUseMeanRevModule = true;           // Enable mean-reversion module (MR)

input group "=== TF module: Donchian breakout ==="
input int             InpTF_EntryChannel  = 40;             // TF: entry channel period (bars)
input int             InpTF_ExitChannel   = 20;             // TF: exit channel period (bars)
input bool            InpTF_UseChannelExit= true;           // TF: use opposite-channel exit
input bool            InpTF_UseEMAFilter  = true;           // TF: trade only with EMA regime
input double          InpTF_RiskPercent   = 0.4;            // TF: risk per trade, % of equity
input double          InpTF_SL_ATR        = 3.0;            // TF: initial stop (x ATR)
input double          InpTF_TP_ATR        = 0.0;            // TF: take profit (x ATR, 0 = none)
input double          InpTF_Trail_ATR     = 4.0;            // TF: chandelier trail (x ATR, 0 = off)
input double          InpTF_BreakEvenTrig = 0.0;            // TF: break-even trigger (x ATR, 0 = off)
input double          InpTF_BreakEvenLock = 0.2;            // TF: break-even lock-in (x ATR)
input int             InpTF_MaxPositions  = 10;             // TF: max open positions (module-wide)
input bool            InpTF_AllowLong     = true;           // TF: allow longs
input bool            InpTF_AllowShort    = true;           // TF: allow shorts

input group "=== MR module: trend-aligned RSI pullback ==="
input int             InpMR_RSIPeriod     = 2;              // MR: RSI period
input double          InpMR_BuyLevel      = 15.0;           // MR: buy when RSI below (uptrend only)
input double          InpMR_SellLevel     = 85.0;           // MR: sell when RSI above (downtrend only)
input double          InpMR_ExitLong      = 70.0;           // MR: close longs when RSI above
input double          InpMR_ExitShort     = 30.0;           // MR: close shorts when RSI below
input int             InpMR_MaxHoldBars   = 8;              // MR: time stop (bars, 0 = off)
input double          InpMR_RiskPercent   = 0.3;            // MR: risk per trade, % of equity
input double          InpMR_SL_ATR        = 2.5;            // MR: stop-loss (x ATR)
input double          InpMR_TP_ATR        = 0.0;            // MR: take profit (x ATR, 0 = RSI/time exit)
input int             InpMR_MaxPositions  = 12;             // MR: max open positions (module-wide)
input bool            InpMR_AllowLong     = true;           // MR: allow longs
input bool            InpMR_AllowShort    = true;           // MR: allow shorts

input group "=== Shared signal settings ==="
input int             InpATRPeriod        = 20;             // ATR period
input int             InpTrendEMA         = 200;            // Regime EMA period (TF filter + MR regime)
input int             InpSignalTTLMin     = 240;            // Pending signal lifetime, minutes (within its bar)

input group "=== Portfolio risk ==="
input int             InpMaxPosPerSymbol  = 2;              // Max positions per symbol (all modules)
input int             InpMaxPosTotal      = 20;             // Max positions across portfolio
input double          InpMaxPortfolioRisk = 6.0;            // Max total open risk, % of equity
input int             InpMaxPerCurrency   = 4;              // Max positions sharing one currency (0 = off)
input double          InpMinLotRiskFactor = 1.5;            // Max risk overshoot at min lot (x intended)
input int             InpSlippagePoints   = 30;             // Max slippage / deviation (points)

input group "=== Equity protection ==="
input double          InpMaxDailyDD       = 4.0;            // Max daily drawdown % (0 = off)
input double          InpMaxWeeklyDD      = 6.0;            // Max weekly drawdown % (0 = off)
input double          InpMaxMonthlyDD     = 8.0;            // Max monthly drawdown % (0 = off)
input ENUM_DD_ACTION  InpDDAction         = DD_HALT_ONLY;   // Action on period limit
input double          InpEmergencyDD      = 15.0;           // Emergency stop: % below equity peak (0 = off)
input bool            InpEmergencyPermanent = false;        // Emergency halt permanent (false = resume next month)

input group "=== Filters ==="
input double          InpMaxSpreadATR     = 0.20;           // Max spread as fraction of ATR (0 = off)
input int             InpMaxSpreadPoints  = 0;              // Max absolute spread, points (0 = off)
input double          InpMinATRPct        = 0.05;           // Min ATR as % of price (0 = off)
input double          InpMaxATRPct        = 0.0;            // Max ATR as % of price (0 = off)
input bool            InpUseSessionFilter = false;          // Restrict entries to session hours
input int             InpSessionStartHour = 0;              // Session start hour (server time)
input int             InpSessionEndHour   = 0;              // Session end hour (= start means 24h)
input bool            InpTradeSunday      = false;          // Entries on Sunday (crypto)
input bool            InpTradeMonday      = true;           // Entries on Monday
input bool            InpTradeTuesday     = true;           // Entries on Tuesday
input bool            InpTradeWednesday   = true;           // Entries on Wednesday
input bool            InpTradeThursday    = true;           // Entries on Thursday
input bool            InpTradeFriday      = true;           // Entries on Friday
input bool            InpTradeSaturday    = false;          // Entries on Saturday (crypto)

input group "=== News filter (built-in calendar, live only) ==="
input bool            InpUseNewsFilter    = false;          // Block entries around high-impact news
input int             InpNewsBeforeMin    = 60;             // Blackout minutes before event
input int             InpNewsAfterMin     = 30;             // Blackout minutes after event

//+------------------------------------------------------------------+
//| Structures                                                       |
//+------------------------------------------------------------------+
struct Pending
  {
   bool              active;
   int               dir;           // +1 long, -1 short
   double            atr;           // ATR at signal time (closed bar)
   datetime          barTime;       // bar the signal belongs to
   datetime          since;         // when the signal was created
  };

struct SymState
  {
   string            name;
   bool              enabled;
   int               hATR;
   int               hEMA;
   int               hRSI;
   datetime          lastBar;
   Pending           pTF;
   Pending           pMR;
  };

struct NewsItem
  {
   datetime          t;
   string            ccy;
  };

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade    g_trade;
SymState  g_sym[];
bool      g_isNetting    = false;

double    g_peakEquity   = 0.0;
double    g_dayPeak      = 0.0;
double    g_weekPeak     = 0.0;
double    g_monthPeak    = 0.0;
int       g_dayId        = -1;
int       g_weekId       = -1;
int       g_monthId      = -1;
bool      g_dayHalt      = false;
bool      g_weekHalt     = false;
bool      g_monthHalt    = false;
bool      g_emergencyHalt= false;

NewsItem  g_news[];
datetime  g_lastNewsFetch= 0;

long MagicTF() { return InpMagic;     }
long MagicMR() { return InpMagic + 1; }
bool IsOurMagic(const long m) { return (m == InpMagic || m == InpMagic + 1); }

void LogI(const string msg) { Print("[PHT] ", msg); }
void LogV(const string msg) { if(InpVerboseLog) Print("[PHT] ", msg); }

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!InpUseTrendModule && !InpUseMeanRevModule)
     { LogI("Both modules disabled - nothing to trade"); return INIT_PARAMETERS_INCORRECT; }
   if(InpTF_EntryChannel < 5 || InpTF_ExitChannel < 2)
     { LogI("Invalid TF channel periods"); return INIT_PARAMETERS_INCORRECT; }
   if(InpATRPeriod < 2 || InpTF_SL_ATR <= 0.0 || InpMR_SL_ATR <= 0.0)
     { LogI("Invalid ATR period or SL multipliers"); return INIT_PARAMETERS_INCORRECT; }
   if(InpTF_RiskPercent <= 0.0 || InpTF_RiskPercent > 5.0 ||
      InpMR_RiskPercent <= 0.0 || InpMR_RiskPercent > 5.0)
     { LogI("Module risk must be in (0, 5] percent"); return INIT_PARAMETERS_INCORRECT; }
   if(InpMR_RSIPeriod < 2 || InpMR_BuyLevel >= InpMR_ExitLong || InpMR_SellLevel <= InpMR_ExitShort)
     { LogI("Invalid RSI settings (need buy < exitLong, sell > exitShort)"); return INIT_PARAMETERS_INCORRECT; }
   if(InpMaxPosPerSymbol < 1 || InpMaxPosTotal < 1)
     { LogI("Position limits must be >= 1"); return INIT_PARAMETERS_INCORRECT; }
   if(InpSessionStartHour < 0 || InpSessionStartHour > 23 || InpSessionEndHour < 0 || InpSessionEndHour > 23)
     { LogI("Session hours must be 0..23"); return INIT_PARAMETERS_INCORRECT; }
   if(InpTF_RiskPercent + InpMR_RiskPercent > 2.0)
      LogI("WARNING: combined per-trade risk above 2% is aggressive");

   g_isNetting = ((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)
                  != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   if(g_isNetting)
      LogI("Netting account detected: max 1 position per symbol enforced");

   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetDeviationInPoints((ulong)InpSlippagePoints);
   g_trade.SetMarginMode();
   g_trade.SetAsyncMode(false);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   if(!ParseSymbols())
     { LogI("No tradable symbols - check InpSymbols / InpSymbolSuffix"); return INIT_FAILED; }

   double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
   g_peakEquity = eq;
   g_dayPeak    = eq;
   g_weekPeak   = eq;
   g_monthPeak  = eq;
   g_dayId = g_weekId = g_monthId = -1;

   EventSetTimer(10);
   LogI(StringFormat("Initialized: %d symbols, %s, magic %I64d/%I64d, risk TF %.2f%% MR %.2f%%",
                     ArraySize(g_sym), EnumToString(InpTimeframe), MagicTF(), MagicMR(),
                     InpTF_RiskPercent, InpMR_RiskPercent));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   for(int i = 0; i < ArraySize(g_sym); i++)
     {
      if(g_sym[i].hATR != INVALID_HANDLE) IndicatorRelease(g_sym[i].hATR);
      if(g_sym[i].hEMA != INVALID_HANDLE) IndicatorRelease(g_sym[i].hEMA);
      if(g_sym[i].hRSI != INVALID_HANDLE) IndicatorRelease(g_sym[i].hRSI);
     }
   Comment("");
  }

void OnTick()  { ProcessAll(); }
void OnTimer() { ProcessAll(); }

//+------------------------------------------------------------------+
//| Custom optimization criterion: net profit / max equity drawdown  |
//+------------------------------------------------------------------+
double OnTester()
  {
   double profit = TesterStatistics(STAT_PROFIT);
   double maxdd  = TesterStatistics(STAT_EQUITY_DD);
   if(maxdd <= 0.0) maxdd = 1.0;
   return profit / maxdd;
  }

//+------------------------------------------------------------------+
//| Parse and validate the symbol list                               |
//+------------------------------------------------------------------+
bool ParseSymbols()
  {
   string parts[];
   int n = StringSplit(InpSymbols, ',', parts);
   if(n <= 0) return false;

   ArrayResize(g_sym, 0);
   int added = 0;
   bool needEMA = (InpUseMeanRevModule || (InpUseTrendModule && InpTF_UseEMAFilter));
   for(int i = 0; i < n; i++)
     {
      string s = parts[i];
      StringTrimLeft(s);
      StringTrimRight(s);
      if(s == "") continue;
      s += InpSymbolSuffix;

      bool dup = false;
      for(int j = 0; j < added; j++)
         if(g_sym[j].name == s) { dup = true; break; }
      if(dup) continue;

      if(!SymbolSelect(s, true))
        { LogI(StringFormat("Symbol '%s' not found at this broker - skipped", s)); continue; }

      long tmode = SymbolInfoInteger(s, SYMBOL_TRADE_MODE);
      if(tmode == SYMBOL_TRADE_MODE_DISABLED || tmode == SYMBOL_TRADE_MODE_CLOSEONLY)
        { LogI(StringFormat("Symbol '%s' is not fully tradable - skipped", s)); continue; }

      ArrayResize(g_sym, added + 1);
      g_sym[added].name    = s;
      g_sym[added].enabled = true;
      g_sym[added].lastBar = 0;
      g_sym[added].pTF.active = false;
      g_sym[added].pMR.active = false;
      g_sym[added].hATR = iATR(s, InpTimeframe, InpATRPeriod);
      g_sym[added].hEMA = (needEMA ? iMA(s, InpTimeframe, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE)
                                   : INVALID_HANDLE);
      g_sym[added].hRSI = (InpUseMeanRevModule ? iRSI(s, InpTimeframe, InpMR_RSIPeriod, PRICE_CLOSE)
                                               : INVALID_HANDLE);
      if(g_sym[added].hATR == INVALID_HANDLE ||
         (needEMA && g_sym[added].hEMA == INVALID_HANDLE) ||
         (InpUseMeanRevModule && g_sym[added].hRSI == INVALID_HANDLE))
        {
         LogI(StringFormat("Indicator handle creation failed for '%s' - symbol disabled", s));
         g_sym[added].enabled = false;
        }
      added++;
     }
   LogI(StringFormat("Active symbols: %d of %d listed", added, n));
   return added > 0;
  }

//+------------------------------------------------------------------+
//| Main processing pass                                             |
//+------------------------------------------------------------------+
void ProcessAll()
  {
   UpdateEquityGuards();
   for(int i = 0; i < ArraySize(g_sym); i++)
     {
      if(!g_sym[i].enabled) continue;
      ProcessSymbol(i);
     }
   if(InpShowDashboard && !MQLInfoInteger(MQL_OPTIMIZATION))
      UpdateDashboard();
  }

//+------------------------------------------------------------------+
//| Equity guards: daily / weekly / monthly / emergency drawdown     |
//+------------------------------------------------------------------+
void UpdateEquityGuards()
  {
   double   eq = AccountInfoDouble(ACCOUNT_EQUITY);
   datetime t  = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(t, dt);

   int dayId   = dt.year * 1000 + dt.day_of_year;
   int weekId  = (int)MathFloor(((double)(long)t - 345600.0) / 604800.0);
   int monthId = dt.year * 12 + dt.mon;

   if(dayId != g_dayId)
     {
      g_dayId = dayId; g_dayPeak = eq;
      if(g_dayHalt) LogI("Daily drawdown halt lifted (new day)");
      g_dayHalt = false;
     }
   if(weekId != g_weekId)
     {
      g_weekId = weekId; g_weekPeak = eq;
      if(g_weekHalt) LogI("Weekly drawdown halt lifted (new week)");
      g_weekHalt = false;
     }
   if(monthId != g_monthId)
     {
      bool firstCall = (g_monthId == -1);
      g_monthId = monthId; g_monthPeak = eq;
      if(g_monthHalt) LogI("Monthly drawdown halt lifted (new month)");
      g_monthHalt = false;
      if(!firstCall && g_emergencyHalt && !InpEmergencyPermanent)
        {
         g_emergencyHalt = false;
         g_peakEquity    = eq;   // re-anchor, otherwise it re-triggers instantly
         LogI("EMERGENCY halt lifted at month start - equity peak re-anchored");
        }
     }

   g_dayPeak    = MathMax(g_dayPeak, eq);
   g_weekPeak   = MathMax(g_weekPeak, eq);
   g_monthPeak  = MathMax(g_monthPeak, eq);
   g_peakEquity = MathMax(g_peakEquity, eq);

   if(!g_emergencyHalt && InpEmergencyDD > 0.0 && eq <= g_peakEquity * (1.0 - InpEmergencyDD / 100.0))
     {
      g_emergencyHalt = true;
      LogI(StringFormat("EMERGENCY STOP: equity %.2f is %.1f%% below peak %.2f - closing all positions",
                        eq, InpEmergencyDD, g_peakEquity));
      CloseAllPositions("emergency equity protection");
     }

   CheckPeriodHalt(g_dayHalt,   g_dayPeak,   InpMaxDailyDD,   "daily");
   CheckPeriodHalt(g_weekHalt,  g_weekPeak,  InpMaxWeeklyDD,  "weekly");
   CheckPeriodHalt(g_monthHalt, g_monthPeak, InpMaxMonthlyDD, "monthly");
  }

void CheckPeriodHalt(bool &halt, const double peak, const double limitPct, const string label)
  {
   if(halt || limitPct <= 0.0) return;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq <= peak * (1.0 - limitPct / 100.0))
     {
      halt = true;
      LogI(StringFormat("Max %s drawdown %.1f%% reached (equity %.2f, %s peak %.2f) - new entries halted",
                        label, limitPct, eq, label, peak));
      if(InpDDAction == DD_CLOSE_ALL)
         CloseAllPositions(label + " drawdown limit");
     }
  }

bool EntriesAllowed()
  {
   return !(g_emergencyHalt || g_dayHalt || g_weekHalt || g_monthHalt);
  }

//+------------------------------------------------------------------+
//| Per-symbol processing                                            |
//+------------------------------------------------------------------+
void ProcessSymbol(const int i)
  {
   string   sym    = g_sym[i].name;
   datetime curBar = iTime(sym, InpTimeframe, 0);
   if(curBar <= 0) return;

   //--- once per new bar: closed-bar exits + signal computation
   if(curBar != g_sym[i].lastBar)
     {
      // these return false only when history/indicator data is not ready;
      // in that case do NOT latch the bar - retry on the next call
      if(!ManageTrend(i))   return;
      if(!ManageMeanRev(i)) return;
      if(!ComputeSignals(i, curBar)) return;
      g_sym[i].lastBar = curBar;
     }

   //--- every call: try to execute pending signals (spread may have
   //    normalized after the rollover, a slot may have freed up, etc.)
   if(InpUseTrendModule)
      ExecutePending(i, g_sym[i].pTF, MagicTF(), "PHT-TF", InpTF_RiskPercent,
                     InpTF_SL_ATR, InpTF_TP_ATR, InpTF_MaxPositions);
   if(InpUseMeanRevModule)
      ExecutePending(i, g_sym[i].pMR, MagicMR(), "PHT-MR", InpMR_RiskPercent,
                     InpMR_SL_ATR, InpMR_TP_ATR, InpMR_MaxPositions);
  }

//+------------------------------------------------------------------+
//| Read one indicator value from the last CLOSED bar (shift 1)      |
//+------------------------------------------------------------------+
bool GetValue(const int handle, double &val)
  {
   if(handle == INVALID_HANDLE) return false;
   double buf[1];
   if(CopyBuffer(handle, 0, 1, 1, buf) != 1) return false;
   if(buf[0] == EMPTY_VALUE) return false;
   val = buf[0];
   return true;
  }

//+------------------------------------------------------------------+
//| Compute both modules' signals from closed bars.                  |
//| Returns false only if data is not ready yet.                     |
//+------------------------------------------------------------------+
bool ComputeSignals(const int i, const datetime curBar)
  {
   string sym = g_sym[i].name;

   //--- a new bar invalidates any unexecuted signal from the old bar
   g_sym[i].pTF.active = false;
   g_sym[i].pMR.active = false;

   double atr = 0.0;
   if(!GetValue(g_sym[i].hATR, atr) || atr <= 0.0) return false;

   bool needEMA = (InpUseMeanRevModule || (InpUseTrendModule && InpTF_UseEMAFilter));
   double ema = 0.0;
   if(needEMA && !GetValue(g_sym[i].hEMA, ema)) return false;

   double rsi = 0.0;
   if(InpUseMeanRevModule && !GetValue(g_sym[i].hRSI, rsi)) return false;

   //--- closed-bar rates: rates[0] = signal bar (shift 1),
   //    rates[1..TF_EntryChannel] = channel bars preceding it
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int need = InpTF_EntryChannel + 1;
   if(CopyRates(sym, InpTimeframe, 1, need, rates) < need) return false;
   double closed = rates[0].close;
   if(closed <= 0.0) return false;

   //--- shared volatility filter (signal-time, closed-bar data)
   double atrPct = 100.0 * atr / closed;
   if(InpMinATRPct > 0.0 && atrPct < InpMinATRPct) return true;
   if(InpMaxATRPct > 0.0 && atrPct > InpMaxATRPct) return true;

   //--- TF module: Donchian breakout
   if(InpUseTrendModule && CountPositions(sym, MagicTF()) == 0)
     {
      double hh = rates[1].high, ll = rates[1].low;
      for(int k = 2; k <= InpTF_EntryChannel; k++)
        {
         hh = MathMax(hh, rates[k].high);
         ll = MathMin(ll, rates[k].low);
        }
      bool longOK  = InpTF_AllowLong  && closed > hh && (!InpTF_UseEMAFilter || closed > ema);
      bool shortOK = InpTF_AllowShort && closed < ll && (!InpTF_UseEMAFilter || closed < ema);
      if(longOK || shortOK)
        {
         g_sym[i].pTF.active  = true;
         g_sym[i].pTF.dir     = (longOK ? 1 : -1);
         g_sym[i].pTF.atr     = atr;
         g_sym[i].pTF.barTime = curBar;
         g_sym[i].pTF.since   = TimeCurrent();
         LogV(StringFormat("%s: TF %s signal pending (close %.5f)", sym, longOK ? "LONG" : "SHORT", closed));
        }
     }

   //--- MR module: pullback inside the EMA regime
   if(InpUseMeanRevModule && CountPositions(sym, MagicMR()) == 0)
     {
      bool longOK  = InpMR_AllowLong  && closed > ema && rsi <= InpMR_BuyLevel;
      bool shortOK = InpMR_AllowShort && closed < ema && rsi >= InpMR_SellLevel;
      if(longOK || shortOK)
        {
         g_sym[i].pMR.active  = true;
         g_sym[i].pMR.dir     = (longOK ? 1 : -1);
         g_sym[i].pMR.atr     = atr;
         g_sym[i].pMR.barTime = curBar;
         g_sym[i].pMR.since   = TimeCurrent();
         LogV(StringFormat("%s: MR %s signal pending (RSI %.1f)", sym, longOK ? "LONG" : "SHORT", rsi));
        }
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Try to execute a pending signal. Signals were computed from      |
//| closed bars; here we only wait for clean execution conditions    |
//| (spread, session, news, caps) within the signal's own bar.       |
//+------------------------------------------------------------------+
void ExecutePending(const int i, Pending &p, const long magic, const string tag,
                    const double riskPct, const double slATR, const double tpATR,
                    const int moduleCap)
  {
   if(!p.active) return;
   string sym = g_sym[i].name;

   //--- expiry: bar rolled over, or TTL exceeded
   if(iTime(sym, InpTimeframe, 0) != p.barTime) { p.active = false; return; }
   if(InpSignalTTLMin > 0 && (long)(TimeCurrent() - p.since) > (long)InpSignalTTLMin * 60)
     { p.active = false; return; }

   //--- portfolio state checks (retry while pending if they fail)
   if(!EntriesAllowed()) return;
   if(!SessionOK())      return;
   if(CountPositions(sym, magic) > 0) { p.active = false; return; }   // module already in
   int perSymCap = (g_isNetting ? 1 : InpMaxPosPerSymbol);
   if(CountPositions(sym, 0) >= perSymCap)        return;
   if(HasOppositeDir(sym, p.dir))                 return;             // never hedge ourselves
   if(CountPositions(NULL, 0)  >= InpMaxPosTotal) return;
   if(CountPositions(NULL, magic) >= moduleCap)   return;

   if(InpMaxPerCurrency > 0)
     {
      string bccy = SymbolInfoString(sym, SYMBOL_CURRENCY_BASE);
      string qccy = SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT);
      if(CurrencyExposure(bccy) >= InpMaxPerCurrency ||
         CurrencyExposure(qccy) >= InpMaxPerCurrency)
        { LogV(sym + ": currency exposure cap - waiting"); return; }
     }
   if(InpMaxPortfolioRisk > 0.0 && PortfolioOpenRiskPct() + riskPct > InpMaxPortfolioRisk)
     { LogV(sym + ": portfolio risk cap - waiting"); return; }

   //--- execution-quality checks (the whole point of pending retry:
   //    rollover spreads pass within minutes, the signal is not lost)
   if(!SpreadOK(sym, p.atr)) return;
   if(InpUseNewsFilter && IsNewsBlackout(sym)) return;

   //--- one attempt that reaches OrderSend consumes the signal
   p.active = false;
   OpenPosition(sym, magic, tag, p.dir, p.atr, riskPct, slATR, tpATR);
  }

//+------------------------------------------------------------------+
//| Open a position with ATR stop and fixed-fractional sizing        |
//+------------------------------------------------------------------+
void OpenPosition(const string sym, const long magic, const string tag, const int dir,
                  const double atr, const double riskPct, const double slATR, const double tpATR)
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     { LogV("Trading not allowed by terminal settings"); return; }

   MqlTick tick;
   if(!SymbolInfoTick(sym, tick) || tick.bid <= 0.0 || tick.ask <= 0.0)
     { LogV(sym + ": no current tick - entry skipped"); return; }

   double price   = (dir > 0 ? tick.ask : tick.bid);
   double slDist  = slATR * atr;
   double minDist = StopsMinDistance(sym);
   if(slDist < minDist) slDist = minDist;

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * riskPct / 100.0;
   ENUM_ORDER_TYPE otype = (dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double lots = CalcLots(sym, slDist, riskMoney, otype, price);
   if(lots <= 0.0) return;

   double sl = RoundPrice(sym, dir > 0 ? price - slDist : price + slDist);
   double tp = 0.0;
   if(tpATR > 0.0)
      tp = RoundPrice(sym, dir > 0 ? price + tpATR * atr : price - tpATR * atr);

   g_trade.SetExpertMagicNumber((ulong)magic);
   g_trade.SetTypeFilling(GetFilling(sym));
   bool sent = (dir > 0 ? g_trade.Buy(lots, sym, 0.0, sl, tp, tag)
                        : g_trade.Sell(lots, sym, 0.0, sl, tp, tag));
   uint rc = g_trade.ResultRetcode();
   if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED))
     {
      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      LogI(StringFormat("%s %s %s %.2f lots @ %s, SL %s, TP %s (risk %.2f%%)",
                        tag, dir > 0 ? "BUY" : "SELL", sym, lots,
                        DoubleToString(g_trade.ResultPrice(), digits),
                        DoubleToString(sl, digits),
                        tp > 0.0 ? DoubleToString(tp, digits) : "none", riskPct));
     }
   else
      LogI(StringFormat("OrderSend FAILED %s %s: retcode=%u (%s)",
                        tag, sym, rc, g_trade.ResultRetcodeDescription()));
  }

//+------------------------------------------------------------------+
//| Position sizing (identical math for FX/JPY/metals/oil/crypto)    |
//+------------------------------------------------------------------+
double CalcLots(const string sym, const double slDist, const double riskMoney,
                const ENUM_ORDER_TYPE otype, const double price)
  {
   double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tickVal  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickVal <= 0.0) tickVal = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickVal <= 0.0 || slDist <= 0.0 || riskMoney <= 0.0)
     { LogV(sym + ": unusable tick size/value - entry skipped"); return 0.0; }

   double lossPerLot = slDist / tickSize * tickVal;
   if(lossPerLot <= 0.0) return 0.0;
   double lots = riskMoney / lossPerLot;

   double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) step = (minLot > 0.0 ? minLot : 0.01);

   lots = MathFloor(lots / step + 1e-9) * step;

   if(lots < minLot)
     {
      if(minLot * lossPerLot <= riskMoney * InpMinLotRiskFactor)
         lots = minLot;
      else
        {
         LogV(StringFormat("%s: min lot %.2f would risk %.2f (> %.2f x %.1f) - entry skipped",
                           sym, minLot, minLot * lossPerLot, riskMoney, InpMinLotRiskFactor));
         return 0.0;
        }
     }
   if(maxLot > 0.0) lots = MathMin(lots, maxLot);
   double volLimit = SymbolInfoDouble(sym, SYMBOL_VOLUME_LIMIT);
   if(volLimit > 0.0) lots = MathMin(lots, volLimit);

   double margin = 0.0;
   if(OrderCalcMargin(otype, sym, lots, price, margin) && margin > 0.0)
     {
      double freeM = AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.8;
      if(margin > freeM)
        {
         lots = MathFloor(lots * freeM / margin / step) * step;
         if(lots < minLot)
           { LogV(sym + ": insufficient free margin - entry skipped"); return 0.0; }
        }
     }

   int stepDigits = 0;
   double s = step;
   while(s < 0.999 && stepDigits < 8) { s *= 10.0; stepDigits++; }
   return NormalizeDouble(lots, stepDigits);
  }

//+------------------------------------------------------------------+
//| TF module management: channel exit, break-even, chandelier       |
//| (closed-bar logic; returns false only if data is not ready)      |
//+------------------------------------------------------------------+
bool ManageTrend(const int i)
  {
   if(!InpUseTrendModule) return true;
   string sym = g_sym[i].name;
   if(CountPositions(sym, MagicTF()) == 0) return true;

   double atr = 0.0;
   if(!GetValue(g_sym[i].hATR, atr) || atr <= 0.0) return false;

   double exitHi = 0.0, exitLo = 0.0, lastClose = 0.0;
   if(InpTF_UseChannelExit)
     {
      MqlRates r[];
      ArraySetAsSeries(r, true);
      int need = InpTF_ExitChannel + 1;
      if(CopyRates(sym, InpTimeframe, 1, need, r) < need) return false;
      lastClose = r[0].close;
      exitHi = r[1].high;
      exitLo = r[1].low;
      for(int k = 2; k <= InpTF_ExitChannel; k++)
        {
         exitHi = MathMax(exitHi, r[k].high);
         exitLo = MathMin(exitLo, r[k].low);
        }
     }

   MqlTick tick;
   if(!SymbolInfoTick(sym, tick) || tick.bid <= 0.0 || tick.ask <= 0.0) return false;
   double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0) tickSize = SymbolInfoDouble(sym, SYMBOL_POINT);

   for(int p = PositionsTotal() - 1; p >= 0; p--)
     {
      ulong tk = PositionGetTicket(p);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicTF()) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double   op    = PositionGetDouble(POSITION_PRICE_OPEN);
      double   sl    = PositionGetDouble(POSITION_SL);
      double   tp    = PositionGetDouble(POSITION_TP);
      datetime opent = (datetime)PositionGetInteger(POSITION_TIME);

      int shOpen = iBarShift(sym, InpTimeframe, opent);
      if(shOpen < 1) continue;

      if(InpTF_UseChannelExit)
        {
         bool exitNow = (type == POSITION_TYPE_BUY ? lastClose < exitLo : lastClose > exitHi);
         if(exitNow)
           {
            g_trade.SetTypeFilling(GetFilling(sym));
            if(g_trade.PositionClose(tk))
               LogI(StringFormat("TF %s #%I64u closed by %d-bar channel exit", sym, tk, InpTF_ExitChannel));
            else
               LogI(StringFormat("TF channel-exit close FAILED %s #%I64u rc=%u", sym, tk, g_trade.ResultRetcode()));
            continue;
           }
        }

      double newSL = sl;
      if(InpTF_BreakEvenTrig > 0.0)
        {
         if(type == POSITION_TYPE_BUY && tick.bid - op >= InpTF_BreakEvenTrig * atr)
            newSL = BetterSL(type, newSL, op + InpTF_BreakEvenLock * atr);
         if(type == POSITION_TYPE_SELL && op - tick.ask >= InpTF_BreakEvenTrig * atr)
            newSL = BetterSL(type, newSL, op - InpTF_BreakEvenLock * atr);
        }
      if(InpTF_Trail_ATR > 0.0)
        {
         if(type == POSITION_TYPE_BUY)
           {
            int idx = iHighest(sym, InpTimeframe, MODE_HIGH, shOpen, 1);
            double hh = (idx >= 0 ? iHigh(sym, InpTimeframe, idx) : 0.0);
            if(hh > 0.0) newSL = BetterSL(type, newSL, hh - InpTF_Trail_ATR * atr);
           }
         else
           {
            int idx = iLowest(sym, InpTimeframe, MODE_LOW, shOpen, 1);
            double lo = (idx >= 0 ? iLow(sym, InpTimeframe, idx) : 0.0);
            if(lo > 0.0) newSL = BetterSL(type, newSL, lo + InpTF_Trail_ATR * atr);
           }
        }

      double eps = tickSize * 0.5;
      bool improved = (sl <= 0.0 && newSL > 0.0) ||
                      (type == POSITION_TYPE_BUY  ? newSL > sl + eps
                                                  : (sl > 0.0 && newSL < sl - eps));
      if(improved)
         TryModifySL(sym, tk, type, newSL, tp, tick);
     }
   return true;
  }

//+------------------------------------------------------------------+
//| MR module management: RSI exit and time stop (closed-bar logic)  |
//+------------------------------------------------------------------+
bool ManageMeanRev(const int i)
  {
   if(!InpUseMeanRevModule) return true;
   string sym = g_sym[i].name;
   if(CountPositions(sym, MagicMR()) == 0) return true;

   double rsi = 0.0;
   if(!GetValue(g_sym[i].hRSI, rsi)) return false;

   for(int p = PositionsTotal() - 1; p >= 0; p--)
     {
      ulong tk = PositionGetTicket(p);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicMR()) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      datetime opent = (datetime)PositionGetInteger(POSITION_TIME);
      int shOpen = iBarShift(sym, InpTimeframe, opent);
      if(shOpen < 1) continue;

      string why = "";
      if(type == POSITION_TYPE_BUY  && rsi >= InpMR_ExitLong)  why = "RSI exit";
      if(type == POSITION_TYPE_SELL && rsi <= InpMR_ExitShort) why = "RSI exit";
      if(why == "" && InpMR_MaxHoldBars > 0 && shOpen >= InpMR_MaxHoldBars) why = "time stop";
      if(why == "") continue;

      g_trade.SetTypeFilling(GetFilling(sym));
      if(g_trade.PositionClose(tk))
         LogI(StringFormat("MR %s #%I64u closed by %s (RSI %.1f, held %d bars)", sym, tk, why, rsi, shOpen));
      else
         LogI(StringFormat("MR close FAILED %s #%I64u rc=%u", sym, tk, g_trade.ResultRetcode()));
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Stop helpers                                                     |
//+------------------------------------------------------------------+
double BetterSL(const ENUM_POSITION_TYPE type, const double cur, const double cand)
  {
   if(cand <= 0.0) return cur;
   if(cur  <= 0.0) return cand;
   return (type == POSITION_TYPE_BUY ? MathMax(cur, cand) : MathMin(cur, cand));
  }

void TryModifySL(const string sym, const ulong ticket, const ENUM_POSITION_TYPE type,
                 double newSL, const double tp, const MqlTick &tick)
  {
   double minDist = StopsMinDistance(sym);
   if(type == POSITION_TYPE_BUY  && newSL > tick.bid - minDist) return;
   if(type == POSITION_TYPE_SELL && newSL < tick.ask + minDist) return;
   newSL = RoundPrice(sym, newSL);
   if(!g_trade.PositionModify(ticket, newSL, tp))
      LogV(StringFormat("PositionModify failed %s #%I64u rc=%u", sym, ticket, g_trade.ResultRetcode()));
   else
      LogV(StringFormat("%s #%I64u SL moved to %s", sym, ticket,
                        DoubleToString(newSL, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS))));
  }

//+------------------------------------------------------------------+
//| Position queries                                                 |
//+------------------------------------------------------------------+
// sym = NULL -> all symbols; magic = 0 -> any of this EA's magics
int CountPositions(const string sym, const long magic)
  {
   int cnt = 0;
   for(int p = PositionsTotal() - 1; p >= 0; p--)
     {
      ulong tk = PositionGetTicket(p);
      if(tk == 0) continue;
      long m = PositionGetInteger(POSITION_MAGIC);
      if(magic == 0) { if(!IsOurMagic(m)) continue; }
      else           { if(m != magic)     continue; }
      if(sym != NULL && PositionGetString(POSITION_SYMBOL) != sym) continue;
      cnt++;
     }
   return cnt;
  }

bool HasOppositeDir(const string sym, const int dir)
  {
   for(int p = PositionsTotal() - 1; p >= 0; p--)
     {
      ulong tk = PositionGetTicket(p);
      if(tk == 0) continue;
      if(!IsOurMagic(PositionGetInteger(POSITION_MAGIC))) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(dir > 0 && type == POSITION_TYPE_SELL) return true;
      if(dir < 0 && type == POSITION_TYPE_BUY)  return true;
     }
   return false;
  }

// number of our positions whose base or quote currency matches ccy
int CurrencyExposure(const string ccy)
  {
   int cnt = 0;
   for(int p = PositionsTotal() - 1; p >= 0; p--)
     {
      ulong tk = PositionGetTicket(p);
      if(tk == 0) continue;
      if(!IsOurMagic(PositionGetInteger(POSITION_MAGIC))) continue;
      string s = PositionGetString(POSITION_SYMBOL);
      if(SymbolInfoString(s, SYMBOL_CURRENCY_BASE)   == ccy ||
         SymbolInfoString(s, SYMBOL_CURRENCY_PROFIT) == ccy)
         cnt++;
     }
   return cnt;
  }

//+------------------------------------------------------------------+
//| Remaining open risk of all EA positions, % of equity             |
//+------------------------------------------------------------------+
double PortfolioOpenRiskPct()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq <= 0.0) return 0.0;
   double fallback = MathMax(InpTF_RiskPercent, InpMR_RiskPercent);
   double total = 0.0;
   for(int p = PositionsTotal() - 1; p >= 0; p--)
     {
      ulong tk = PositionGetTicket(p);
      if(tk == 0) continue;
      if(!IsOurMagic(PositionGetInteger(POSITION_MAGIC))) continue;

      string s   = PositionGetString(POSITION_SYMBOL);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double op  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl  = PositionGetDouble(POSITION_SL);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(sl <= 0.0) { total += fallback; continue; }
      double dist = (type == POSITION_TYPE_BUY ? op - sl : sl - op);
      if(dist <= 0.0) continue;

      double tickSize = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_SIZE);
      double tickVal  = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tickVal <= 0.0) tickVal = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_VALUE);
      if(tickSize <= 0.0 || tickVal <= 0.0) { total += fallback; continue; }

      total += 100.0 * (dist / tickSize * tickVal * vol) / eq;
     }
   return total;
  }

//+------------------------------------------------------------------+
//| Close every position belonging to this EA                       |
//+------------------------------------------------------------------+
void CloseAllPositions(const string reason)
  {
   LogI("Closing all positions: " + reason);
   for(int p = PositionsTotal() - 1; p >= 0; p--)
     {
      ulong tk = PositionGetTicket(p);
      if(tk == 0) continue;
      if(!IsOurMagic(PositionGetInteger(POSITION_MAGIC))) continue;
      string s = PositionGetString(POSITION_SYMBOL);
      g_trade.SetTypeFilling(GetFilling(s));
      if(!g_trade.PositionClose(tk))
         LogI(StringFormat("Close FAILED %s #%I64u rc=%u (%s)",
                           s, tk, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
     }
  }

//+------------------------------------------------------------------+
//| Session / day-of-week filter (server time, entries only)         |
//+------------------------------------------------------------------+
bool SessionOK()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   bool dayOK = true;
   switch(dt.day_of_week)
     {
      case 0: dayOK = InpTradeSunday;    break;
      case 1: dayOK = InpTradeMonday;    break;
      case 2: dayOK = InpTradeTuesday;   break;
      case 3: dayOK = InpTradeWednesday; break;
      case 4: dayOK = InpTradeThursday;  break;
      case 5: dayOK = InpTradeFriday;    break;
      case 6: dayOK = InpTradeSaturday;  break;
     }
   if(!dayOK) return false;
   if(!InpUseSessionFilter) return true;
   if(InpSessionStartHour == InpSessionEndHour) return true;

   int h = dt.hour;
   if(InpSessionStartHour < InpSessionEndHour)
      return (h >= InpSessionStartHour && h < InpSessionEndHour);
   return (h >= InpSessionStartHour || h < InpSessionEndHour);
  }

//+------------------------------------------------------------------+
//| Spread filter                                                    |
//+------------------------------------------------------------------+
bool SpreadOK(const string sym, const double atr)
  {
   MqlTick tick;
   if(!SymbolInfoTick(sym, tick) || tick.bid <= 0.0 || tick.ask <= 0.0) return false;
   double spread = tick.ask - tick.bid;
   if(spread < 0.0) return false;

   if(InpMaxSpreadPoints > 0)
     {
      double point = SymbolInfoDouble(sym, SYMBOL_POINT);
      if(point > 0.0 && spread > InpMaxSpreadPoints * point) return false;
     }
   if(InpMaxSpreadATR > 0.0 && atr > 0.0 && spread > InpMaxSpreadATR * atr) return false;
   return true;
  }

//+------------------------------------------------------------------+
//| News filter (built-in calendar; inactive in the Strategy Tester) |
//+------------------------------------------------------------------+
bool IsNewsBlackout(const string sym)
  {
   if(MQLInfoInteger(MQL_TESTER)) return false;
   RefreshNewsCache();

   string base  = SymbolInfoString(sym, SYMBOL_CURRENCY_BASE);
   string quote = SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT);
   datetime now = TimeCurrent();
   for(int k = 0; k < ArraySize(g_news); k++)
     {
      if(g_news[k].ccy != base && g_news[k].ccy != quote) continue;
      if(now >= g_news[k].t - InpNewsBeforeMin * 60 &&
         now <= g_news[k].t + InpNewsAfterMin  * 60)
         return true;
     }
   return false;
  }

void RefreshNewsCache()
  {
   datetime now = TimeCurrent();
   if(g_lastNewsFetch > 0 && now - g_lastNewsFetch < 900) return;
   g_lastNewsFetch = now;
   ArrayResize(g_news, 0);

   MqlCalendarValue vals[];
   datetime from = (datetime)((long)now - (InpNewsAfterMin * 60 + 3600));
   datetime to   = (datetime)((long)now + 86400);
   if(!CalendarValueHistory(vals, from, to))
     { LogV("Economic calendar query failed"); return; }

   int cnt = 0;
   for(int k = 0; k < ArraySize(vals); k++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(vals[k].event_id, ev)) continue;
      if(ev.importance != CALENDAR_IMPORTANCE_HIGH) continue;
      MqlCalendarCountry cn;
      if(!CalendarCountryById(ev.country_id, cn)) continue;
      ArrayResize(g_news, cnt + 1);
      g_news[cnt].t   = vals[k].time;
      g_news[cnt].ccy = cn.currency;
      cnt++;
     }
   LogV(StringFormat("News cache refreshed: %d high-impact events in window", cnt));
  }

//+------------------------------------------------------------------+
//| Broker helpers                                                   |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFilling(const string sym)
  {
   long flags = SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((flags & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   if((flags & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

double RoundPrice(const string sym, double price)
  {
   double tick = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(tick > 0.0) price = MathRound(price / tick) * tick;
   return NormalizeDouble(price, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));
  }

double StopsMinDistance(const string sym)
  {
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   long lv = MathMax(SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL),
                     SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL));
   double spread = 0.0;
   MqlTick tk;
   if(SymbolInfoTick(sym, tk) && tk.ask > 0.0 && tk.bid > 0.0)
      spread = tk.ask - tk.bid;
   return (double)(lv + 2) * point + spread;
  }

string B2S(const bool b) { return b ? "YES" : "no"; }

//+------------------------------------------------------------------+
//| Chart dashboard                                                  |
//+------------------------------------------------------------------+
void UpdateDashboard()
  {
   static datetime lastDraw = 0;
   datetime now = TimeCurrent();
   if(lastDraw > 0 && now - lastDraw < 5) return;
   lastDraw = now;

   int pendCnt = 0;
   for(int i = 0; i < ArraySize(g_sym); i++)
     {
      if(g_sym[i].pTF.active) pendCnt++;
      if(g_sym[i].pMR.active) pendCnt++;
     }

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   string s = StringFormat("Portfolio Hybrid Trader v2  |  magic %I64d/%I64d  |  %s\n",
                           MagicTF(), MagicMR(), EnumToString(InpTimeframe));
   s += StringFormat("Equity %.2f (peak %.2f)   Open %d/%d  [TF %d/%d, MR %d/%d]   Pending %d   Risk %.2f%%/%.2f%%\n",
                     eq, g_peakEquity,
                     CountPositions(NULL, 0), InpMaxPosTotal,
                     CountPositions(NULL, MagicTF()), InpTF_MaxPositions,
                     CountPositions(NULL, MagicMR()), InpMR_MaxPositions,
                     pendCnt, PortfolioOpenRiskPct(), InpMaxPortfolioRisk);
   s += StringFormat("Entry halts - day: %s  week: %s  month: %s  EMERGENCY: %s\n",
                     B2S(g_dayHalt), B2S(g_weekHalt), B2S(g_monthHalt), B2S(g_emergencyHalt));
   s += StringFormat("Symbols active: %d\n", ArraySize(g_sym));
   Comment(s);
  }
//+------------------------------------------------------------------+
