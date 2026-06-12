//+------------------------------------------------------------------+
//|                                      PortfolioTrendFollower.mq5 |
//|        Multi-symbol portfolio trend-following Expert Advisor    |
//|                                                                  |
//|  Strategy: Donchian-channel breakout in the direction of a      |
//|  long-term EMA regime filter, with ATR-normalized stops,        |
//|  position sizing and exits. One parameter set is shared by      |
//|  every symbol (no per-symbol curve fitting).                    |
//|                                                                  |
//|  - Signals are evaluated ONLY on closed bars (shift >= 1).      |
//|    The current unfinished candle is never used for decisions.   |
//|  - No martingale, no grid, no averaging down, no recovery       |
//|    logic. Every position has a hard stop-loss from the start.   |
//|  - All indicators are MT5-native (iATR, iMA, iADX) or computed  |
//|    internally from closed bars (Donchian channels). Nothing     |
//|    repaints, nothing external is required.                      |
//|                                                                  |
//|  Attach to ONE chart (any symbol, recommended EURUSD D1).       |
//|  The EA scans and trades every symbol in InpSymbols.            |
//+------------------------------------------------------------------+
#property copyright   "2026"
#property link        "https://www.mql5.com"
#property version     "1.00"
#property description "Multi-symbol Donchian breakout trend follower with EMA regime filter,"
#property description "ATR-based risk management and portfolio-level equity protection."

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
input long            InpMagic            = 772045;        // Magic number
input string          InpSymbols          = "AUDCAD,AUDCHF,AUDJPY,AUDNZD,AUDUSD,CADCHF,CADJPY,CHFJPY,EURAUD,EURCAD,EURCHF,EURGBP,EURJPY,EURNZD,EURUSD,GBPAUD,GBPCAD,GBPCHF,GBPJPY,GBPNZD,GBPUSD,NZDCAD,NZDCHF,NZDJPY,NZDUSD,USDCAD,USDCHF,USDJPY,XAUUSD,XAGUSD,USOIL,UKOIL,BTCUSD,ETHUSD"; // Symbol list (comma separated)
input string          InpSymbolSuffix     = "";             // Broker symbol suffix (e.g. ".a", "m")
input ENUM_TIMEFRAMES InpTimeframe        = PERIOD_D1;      // Working timeframe
input bool            InpVerboseLog       = false;          // Verbose logging (filters, sizing, modifies)
input bool            InpShowDashboard    = true;           // Show chart Comment() dashboard

input group "=== Signal: Donchian breakout + regime filter ==="
input int             InpEntryChannel     = 55;             // Entry channel period (bars)
input int             InpExitChannel      = 20;             // Exit channel period (bars)
input bool            InpUseChannelExit   = true;           // Use opposite-channel exit
input int             InpATRPeriod        = 20;             // ATR period
input bool            InpUseTrendFilter   = true;           // Use long-term EMA regime filter
input int             InpTrendEMA         = 200;            // Regime EMA period
input int             InpADXPeriod        = 14;             // ADX period
input double          InpADXMin           = 0.0;            // Minimum ADX (0 = filter disabled)
input bool            InpAllowLong        = true;           // Allow long trades
input bool            InpAllowShort       = true;           // Allow short trades

input group "=== Risk & money management ==="
input double          InpRiskPercent      = 0.5;            // Risk per trade, % of equity
input double          InpSL_ATR           = 3.0;            // Initial stop-loss distance (x ATR)
input double          InpTP_ATR           = 0.0;            // Take-profit distance (x ATR, 0 = none)
input double          InpTrail_ATR        = 4.0;            // Chandelier trailing stop (x ATR, 0 = off)
input double          InpBreakEvenTrigATR = 0.0;            // Break-even trigger (x ATR, 0 = off)
input double          InpBreakEvenLockATR = 0.2;            // Break-even lock-in (x ATR beyond entry)
input int             InpMaxPosPerSymbol  = 1;              // Max open positions per symbol
input int             InpMaxPosTotal      = 10;             // Max open positions across portfolio
input double          InpMaxPortfolioRisk = 4.0;            // Max total open risk, % of equity
input double          InpMinLotRiskFactor = 1.5;            // Max allowed risk overshoot at min lot (x intended)
input int             InpSlippagePoints   = 30;             // Max slippage / deviation (points)

