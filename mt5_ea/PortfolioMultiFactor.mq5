//+------------------------------------------------------------------+
//|                                         PortfolioMultiFactor.mq5 |
//|   Institutional FX factor portfolio: Carry + Cross-Sectional    |
//|   Momentum + Time-Series Trend, on one ATR-normalized risk core |
//|                                                                  |
//|  Version 3. This implements the three documented "currency      |
//|  factor" strategies that banks and currency hedge funds         |
//|  actually run (the FX style literature: carry, momentum, trend) |
//|  to the extent they are implementable in retail MT5:            |
//|                                                                  |
//|  - CY  Carry: hold pairs whose SWAP you EARN (interest-rate     |
//|        differential), highest carry-to-volatility first,        |
//|        optionally only when not fighting the trend (classic    |
//|        carry-crash protection). Weekly rebalance.               |
//|        IMPORTANT: the MT5 tester applies TODAY'S swap rates to  |
//|        the whole history, so carry backtests are indicative     |
//|        only - judge this module on recent data and forward/live.|
//|                                                                  |
//|  - XS  Cross-sectional momentum: score each major currency by   |
//|        the average return of all its pairs over a lookback,     |
//|        then long strongest-vs-weakest pairs. Weekly rebalance.  |
//|                                                                  |
//|  - TF  Time-series trend: Donchian breakout with EMA regime     |
//|        filter and chandelier trail (the CTA strategy).          |
//|                                                                  |
//|  Shared core: pending-signal execution (signals computed on     |
//|  CLOSED bars only, execution retried until spreads/caps clear), |
//|  fixed-fractional ATR sizing, per-currency exposure caps,       |
//|  portfolio risk caps, daily/weekly/monthly/emergency drawdown   |
//|  guards, netting-account safety. No martingale, no grid, no     |
//|  averaging down, no lookahead, no repainting, no external       |
//|  indicators required (price + swap data only).                  |
//|                                                                  |
//|  Attach to ONE chart (recommended EURUSD D1). The EA trades     |
//|  every symbol in InpSymbols.                                    |
//+------------------------------------------------------------------+
#property copyright   "2026"
#property link        "https://www.mql5.com"
#property version     "3.00"
#property description "FX factor portfolio: carry + cross-sectional momentum + trend following,"
#property description "ATR-normalized risk, weekly factor rebalance, portfolio-level protection."

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
input long            InpMagic            = 772200;        // Magic base (TF=+0, XS=+1, CY=+2)
input string          InpSymbols          = "AUDCAD,AUDCHF,AUDJPY,AUDNZD,AUDUSD,CADCHF,CADJPY,CHFJPY,EURAUD,EURCAD,EURCHF,EURGBP,EURJPY,EURNZD,EURUSD,GBPAUD,GBPCAD,GBPCHF,GBPJPY,GBPNZD,GBPUSD,NZDCAD,NZDCHF,NZDJPY,NZDUSD,USDCAD,USDCHF,USDJPY,XAUUSD,XAGUSD,USOIL,UKOIL,BTCUSD,ETHUSD"; // Symbol list (comma separated)
input string          InpSymbolSuffix     = "";             // Broker symbol suffix (e.g. ".a", "m")
input ENUM_TIMEFRAMES InpTimeframe        = PERIOD_D1;      // Working timeframe
input bool            InpVerboseLog       = false;          // Verbose logging
input bool            InpShowDashboard    = true;           // Show chart Comment() dashboard

input group "=== Modules ==="
input bool            InpUseTrendModule   = true;           // TF: time-series trend (Donchian)
input bool            InpUseXSMomModule   = true;           // XS: cross-sectional currency momentum
input bool            InpUseCarryModule   = true;           // CY: carry (swap differential)

input group "=== TF module: Donchian breakout trend ==="
input int             InpTF_EntryChannel  = 40;             // TF: entry channel period (bars)
input int             InpTF_ExitChannel   = 20;             // TF: exit channel period (bars)
input bool            InpTF_UseChannelExit= true;           // TF: use opposite-channel exit
input bool            InpTF_UseEMAFilter  = true;           // TF: trade only with EMA regime
input double          InpTF_RiskPercent   = 0.4;            // TF: risk per trade, % of equity
input double          InpTF_SL_ATR        = 3.0;            // TF: initial stop (x ATR)
input double          InpTF_Trail_ATR     = 4.0;            // TF: chandelier trail (x ATR, 0 = off)
input int             InpTF_MaxPositions  = 8;              // TF: max open positions
input bool            InpTF_AllowLong     = true;           // TF: allow longs
input bool            InpTF_AllowShort    = true;           // TF: allow shorts

