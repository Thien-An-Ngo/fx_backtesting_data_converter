//+------------------------------------------------------------------+
//|                                            NNFX_MultiSymbol.mq5 |
//|        No Nonsense Forex (NNFX) style multi-symbol algorithm     |
//|                                                                  |
//|  Implements the classic NNFX component-slot system on D1:        |
//|                                                                  |
//|    ATR(14)    - stop, target, sizing, "too far gone" rule        |
//|    BASELINE   - price side defines allowed direction; baseline   |
//|                 cross is also an entry trigger                   |
//|    C1         - primary confirmation: its flip IS the signal     |
//|    C2         - secondary confirmation: must agree (optional)    |
//|    VOLUME     - participation filter (ADX & friends, optional)   |
//|    EXIT       - C1 reverse / baseline cross / PSAR (optional)    |
//|                                                                  |
//|  Money management per NNFX:                                      |
//|    - SL = 1.5 x ATR, TP = 1.0 x ATR on HALF the position         |
//|    - runner half: breakeven once +1 ATR is reached, then a       |
//|      1.5 x ATR trail, plus indicator exits                       |
//|    - risk split across the two halves; one trade per pair        |
//|                                                                  |
//|  Every slot can be a NATIVE MT5 indicator (no downloads) or a    |
//|  CUSTOM indicator via iCustom (set the indicator file name and   |
//|  buffer indices; the indicator must be compiled in               |
//|  MQL5\Indicators and is used with its own default inputs).       |
//|                                                                  |
//|  All decisions are made on CLOSED bars (shift >= 1): no current- |
//|  candle logic, no lookahead. Pending-signal execution retries    |
//|  entries during the bar until spread/caps clear (rollover-safe). |
//|  No martingale, no grid, no averaging down; hard SL always set.  |
//|                                                                  |
//|  Attach to ONE chart (recommended EURUSD D1). The EA trades      |
//|  every symbol in InpSymbols.                                     |
//|                                                                  |
//|  v1.10: adds INTERNALLY COMPUTED NNFX community favourites -     |
//|  SSL Channel, Aroon, Vortex (C1/C2), Hull MA and McGinley        |
//|  Dynamic (baseline), Waddah Attar Explosion (volume). No         |
//|  downloads, no repainting. New defaults: McGinley(24) baseline,  |
//|  SSL(10) C1, Vortex(14) C2, WAE volume.                          |
//|                                                                  |
//|  v1.20: NNFX money management tightened - ONE trade per          |
//|  currency (VP's rule), max 4 concurrent trades, drawdown risk    |
//|  throttle (reduced risk while equity is below its peak, never    |
//|  increased - anti-martingale). Component speeds aligned into a   |
//|  ladder (fast SSL(10) trigger -> mid McGinley(30) baseline ->    |
//|  slow Aroon(30) regime gate) plus two chop filters: minimum      |
//|  baseline slope and maximum signal-bar range.                    |
//+------------------------------------------------------------------+
#property copyright   "2026"
#property link        "https://www.mql5.com"
#property version     "1.20"
#property description "NNFX-style component system: Baseline / C1 / C2 / Volume / Exit slots,"
#property description "ATR money management with split TP and runner trail, multi-symbol."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum ENUM_DD_ACTION
  {
   DD_HALT_ONLY = 0,   // Halt new entries only
   DD_CLOSE_ALL = 1    // Halt entries and close all positions
  };

enum ENUM_BASE_TYPE
  {
   BASE_EMA    = 0,    // EMA
   BASE_SMA    = 1,    // SMA
   BASE_KIJUN  = 2,    // Ichimoku Kijun-sen
   BASE_TEMA   = 3,    // TEMA
   BASE_DEMA   = 4,    // DEMA
   BASE_AMA    = 5,    // Kaufman AMA
   BASE_VIDYA  = 6,    // VIDYA
   BASE_FRAMA  = 7,    // FRAMA
   BASE_CUSTOM = 8,    // Custom indicator (iCustom)
   BASE_HMA    = 9,    // Hull MA (computed internally)
   BASE_MCGINLEY = 10  // McGinley Dynamic (computed internally)
  };

enum ENUM_CONF_TYPE
  {
   CONF_OFF          = 0,   // Disabled (allowed for C2 only)
   CONF_DMI          = 1,   // DMI: +DI vs -DI
   CONF_MACD_ZERO    = 2,   // MACD main vs zero
   CONF_AO_ZERO      = 3,   // Awesome Oscillator vs zero
   CONF_CCI_ZERO     = 4,   // CCI vs zero
   CONF_RSI_50       = 5,   // RSI vs 50
   CONF_STOCH_KD     = 6,   // Stochastic %K vs %D
   CONF_TRIX_ZERO    = 7,   // TRIX vs zero
   CONF_RVI_CROSS    = 8,   // RVI main vs signal
   CONF_DEMARKER_50  = 9,   // DeMarker vs 0.5
   CONF_CUSTOM_ZERO  = 10,  // Custom: buffer A vs zero
   CONF_CUSTOM_2LINE = 11,  // Custom: buffer A vs buffer B
   CONF_SSL          = 12,  // SSL Channel (computed internally)
   CONF_AROON        = 13,  // Aroon up/down (computed internally)
   CONF_VORTEX       = 14   // Vortex VI+/VI- (computed internally)
  };