input group "=== Equity protection ==="
input double          InpMaxDailyDD       = 3.0;            // Max daily drawdown % (0 = off)
input double          InpMaxWeeklyDD      = 5.0;            // Max weekly drawdown % (0 = off)
input double          InpMaxMonthlyDD     = 8.0;            // Max monthly drawdown % (0 = off)
input ENUM_DD_ACTION  InpDDAction         = DD_HALT_ONLY;   // Action on daily/weekly/monthly limit
input double          InpEmergencyDD      = 12.0;           // Emergency stop: % below equity peak (0 = off)
input bool            InpEmergencyPermanent = false;        // Emergency halt is permanent (false = resume next month)

input group "=== Filters ==="
input double          InpMaxSpreadATR     = 0.15;           // Max spread as fraction of ATR (0 = off)
input int             InpMaxSpreadPoints  = 0;              // Max absolute spread, points (0 = off)
input double          InpMinATRPct        = 0.10;           // Min ATR as % of price (volatility floor, 0 = off)
input double          InpMaxATRPct        = 0.0;            // Max ATR as % of price (0 = off)
input bool            InpUseSessionFilter = false;          // Restrict entries to session hours
input int             InpSessionStartHour = 0;              // Session start hour (server time)
input int             InpSessionEndHour   = 0;              // Session end hour (server time, = start means 24h)
input bool            InpTradeSunday      = false;          // Allow entries on Sunday (crypto)
input bool            InpTradeMonday      = true;           // Allow entries on Monday
input bool            InpTradeTuesday     = true;           // Allow entries on Tuesday
input bool            InpTradeWednesday   = true;           // Allow entries on Wednesday
input bool            InpTradeThursday    = true;           // Allow entries on Thursday
input bool            InpTradeFriday      = true;           // Allow entries on Friday
input bool            InpTradeSaturday    = false;          // Allow entries on Saturday (crypto)

input group "=== News filter (built-in calendar, live only) ==="
input bool            InpUseNewsFilter    = false;          // Block entries around high-impact news
input int             InpNewsBeforeMin    = 60;             // Blackout minutes before event
input int             InpNewsAfterMin     = 30;             // Blackout minutes after event

//+------------------------------------------------------------------+
//| Per-symbol state                                                 |
//+------------------------------------------------------------------+
struct SymState
  {
   string            name;          // broker symbol name (with suffix)
   bool              enabled;       // false if symbol unusable
   int               hATR;          // ATR indicator handle
   int               hEMA;          // EMA indicator handle (regime filter)
   int               hADX;          // ADX indicator handle
   datetime          lastBar;       // open time of last fully processed bar
  };

struct NewsItem
  {
   datetime          t;             // event time
   string            ccy;           // event currency
  };

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade    g_trade;
SymState  g_sym[];

double    g_peakEquity   = 0.0;     // all-time equity peak (for emergency stop)
double    g_dayPeak      = 0.0;     // intraday equity peak
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