input group "=== XS module: cross-sectional momentum ==="
input int             InpXS_Lookback      = 90;             // XS: momentum lookback (bars)
input int             InpXS_SkipBars      = 5;              // XS: skip most recent bars (reversal noise)
input double          InpXS_MinScore      = 1.0;            // XS: min strength spread, % (base - quote)
input int             InpXS_MaxPositions  = 4;              // XS: max open positions
input double          InpXS_RiskPercent   = 0.4;            // XS: risk per trade, % of equity
input double          InpXS_SL_ATR        = 3.0;            // XS: stop-loss (x ATR)

input group "=== CY module: carry ==="
input double          InpCY_MinAnnualPct  = 1.0;            // CY: min earned swap, % per year
input double          InpCY_MinCarryToVol = 0.10;           // CY: min carry / annualized volatility
input bool            InpCY_UseTrendFilter= true;           // CY: don't hold carry against the EMA regime
input int             InpCY_MaxPositions  = 6;              // CY: max open positions
input double          InpCY_RiskPercent   = 0.4;            // CY: risk per trade, % of equity
input double          InpCY_SL_ATR        = 4.0;            // CY: stop-loss (x ATR, wide)

input group "=== Shared signal settings ==="
input int             InpATRPeriod        = 20;             // ATR period
input int             InpTrendEMA         = 200;            // Regime EMA period (TF + CY filter)
input int             InpSignalTTLMin     = 240;            // TF pending signal lifetime, minutes
input int             InpFactorTTLHours   = 48;             // XS/CY pending signal lifetime, hours

input group "=== Portfolio risk ==="
input int             InpMaxPosPerSymbol  = 2;              // Max positions per symbol (all modules)
input int             InpMaxPosTotal      = 16;             // Max positions across portfolio
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
   double            atr;           // ATR at signal time (refreshed at execution)
   datetime          barTime;       // bar the signal belongs to (TF expiry)
   datetime          since;         // when the signal was created
  };