enum ENUM_VOL_TYPE
  {
   VOL_OFF          = 0,    // Disabled
   VOL_ADX          = 1,    // ADX above threshold
   VOL_STDDEV_RISE  = 2,    // StdDev rising
   VOL_TICKVOL_MA   = 3,    // Tick volume above its average
   VOL_CUSTOM       = 4,    // Custom: buffer above threshold
   VOL_WAE          = 5     // Waddah Attar Explosion (computed internally)
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== General ==="
input long            InpMagic            = 772300;        // Magic base (TP-half = +0, runner = +1)
input string          InpSymbols          = "AUDCAD,AUDCHF,AUDJPY,AUDNZD,AUDUSD,CADCHF,CADJPY,CHFJPY,EURAUD,EURCAD,EURCHF,EURGBP,EURJPY,EURNZD,EURUSD,GBPAUD,GBPCAD,GBPCHF,GBPJPY,GBPNZD,GBPUSD,NZDCAD,NZDCHF,NZDJPY,NZDUSD,USDCAD,USDCHF,USDJPY"; // Symbol list (28 NNFX pairs)
input string          InpSymbolSuffix     = "";             // Broker symbol suffix (e.g. ".a", "m")
input ENUM_TIMEFRAMES InpTimeframe        = PERIOD_D1;      // Working timeframe (NNFX = D1)
input bool            InpVerboseLog       = false;          // Verbose logging
input bool            InpShowDashboard    = true;           // Show chart Comment() dashboard

input group "=== BASELINE slot ==="
input ENUM_BASE_TYPE  InpBaselineType     = BASE_MCGINLEY;  // Baseline indicator
input int             InpBaselinePeriod   = 30;             // Baseline period
input bool            InpUseBaselineEntry = true;           // Baseline cross is also an entry trigger
input double          InpMaxBaseDistATR   = 1.0;            // "Too far gone": max |close-baseline| in ATR (0=off)
input double          InpMinBaseSlopeATR  = 0.10;           // Chop filter: min baseline slope in ATR (0=off)
input int             InpBaseSlopeBars    = 3;              // Bars for the slope measurement
input double          InpMaxSignalBarATR  = 1.5;            // Chop filter: max signal-bar range in ATR (0=off)
input string          InpBaseCustomName   = "";             // Custom baseline: indicator file name
input int             InpBaseCustomBuffer = 0;              // Custom baseline: buffer index

input group "=== C1 slot (primary confirmation = the signal) ==="
input ENUM_CONF_TYPE  InpC1Type           = CONF_SSL;       // C1 indicator
input int             InpC1Period         = 10;             // C1 period (where applicable)
input string          InpC1CustomName     = "";             // C1 custom: indicator file name
input int             InpC1BufferA        = 0;              // C1 custom: buffer A
input int             InpC1BufferB        = 1;              // C1 custom: buffer B (2-line mode)

input group "=== C2 slot (secondary confirmation) ==="
input ENUM_CONF_TYPE  InpC2Type           = CONF_AROON;     // C2 indicator (CONF_OFF = disabled)
input int             InpC2Period         = 30;             // C2 period (where applicable)
input string          InpC2CustomName     = "";             // C2 custom: indicator file name
input int             InpC2BufferA        = 0;              // C2 custom: buffer A
input int             InpC2BufferB        = 1;              // C2 custom: buffer B (2-line mode)

input group "=== VOLUME slot ==="
input ENUM_VOL_TYPE   InpVolType          = VOL_WAE;        // Volume/participation filter
input int             InpVolPeriod        = 14;             // Volume indicator period
input double          InpADXThreshold     = 20.0;           // ADX minimum (VOL_ADX)
input string          InpVolCustomName    = "";             // Volume custom: indicator file name
input int             InpVolCustomBuffer  = 0;              // Volume custom: buffer index
input double          InpVolCustomThresh  = 0.0;            // Volume custom: minimum value
input int             InpWAE_MacdFast     = 20;             // WAE: fast EMA period
input int             InpWAE_MacdSlow     = 40;             // WAE: slow EMA period
input int             InpWAE_BBPeriod     = 20;             // WAE: Bollinger period
input double          InpWAE_BBDev        = 2.0;            // WAE: Bollinger deviation
input double          InpWAE_Sensitivity  = 150.0;          // WAE: sensitivity

input group "=== EXIT rules ==="
input bool            InpExitOnC1Reverse  = true;           // Exit when C1 crosses against the position
input bool            InpExitOnBaseCross  = true;           // Exit when close crosses baseline against position
input bool            InpUseSARExit       = false;          // Exit on Parabolic SAR flip
input double          InpSARStep          = 0.02;           // SAR step
input double          InpSARMax           = 0.2;            // SAR maximum

input group "=== Money management (NNFX) ==="
input double          InpRiskPercent      = 1.0;            // Total risk per trade, % (split over 2 halves)
input double          InpDDThrottlePct    = 5.0;            // Throttle: equity this % below peak (0 = off)
input double          InpDDThrottleFactor = 0.5;            // Throttle: risk multiplier while in drawdown
input int             InpATRPeriod        = 14;             // ATR period
input double          InpSL_ATR           = 1.5;            // Stop-loss (x ATR)
input double          InpTP_ATR           = 1.0;            // Take-profit on half (x ATR) + breakeven trigger
input double          InpTrail_ATR        = 1.5;            // Runner trail after breakeven (x ATR, 0 = off)
input bool            InpUseSplitTP       = true;           // Two halves (TP half + runner). false = single runner
input double          InpMinLotRiskFactor = 1.5;            // Max risk overshoot at min lot (x intended)
input int             InpSlippagePoints   = 30;             // Max slippage / deviation (points)
input int             InpSignalTTLMin     = 240;            // Pending signal lifetime within its bar, minutes

input group "=== Portfolio limits ==="
input int             InpMaxTradesTotal   = 4;              // Max symbols in a trade at once (NNFX: 4)
input int             InpMaxPerCurrency   = 1;              // Max traded symbols per currency (NNFX rule: 1)
input double          InpMaxPortfolioRisk = 6.0;            // Max total open risk, % of equity

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
input bool            InpUseSessionFilter = false;          // Restrict entries to session hours
input int             InpSessionStartHour = 0;              // Session start hour (server time)
input int             InpSessionEndHour   = 0;              // Session end hour (= start means 24h)
input bool            InpTradeSunday      = false;          // Entries on Sunday
input bool            InpTradeMonday      = true;           // Entries on Monday
input bool            InpTradeTuesday     = true;           // Entries on Tuesday
input bool            InpTradeWednesday   = true;           // Entries on Wednesday
input bool            InpTradeThursday    = true;           // Entries on Thursday
input bool            InpTradeFriday      = true;           // Entries on Friday
input bool            InpTradeSaturday    = false;          // Entries on Saturday

input group "=== News filter (built-in calendar, live only; NNFX: 24h) ==="
input bool            InpUseNewsFilter    = false;          // Block entries around high-impact news
input int             InpNewsBeforeMin    = 1440;           // Blackout minutes before event
input int             InpNewsAfterMin     = 60;              // Blackout minutes after event

//+------------------------------------------------------------------+
//| Structures                                                       |
//+------------------------------------------------------------------+
struct Pending
  {
   bool              active;
   int               dir;           // +1 long, -1 short
   double            atr;           // ATR at signal time
   datetime          barTime;       // bar the signal belongs to
   datetime          since;
  };

struct SymState
  {
   string            name;
   bool              enabled;
   int               hATR;
   int               hBase;
   int               hC1;
   int               hC2;
   int               hVol;          // ADX / StdDev / custom (TICKVOL uses rates)
   int               hVol2;         // WAE second handle (Bollinger Bands)
   int               hSAR;
   datetime          lastBar;
   Pending           pend;
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

long MagicA() { return InpMagic;     }   // TP half
long MagicB() { return InpMagic + 1; }   // runner half
bool IsOurMagic(const long m) { return (m == InpMagic || m == InpMagic + 1); }

void LogI(const string msg) { Print("[NNFX] ", msg); }
void LogV(const string msg) { if(InpVerboseLog) Print("[NNFX] ", msg); }

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpC1Type == CONF_OFF)
     { LogI("C1 cannot be CONF_OFF - it generates the signal"); return INIT_PARAMETERS_INCORRECT; }
   if((InpC1Type == CONF_CUSTOM_ZERO || InpC1Type == CONF_CUSTOM_2LINE) && InpC1CustomName == "")
     { LogI("C1 custom selected but no indicator name set"); return INIT_PARAMETERS_INCORRECT; }
   if((InpC2Type == CONF_CUSTOM_ZERO || InpC2Type == CONF_CUSTOM_2LINE) && InpC2CustomName == "")
     { LogI("C2 custom selected but no indicator name set"); return INIT_PARAMETERS_INCORRECT; }
   if(InpBaselineType == BASE_CUSTOM && InpBaseCustomName == "")
     { LogI("Custom baseline selected but no indicator name set"); return INIT_PARAMETERS_INCORRECT; }
   if(InpVolType == VOL_CUSTOM && InpVolCustomName == "")
     { LogI("Custom volume selected but no indicator name set"); return INIT_PARAMETERS_INCORRECT; }
   if(InpBaselinePeriod < 1 || InpC1Period < 1 || InpC2Period < 1 || InpVolPeriod < 1 || InpATRPeriod < 2)
     { LogI("Invalid indicator periods"); return INIT_PARAMETERS_INCORRECT; }
   if(InpRiskPercent <= 0.0 || InpRiskPercent > 5.0)
     { LogI("Risk per trade must be in (0, 5] percent"); return INIT_PARAMETERS_INCORRECT; }
   if(InpSL_ATR <= 0.0 || InpTP_ATR < 0.0)
     { LogI("Invalid SL/TP multipliers"); return INIT_PARAMETERS_INCORRECT; }
   if(InpSessionStartHour < 0 || InpSessionStartHour > 23 || InpSessionEndHour < 0 || InpSessionEndHour > 23)
     { LogI("Session hours must be 0..23"); return INIT_PARAMETERS_INCORRECT; }

   g_isNetting = ((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)
                  != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   if(g_isNetting && InpUseSplitTP)
      LogI("Netting account: split halves would merge - trading a SINGLE runner per signal instead");

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
   LogI(StringFormat("Initialized: %d symbols on %s | baseline %s(%d) C1 %s C2 %s vol %s",
                     ArraySize(g_sym), EnumToString(InpTimeframe),
                     EnumToString(InpBaselineType), InpBaselinePeriod,
                     EnumToString(InpC1Type), EnumToString(InpC2Type), EnumToString(InpVolType)));
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
      if(g_sym[i].hATR  != INVALID_HANDLE) IndicatorRelease(g_sym[i].hATR);
      if(g_sym[i].hBase != INVALID_HANDLE) IndicatorRelease(g_sym[i].hBase);
      if(g_sym[i].hC1   != INVALID_HANDLE) IndicatorRelease(g_sym[i].hC1);
      if(g_sym[i].hC2   != INVALID_HANDLE) IndicatorRelease(g_sym[i].hC2);
      if(g_sym[i].hVol  != INVALID_HANDLE) IndicatorRelease(g_sym[i].hVol);
      if(g_sym[i].hVol2 != INVALID_HANDLE) IndicatorRelease(g_sym[i].hVol2);
      if(g_sym[i].hSAR  != INVALID_HANDLE) IndicatorRelease(g_sym[i].hSAR);
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
//| Indicator handle creation per slot                               |
//+------------------------------------------------------------------+
int MakeBaselineHandle(const string s)
  {
   switch(InpBaselineType)
     {
      case BASE_EMA:    return iMA(s, InpTimeframe, InpBaselinePeriod, 0, MODE_EMA, PRICE_CLOSE);
      case BASE_SMA:    return iMA(s, InpTimeframe, InpBaselinePeriod, 0, MODE_SMA, PRICE_CLOSE);
      case BASE_KIJUN:  return iIchimoku(s, InpTimeframe, 9, InpBaselinePeriod, 52);
      case BASE_TEMA:   return iTEMA(s, InpTimeframe, InpBaselinePeriod, 0, PRICE_CLOSE);
      case BASE_DEMA:   return iDEMA(s, InpTimeframe, InpBaselinePeriod, 0, PRICE_CLOSE);
      case BASE_AMA:    return iAMA(s, InpTimeframe, InpBaselinePeriod, 2, 30, 0, PRICE_CLOSE);
      case BASE_VIDYA:  return iVIDyA(s, InpTimeframe, 9, InpBaselinePeriod, 0, PRICE_CLOSE);
      case BASE_FRAMA:  return iFrAMA(s, InpTimeframe, InpBaselinePeriod, 0, PRICE_CLOSE);
      case BASE_CUSTOM: return iCustom(s, InpTimeframe, InpBaseCustomName);
      case BASE_HMA:
      case BASE_MCGINLEY: return INVALID_HANDLE;   // computed internally, no handle
     }
   return INVALID_HANDLE;
  }

bool BaseNeedsHandle()
  {
   return (InpBaselineType != BASE_HMA && InpBaselineType != BASE_MCGINLEY);
  }

bool ConfNeedsHandle(const ENUM_CONF_TYPE t)
  {
   return (t != CONF_OFF && t != CONF_SSL && t != CONF_AROON && t != CONF_VORTEX);
  }

int MakeConfHandle(const string s, const ENUM_CONF_TYPE t, const int period, const string customName)
  {
   switch(t)
     {
      case CONF_OFF:          return INVALID_HANDLE;
      case CONF_DMI:          return iADX(s, InpTimeframe, period);
      case CONF_MACD_ZERO:    return iMACD(s, InpTimeframe, 12, 26, 9, PRICE_CLOSE);
      case CONF_AO_ZERO:      return iAO(s, InpTimeframe);
      case CONF_CCI_ZERO:     return iCCI(s, InpTimeframe, period, PRICE_TYPICAL);
      case CONF_RSI_50:       return iRSI(s, InpTimeframe, period, PRICE_CLOSE);
      case CONF_STOCH_KD:     return iStochastic(s, InpTimeframe, period, 3, 3, MODE_SMA, STO_LOWHIGH);
      case CONF_TRIX_ZERO:    return iTriX(s, InpTimeframe, period, PRICE_CLOSE);
      case CONF_RVI_CROSS:    return iRVI(s, InpTimeframe, period);
      case CONF_DEMARKER_50:  return iDeMarker(s, InpTimeframe, period);
      case CONF_CUSTOM_ZERO:
      case CONF_CUSTOM_2LINE: return iCustom(s, InpTimeframe, customName);
      case CONF_SSL:
      case CONF_AROON:
      case CONF_VORTEX:       return INVALID_HANDLE;   // computed internally
     }
   return INVALID_HANDLE;
  }

int MakeVolHandle(const string s)
  {
   switch(InpVolType)
     {
      case VOL_OFF:         return INVALID_HANDLE;
      case VOL_ADX:         return iADX(s, InpTimeframe, InpVolPeriod);
      case VOL_STDDEV_RISE: return iStdDev(s, InpTimeframe, InpVolPeriod, 0, MODE_SMA, PRICE_CLOSE);
      case VOL_TICKVOL_MA:  return INVALID_HANDLE;   // computed from rates directly
      case VOL_CUSTOM:      return iCustom(s, InpTimeframe, InpVolCustomName);
      case VOL_WAE:         return iMACD(s, InpTimeframe, InpWAE_MacdFast, InpWAE_MacdSlow, 9, PRICE_CLOSE);
     }
   return INVALID_HANDLE;
  }

//+------------------------------------------------------------------+
//| Parse and validate the symbol list, create all slot handles      |
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
      g_sym[added].name        = s;
      g_sym[added].enabled     = true;
      g_sym[added].lastBar     = 0;
      g_sym[added].pend.active = false;
      g_sym[added].hATR  = iATR(s, InpTimeframe, InpATRPeriod);
      g_sym[added].hBase = MakeBaselineHandle(s);
      g_sym[added].hC1   = MakeConfHandle(s, InpC1Type, InpC1Period, InpC1CustomName);
      g_sym[added].hC2   = MakeConfHandle(s, InpC2Type, InpC2Period, InpC2CustomName);
      g_sym[added].hVol  = MakeVolHandle(s);
      g_sym[added].hVol2 = (InpVolType == VOL_WAE
                            ? iBands(s, InpTimeframe, InpWAE_BBPeriod, 0, InpWAE_BBDev, PRICE_CLOSE)
                            : INVALID_HANDLE);
      g_sym[added].hSAR  = (InpUseSARExit ? iSAR(s, InpTimeframe, InpSARStep, InpSARMax) : INVALID_HANDLE);

      bool volNeedsHandle = (InpVolType == VOL_ADX || InpVolType == VOL_STDDEV_RISE || InpVolType == VOL_CUSTOM);
      bool bad = (g_sym[added].hATR == INVALID_HANDLE ||
                  (BaseNeedsHandle() && g_sym[added].hBase == INVALID_HANDLE) ||
                  (ConfNeedsHandle(InpC1Type) && g_sym[added].hC1 == INVALID_HANDLE) ||
                  (ConfNeedsHandle(InpC2Type) && g_sym[added].hC2 == INVALID_HANDLE) ||
                  (volNeedsHandle && g_sym[added].hVol == INVALID_HANDLE) ||
                  (InpVolType == VOL_WAE && (g_sym[added].hVol == INVALID_HANDLE || g_sym[added].hVol2 == INVALID_HANDLE)) ||
                  (InpUseSARExit && g_sym[added].hSAR == INVALID_HANDLE));
      if(bad)
        {
         LogI(StringFormat("Indicator handle creation failed for '%s' - symbol disabled (check custom names)", s));
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
         g_peakEquity    = eq;
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

   if(curBar != g_sym[i].lastBar)
     {
      if(!ManageOpen(i))   return;          // data not ready -> retry, don't latch
      if(!ComputeSignal(i, curBar)) return;
      g_sym[i].lastBar = curBar;
     }
   ExecutePending(i);
  }

//+------------------------------------------------------------------+
//| Buffer access on closed bars                                     |
//+------------------------------------------------------------------+
bool GetBuf(const int handle, const int buffer, const int shift, double &val)
  {
   if(handle == INVALID_HANDLE) return false;
   double b[1];
   if(CopyBuffer(handle, buffer, shift, 1, b) != 1) return false;
   if(b[0] == EMPTY_VALUE) return false;
   val = b[0];
   return true;
  }

//+------------------------------------------------------------------+
//| Internally computed NNFX community indicators (closed bars only) |
//+------------------------------------------------------------------+
// linearly weighted MA over arr[start..start+period-1] (series array)
double LWMAAt(const double &arr[], const int start, const int period)
  {
   double num = 0.0, den = 0.0;
   for(int k = 0; k < period; k++)
     {
      double w = period - k;
      num += arr[start + k] * w;
      den += w;
     }
   return (den > 0.0 ? num / den : 0.0);
  }

// Hull Moving Average at shift
bool HMAValue(const string sym, const int period, const int shift, double &val)
  {
   int half = MathMax(1, period / 2);
   int sq   = (int)MathMax(1.0, MathRound(MathSqrt((double)period)));
   int need = shift + period + sq + 2;
   double c[];
   ArraySetAsSeries(c, true);
   if(CopyClose(sym, InpTimeframe, 0, need, c) < need) return false;
   double diff[];
   ArrayResize(diff, sq);
   for(int j = 0; j < sq; j++)
      diff[j] = 2.0 * LWMAAt(c, shift + j, half) - LWMAAt(c, shift + j, period);
   double num = 0.0, den = 0.0;
   for(int k = 0; k < sq; k++)
     {
      double w = sq - k;
      num += diff[k] * w;
      den += w;
     }
   if(den <= 0.0) return false;
   val = num / den;
   return (val > 0.0);
  }

// McGinley Dynamic at shift (seeded with an SMA far back, iterated forward)
bool McGinleyValue(const string sym, const int period, const int shift, double &val)
  {
   int hist = shift + period * 6 + 10;
   double c[];
   ArraySetAsSeries(c, true);
   int got = CopyClose(sym, InpTimeframe, 0, hist, c);
   if(got < shift + period + 10) return false;
   double md = 0.0;
   for(int k = got - period; k < got; k++) md += c[k];
   md /= period;
   for(int k = got - period - 1; k >= shift; k--)
     {
      if(md <= 0.0 || c[k] <= 0.0) return false;
      double ratio = c[k] / md;
      double denom = 0.6 * period * ratio * ratio * ratio * ratio;
      if(denom < 1e-10) denom = 1e-10;
      md += (c[k] - md) / denom;
     }
   val = md;
   return (val > 0.0);
  }

// SSL Channel direction at shift: +1 long side, -1 short side
bool SSLDir(const string sym, const int period, const int shift, int &dir)
  {
   int seed = 150;                        // bars to settle the recursive Hlv state
   double hi[], lo[], cl[];
   ArraySetAsSeries(hi, true);
   ArraySetAsSeries(lo, true);
   ArraySetAsSeries(cl, true);
   int need = shift + seed + period + 2;
   int g1 = CopyHigh(sym, InpTimeframe, 0, need, hi);
   int g2 = CopyLow(sym, InpTimeframe, 0, need, lo);
   int g3 = CopyClose(sym, InpTimeframe, 0, need, cl);
   int got = MathMin(g1, MathMin(g2, g3));
   if(got < shift + period + 5) return false;
   int start = got - period - 1;          // oldest evaluable bar
   int hlv = 0;
   for(int b = start; b >= shift; b--)
     {
      double smaH = 0.0, smaL = 0.0;
      for(int k = 0; k < period; k++)
        {
         smaH += hi[b + k];
         smaL += lo[b + k];
        }
      smaH /= period;
      smaL /= period;
      if(cl[b] > smaH) hlv = 1;
      else if(cl[b] < smaL) hlv = -1;     // otherwise keep previous state
     }
   dir = hlv;
   return true;
  }

// Aroon direction at shift
bool AroonDir(const string sym, const int period, const int shift, int &dir)
  {
   double hi[], lo[];
   ArraySetAsSeries(hi, true);
   ArraySetAsSeries(lo, true);
   int need = shift + period + 2;
   if(CopyHigh(sym, InpTimeframe, 0, need, hi) < need) return false;
   if(CopyLow(sym, InpTimeframe, 0, need, lo) < need) return false;
   int hIdx = shift, lIdx = shift;
   for(int k = shift; k <= shift + period; k++)
     {
      if(hi[k] > hi[hIdx]) hIdx = k;
      if(lo[k] < lo[lIdx]) lIdx = k;
     }
   double up   = 100.0 * (period - (hIdx - shift)) / period;
   double down = 100.0 * (period - (lIdx - shift)) / period;
   dir = (up > down ? 1 : (up < down ? -1 : 0));
   return true;
  }

// Vortex direction at shift: VI+ vs VI-
bool VortexDir(const string sym, const int period, const int shift, int &dir)
  {
   double hi[], lo[], cl[];
   ArraySetAsSeries(hi, true);
   ArraySetAsSeries(lo, true);
   ArraySetAsSeries(cl, true);
   int need = shift + period + 2;
   if(CopyHigh(sym, InpTimeframe, 0, need, hi) < need) return false;
   if(CopyLow(sym, InpTimeframe, 0, need, lo) < need) return false;
   if(CopyClose(sym, InpTimeframe, 0, need, cl) < need) return false;
   double vip = 0.0, vim = 0.0, tr = 0.0;
   for(int b = shift; b < shift + period; b++)
     {
      vip += MathAbs(hi[b] - lo[b + 1]);
      vim += MathAbs(lo[b] - hi[b + 1]);
      tr  += MathMax(hi[b] - lo[b], MathMax(MathAbs(hi[b] - cl[b + 1]), MathAbs(lo[b] - cl[b + 1])));
     }
   if(tr <= 0.0) return false;
   dir = (vip > vim ? 1 : (vip < vim ? -1 : 0));
   return true;
  }

//+------------------------------------------------------------------+
//| Baseline value at shift                                          |
//+------------------------------------------------------------------+
bool BaselineVal(const int i, const int shift, double &val)
  {
   if(InpBaselineType == BASE_HMA)
      return HMAValue(g_sym[i].name, InpBaselinePeriod, shift, val);
   if(InpBaselineType == BASE_MCGINLEY)
      return McGinleyValue(g_sym[i].name, InpBaselinePeriod, shift, val);
   int buffer = 0;
   if(InpBaselineType == BASE_KIJUN)  buffer = 1;                    // KIJUNSEN line
   if(InpBaselineType == BASE_CUSTOM) buffer = InpBaseCustomBuffer;
   return GetBuf(g_sym[i].hBase, buffer, shift, val);
  }

//+------------------------------------------------------------------+
//| Confirmation direction at shift: +1 / -1 / 0                     |
//+------------------------------------------------------------------+
bool ConfDir(const int handle, const ENUM_CONF_TYPE t, const int bufA, const int bufB,
             const int shift, int &dir)
  {
   dir = 0;
   double a = 0.0, b = 0.0;
   switch(t)
     {
      case CONF_DMI:
         if(!GetBuf(handle, 1, shift, a) || !GetBuf(handle, 2, shift, b)) return false;
         break;
      case CONF_MACD_ZERO:
      case CONF_AO_ZERO:
      case CONF_CCI_ZERO:
      case CONF_TRIX_ZERO:
         if(!GetBuf(handle, 0, shift, a)) return false;
         b = 0.0;
         break;
      case CONF_RSI_50:
         if(!GetBuf(handle, 0, shift, a)) return false;
         b = 50.0;
         break;
      case CONF_DEMARKER_50:
         if(!GetBuf(handle, 0, shift, a)) return false;
         b = 0.5;
         break;
      case CONF_STOCH_KD:
      case CONF_RVI_CROSS:
         if(!GetBuf(handle, 0, shift, a) || !GetBuf(handle, 1, shift, b)) return false;
         break;
      case CONF_CUSTOM_ZERO:
         if(!GetBuf(handle, bufA, shift, a)) return false;
         b = 0.0;
         break;
      case CONF_CUSTOM_2LINE:
         if(!GetBuf(handle, bufA, shift, a) || !GetBuf(handle, bufB, shift, b)) return false;
         break;
      default:
         return false;
     }
   if(a > b) dir = 1;
   else if(a < b) dir = -1;
   return true;
  }

//+------------------------------------------------------------------+
//| Confirmation direction for slot C1/C2 at shift (any type)        |
//+------------------------------------------------------------------+
bool ConfDirAt(const int i, const bool isC1, const int shift, int &dir)
  {
   ENUM_CONF_TYPE t = (isC1 ? InpC1Type : InpC2Type);
   int    period = (isC1 ? InpC1Period  : InpC2Period);
   int    handle = (isC1 ? g_sym[i].hC1 : g_sym[i].hC2);
   int    bufA   = (isC1 ? InpC1BufferA : InpC2BufferA);
   int    bufB   = (isC1 ? InpC1BufferB : InpC2BufferB);
   string sym    = g_sym[i].name;
   switch(t)
     {
      case CONF_SSL:    return SSLDir(sym, period, shift, dir);
      case CONF_AROON:  return AroonDir(sym, period, shift, dir);
      case CONF_VORTEX: return VortexDir(sym, period, shift, dir);
      default:          return ConfDir(handle, t, bufA, bufB, shift, dir);
     }
  }

//+------------------------------------------------------------------+
//| Volume/participation filter at shift 1 (dir used by WAE)         |
//| Returns: 1 pass, 0 fail, -1 data not ready                       |
//+------------------------------------------------------------------+
int VolumePass(const int i, const int dir)
  {
   string sym = g_sym[i].name;
   double a = 0.0, b = 0.0;
   switch(InpVolType)
     {
      case VOL_OFF:
         return 1;
      case VOL_ADX:
         if(!GetBuf(g_sym[i].hVol, 0, 1, a)) return -1;
         return (a >= InpADXThreshold ? 1 : 0);
      case VOL_STDDEV_RISE:
         if(!GetBuf(g_sym[i].hVol, 0, 1, a) || !GetBuf(g_sym[i].hVol, 0, 2, b)) return -1;
         return (a > b ? 1 : 0);
      case VOL_TICKVOL_MA:
        {
         MqlRates r[];
         ArraySetAsSeries(r, true);
         int need = InpVolPeriod + 1;
         if(CopyRates(sym, InpTimeframe, 1, need, r) < need) return -1;
         double avg = 0.0;
         for(int k = 1; k <= InpVolPeriod; k++) avg += (double)r[k].tick_volume;
         avg /= InpVolPeriod;
         return ((double)r[0].tick_volume > avg ? 1 : 0);
        }
      case VOL_CUSTOM:
         if(!GetBuf(g_sym[i].hVol, InpVolCustomBuffer, 1, a)) return -1;
         return (a >= InpVolCustomThresh ? 1 : 0);
      case VOL_WAE:
        {
         // Waddah Attar Explosion: MACD impulse vs Bollinger band width
         double m1 = 0.0, m2 = 0.0, bu = 0.0, bl = 0.0;
         if(!GetBuf(g_sym[i].hVol, 0, 1, m1) || !GetBuf(g_sym[i].hVol, 0, 2, m2)) return -1;
         if(!GetBuf(g_sym[i].hVol2, 1, 1, bu) || !GetBuf(g_sym[i].hVol2, 2, 1, bl)) return -1;
         double t1 = (m1 - m2) * InpWAE_Sensitivity;   // trend impulse
         double e1 = bu - bl;                          // explosion line
         if(dir > 0 && t1 <= 0.0) return 0;            // impulse must match direction
         if(dir < 0 && t1 >= 0.0) return 0;
         return (MathAbs(t1) > e1 ? 1 : 0);
        }
     }
   return 0;
  }

//+------------------------------------------------------------------+
//| NNFX entry signal on closed bars.                                |
//| Signal = C1 cross (with price on right side of baseline) OR      |
//| baseline cross (with C1 agreeing). Then: C2 agrees, volume       |
//| passes, price not "too far gone" from baseline.                  |
//| Returns false only when data is not ready (retry next call).     |
//+------------------------------------------------------------------+
bool ComputeSignal(const int i, const datetime curBar)
  {
   string sym = g_sym[i].name;
   g_sym[i].pend.active = false;                 // new bar invalidates old signal

   if(CountPositions(sym, 0) > 0) return true;   // one trade per pair

   double atr = 0.0;
   if(!GetBuf(g_sym[i].hATR, 0, 1, atr) || atr <= 0.0) return false;

   double base1 = 0.0, base2 = 0.0;
   if(!BaselineVal(i, 1, base1) || !BaselineVal(i, 2, base2)) return false;

   int c1d1 = 0, c1d2 = 0;
   if(!ConfDirAt(i, true, 1, c1d1)) return false;
   if(!ConfDirAt(i, true, 2, c1d2)) return false;

   int c2d1 = 0;
   if(InpC2Type != CONF_OFF)
      if(!ConfDirAt(i, false, 1, c2d1)) return false;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(sym, InpTimeframe, 1, 2, r) < 2) return false;
   double close1 = r[0].close, close2 = r[1].close;
   if(close1 <= 0.0 || close2 <= 0.0) return false;

   //--- volatility floor
   if(InpMinATRPct > 0.0 && 100.0 * atr / close1 < InpMinATRPct) return true;

   int side1 = (close1 > base1 ? 1 : (close1 < base1 ? -1 : 0));
   int side2 = (close2 > base2 ? 1 : (close2 < base2 ? -1 : 0));

   for(int dir = 1; dir >= -1; dir -= 2)
     {
      bool c1Cross   = (c1d1 == dir && c1d2 != dir);
      bool baseCross = InpUseBaselineEntry && (side1 == dir && side2 != dir);
      bool trigger   = (c1Cross && side1 == dir) || (baseCross && c1d1 == dir);
      if(!trigger) continue;
      if(InpC2Type != CONF_OFF && c2d1 != dir)
        { LogV(sym + ": C2 disagrees - no entry"); continue; }
      int volPass = VolumePass(i, dir);
      if(volPass < 0) return false;
      if(volPass == 0)
        { LogV(sym + ": volume filter failed - no entry"); continue; }
      if(InpMaxBaseDistATR > 0.0 && MathAbs(close1 - base1) > InpMaxBaseDistATR * atr)
        { LogV(sym + ": too far gone from baseline - no entry"); continue; }
      if(InpMaxSignalBarATR > 0.0 && (r[0].high - r[0].low) > InpMaxSignalBarATR * atr)
        { LogV(sym + ": signal bar too large (exhaustion) - no entry"); continue; }
      if(InpMinBaseSlopeATR > 0.0)
        {
         double baseOld = 0.0;
         if(!BaselineVal(i, 1 + InpBaseSlopeBars, baseOld)) return false;
         double slope = base1 - baseOld;
         bool flat = (dir > 0 ? slope <  InpMinBaseSlopeATR * atr
                              : slope > -InpMinBaseSlopeATR * atr);
         if(flat)
           { LogV(sym + ": baseline too flat (chop) - no entry"); continue; }
        }

      g_sym[i].pend.active  = true;
      g_sym[i].pend.dir     = dir;
      g_sym[i].pend.atr     = atr;
      g_sym[i].pend.barTime = curBar;
      g_sym[i].pend.since   = TimeCurrent();
      LogV(StringFormat("%s: NNFX %s signal pending (%s)", sym, dir > 0 ? "LONG" : "SHORT",
                        c1Cross ? "C1 cross" : "baseline cross"));
      break;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Try to execute the pending signal                                |
//+------------------------------------------------------------------+
void ExecutePending(const int i)
  {
   Pending p = g_sym[i].pend;
   if(!p.active) return;
   string sym = g_sym[i].name;

   if(iTime(sym, InpTimeframe, 0) != p.barTime) { g_sym[i].pend.active = false; return; }
   if(InpSignalTTLMin > 0 && (long)(TimeCurrent() - p.since) > (long)InpSignalTTLMin * 60)
     { g_sym[i].pend.active = false; return; }

   if(!EntriesAllowed()) return;
   if(!SessionOK())      return;
   if(CountPositions(sym, 0) > 0) { g_sym[i].pend.active = false; return; }
   if(CountEngagedSymbols() >= InpMaxTradesTotal) return;

   if(InpMaxPerCurrency > 0)
     {
      string bccy = SymbolInfoString(sym, SYMBOL_CURRENCY_BASE);
      string qccy = SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT);
      if(CurrencySymbolExposure(bccy) >= InpMaxPerCurrency ||
         CurrencySymbolExposure(qccy) >= InpMaxPerCurrency)
        { LogV(sym + ": currency exposure cap - waiting"); return; }
     }
   if(InpMaxPortfolioRisk > 0.0 && PortfolioOpenRiskPct() + InpRiskPercent > InpMaxPortfolioRisk)
     { LogV(sym + ": portfolio risk cap - waiting"); return; }

   double freshAtr = 0.0;
   if(GetBuf(g_sym[i].hATR, 0, 1, freshAtr) && freshAtr > 0.0)
      p.atr = freshAtr;

   if(!SpreadOK(sym, p.atr)) return;
   if(InpUseNewsFilter && IsNewsBlackout(sym)) return;

   g_sym[i].pend.active = false;
   OpenSplitTrade(sym, p.dir, p.atr);
  }

//+------------------------------------------------------------------+
//| Open the NNFX trade: TP half (magic A) + runner half (magic B).  |
//| On netting accounts, or when halves round below min lot, a       |
//| single runner carries the full risk.                             |
//+------------------------------------------------------------------+
void OpenSplitTrade(const string sym, const int dir, const double atr)
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     { LogV("Trading not allowed by terminal settings"); return; }

   MqlTick tick;
   if(!SymbolInfoTick(sym, tick) || tick.bid <= 0.0 || tick.ask <= 0.0)
     { LogV(sym + ": no current tick - entry skipped"); return; }

   double price   = (dir > 0 ? tick.ask : tick.bid);
   double slDist  = InpSL_ATR * atr;
   double minDist = StopsMinDistance(sym);
   if(slDist < minDist) slDist = minDist;
   double sl = RoundPrice(sym, dir > 0 ? price - slDist : price + slDist);
   double tpA = (InpTP_ATR > 0.0 ? RoundPrice(sym, dir > 0 ? price + InpTP_ATR * atr
                                                           : price - InpTP_ATR * atr) : 0.0);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskPct = InpRiskPercent;
   if(InpDDThrottlePct > 0.0 && equity <= g_peakEquity * (1.0 - InpDDThrottlePct / 100.0))
     {
      riskPct *= InpDDThrottleFactor;       // reduce risk in drawdown, never increase
      LogV(StringFormat("%s: drawdown risk throttle active - risk %.2f%%", sym, riskPct));
     }
   bool   split  = (InpUseSplitTP && !g_isNetting && InpTP_ATR > 0.0);
   ENUM_ORDER_TYPE otype = (dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);

   if(split)
     {
      double riskHalf = equity * (riskPct * 0.5) / 100.0;
      double lots = CalcLots(sym, slDist, riskHalf, otype, price);
      if(lots <= 0.0)
        { split = false; }                       // halves too small: single runner
      else
        {
         SendOrder(sym, MagicA(), "NNFX-TP",  dir, lots, sl, tpA);
         SendOrder(sym, MagicB(), "NNFX-RUN", dir, lots, sl, 0.0);
         return;
        }
     }
   // single runner with the full risk
   double riskMoney = equity * riskPct / 100.0;
   double lots = CalcLots(sym, slDist, riskMoney, otype, price);
   if(lots <= 0.0) return;
   SendOrder(sym, MagicB(), "NNFX-RUN", dir, lots, sl, 0.0);
  }

void SendOrder(const string sym, const long magic, const string tag, const int dir,
               const double lots, const double sl, const double tp)
  {
   g_trade.SetExpertMagicNumber((ulong)magic);
   g_trade.SetTypeFilling(GetFilling(sym));
   bool sent = (dir > 0 ? g_trade.Buy(lots, sym, 0.0, sl, tp, tag)
                        : g_trade.Sell(lots, sym, 0.0, sl, tp, tag));
   uint rc = g_trade.ResultRetcode();
   if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED))
     {
      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      LogI(StringFormat("%s %s %s %.2f lots @ %s, SL %s, TP %s",
                        tag, dir > 0 ? "BUY" : "SELL", sym, lots,
                        DoubleToString(g_trade.ResultPrice(), digits),
                        DoubleToString(sl, digits),
                        tp > 0.0 ? DoubleToString(tp, digits) : "none"));
     }
   else
      LogI(StringFormat("OrderSend FAILED %s %s: retcode=%u (%s)",
                        tag, sym, rc, g_trade.ResultRetcodeDescription()));
  }