//+------------------------------------------------------------------+
//| Logging helpers                                                  |
//+------------------------------------------------------------------+
void LogI(const string msg) { Print("[PTF] ", msg); }
void LogV(const string msg) { if(InpVerboseLog) Print("[PTF] ", msg); }

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- input sanity checks
   if(InpEntryChannel < 5 || InpExitChannel < 2)
     { LogI("Invalid channel periods (entry >= 5, exit >= 2 required)"); return INIT_PARAMETERS_INCORRECT; }
   if(InpATRPeriod < 2 || InpSL_ATR <= 0.0)
     { LogI("Invalid ATR period or SL multiplier"); return INIT_PARAMETERS_INCORRECT; }
   if(InpRiskPercent <= 0.0 || InpRiskPercent > 10.0)
     { LogI("Risk per trade must be in (0, 10] percent"); return INIT_PARAMETERS_INCORRECT; }
   if(InpMaxPosPerSymbol < 1 || InpMaxPosTotal < 1)
     { LogI("Position limits must be >= 1"); return INIT_PARAMETERS_INCORRECT; }
   if(InpSessionStartHour < 0 || InpSessionStartHour > 23 || InpSessionEndHour < 0 || InpSessionEndHour > 23)
     { LogI("Session hours must be 0..23"); return INIT_PARAMETERS_INCORRECT; }
   if(InpRiskPercent > 2.0)
      LogI("WARNING: risk per trade above 2% is aggressive for a portfolio system");

   //--- trade object
   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetDeviationInPoints((ulong)InpSlippagePoints);
   g_trade.SetMarginMode();            // adapt to netting / hedging account
   g_trade.SetAsyncMode(false);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   //--- symbol list
   if(!ParseSymbols())
     { LogI("No tradable symbols - check InpSymbols / InpSymbolSuffix"); return INIT_FAILED; }

   //--- equity guards
   double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
   g_peakEquity = eq;
   g_dayPeak    = eq;
   g_weekPeak   = eq;
   g_monthPeak  = eq;
   g_dayId = g_weekId = g_monthId = -1;   // forces re-anchor on first tick

   EventSetTimer(15);                     // safety net when chart symbol is quiet
   LogI(StringFormat("Initialized: %d symbols, timeframe %s, magic %I64d, risk %.2f%%/trade",
                     ArraySize(g_sym), EnumToString(InpTimeframe), InpMagic, InpRiskPercent));
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
      if(g_sym[i].hADX != INVALID_HANDLE) IndicatorRelease(g_sym[i].hADX);
     }
   Comment("");
  }

//+------------------------------------------------------------------+
//| Event entry points                                               |
//+------------------------------------------------------------------+
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
      g_sym[added].hATR    = iATR(s, InpTimeframe, InpATRPeriod);
      g_sym[added].hEMA    = (InpUseTrendFilter ? iMA(s, InpTimeframe, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE)
                                                : INVALID_HANDLE);
      g_sym[added].hADX    = (InpADXMin > 0.0   ? iADX(s, InpTimeframe, InpADXPeriod)
                                                : INVALID_HANDLE);
      if(g_sym[added].hATR == INVALID_HANDLE ||
         (InpUseTrendFilter && g_sym[added].hEMA == INVALID_HANDLE) ||
         (InpADXMin > 0.0   && g_sym[added].hADX == INVALID_HANDLE))
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
   int weekId  = (int)MathFloor(((double)(long)t - 345600.0) / 604800.0); // weeks aligned to Monday 00:00
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
      // optional emergency reset at month rollover: requires explicit re-anchor
      if(!firstCall && g_emergencyHalt && !InpEmergencyPermanent)
        {
         g_emergencyHalt = false;
         g_peakEquity    = eq;   // re-anchor, otherwise it would re-trigger instantly
         LogI("EMERGENCY halt lifted at month start - equity peak re-anchored");
        }
     }

   g_dayPeak    = MathMax(g_dayPeak, eq);
   g_weekPeak   = MathMax(g_weekPeak, eq);
   g_monthPeak  = MathMax(g_monthPeak, eq);
   g_peakEquity = MathMax(g_peakEquity, eq);

   //--- emergency stop (close everything, halt)
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