struct SymState
  {
   string            name;
   bool              enabled;
   bool              isFX;          // both currencies are in the major-8 set
   int               baseIdx;       // index into g_ccyList, -1 if not a major
   int               quoteIdx;
   int               hATR;
   int               hEMA;
   datetime          lastBar;
   Pending           pTF;
   Pending           pXS;
   Pending           pCY;
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

string    g_ccyList[8]   = {"USD","EUR","GBP","JPY","CHF","AUD","NZD","CAD"};

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

int       g_lastRebalWeek= -2147483647;   // week id of last successful factor rebalance

// desired factor books, rebuilt at each weekly rebalance
int       gXS_idx[];      // symbol indices
int       gXS_dir[];      // +1 / -1
int       gCY_idx[];
int       gCY_dir[];

NewsItem  g_news[];
datetime  g_lastNewsFetch= 0;

long MagicTF() { return InpMagic;     }
long MagicXS() { return InpMagic + 1; }
long MagicCY() { return InpMagic + 2; }
bool IsOurMagic(const long m) { return (m >= InpMagic && m <= InpMagic + 2); }

void LogI(const string msg) { Print("[PMF] ", msg); }
void LogV(const string msg) { if(InpVerboseLog) Print("[PMF] ", msg); }

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!InpUseTrendModule && !InpUseXSMomModule && !InpUseCarryModule)
     { LogI("All modules disabled - nothing to trade"); return INIT_PARAMETERS_INCORRECT; }
   if(InpTF_EntryChannel < 5 || InpTF_ExitChannel < 2)
     { LogI("Invalid TF channel periods"); return INIT_PARAMETERS_INCORRECT; }
   if(InpATRPeriod < 2 || InpTF_SL_ATR <= 0.0 || InpXS_SL_ATR <= 0.0 || InpCY_SL_ATR <= 0.0)
     { LogI("Invalid ATR period or SL multipliers"); return INIT_PARAMETERS_INCORRECT; }
   if(InpXS_Lookback < 20 || InpXS_SkipBars < 0)
     { LogI("Invalid XS lookback/skip"); return INIT_PARAMETERS_INCORRECT; }
   if(InpTF_RiskPercent <= 0.0 || InpTF_RiskPercent > 5.0 ||
      InpXS_RiskPercent <= 0.0 || InpXS_RiskPercent > 5.0 ||
      InpCY_RiskPercent <= 0.0 || InpCY_RiskPercent > 5.0)
     { LogI("Module risk must be in (0, 5] percent"); return INIT_PARAMETERS_INCORRECT; }
   if(InpMaxPosPerSymbol < 1 || InpMaxPosTotal < 1)
     { LogI("Position limits must be >= 1"); return INIT_PARAMETERS_INCORRECT; }
   if(InpSessionStartHour < 0 || InpSessionStartHour > 23 || InpSessionEndHour < 0 || InpSessionEndHour > 23)
     { LogI("Session hours must be 0..23"); return INIT_PARAMETERS_INCORRECT; }

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

   ArrayResize(gXS_idx, 0); ArrayResize(gXS_dir, 0);
   ArrayResize(gCY_idx, 0); ArrayResize(gCY_dir, 0);

   EventSetTimer(10);
   LogI(StringFormat("Initialized: %d symbols, %s, magics %I64d/%I64d/%I64d (TF/XS/CY)",
                     ArraySize(g_sym), EnumToString(InpTimeframe), MagicTF(), MagicXS(), MagicCY()));
   if(InpUseCarryModule && MQLInfoInteger(MQL_TESTER))
      LogI("NOTE: the tester applies TODAY'S swap rates to all history - carry results are indicative only");
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
//| Helpers: currency mapping                                        |
//+------------------------------------------------------------------+
int CcyIndex(const string c)
  {
   for(int k = 0; k < 8; k++)
      if(g_ccyList[k] == c) return k;
   return -1;
  }