//+------------------------------------------------------------------+
//| Manage open trade on closed bars: indicator exits, breakeven,    |
//| runner trail. Returns false only if data is not ready.           |
//+------------------------------------------------------------------+
bool ManageOpen(const int i)
  {
   string sym = g_sym[i].name;
   if(CountPositions(sym, 0) == 0) return true;

   double atr = 0.0;
   if(!GetBuf(g_sym[i].hATR, 0, 1, atr) || atr <= 0.0) return false;

   double base1 = 0.0, base2 = 0.0;
   if(!BaselineVal(i, 1, base1) || !BaselineVal(i, 2, base2)) return false;

   int c1d1 = 0, c1d2 = 0;
   if(InpExitOnC1Reverse)
     {
      if(!ConfDirAt(i, true, 1, c1d1)) return false;
      if(!ConfDirAt(i, true, 2, c1d2)) return false;
     }

   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(sym, InpTimeframe, 1, 2, r) < 2) return false;
   double close1 = r[0].close, close2 = r[1].close;

   double sar1 = 0.0, sar2 = 0.0;
   if(InpUseSARExit)
     {
      if(!GetBuf(g_sym[i].hSAR, 0, 1, sar1)) return false;
      if(!GetBuf(g_sym[i].hSAR, 0, 2, sar2)) return false;
     }

   MqlTick tick;
   if(!SymbolInfoTick(sym, tick) || tick.bid <= 0.0 || tick.ask <= 0.0) return false;
   double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0) tickSize = SymbolInfoDouble(sym, SYMBOL_POINT);

   //--- determine position direction (all halves share it)
   int pdir = 0;
   for(int p = PositionsTotal() - 1; p >= 0; p--)
     {
      ulong tk = PositionGetTicket(p);
      if(tk == 0) continue;
      if(!IsOurMagic(PositionGetInteger(POSITION_MAGIC))) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      pdir = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1);
      break;
     }
   if(pdir == 0) return true;

   //--- indicator exits (fresh crosses against the position)
   string why = "";
   if(InpExitOnC1Reverse && c1d1 == -pdir && c1d2 != -pdir)            why = "C1 reversed";
   if(why == "" && InpExitOnBaseCross)
     {
      int side1 = (close1 > base1 ? 1 : (close1 < base1 ? -1 : 0));
      int side2 = (close2 > base2 ? 1 : (close2 < base2 ? -1 : 0));
      if(side1 == -pdir && side2 != -pdir)                             why = "baseline crossed";
     }
   if(why == "" && InpUseSARExit)
     {
      int s1 = (close1 > sar1 ? 1 : -1);
      int s2 = (close2 > sar2 ? 1 : -1);
      if(s1 == -pdir && s2 != -pdir)                                   why = "SAR flipped";
     }
   if(why != "")
     {
      CloseSymbolTrade(sym, why);
      return true;
     }

   //--- breakeven + runner trail
   for(int p = PositionsTotal() - 1; p >= 0; p--)
     {
      ulong tk = PositionGetTicket(p);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicB()) continue;   // manage the runner only
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double   op    = PositionGetDouble(POSITION_PRICE_OPEN);
      double   sl    = PositionGetDouble(POSITION_SL);
      double   tp    = PositionGetDouble(POSITION_TP);
      datetime opent = (datetime)PositionGetInteger(POSITION_TIME);
      if(iBarShift(sym, InpTimeframe, opent) < 1) continue;

      double newSL = sl;
      if(type == POSITION_TYPE_BUY)
        {
         if(InpTP_ATR > 0.0 && close1 >= op + InpTP_ATR * atr)
            newSL = BetterSL(type, newSL, op);                         // breakeven at +1 ATR
         if(sl >= op && InpTrail_ATR > 0.0)
            newSL = BetterSL(type, newSL, close1 - InpTrail_ATR * atr);// trail after BE
        }
      else
        {
         if(InpTP_ATR > 0.0 && close1 <= op - InpTP_ATR * atr)
            newSL = BetterSL(type, newSL, op);
         if(sl > 0.0 && sl <= op && InpTrail_ATR > 0.0)
            newSL = BetterSL(type, newSL, close1 + InpTrail_ATR * atr);
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
//| Close all halves of one symbol's trade                           |
//+------------------------------------------------------------------+
void CloseSymbolTrade(const string sym, const string reason)
  {
   for(int p = PositionsTotal() - 1; p >= 0; p--)
     {
      ulong tk = PositionGetTicket(p);
      if(tk == 0) continue;
      if(!IsOurMagic(PositionGetInteger(POSITION_MAGIC))) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      g_trade.SetTypeFilling(GetFilling(sym));
      if(g_trade.PositionClose(tk))
         LogI(StringFormat("%s #%I64u closed: %s", sym, tk, reason));
      else
         LogI(StringFormat("Close FAILED %s #%I64u rc=%u", sym, tk, g_trade.ResultRetcode()));
     }
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

// number of symbols currently holding any of our positions
int CountEngagedSymbols()
  {
   int cnt = 0;
   for(int i = 0; i < ArraySize(g_sym); i++)
      if(CountPositions(g_sym[i].name, 0) > 0) cnt++;
   return cnt;
  }

// number of engaged symbols whose base or quote currency matches ccy
int CurrencySymbolExposure(const string ccy)
  {
   int cnt = 0;
   for(int i = 0; i < ArraySize(g_sym); i++)
     {
      if(CountPositions(g_sym[i].name, 0) == 0) continue;
      if(SymbolInfoString(g_sym[i].name, SYMBOL_CURRENCY_BASE)   == ccy ||
         SymbolInfoString(g_sym[i].name, SYMBOL_CURRENCY_PROFIT) == ccy)
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

      if(sl <= 0.0) { total += InpRiskPercent * 0.5; continue; }
      double dist = (type == POSITION_TYPE_BUY ? op - sl : sl - op);
      if(dist <= 0.0) continue;

      double tickSize = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_SIZE);
      double tickVal  = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tickVal <= 0.0) tickVal = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_VALUE);
      if(tickSize <= 0.0 || tickVal <= 0.0) { total += InpRiskPercent * 0.5; continue; }

      total += 100.0 * (dist / tickSize * tickVal * vol) / eq;
     }
   return total;
  }