//+------------------------------------------------------------------+
//| Trip one period drawdown limit if breached                       |
//+------------------------------------------------------------------+
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
//| Per-symbol processing: act once per NEW bar, on closed-bar data  |
//+------------------------------------------------------------------+
void ProcessSymbol(const int i)
  {
   string   sym    = g_sym[i].name;
   datetime curBar = iTime(sym, InpTimeframe, 0);
   if(curBar <= 0) return;                 // no data yet (still synchronizing)
   if(curBar == g_sym[i].lastBar) return;  // bar already processed

   // ManagePositions/TryEnter return false only when history/indicator data
   // is not ready yet; in that case do NOT latch the bar, retry next call.
   if(!ManagePositions(i)) return;
   if(EntriesAllowed())
     {
      if(!TryEnter(i)) return;
     }
   g_sym[i].lastBar = curBar;
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
//| Entry logic (returns false only if data is not ready)            |
//+------------------------------------------------------------------+
bool TryEnter(const int i)
  {
   string sym = g_sym[i].name;

   //--- position limits
   if(CountPositions(sym)  >= InpMaxPosPerSymbol) return true;
   if(CountPositions(NULL) >= InpMaxPosTotal)
     { LogV(sym + ": max total positions reached - no entry"); return true; }

   //--- closed-bar rates: rates[0] = signal bar (shift 1),
   //    rates[1..EntryChannel] = the channel bars preceding it
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int need = InpEntryChannel + 1;
   if(CopyRates(sym, InpTimeframe, 1, need, rates) < need)
      return false;                              // history still loading

   double atr = 0.0, ema = 0.0, adx = 0.0;
   if(!GetValue(g_sym[i].hATR, atr) || atr <= 0.0)            return false;
   if(InpUseTrendFilter && !GetValue(g_sym[i].hEMA, ema))     return false;
   if(InpADXMin > 0.0   && !GetValue(g_sym[i].hADX, adx))     return false;

   double closed = rates[0].close;
   double hh = rates[1].high, ll = rates[1].low;
   for(int k = 2; k <= InpEntryChannel; k++)
     {
      hh = MathMax(hh, rates[k].high);
      ll = MathMin(ll, rates[k].low);
     }

   //--- volatility filter (ATR as % of price)
   double atrPct = 100.0 * atr / closed;
   if(InpMinATRPct > 0.0 && atrPct < InpMinATRPct)
     { LogV(StringFormat("%s: ATR %.3f%% below floor - no entry", sym, atrPct)); return true; }
   if(InpMaxATRPct > 0.0 && atrPct > InpMaxATRPct)
     { LogV(StringFormat("%s: ATR %.3f%% above cap - no entry", sym, atrPct)); return true; }

   //--- session / day-of-week filter (entries only)
   if(!SessionOK()) return true;

   //--- signal: close of last completed bar breaks the channel of the
   //    InpEntryChannel bars before it, in the direction of the regime
   bool longOK  = InpAllowLong  && closed > hh &&
                  (!InpUseTrendFilter || closed > ema) &&
                  (InpADXMin <= 0.0 || adx >= InpADXMin);
   bool shortOK = InpAllowShort && closed < ll &&
                  (!InpUseTrendFilter || closed < ema) &&
                  (InpADXMin <= 0.0 || adx >= InpADXMin);
   if(!longOK && !shortOK) return true;
   int dir = (longOK ? 1 : -1);

   //--- execution-quality filters
   if(!SpreadOK(sym, atr)) return true;
   if(InpUseNewsFilter && IsNewsBlackout(sym))
     { LogV(sym + ": high-impact news blackout - no entry"); return true; }

   OpenPosition(i, dir, atr);
   return true;
  }

//+------------------------------------------------------------------+
//| Open a position with ATR stop and fixed-fractional sizing        |
//+------------------------------------------------------------------+
void OpenPosition(const int i, const int dir, const double atr)
  {
   string sym = g_sym[i].name;

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     { LogV("Trading not allowed by terminal settings"); return; }

   MqlTick tick;
   if(!SymbolInfoTick(sym, tick) || tick.bid <= 0.0 || tick.ask <= 0.0)
     { LogV(sym + ": no current tick - entry skipped"); return; }

   double price  = (dir > 0 ? tick.ask : tick.bid);
   double slDist = InpSL_ATR * atr;
   double minDist = StopsMinDistance(sym);
   if(slDist < minDist) slDist = minDist;        // respect broker stop level

   //--- portfolio risk cap (sum of remaining open risk + this trade)
   double openRisk = PortfolioOpenRiskPct();
   if(InpMaxPortfolioRisk > 0.0 && openRisk + InpRiskPercent > InpMaxPortfolioRisk)
     {
      LogV(StringFormat("%s: portfolio risk %.2f%% + %.2f%% would exceed cap %.2f%% - no entry",
                        sym, openRisk, InpRiskPercent, InpMaxPortfolioRisk));
      return;
     }

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPercent / 100.0;
   ENUM_ORDER_TYPE otype = (dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double lots = CalcLots(sym, slDist, riskMoney, otype, price);
   if(lots <= 0.0) return;

   double sl = RoundPrice(sym, dir > 0 ? price - slDist : price + slDist);
   double tp = 0.0;
   if(InpTP_ATR > 0.0)
      tp = RoundPrice(sym, dir > 0 ? price + InpTP_ATR * atr : price - InpTP_ATR * atr);

   g_trade.SetTypeFilling(GetFilling(sym));
   bool sent = (dir > 0 ? g_trade.Buy(lots, sym, 0.0, sl, tp, "PTF breakout")
                        : g_trade.Sell(lots, sym, 0.0, sl, tp, "PTF breakout"));
   uint rc = g_trade.ResultRetcode();
   if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED))
     {
      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      LogI(StringFormat("%s %s %.2f lots @ %s, SL %s, TP %s (ATR %s, risk %.2f%%)",
                        dir > 0 ? "BUY" : "SELL", sym, lots,
                        DoubleToString(g_trade.ResultPrice(), digits),
                        DoubleToString(sl, digits),
                        tp > 0.0 ? DoubleToString(tp, digits) : "none",
                        DoubleToString(atr, digits), InpRiskPercent));
     }
   else
      LogI(StringFormat("OrderSend FAILED on %s: retcode=%u (%s)", sym, rc, g_trade.ResultRetcodeDescription()));
  }