int SymIndex(const string name)
  {
   for(int i = 0; i < ArraySize(g_sym); i++)
      if(g_sym[i].name == name) return i;
   return -1;
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
      g_sym[added].name     = s;
      g_sym[added].enabled  = true;
      g_sym[added].lastBar  = 0;
      g_sym[added].pTF.active = false;
      g_sym[added].pXS.active = false;
      g_sym[added].pCY.active = false;
      g_sym[added].baseIdx  = CcyIndex(SymbolInfoString(s, SYMBOL_CURRENCY_BASE));
      g_sym[added].quoteIdx = CcyIndex(SymbolInfoString(s, SYMBOL_CURRENCY_PROFIT));
      g_sym[added].isFX     = (g_sym[added].baseIdx >= 0 && g_sym[added].quoteIdx >= 0);
      g_sym[added].hATR     = iATR(s, InpTimeframe, InpATRPeriod);
      g_sym[added].hEMA     = iMA(s, InpTimeframe, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);
      if(g_sym[added].hATR == INVALID_HANDLE || g_sym[added].hEMA == INVALID_HANDLE)
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

   //--- weekly factor rebalance (XS + CY); retried until data is ready
   if((InpUseXSMomModule || InpUseCarryModule) && g_weekId != g_lastRebalWeek)
     {
      if(RebalanceFactors())
         g_lastRebalWeek = g_weekId;
     }

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

   //--- once per new bar: closed-bar TF management + TF signal
   if(curBar != g_sym[i].lastBar)
     {
      if(!ManageTrend(i)) return;            // data not ready -> retry, don't latch
      if(InpUseTrendModule)
        {
         if(!ComputeTrendSignal(i, curBar)) return;
        }
      g_sym[i].lastBar = curBar;
     }

   //--- every call: try to execute pending signals
   if(InpUseTrendModule)
      ExecutePending(i, g_sym[i].pTF, MagicTF(), "PMF-TF", InpTF_RiskPercent,
                     InpTF_SL_ATR, InpTF_MaxPositions, true,  InpSignalTTLMin);
   if(InpUseXSMomModule)
      ExecutePending(i, g_sym[i].pXS, MagicXS(), "PMF-XS", InpXS_RiskPercent,
                     InpXS_SL_ATR, InpXS_MaxPositions, false, InpFactorTTLHours * 60);
   if(InpUseCarryModule)
      ExecutePending(i, g_sym[i].pCY, MagicCY(), "PMF-CY", InpCY_RiskPercent,
                     InpCY_SL_ATR, InpCY_MaxPositions, false, InpFactorTTLHours * 60);
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
//| TF signal: Donchian breakout on closed bars                      |
//+------------------------------------------------------------------+
bool ComputeTrendSignal(const int i, const datetime curBar)
  {
   string sym = g_sym[i].name;
   g_sym[i].pTF.active = false;            // new bar invalidates the old signal

   if(CountPositions(sym, MagicTF()) > 0) return true;

   double atr = 0.0, ema = 0.0;
   if(!GetValue(g_sym[i].hATR, atr) || atr <= 0.0) return false;
   if(InpTF_UseEMAFilter && !GetValue(g_sym[i].hEMA, ema)) return false;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int need = InpTF_EntryChannel + 1;
   if(CopyRates(sym, InpTimeframe, 1, need, rates) < need) return false;
   double closed = rates[0].close;
   if(closed <= 0.0) return false;

   double atrPct = 100.0 * atr / closed;
   if(InpMinATRPct > 0.0 && atrPct < InpMinATRPct) return true;
   if(InpMaxATRPct > 0.0 && atrPct > InpMaxATRPct) return true;

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
      LogV(StringFormat("%s: TF %s signal pending", sym, longOK ? "LONG" : "SHORT"));
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Carry: annualized swap earned for a direction, % of price/year.  |
//| Handles points / money / interest swap modes; other modes are    |
//| excluded from the carry module.                                  |
//+------------------------------------------------------------------+
bool CarryAnnualPct(const string sym, const bool isLong, double &annPct)
  {
   annPct = 0.0;
   double swap = SymbolInfoDouble(sym, isLong ? SYMBOL_SWAP_LONG : SYMBOL_SWAP_SHORT);
   long   mode = SymbolInfoInteger(sym, SYMBOL_SWAP_MODE);
   if(mode == SYMBOL_SWAP_MODE_DISABLED) return false;
   if(swap == 0.0) return true;

   MqlTick tick;
   if(!SymbolInfoTick(sym, tick) || tick.bid <= 0.0) return false;
   double price = tick.bid;

   if(mode == SYMBOL_SWAP_MODE_POINTS)
     {
      double point = SymbolInfoDouble(sym, SYMBOL_POINT);
      annPct = swap * point * 365.0 / price * 100.0;
      return true;
     }
   if(mode == SYMBOL_SWAP_MODE_CURRENCY_SYMBOL ||
      mode == SYMBOL_SWAP_MODE_CURRENCY_MARGIN ||
      mode == SYMBOL_SWAP_MODE_CURRENCY_DEPOSIT)
     {
      double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
      double tickVal  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
      if(tickSize <= 0.0 || tickVal <= 0.0) return false;
      double swapPrice = swap * tickSize / tickVal;   // money/lot/day -> price units/day
      annPct = swapPrice * 365.0 / price * 100.0;
      return true;
     }
   if(mode == SYMBOL_SWAP_MODE_INTEREST_CURRENT || mode == SYMBOL_SWAP_MODE_INTEREST_OPEN)
     {
      annPct = swap;                                  // already % per year
      return true;
     }
   return false;                                      // exotic modes: skip for carry
  }

//+------------------------------------------------------------------+
//| Weekly factor rebalance: build XS and CY desired books, close    |
//| disqualified positions, queue pendings for new entries.          |
//| Returns false only if no symbol had usable data yet (retry).     |
//+------------------------------------------------------------------+
bool RebalanceFactors()
  {
   int ns = ArraySize(g_sym);
   if(ns == 0) return false;

   //--- per-symbol snapshot for this rebalance
   double srAtr[];  ArrayResize(srAtr, ns);
   double srEma[];  ArrayResize(srEma, ns);
   double srClose[];ArrayResize(srClose, ns);
   double srRet[];  ArrayResize(srRet, ns);    // lookback return, %
   bool   evald[];  ArrayResize(evald, ns);

   double score[8];
   int    scnt[8];
   ArrayInitialize(score, 0.0);
   ArrayInitialize(scnt, 0);

   int usable = 0;
   for(int i = 0; i < ns; i++)
     {
      evald[i] = false;
      if(!g_sym[i].enabled || !g_sym[i].isFX) continue;
      string sym = g_sym[i].name;

      double atr = 0.0, ema = 0.0;
      if(!GetValue(g_sym[i].hATR, atr) || atr <= 0.0) continue;
      if(!GetValue(g_sym[i].hEMA, ema) || ema <= 0.0) continue;

      MqlRates r[];
      ArraySetAsSeries(r, true);
      int need = InpXS_Lookback + 1;
      if(CopyRates(sym, InpTimeframe, 1 + InpXS_SkipBars, need, r) < need) continue;
      if(r[0].close <= 0.0 || r[InpXS_Lookback].close <= 0.0) continue;

      srAtr[i]   = atr;
      srEma[i]   = ema;
      srClose[i] = r[0].close;
      srRet[i]   = 100.0 * MathLog(r[0].close / r[InpXS_Lookback].close);
      evald[i]   = true;
      usable++;

      score[g_sym[i].baseIdx]  += srRet[i];
      scnt [g_sym[i].baseIdx]  ++;
      score[g_sym[i].quoteIdx] -= srRet[i];
      scnt [g_sym[i].quoteIdx] ++;
     }
   if(usable == 0) return false;   // data still loading - retry next call

   for(int c = 0; c < 8; c++)
      if(scnt[c] > 0) score[c] /= scnt[c];

   //--- XS desired book: top |base score - quote score| pairs
   ArrayResize(gXS_idx, 0); ArrayResize(gXS_dir, 0);
   if(InpUseXSMomModule)
     {
      int    candIdx[];  ArrayResize(candIdx, 0);
      double candVal[];  ArrayResize(candVal, 0);
      for(int i = 0; i < ns; i++)
        {
         if(!evald[i]) continue;
         if(scnt[g_sym[i].baseIdx] < 2 || scnt[g_sym[i].quoteIdx] < 2) continue;
         double ps = score[g_sym[i].baseIdx] - score[g_sym[i].quoteIdx];
         if(MathAbs(ps) < InpXS_MinScore) continue;
         int m = ArraySize(candIdx);
         ArrayResize(candIdx, m + 1); ArrayResize(candVal, m + 1);
         candIdx[m] = i;
         candVal[m] = ps;
        }
      // pick top K by |score| (selection sort, small arrays)
      int want = MathMin(InpXS_MaxPositions, ArraySize(candIdx));
      for(int k = 0; k < want; k++)
        {
         int best = -1;
         for(int m = 0; m < ArraySize(candIdx); m++)
           {
            if(candIdx[m] < 0) continue;
            if(best < 0 || MathAbs(candVal[m]) > MathAbs(candVal[best])) best = m;
           }
         if(best < 0) break;
         int sz = ArraySize(gXS_idx);
         ArrayResize(gXS_idx, sz + 1); ArrayResize(gXS_dir, sz + 1);
         gXS_idx[sz] = candIdx[best];
         gXS_dir[sz] = (candVal[best] > 0.0 ? 1 : -1);
         candIdx[best] = -1;
        }
     }

   //--- CY desired book: top carry-to-vol among qualifying pairs
   ArrayResize(gCY_idx, 0); ArrayResize(gCY_dir, 0);
   if(InpUseCarryModule)
     {
      int    cIdx[];  ArrayResize(cIdx, 0);
      int    cDir[];  ArrayResize(cDir, 0);
      double cVal[];  ArrayResize(cVal, 0);
      for(int i = 0; i < ns; i++)
        {
         if(!evald[i]) continue;
         string sym = g_sym[i].name;
         double annL = 0.0, annS = 0.0;
         bool okL = CarryAnnualPct(sym, true,  annL);
         bool okS = CarryAnnualPct(sym, false, annS);
         if(!okL && !okS) continue;
         double annVol = 100.0 * srAtr[i] / srClose[i] * 16.0;   // ~sqrt(252) annualization
         if(annVol <= 0.0) continue;

         bool qL = okL && annL >= InpCY_MinAnnualPct && annL / annVol >= InpCY_MinCarryToVol &&
                   (!InpCY_UseTrendFilter || srClose[i] > srEma[i]);
         bool qS = okS && annS >= InpCY_MinAnnualPct && annS / annVol >= InpCY_MinCarryToVol &&
                   (!InpCY_UseTrendFilter || srClose[i] < srEma[i]);
         if(!qL && !qS) continue;

         int    dir = 0;
         double ann = 0.0;
         if(qL && (!qS || annL >= annS)) { dir = 1;  ann = annL; }
         else                            { dir = -1; ann = annS; }

         int m = ArraySize(cIdx);
         ArrayResize(cIdx, m + 1); ArrayResize(cDir, m + 1); ArrayResize(cVal, m + 1);
         cIdx[m] = i;
         cDir[m] = dir;
         cVal[m] = ann / annVol;
        }
      int want = MathMin(InpCY_MaxPositions, ArraySize(cIdx));
      for(int k = 0; k < want; k++)
        {
         int best = -1;
         for(int m = 0; m < ArraySize(cIdx); m++)
           {
            if(cIdx[m] < 0) continue;
            if(best < 0 || cVal[m] > cVal[best]) best = m;
           }
         if(best < 0) break;
         int sz = ArraySize(gCY_idx);
         ArrayResize(gCY_idx, sz + 1); ArrayResize(gCY_dir, sz + 1);
         gCY_idx[sz] = cIdx[best];
         gCY_dir[sz] = cDir[best];
         cIdx[best] = -1;
        }
     }

   //--- close factor positions that are no longer in their desired book
   //    (only for symbols we could evaluate this week)
   CloseDisqualified(MagicXS(), "XS", gXS_idx, gXS_dir, evald);
   CloseDisqualified(MagicCY(), "CY", gCY_idx, gCY_dir, evald);

   //--- queue pendings for desired entries we do not hold yet
   datetime now = TimeCurrent();
   for(int k = 0; k < ArraySize(gXS_idx); k++)
     {
      int i = gXS_idx[k];
      if(CountPositions(g_sym[i].name, MagicXS()) > 0) continue;
      g_sym[i].pXS.active  = true;
      g_sym[i].pXS.dir     = gXS_dir[k];
      g_sym[i].pXS.atr     = srAtr[i];
      g_sym[i].pXS.barTime = iTime(g_sym[i].name, InpTimeframe, 0);
      g_sym[i].pXS.since   = now;
     }
   for(int k = 0; k < ArraySize(gCY_idx); k++)
     {
      int i = gCY_idx[k];
      if(CountPositions(g_sym[i].name, MagicCY()) > 0) continue;
      g_sym[i].pCY.active  = true;
      g_sym[i].pCY.dir     = gCY_dir[k];
      g_sym[i].pCY.atr     = srAtr[i];
      g_sym[i].pCY.barTime = iTime(g_sym[i].name, InpTimeframe, 0);
      g_sym[i].pCY.since   = now;
     }

   LogI(StringFormat("Factor rebalance: %d symbols evaluated, XS book %d, CY book %d",
                     usable, ArraySize(gXS_idx), ArraySize(gCY_idx)));
   return true;
  }

//+------------------------------------------------------------------+
//| Close module positions whose symbol/direction left the book      |
//+------------------------------------------------------------------+
void CloseDisqualified(const long magic, const string tag,
                       const int &bookIdx[], const int &bookDir[], const bool &evald[])
  {
   for(int p = PositionsTotal() - 1; p >= 0; p--)
     {
      ulong tk = PositionGetTicket(p);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      string s = PositionGetString(POSITION_SYMBOL);
      int idx  = SymIndex(s);
      if(idx < 0) continue;
      if(!evald[idx]) continue;     // no fresh data: leave the position alone

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      int held = (type == POSITION_TYPE_BUY ? 1 : -1);

      bool keep = false;
      for(int k = 0; k < ArraySize(bookIdx); k++)
         if(bookIdx[k] == idx && bookDir[k] == held) { keep = true; break; }
      if(keep) continue;

      g_trade.SetTypeFilling(GetFilling(s));
      if(g_trade.PositionClose(tk))
         LogI(StringFormat("%s %s #%I64u closed at rebalance (left the book)", tag, s, tk));
      else
         LogI(StringFormat("%s rebalance close FAILED %s #%I64u rc=%u", tag, s, tk, g_trade.ResultRetcode()));
     }
  }

//+------------------------------------------------------------------+
//| Try to execute a pending signal (spread/session/caps gating)     |
//+------------------------------------------------------------------+
void ExecutePending(const int i, Pending &p, const long magic, const string tag,
                    const double riskPct, const double slATR, const int moduleCap,
                    const bool sameBarOnly, const int ttlMin)
  {
   if(!p.active) return;
   string sym = g_sym[i].name;

   if(sameBarOnly && iTime(sym, InpTimeframe, 0) != p.barTime) { p.active = false; return; }
   if(ttlMin > 0 && (long)(TimeCurrent() - p.since) > (long)ttlMin * 60)
     { p.active = false; return; }

   if(!EntriesAllowed()) return;
   if(!SessionOK())      return;
   if(CountPositions(sym, magic) > 0) { p.active = false; return; }
   int perSymCap = (g_isNetting ? 1 : InpMaxPosPerSymbol);
   if(CountPositions(sym, 0) >= perSymCap)        return;
   if(HasOppositeDir(sym, p.dir))                 return;
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

   //--- refresh ATR for factor signals that waited (sizing accuracy)
   double freshAtr = 0.0;
   if(GetValue(g_sym[i].hATR, freshAtr) && freshAtr > 0.0)
      p.atr = freshAtr;

   if(!SpreadOK(sym, p.atr)) return;
   if(InpUseNewsFilter && IsNewsBlackout(sym)) return;

   p.active = false;     // one attempt that reaches OrderSend consumes the signal
   OpenPosition(sym, magic, tag, p.dir, p.atr, riskPct, slATR);
  }

//+------------------------------------------------------------------+
//| Open a position with ATR stop and fixed-fractional sizing        |
//+------------------------------------------------------------------+
void OpenPosition(const string sym, const long magic, const string tag, const int dir,
                  const double atr, const double riskPct, const double slATR)
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

   g_trade.SetExpertMagicNumber((ulong)magic);
   g_trade.SetTypeFilling(GetFilling(sym));
   bool sent = (dir > 0 ? g_trade.Buy(lots, sym, 0.0, sl, 0.0, tag)
                        : g_trade.Sell(lots, sym, 0.0, sl, 0.0, tag));
   uint rc = g_trade.ResultRetcode();
   if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED))
     {
      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      LogI(StringFormat("%s %s %s %.2f lots @ %s, SL %s (risk %.2f%%)",
                        tag, dir > 0 ? "BUY" : "SELL", sym, lots,
                        DoubleToString(g_trade.ResultPrice(), digits),
                        DoubleToString(sl, digits), riskPct));
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
//| TF management: channel exit + chandelier trail (closed bars)     |
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
   double fallback = MathMax(InpTF_RiskPercent, MathMax(InpXS_RiskPercent, InpCY_RiskPercent));
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

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   string s = StringFormat("Portfolio Multi-Factor v3  |  magics %I64d/%I64d/%I64d (TF/XS/CY)  |  %s\n",
                           MagicTF(), MagicXS(), MagicCY(), EnumToString(InpTimeframe));
   s += StringFormat("Equity %.2f (peak %.2f)   Open %d/%d  [TF %d/%d, XS %d/%d, CY %d/%d]   Risk %.2f%%/%.2f%%\n",
                     eq, g_peakEquity,
                     CountPositions(NULL, 0), InpMaxPosTotal,
                     CountPositions(NULL, MagicTF()), InpTF_MaxPositions,
                     CountPositions(NULL, MagicXS()), InpXS_MaxPositions,
                     CountPositions(NULL, MagicCY()), InpCY_MaxPositions,
                     PortfolioOpenRiskPct(), InpMaxPortfolioRisk);
   s += StringFormat("Books: XS %d, CY %d   Halts - day: %s week: %s month: %s EMERGENCY: %s\n",
                     ArraySize(gXS_idx), ArraySize(gCY_idx),
                     B2S(g_dayHalt), B2S(g_weekHalt), B2S(g_monthHalt), B2S(g_emergencyHalt));
   s += StringFormat("Symbols active: %d\n", ArraySize(g_sym));
   Comment(s);
  }
//+------------------------------------------------------------------+