//+------------------------------------------------------------------+
//| Position sizing (symbol-property based, no pip assumptions)      |
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
   datetime to   = (datetime)((long)now + 2 * 86400);
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
      if(g_sym[i].pend.active) pendCnt++;

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   string s = StringFormat("NNFX Multi-Symbol  |  magic %I64d/%I64d  |  %s\n",
                           MagicA(), MagicB(), EnumToString(InpTimeframe));
   s += StringFormat("Baseline %s(%d)  C1 %s  C2 %s  Vol %s\n",
                     EnumToString(InpBaselineType), InpBaselinePeriod,
                     EnumToString(InpC1Type), EnumToString(InpC2Type), EnumToString(InpVolType));
   s += StringFormat("Equity %.2f (peak %.2f)   Trades %d/%d   Pending %d   Open risk %.2f%% (cap %.2f%%)\n",
                     eq, g_peakEquity, CountEngagedSymbols(), InpMaxTradesTotal, pendCnt,
                     PortfolioOpenRiskPct(), InpMaxPortfolioRisk);
   bool throttled = (InpDDThrottlePct > 0.0 &&
                     eq <= g_peakEquity * (1.0 - InpDDThrottlePct / 100.0));
   s += StringFormat("Risk throttle: %s   Halts - day: %s  week: %s  month: %s  EMERGENCY: %s   Symbols: %d\n",
                     B2S(throttled), B2S(g_dayHalt), B2S(g_weekHalt), B2S(g_monthHalt), B2S(g_emergencyHalt),
                     ArraySize(g_sym));
   Comment(s);
  }
//+------------------------------------------------------------------+