//+------------------------------------------------------------------+
//| Position sizing: fixed-fractional risk over stop distance.       |
//| Handles tick value/size, lot step, min/max, volume limit and a   |
//| free-margin cap. Works for FX, JPY, metals, oil and crypto       |
//| because only symbol properties are used (no pip assumptions).    |
//+------------------------------------------------------------------+
double CalcLots(const string sym, const double slDist, const double riskMoney,
                const ENUM_ORDER_TYPE otype, const double price)
  {
   double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tickVal  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickVal <= 0.0) tickVal = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickVal <= 0.0 || slDist <= 0.0 || riskMoney <= 0.0)
     { LogV(sym + ": unusable tick size/value - entry skipped"); return 0.0; }

   double lossPerLot = slDist / tickSize * tickVal;   // account currency loss for 1 lot at SL
   if(lossPerLot <= 0.0) return 0.0;
   double lots = riskMoney / lossPerLot;

   double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) step = (minLot > 0.0 ? minLot : 0.01);

   lots = MathFloor(lots / step + 1e-9) * step;       // round DOWN to lot step

   if(lots < minLot)
     {
      // smallest size still risks more than intended: allow a limited
      // overshoot (InpMinLotRiskFactor), otherwise skip the trade
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

   //--- margin check: stay within 80% of free margin
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

   //--- normalize to the lot-step precision
   int stepDigits = 0;
   double s = step;
   while(s < 0.999 && stepDigits < 8) { s *= 10.0; stepDigits++; }
   return NormalizeDouble(lots, stepDigits);
  }

//+------------------------------------------------------------------+
//| Manage open positions of one symbol (closed-bar logic).          |
//| Returns false only when required data is not ready yet.          |
//+------------------------------------------------------------------+
bool ManagePositions(const int i)
  {
   string sym = g_sym[i].name;
   if(CountPositions(sym) == 0) return true;

   double atr = 0.0;
   if(!GetValue(g_sym[i].hATR, atr) || atr <= 0.0) return false;

   //--- Donchian exit channel of the bars preceding the last closed bar
   double exitHi = 0.0, exitLo = 0.0, lastClose = 0.0;
   if(InpUseChannelExit)
     {
      MqlRates r[];
      ArraySetAsSeries(r, true);
      int need = InpExitChannel + 1;
      if(CopyRates(sym, InpTimeframe, 1, need, r) < need) return false;
      lastClose = r[0].close;
      exitHi = r[1].high;
      exitLo = r[1].low;
      for(int k = 2; k <= InpExitChannel; k++)
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
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double   op    = PositionGetDouble(POSITION_PRICE_OPEN);
      double   sl    = PositionGetDouble(POSITION_SL);
      double   tp    = PositionGetDouble(POSITION_TP);
      datetime opent = (datetime)PositionGetInteger(POSITION_TIME);

      int shOpen = iBarShift(sym, InpTimeframe, opent);
      if(shOpen < 1) continue;              // entry bar not closed yet - no management

      //--- 1) opposite-channel exit on closed bar
      if(InpUseChannelExit)
        {
         bool exitNow = (type == POSITION_TYPE_BUY ? lastClose < exitLo : lastClose > exitHi);
         if(exitNow)
           {
            g_trade.SetTypeFilling(GetFilling(sym));
            if(g_trade.PositionClose(tk))
               LogI(StringFormat("%s #%I64u closed by %d-bar channel exit", sym, tk, InpExitChannel));
            else
               LogI(StringFormat("Channel-exit close FAILED %s #%I64u rc=%u", sym, tk, g_trade.ResultRetcode()));
            continue;
           }
        }

      //--- 2) break-even and 3) chandelier trailing: pick the best stop
      double newSL = sl;
      if(InpBreakEvenTrigATR > 0.0)
        {
         if(type == POSITION_TYPE_BUY && tick.bid - op >= InpBreakEvenTrigATR * atr)
            newSL = BetterSL(type, newSL, op + InpBreakEvenLockATR * atr);
         if(type == POSITION_TYPE_SELL && op - tick.ask >= InpBreakEvenTrigATR * atr)
            newSL = BetterSL(type, newSL, op - InpBreakEvenLockATR * atr);
        }
      if(InpTrail_ATR > 0.0)
        {
         if(type == POSITION_TYPE_BUY)
           {
            int idx = iHighest(sym, InpTimeframe, MODE_HIGH, shOpen, 1);
            double hh = (idx >= 0 ? iHigh(sym, InpTimeframe, idx) : 0.0);
            if(hh > 0.0) newSL = BetterSL(type, newSL, hh - InpTrail_ATR * atr);
           }
         else
           {
            int idx = iLowest(sym, InpTimeframe, MODE_LOW, shOpen, 1);
            double lo = (idx >= 0 ? iLow(sym, InpTimeframe, idx) : 0.0);
            if(lo > 0.0) newSL = BetterSL(type, newSL, lo + InpTrail_ATR * atr);
           }
        }

      //--- apply only a real improvement (>= half a tick)
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
//| Pick the tighter (better) protective stop for the direction      |
//+------------------------------------------------------------------+
double BetterSL(const ENUM_POSITION_TYPE type, const double cur, const double cand)
  {
   if(cand <= 0.0) return cur;
   if(cur  <= 0.0) return cand;
   return (type == POSITION_TYPE_BUY ? MathMax(cur, cand) : MathMin(cur, cand));
  }

//+------------------------------------------------------------------+
//| Modify the stop-loss if broker distance rules allow it           |
//+------------------------------------------------------------------+
void TryModifySL(const string sym, const ulong ticket, const ENUM_POSITION_TYPE type,
                 double newSL, const double tp, const MqlTick &tick)
  {
   double minDist = StopsMinDistance(sym);
   if(type == POSITION_TYPE_BUY  && newSL > tick.bid - minDist) return;  // too close to market
   if(type == POSITION_TYPE_SELL && newSL < tick.ask + minDist) return;
   newSL = RoundPrice(sym, newSL);
   if(!g_trade.PositionModify(ticket, newSL, tp))
      LogV(StringFormat("PositionModify failed %s #%I64u rc=%u", sym, ticket, g_trade.ResultRetcode()));
   else
      LogV(StringFormat("%s #%I64u SL moved to %s", sym, ticket,
                        DoubleToString(newSL, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS))));
  }

//+------------------------------------------------------------------+
//| Count open positions of this EA (sym = NULL -> whole portfolio)  |
//+------------------------------------------------------------------+
int CountPositions(const string sym)
  {
   int cnt = 0;
   for(int p = PositionsTotal() - 1; p >= 0; p--)
     {
      ulong tk = PositionGetTicket(p);
      if(tk == 0) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(sym != NULL && PositionGetString(POSITION_SYMBOL) != sym) continue;
      cnt++;
     }
   return cnt;
  }

//+------------------------------------------------------------------+
//| Remaining open risk of all EA positions, % of equity.            |
//| Stops at/beyond break-even count as zero remaining risk.         |
//+------------------------------------------------------------------+
double PortfolioOpenRiskPct()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq <= 0.0) return 0.0;
   double total = 0.0;
   for(int p = PositionsTotal() - 1; p >= 0; p--)
     {
      ulong tk = PositionGetTicket(p);
      if(tk == 0) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      string s   = PositionGetString(POSITION_SYMBOL);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double op  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl  = PositionGetDouble(POSITION_SL);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(sl <= 0.0) { total += InpRiskPercent; continue; }   // no SL: assume one full unit
      double dist = (type == POSITION_TYPE_BUY ? op - sl : sl - op);
      if(dist <= 0.0) continue;                              // SL beyond entry: risk locked out

      double tickSize = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_SIZE);
      double tickVal  = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tickVal <= 0.0) tickVal = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_VALUE);
      if(tickSize <= 0.0 || tickVal <= 0.0) { total += InpRiskPercent; continue; }

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
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
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
   if(InpSessionStartHour == InpSessionEndHour) return true;   // 24h

   int h = dt.hour;
   if(InpSessionStartHour < InpSessionEndHour)
      return (h >= InpSessionStartHour && h < InpSessionEndHour);
   return (h >= InpSessionStartHour || h < InpSessionEndHour); // overnight session
  }

//+------------------------------------------------------------------+
//| Spread filter: relative to ATR and/or absolute points            |
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
      if(point > 0.0 && spread > InpMaxSpreadPoints * point)
        { LogV(StringFormat("%s: spread %.1f points over absolute cap - no entry", sym, spread / point)); return false; }
     }
   if(InpMaxSpreadATR > 0.0 && atr > 0.0 && spread > InpMaxSpreadATR * atr)
     { LogV(StringFormat("%s: spread is %.1f%% of ATR (cap %.1f%%) - no entry", sym, 100.0 * spread / atr, 100.0 * InpMaxSpreadATR)); return false; }
   return true;
  }

//+------------------------------------------------------------------+
//| News filter using the built-in MQL5 economic calendar.           |
//| The calendar is NOT available in the Strategy Tester, so this    |
//| filter is automatically inactive in backtests (live/demo only).  |
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
   if(g_lastNewsFetch > 0 && now - g_lastNewsFetch < 900) return;   // refresh every 15 min
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

// minimum SL distance from current price: stop/freeze level + spread + pad
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
   string s = StringFormat("Portfolio Trend Follower  |  magic %I64d  |  %s\n", InpMagic, EnumToString(InpTimeframe));
   s += StringFormat("Equity %.2f  (peak %.2f)   Open positions %d/%d   Open risk %.2f%% (cap %.2f%%)\n",
                     eq, g_peakEquity, CountPositions(NULL), InpMaxPosTotal,
                     PortfolioOpenRiskPct(), InpMaxPortfolioRisk);
   s += StringFormat("Entry halts  -  day: %s   week: %s   month: %s   EMERGENCY: %s\n",
                     B2S(g_dayHalt), B2S(g_weekHalt), B2S(g_monthHalt), B2S(g_emergencyHalt));
   s += StringFormat("Symbols active: %d\n", ArraySize(g_sym));
   Comment(s);
  }
//+------------------------------------------------------------------+
