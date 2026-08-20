//+------------------------------------------------------------------+
//|                            FarhanFX MTF Trend Strategy.mq5        |
//|  Single-position (not basket/martingale) trend-following EA for   |
//|  XAUUSD, ported from the TradingView strategy at                  |
//|  E:\Farhan Fx Algo\FarhanFX_MTF_Trend_Strategy.pine - a 6-EMA      |
//|  Fibonacci ribbon trend system with candlestick + support/        |
//|  resistance + RSI confluence filters, a REAL ATR-based stop-loss,  |
//|  and a 6-level ATR-stepped scaled take-profit.                    |
//|                                                                    |
//|  2026-08-21: built as a deliberate architectural break from the   |
//|  sibling "Scalping Ai Pro By Farhan FX.mq5" in this same folder    |
//|  (dual-basket DCA/martingale, no stop-loss anywhere - an explicit  |
//|  standing decision on that EA, and the direct cause of two real    |
//|  live bugs the same week this file was built). Market research    |
//|  into how consistently profitable traders actually operate        |
//|  (sub-1% risk discipline, 2:1-3:1 R:R, hard predefined stops -     |
//|  see ml\learnings.md's 2026-08-21 entry for sources) is the        |
//|  opposite of that design in every respect. This EA has: one        |
//|  position per direction at a time, a real broker-side stop-loss    |
//|  on every entry, no martingale, no DCA legs.                       |
//|                                                                    |
//|  Position sizing is a deliberate exception to the "risk-based"     |
//|  research finding: it matches the Pine script's own                |
//|  percent_of_equity convention (notional, not risk-based) per       |
//|  explicit user request, so results stay comparable to whatever     |
//|  the Pine version has already shown on TradingView. See            |
//|  CalcPositionSize() for the exact formula and why it's notional,   |
//|  not risk-based.                                                   |
//|                                                                    |
//|  Dashboard/license/broker-preset/branding infrastructure is        |
//|  reused verbatim in pattern from the sibling EA in this folder -   |
//|  same look, same license-key list, same hard-won "license check    |
//|  must never block OnInit()/the dashboard" lesson from that EA's    |
//|  own history (see its ml\learnings.md, 2026-08-14/16 entries).     |
//+------------------------------------------------------------------+
#property copyright "FarhanFX Algo"
#property version   "1.00"
#property strict
#property description "Single-position trend-following EA for XAUUSD - 6-EMA ribbon + candle/S-R/RSI confluence, real ATR stop-loss, 6-level scaled TP."

// Same brand assets as the sibling EA in this folder - reused as-is, no new
// images. Must exist at <data_folder>\MQL5\Images\ on whichever machine
// compiles this (copies live in this repo's resources\ folder).
#resource "\\Images\\FarhanFX_Icon.bmp"
#resource "\\Images\\FarhanFX_Watermark.bmp"
#define WATERMARK_W 420
#define WATERMARK_H 310

#define EA_BUILD_VERSION "v1"

#include <Trade\Trade.mqh>
CTrade trade;

//+------------------------------------------------------------------+
//| Enums                                                              |
//+------------------------------------------------------------------+
enum ENUM_TF_PRESET
  {
   PRESET_30M    = 0, // 30m (Default)
   PRESET_15M    = 1, // 15m
   PRESET_1H     = 2, // 1h
   PRESET_4H     = 3, // 4h
   PRESET_CUSTOM = 4  // Custom (use EMA Ribbon inputs below)
  };

// Same broker/account-type pattern as the sibling EA - same verified
// constants, same reasoning (real $ spread maps to very different raw
// "points" numbers depending on broker/account-type digit convention).
enum ENUM_BROKER_PRESET
  {
   BROKER_CUSTOM  = 0, // Custom (use Max Spread below)
   BROKER_EXNESS  = 1, // Exness
   BROKER_CXM     = 2, // CXM Direct
   BROKER_VANTAGE = 3  // Vantage Markets
  };

enum ENUM_ACCOUNT_TYPE
  {
   ACCOUNT_TYPE_USD = 0, // Standard (USD)
   ACCOUNT_TYPE_USC = 1  // Cent (USC)
  };

enum ENUM_TREND_SIDE
  {
   TREND_NONE = 0,
   TREND_BULL = 1,
   TREND_BEAR = -1
  };

//+------------------------------------------------------------------+
//| Inputs                                                             |
//+------------------------------------------------------------------+
input group "=== Account & Basic Settings ==="
input ulong    InpMagicNumber        = 20270821;  // Magic Number
input long     InpExpectedLogin      = 0;         // Account Login (0 = skip check - client sets their own)
input ENUM_BROKER_PRESET InpBrokerPreset = BROKER_CUSTOM;   // Broker Preset (auto-sets Max Spread)
input ENUM_ACCOUNT_TYPE  InpAccountType  = ACCOUNT_TYPE_USD; // Account Type (scales Max Spread for cent accounts)
input int      InpMaxSpreadPoints    = 300;       // Max Spread (points) - used when Broker Preset = Custom

input group "=== License ==="
input string   InpLicenseKey = ""; // License Key (given individually to each client)

input group "=== Timeframe Preset ==="
input ENUM_TF_PRESET InpTfPreset = PRESET_30M; // Preset (shifts EMA ladder + S/R lookback to fit the chart's timeframe - attach this EA to a matching chart, e.g. M30 for the default)

input group "=== EMA Ribbon (used when Preset = Custom) ==="
input int InpEma1Period = 8;
input int InpEma2Period = 13;
input int InpEma3Period = 21;
input int InpEma4Period = 34;
input int InpEma5Period = 55;
input int InpEma6Period = 89;
input int InpSrLookbackCustom = 20; // S/R Pivot Lookback (Custom/30m preset)

input group "=== Signal Engine ==="
input bool   InpUseCandlePattern = true; // Require Candlestick Confirmation
input bool   InpUseSR            = true; // Require S/R Confluence
input int    InpRsiPeriod        = 14;   // RSI Period
input int    InpRsiLongMax       = 65;   // Max RSI For Long Entry
input int    InpRsiShortMin      = 35;   // Min RSI For Short Entry

input group "=== Risk Management ==="
input int    InpAtrPeriod    = 14;  // ATR Period
input double InpSlAtrMult    = 1.5; // Stop Loss (x ATR) - real broker-side SL, always attached
input double InpTpStepAtrMult = 1.0; // TP Step (x ATR per level, 6 levels)

input group "=== Position Sizing ==="
// Notional, not risk-based - deliberately matches the source Pine script's
// percent_of_equity mode (see file header). Real $ risked per trade still
// varies with SL distance, same as it does in the Pine backtest.
input double InpPositionPercentOfEquity = 10.0; // Position Size (% of equity, notional)

input group "=== Circuit Breakers ==="
input bool   InpUseDailyLossLimit     = true;  // Use Daily Loss Limit
input double InpDailyLossLimitPercent = 3.0;   // Daily Loss Limit (% of day-start balance)
input int    InpMaxConsecutiveLosses  = 4;     // Max Consecutive Losses (0 = off) - pauses new entries until a win

input group "=== Dashboard ==="
input bool   InpShowDashboard        = true;  // Show Dashboard
input int    InpDashboardX           = 10;    // Dashboard X Position
input int    InpDashboardY           = 20;    // Dashboard Y Position
input bool   InpSetWhiteChartTheme   = false; // White Chart Theme (off = dark, matches the Farhan FX brand's black logo background)
input bool   InpShowChartWatermark   = true;  // Show Farhan FX Watermark On Main Chart

//+------------------------------------------------------------------+
//| Globals                                                            |
//+------------------------------------------------------------------+
#define DB_PREFIX "FFXT_DB_"
#define MK_PREFIX "FFXT_MK_"

int g_emaHandles[6] = {INVALID_HANDLE, INVALID_HANDLE, INVALID_HANDLE, INVALID_HANDLE, INVALID_HANDLE, INVALID_HANDLE};
int g_atrHandle = INVALID_HANDLE;
int g_rsiHandle = INVALID_HANDLE;

datetime g_lastBarTime = 0;

int    g_dayStartDateCode = -1;
double g_dayStartBalance  = 0.0;

int      g_consecutiveLosses = 0;
datetime g_lastDealCheckTime = 0;

// The one open position this EA manages at a time (per direction - flat,
// long, or short, never both). Tracks which of the 6 ATR-stepped TP levels
// have already been taken, since MQL5 has no native scale-out order like
// Pine's strategy.exit(qty_percent=...) - this is worked out by hand each
// tick in ManagePartialTP().
ulong  g_posTicket         = 0;
double g_posOriginalVolume = 0;
double g_tpLevels[6];
bool   g_tpTaken[6];

// Last computed signal state, refreshed once per new bar - shown on the
// dashboard and used by the trend-exit check.
ENUM_TREND_SIDE g_currentAlignment = TREND_NONE;
double g_lastResistance = 0;
double g_lastSupport    = 0;
double g_lastRsi        = 0;

//+------------------------------------------------------------------+
//| Broker preset / spread (same pattern as the sibling EA)           |
//+------------------------------------------------------------------+
int EffectiveMaxSpreadPoints()
  {
   bool cent = (InpAccountType == ACCOUNT_TYPE_USC);
   switch(InpBrokerPreset)
     {
      case BROKER_EXNESS:  return cent ? 5000 : 300;
      case BROKER_CXM:     return 300;
      case BROKER_VANTAGE: return 300;
      default:              return InpMaxSpreadPoints;
     }
  }

bool SpreadIsAcceptable()
  {
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return(spread <= EffectiveMaxSpreadPoints());
  }

//+------------------------------------------------------------------+
//| License - same embedded key list + non-blocking gate pattern as   |
//| the sibling EA (see that file's 2026-08-16 header comment for the |
//| full story of why this must never run inside OnInit()'s refusal   |
//| path). Same 20 currently-issued keys.                             |
//+------------------------------------------------------------------+
string g_authorizedLicenseKeys[] =
  {
   "SAIP-EBYZ-G5D5-Q6NZ-7SJG",
   "SAIP-FNWO-AK0W-AX9T-PTQC",
   "SAIP-UBP7-6SNT-V3CO-I2FR",
   "SAIP-JFK8-HYB8-E00Z-AZPH",
   "SAIP-UIV9-N7D7-2AY2-J79B",
   "SAIP-5BKE-HR6W-AUUP-PH25",
   "SAIP-GBBO-OFM7-D70Y-XPYL",
   "SAIP-345R-7HU9-NNEP-KKYL",
   "SAIP-NZL1-VMLC-476Z-KLOW",
   "SAIP-TK1T-SJ0W-NVTG-9QV8",
   "SAIP-8H34-JVTR-KJQV-QLZK",
   "SAIP-VGI3-524U-I9AM-WEIT",
   "SAIP-FNR2-SUOF-8K2T-U8FA",
   "SAIP-GW3I-N0RS-QF0F-BFBD",
   "SAIP-MT8B-OD0J-MEEU-Z4DJ",
   "SAIP-PY5O-46IZ-WGTF-Z5TW",
   "SAIP-SU4V-6UU7-BW82-RYHC",
   "SAIP-1ELE-GXWQ-X681-A8CF",
   "SAIP-6QS2-EHAO-RZ01-5TD2",
   "SAIP-115E-ODQJ-MFP0-MT3X"
  };

bool LicenseOk()
  {
   if(InpLicenseKey == "")
      return false;
   for(int i = 0; i < ArraySize(g_authorizedLicenseKeys); i++)
      if(InpLicenseKey == g_authorizedLicenseKeys[i])
         return true;
   return false;
  }

//+------------------------------------------------------------------+
//| Day tracking / circuit breakers                                   |
//+------------------------------------------------------------------+
void UpdateDayTracking()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int todayCode = dt.year * 10000 + dt.mon * 100 + dt.day;
   if(todayCode != g_dayStartDateCode)
     {
      g_dayStartDateCode = todayCode;
      g_dayStartBalance  = AccountInfoDouble(ACCOUNT_BALANCE);
     }
  }

bool DailyLossLimitHit()
  {
   if(!InpUseDailyLossLimit || g_dayStartBalance <= 0)
      return false;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double lossPct = (g_dayStartBalance - balance) / g_dayStartBalance * 100.0;
   return(lossPct >= InpDailyLossLimitPercent);
  }

bool ConsecutiveLossLimitHit()
  {
   if(InpMaxConsecutiveLosses <= 0)
      return false;
   return(g_consecutiveLosses >= InpMaxConsecutiveLosses);
  }

// Scans closing deals for this magic+symbol since the last check and
// updates the consecutive-loss streak: any loss increments it, any win
// resets it to 0. Called once per new bar - cheap, small lookback window.
void UpdateConsecutiveLossStreak()
  {
   datetime from = (g_lastDealCheckTime > 0) ? g_lastDealCheckTime : (TimeCurrent() - 86400);
   datetime to   = TimeCurrent() + 60;
   if(!HistorySelect(from, to))
      return;

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0)
         continue;
      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
         continue;
      if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != (long)InpMagicNumber)
         continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT &&
         (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT_BY)
         continue;

      datetime dealTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
      if(dealTime <= g_lastDealCheckTime)
         continue;

      double net = HistoryDealGetDouble(dealTicket, DEAL_PROFIT) + HistoryDealGetDouble(dealTicket, DEAL_SWAP) +
                   HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      if(net < 0)
         g_consecutiveLosses++;
      else if(net > 0)
         g_consecutiveLosses = 0;
      // net == 0 (rare, e.g. a partial-close at breakeven): leave streak unchanged
     }

   g_lastDealCheckTime = TimeCurrent();
  }

//+------------------------------------------------------------------+
//| EMA ribbon / S-R lookback per timeframe preset                    |
//+------------------------------------------------------------------+
void GetEmaPeriods(int &p[])
  {
   ArrayResize(p, 6);
   switch(InpTfPreset)
     {
      case PRESET_15M:
         p[0] = 13; p[1] = 21; p[2] = 34; p[3] = 55; p[4] = 89; p[5] = 144;
         break;
      case PRESET_1H:
         p[0] = 5; p[1] = 8; p[2] = 13; p[3] = 21; p[4] = 34; p[5] = 55;
         break;
      case PRESET_4H:
         p[0] = 3; p[1] = 5; p[2] = 8; p[3] = 13; p[4] = 21; p[5] = 34;
         break;
      case PRESET_CUSTOM:
         p[0] = InpEma1Period; p[1] = InpEma2Period; p[2] = InpEma3Period;
         p[3] = InpEma4Period; p[4] = InpEma5Period; p[5] = InpEma6Period;
         break;
      default: // PRESET_30M
         p[0] = 8; p[1] = 13; p[2] = 21; p[3] = 34; p[4] = 55; p[5] = 89;
         break;
     }
  }

int EffectiveSrLookback()
  {
   switch(InpTfPreset)
     {
      case PRESET_15M: return 25;
      case PRESET_1H:  return 15;
      case PRESET_4H:  return 10;
      default:          return InpSrLookbackCustom; // 30m and Custom
     }
  }

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(InpExpectedLogin != 0 && AccountInfoInteger(ACCOUNT_LOGIN) != InpExpectedLogin)
     {
      PrintFormat("FarhanFXTrend: connected account %d does not match InpExpectedLogin %d. Refusing to run.",
                  (int)AccountInfoInteger(ACCOUNT_LOGIN), (int)InpExpectedLogin);
      return(INIT_FAILED);
     }

   if(InpSetWhiteChartTheme)
      ApplyWhiteChartTheme();
   else
      ApplyBlackChartTheme();

   int periods[];
   GetEmaPeriods(periods);
   for(int i = 0; i < 6; i++)
     {
      g_emaHandles[i] = iMA(_Symbol, PERIOD_CURRENT, periods[i], 0, MODE_EMA, PRICE_CLOSE);
      if(g_emaHandles[i] == INVALID_HANDLE)
        {
         PrintFormat("FarhanFXTrend: EMA handle %d (period %d) creation failed.", i + 1, periods[i]);
         return(INIT_FAILED);
        }
     }

   g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, InpAtrPeriod);
   if(g_atrHandle == INVALID_HANDLE)
     {
      Print("FarhanFXTrend: ATR handle creation failed.");
      return(INIT_FAILED);
     }

   g_rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, InpRsiPeriod, PRICE_CLOSE);
   if(g_rsiHandle == INVALID_HANDLE)
     {
      Print("FarhanFXTrend: RSI handle creation failed.");
      return(INIT_FAILED);
     }

   // Not fatal - just a heads-up. The preset only shifts EMA/S-R periods to
   // suit a particular chart timeframe (exactly like the source Pine
   // script's own tooltip says); it doesn't force the chart itself.
   ENUM_TIMEFRAMES expectedTf = PERIOD_M30;
   if(InpTfPreset == PRESET_15M) expectedTf = PERIOD_M15;
   else if(InpTfPreset == PRESET_1H) expectedTf = PERIOD_H1;
   else if(InpTfPreset == PRESET_4H) expectedTf = PERIOD_H4;
   if(InpTfPreset != PRESET_CUSTOM && _Period != expectedTf)
      PrintFormat("FarhanFXTrend: preset expects an %s chart but this is attached to %s - the EMA ladder is tuned for the preset's timeframe, not this one.",
                  EnumToString(expectedTf), EnumToString((ENUM_TIMEFRAMES)_Period));

   RestoreOpenPositionOnInit();
   UpdateDayTracking();

   if(InpShowDashboard)
     {
      CreateDashboard();
      EventSetTimer(1);
     }

   PositionWatermark();

   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   for(int i = 0; i < 6; i++)
      if(g_emaHandles[i] != INVALID_HANDLE)
         IndicatorRelease(g_emaHandles[i]);
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   if(g_rsiHandle != INVALID_HANDLE)
      IndicatorRelease(g_rsiHandle);
   EventKillTimer();
  }

// If the EA restarts/reattaches while a position it opened is still open
// (real SL, so the position could easily have survived a terminal
// restart), rebuild the TP-level tracking from the position's own stored
// data instead of starting with everything untracked. Original volume and
// which levels are "already passed" are inferred from the position's
// current volume vs. a freshly-recomputed level ladder - any level whose
// price the current price has already cleared is marked taken, since it's
// safer to assume a level fired (and possibly wasn't fully accounted for
// across the restart) than to double-close past it.
void RestoreOpenPositionOnInit()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
         continue;

      g_posTicket         = ticket;
      g_posOriginalVolume = PositionGetDouble(POSITION_VOLUME); // best guess - true original is unknown post-restart
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      long   type  = PositionGetInteger(POSITION_TYPE);
      double atr   = LastClosedAtr();
      bool   isBuy = (type == POSITION_TYPE_BUY);
      double current = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      for(int lvl = 0; lvl < 6; lvl++)
        {
         g_tpLevels[lvl] = isBuy ? (entry + atr * InpTpStepAtrMult * (lvl + 1))
                                   : (entry - atr * InpTpStepAtrMult * (lvl + 1));
         g_tpTaken[lvl]  = isBuy ? (current >= g_tpLevels[lvl]) : (current <= g_tpLevels[lvl]);
        }
      return; // only one position is ever open at a time
     }
  }

//+------------------------------------------------------------------+
//| Chart theme (same pattern as the sibling EA)                      |
//+------------------------------------------------------------------+
void ApplyWhiteChartTheme()
  {
   ChartSetInteger(0, CHART_COLOR_BACKGROUND, clrWhite);
   ChartSetInteger(0, CHART_COLOR_FOREGROUND, clrBlack);
   ChartSetInteger(0, CHART_COLOR_GRID, C'225,225,225');
   ChartSetInteger(0, CHART_COLOR_CANDLE_BULL, clrForestGreen);
   ChartSetInteger(0, CHART_COLOR_CANDLE_BEAR, clrCrimson);
   ChartSetInteger(0, CHART_COLOR_CHART_UP, clrForestGreen);
   ChartSetInteger(0, CHART_COLOR_CHART_DOWN, clrCrimson);
   ChartSetInteger(0, CHART_COLOR_CHART_LINE, clrBlack);
   ChartSetInteger(0, CHART_COLOR_VOLUME, C'120,120,200');
   ChartSetInteger(0, CHART_COLOR_BID, clrBlue);
   ChartSetInteger(0, CHART_COLOR_ASK, clrRed);
   ChartSetInteger(0, CHART_COLOR_STOP_LEVEL, clrRed);
   ChartRedraw();
  }

// Forces pure black - the watermark bitmap is pre-scaled against (0,0,0) in
// software, so it only blends invisibly if the real background is
// genuinely pure black, not whatever a broker's default template happens
// to use. See the sibling EA's 2026-08-16 learnings entry for the real
// live bug this exact mistake caused there.
void ApplyBlackChartTheme()
  {
   ChartSetInteger(0, CHART_COLOR_BACKGROUND, clrBlack);
   ChartSetInteger(0, CHART_COLOR_FOREGROUND, clrWhite);
   ChartSetInteger(0, CHART_COLOR_GRID, C'40,40,45');
   ChartSetInteger(0, CHART_COLOR_CANDLE_BULL, clrForestGreen);
   ChartSetInteger(0, CHART_COLOR_CANDLE_BEAR, clrCrimson);
   ChartSetInteger(0, CHART_COLOR_CHART_UP, clrForestGreen);
   ChartSetInteger(0, CHART_COLOR_CHART_DOWN, clrCrimson);
   ChartSetInteger(0, CHART_COLOR_CHART_LINE, clrWhite);
   ChartSetInteger(0, CHART_COLOR_VOLUME, C'120,120,200');
   ChartSetInteger(0, CHART_COLOR_BID, clrDodgerBlue);
   ChartSetInteger(0, CHART_COLOR_ASK, clrRed);
   ChartSetInteger(0, CHART_COLOR_STOP_LEVEL, clrRed);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Indicator value helpers - all read the LAST CLOSED bar (shift 1)  |
//| by default, matching the source Pine script's bar-close           |
//| evaluation (Pine's `close` = the just-completed bar when the      |
//| script fires, not the still-forming realtime bar).                |
//+------------------------------------------------------------------+
double EmaValue(int idx, int shift)
  {
   double buf[];
   if(CopyBuffer(g_emaHandles[idx], 0, shift, 1, buf) < 1)
      return 0;
   return buf[0];
  }

double LastClosedAtr()
  {
   double buf[];
   if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) < 1)
      return 0;
   return buf[0];
  }

double LastClosedRsi()
  {
   double buf[];
   if(CopyBuffer(g_rsiHandle, 0, 1, 1, buf) < 1)
      return 0;
   return buf[0];
  }

// true if all 6 EMAs are in strict bullish (ema1>ema2>...>ema6) or
// bearish order at the given bar shift (1 = last closed, 2 = the one
// before). Mirrors the Pine script's bullAligned/bearAligned exactly.
ENUM_TREND_SIDE AlignmentAt(int shift)
  {
   double e[6];
   for(int i = 0; i < 6; i++)
      e[i] = EmaValue(i, shift);

   bool bull = true, bear = true;
   for(int i = 0; i < 5; i++)
     {
      if(!(e[i] > e[i + 1])) bull = false;
      if(!(e[i] < e[i + 1])) bear = false;
     }
   if(bull) return TREND_BULL;
   if(bear) return TREND_BEAR;
   return TREND_NONE;
  }

//+------------------------------------------------------------------+
//| Candlestick confirmation - ported from the Pine script's           |
//| bullEngulf/bearEngulf/bullPin/bearPin/minBody logic, using the     |
//| last closed bar (rates[0] here) and the one before it (rates[1]).  |
//+------------------------------------------------------------------+
bool CandleConfirms(ENUM_TREND_SIDE side)
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_CURRENT, 1, 2, rates) < 2)
      return false;

   double close1 = rates[0].close, open1 = rates[0].open, high1 = rates[0].high, low1 = rates[0].low;
   double close2 = rates[1].close, open2 = rates[1].open;
   double atr = LastClosedAtr();
   double minBody = atr * 0.15;

   if(side == TREND_BULL)
     {
      bool bullEngulf = (close1 > open1) && (close2 < open2) && (close1 > open2) && (open1 < close2);
      bool bullPin    = ((close1 - low1) > 2 * MathAbs(close1 - open1)) && (close1 > open1);
      bool bigBody    = (close1 > open1) && ((close1 - open1) > minBody);
      return(bullEngulf || bullPin || bigBody);
     }
   else if(side == TREND_BEAR)
     {
      bool bearEngulf = (close1 < open1) && (close2 > open2) && (close1 < open2) && (open1 > close2);
      bool bearPin    = ((high1 - close1) > 2 * MathAbs(close1 - open1)) && (close1 < open1);
      bool bigBody    = (close1 < open1) && ((open1 - close1) > minBody);
      return(bearEngulf || bearPin || bigBody);
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Support / resistance pivots - ported from Pine's                   |
//| ta.pivothigh(high, N, N) / ta.pivotlow(low, N, N): a bar is a       |
//| confirmed pivot only once N bars have formed on both sides of it,  |
//| so the "current" S/R level is always at least N bars old - that's  |
//| the Pine behavior being matched here, not a bug to fix.            |
//+------------------------------------------------------------------+
void UpdateSupportResistance()
  {
   int n = EffectiveSrLookback();
   int lookback = MathMin(500, n * 2 + 60); // enough bars to find at least one confirmed pivot, capped for performance

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_CURRENT, 1, lookback, rates) < lookback)
      return;

   // rates[0] = last closed bar. A pivot at series-index k needs k-n..k+n
   // to all exist and k to be the extreme of that window. The earliest
   // possible (most recent) confirmed pivot is at k = n.
   for(int k = n; k <= lookback - n - 1; k++)
     {
      bool isHigh = true, isLow = true;
      for(int j = k - n; j <= k + n; j++)
        {
         if(j == k)
            continue;
         if(rates[j].high >= rates[k].high) isHigh = false;
         if(rates[j].low  <= rates[k].low)  isLow  = false;
        }
      if(isHigh)
        {
         g_lastResistance = rates[k].high;
         break;
        }
     }
   for(int k = n; k <= lookback - n - 1; k++)
     {
      bool isLow = true;
      for(int j = k - n; j <= k + n; j++)
        {
         if(j == k)
            continue;
         if(rates[j].low <= rates[k].low) isLow = false;
        }
      if(isLow)
        {
         g_lastSupport = rates[k].low;
         break;
        }
     }
  }

bool NearResistance(double price, double atr)
  {
   if(g_lastResistance <= 0)
      return false;
   return(MathAbs(price - g_lastResistance) <= atr * 0.5);
  }

bool NearSupport(double price, double atr)
  {
   if(g_lastSupport <= 0)
      return false;
   return(MathAbs(price - g_lastSupport) <= atr * 0.5);
  }

//+------------------------------------------------------------------+
//| Position sizing - notional (percent-of-equity), matching the       |
//| source Pine script's default_qty_type=strategy.percent_of_equity   |
//| mode exactly, per explicit user request. This is NOT risk-based -  |
//| it does not scale with SL distance, so real $ risked per trade     |
//| still varies (same as it does in the Pine backtest).               |
//+------------------------------------------------------------------+
double CalcPositionSize(double price)
  {
   double equity       = AccountInfoDouble(ACCOUNT_EQUITY);
   double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   if(contractSize <= 0 || price <= 0)
      return 0;

   double notional = equity * (InpPositionPercentOfEquity / 100.0);
   double lots = notional / (price * contractSize);

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lots = MathRound(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   return NormalizeDouble(lots, 2);
  }

//+------------------------------------------------------------------+
//| Entry / trend-exit - evaluated once per new bar only, matching    |
//| the Pine script's default (non-realtime) bar-close evaluation.    |
//+------------------------------------------------------------------+
void EvaluateNewBarSignals()
  {
   ENUM_TREND_SIDE alignNow  = AlignmentAt(1);
   ENUM_TREND_SIDE alignPrev = AlignmentAt(2);
   g_currentAlignment = alignNow;
   g_lastRsi = LastClosedRsi();
   UpdateSupportResistance();

   bool bullFlip = (alignNow == TREND_BULL) && (alignPrev != TREND_BULL);
   bool bearFlip = (alignNow == TREND_BEAR) && (alignPrev != TREND_BEAR);

   bool hasPosition = (g_posTicket != 0 && PositionSelectByTicket(g_posTicket));
   ENUM_POSITION_TYPE posType = hasPosition ? (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) : (ENUM_POSITION_TYPE)-1;

   // Trend-exit: close whatever's left the instant full alignment breaks,
   // regardless of TP progress - same as Pine's trendExitLong/Short.
   if(hasPosition)
     {
      if(posType == POSITION_TYPE_BUY && alignNow != TREND_BULL)
        {
         ClosePositionFully("trend exit - ribbon lost bullish alignment");
         hasPosition = false;
        }
      else if(posType == POSITION_TYPE_SELL && alignNow != TREND_BEAR)
        {
         ClosePositionFully("trend exit - ribbon lost bearish alignment");
         hasPosition = false;
        }
     }

   if(IsNewEntryBlocked())
      return;

   double atr = LastClosedAtr();
   if(atr <= 0)
      return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(bullFlip && (!hasPosition || posType != POSITION_TYPE_BUY))
     {
      bool candleOk = (!InpUseCandlePattern || CandleConfirms(TREND_BULL));
      bool srOk     = (!InpUseSR || !NearResistance(ask, atr));
      bool rsiOk    = (g_lastRsi < InpRsiLongMax);
      if(candleOk && srOk && rsiOk)
        {
         if(hasPosition) // was short - flip
            ClosePositionFully("flip to long");
         OpenPosition(TREND_BULL, ask, atr);
        }
     }
   else if(bearFlip && (!hasPosition || posType != POSITION_TYPE_SELL))
     {
      bool candleOk = (!InpUseCandlePattern || CandleConfirms(TREND_BEAR));
      bool srOk     = (!InpUseSR || !NearSupport(bid, atr));
      bool rsiOk    = (g_lastRsi > InpRsiShortMin);
      if(candleOk && srOk && rsiOk)
        {
         if(hasPosition) // was long - flip
            ClosePositionFully("flip to short");
         OpenPosition(TREND_BEAR, bid, atr);
        }
     }
  }

// Non-blocking gates - matches the sibling EA's pattern (license/daily-
// target/etc never refuse OnInit(), only skip new entries). An existing
// open position keeps being managed (partial TP, trend-exit, real SL)
// regardless of any of these.
bool IsNewEntryBlocked()
  {
   if(!LicenseOk())
      return true;
   if(DailyLossLimitHit())
      return true;
   if(ConsecutiveLossLimitHit())
      return true;
   if(!SpreadIsAcceptable())
      return true;
   return false;
  }

void OpenPosition(ENUM_TREND_SIDE side, double price, double atr)
  {
   double lots = CalcPositionSize(price);
   if(lots <= 0)
      return;

   double sl;
   bool ok;
   string comment = (side == TREND_BULL) ? "FarhanFXTrend-buy" : "FarhanFXTrend-sell";

   if(side == TREND_BULL)
     {
      sl = price - atr * InpSlAtrMult;
      ok = trade.Buy(lots, _Symbol, price, sl, 0, comment);
     }
   else
     {
      sl = price + atr * InpSlAtrMult;
      ok = trade.Sell(lots, _Symbol, price, sl, 0, comment);
     }

   if(!ok)
     {
      PrintFormat("FarhanFXTrend: %s entry failed (lot=%.2f): retcode=%d %s",
                  (side == TREND_BULL ? "BUY" : "SELL"), lots, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return;
     }

   g_posTicket         = trade.ResultOrder();
   g_posOriginalVolume = lots;
   for(int i = 0; i < 6; i++)
     {
      g_tpLevels[i] = (side == TREND_BULL) ? (price + atr * InpTpStepAtrMult * (i + 1))
                                             : (price - atr * InpTpStepAtrMult * (i + 1));
      g_tpTaken[i]  = false;
     }

   DrawEntryMarker(side, price);
  }

void ClosePositionFully(string reason)
  {
   if(g_posTicket == 0 || !PositionSelectByTicket(g_posTicket))
     {
      g_posTicket = 0;
      return;
     }
   if(trade.PositionClose(g_posTicket))
     {
      PrintFormat("FarhanFXTrend: position closed (ticket %d) - %s", (int)g_posTicket, reason);
      DrawCloseMarker(reason);
      g_posTicket = 0;
     }
   else
      PrintFormat("FarhanFXTrend: failed to close ticket %d (%s): retcode=%d %s",
                  (int)g_posTicket, reason, trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Scaled take-profit - checked every tick (price can cross a level  |
//| intrabar), ported from the Pine script's 6-level qty_percent       |
//| ladder (16.67/20/25/33.34/50/100% of whatever's REMAINING at each  |
//| fill - calibrated so each slice equals 1/6 of the ORIGINAL entry   |
//| size; see file header / plan for the arithmetic).                  |
//+------------------------------------------------------------------+
void ManagePartialTP()
  {
   if(g_posTicket == 0 || !PositionSelectByTicket(g_posTicket))
     {
      g_posTicket = 0;
      return;
     }

   static double slicePct[6] = {16.67, 20.0, 25.0, 33.34, 50.0, 100.0};

   long type = PositionGetInteger(POSITION_TYPE);
   bool isBuy = (type == POSITION_TYPE_BUY);
   double current = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = 0; i < 6; i++)
     {
      if(g_tpTaken[i])
         continue;
      bool reached = isBuy ? (current >= g_tpLevels[i]) : (current <= g_tpLevels[i]);
      if(!reached)
         continue;

      g_tpTaken[i] = true; // mark first, so a failed close doesn't retry-loop into the same level every tick
      double remaining = PositionGetDouble(POSITION_VOLUME);
      double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double closeVol = remaining * (slicePct[i] / 100.0);
      closeVol = MathRound(closeVol / volStep) * volStep;
      if(closeVol <= 0)
         continue;

      if(closeVol >= remaining - volStep / 2) // last slice (or rounding leaves nothing worth keeping) - close fully
        {
         ClosePositionFully(StringFormat("TP%d (final slice)", i + 1));
         return;
        }

      if(trade.PositionClosePartial(g_posTicket, closeVol))
         PrintFormat("FarhanFXTrend: TP%d hit, closed %.2f lots (ticket %d)", i + 1, closeVol, (int)g_posTicket);
      else
         PrintFormat("FarhanFXTrend: TP%d partial close failed (ticket %d): retcode=%d %s",
                     i + 1, (int)g_posTicket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Chart markers - entry/close labels, cosmetic only.                 |
//+------------------------------------------------------------------+
void DrawEntryMarker(ENUM_TREND_SIDE side, double price)
  {
   string name = MK_PREFIX + "ENTRY_" + IntegerToString((int)TimeCurrent());
   color clr = (side == TREND_BULL) ? C'0,170,220' : C'230,140,0';
   string text = (side == TREND_BULL) ? "BUY" : "SELL";
   ObjectCreate(0, name, OBJ_TEXT, 0, TimeCurrent(), price);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, side == TREND_BULL ? ANCHOR_UPPER : ANCHOR_LOWER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void DrawCloseMarker(string reason)
  {
   string name = MK_PREFIX + "CLOSE_" + IntegerToString((int)TimeCurrent());
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   ObjectCreate(0, name, OBJ_TEXT, 0, TimeCurrent(), price);
   ObjectSetString(0, name, OBJPROP_TEXT, "EXIT");
   ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrSilver);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
//| Main tick loop                                                     |
//+------------------------------------------------------------------+
void OnTick()
  {
   UpdateDayTracking();

   ManagePartialTP(); // every tick - price can cross a TP level intrabar

   datetime barTime = (datetime)SeriesInfoInteger(_Symbol, PERIOD_CURRENT, SERIES_LASTBAR_DATE);
   if(barTime != g_lastBarTime)
     {
      g_lastBarTime = barTime;
      UpdateConsecutiveLossStreak();
      EvaluateNewBarSignals(); // entries + trend-exit, once per closed bar only
     }

   if(InpShowDashboard)
      UpdateDashboard();
  }

void OnTimer()
  {
   if(InpShowDashboard)
      UpdateDashboard();
  }

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_CHART_CHANGE)
     {
      PositionWatermark();
      return;
     }
   if(id != CHARTEVENT_OBJECT_CLICK)
      return;
   if(sparam == DB_PREFIX + "CloseBtn")
     {
      ClosePositionFully("manual close");
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      ChartRedraw();
     }
  }

//+------------------------------------------------------------------+
//| Chart watermark - identical pattern to the sibling EA.             |
//+------------------------------------------------------------------+
void PositionWatermark()
  {
   string name = MK_PREFIX + "Watermark";
   if(!InpShowChartWatermark)
     {
      ObjectDelete(0, name);
      return;
     }

   int chartW = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int chartH = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
   int wx = MathMax(0, (chartW - WATERMARK_W) / 2);
   int wy = MathMax(0, (chartH - WATERMARK_H) / 2);

   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_BITMAP_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetString(0, name, OBJPROP_BMPFILE, "::Images\\FarhanFX_Watermark.bmp");
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_ZORDER, -100);
     }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, wx);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, wy);
  }

//+------------------------------------------------------------------+
//| Dashboard - same DbLabel/DbDivider/CreateButton/PadRight pattern   |
//| as the sibling EA in this folder.                                  |
//+------------------------------------------------------------------+
void DbLabel(string name, int x, int y, string text, color clr, int fontSize = 8)
  {
   string full = DB_PREFIX + name;
   if(ObjectFind(0, full) < 0)
     {
      ObjectCreate(0, full, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, full, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, full, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, full, OBJPROP_YDISTANCE, y);
      ObjectSetString(0, full, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, full, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, full, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, full, OBJPROP_ZORDER, 100);
     }
   ObjectSetInteger(0, full, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, full, OBJPROP_TEXT, text);
   ObjectSetInteger(0, full, OBJPROP_COLOR, clr);
  }

void DbDivider(string name, int x, int y, int widthPx, color clr)
  {
   string full = DB_PREFIX + name;
   if(ObjectFind(0, full) < 0)
     {
      ObjectCreate(0, full, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, full, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, full, OBJPROP_XSIZE, widthPx);
      ObjectSetInteger(0, full, OBJPROP_YSIZE, 1);
      ObjectSetInteger(0, full, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, full, OBJPROP_BACK, false);
      ObjectSetInteger(0, full, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, full, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, full, OBJPROP_ZORDER, 50);
     }
   ObjectSetInteger(0, full, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, full, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, full, OBJPROP_BGCOLOR, clr);
   ObjectSetInteger(0, full, OBJPROP_COLOR, clr);
  }

string PadRight(string s, int width)
  {
   while(StringLen(s) < width)
      s += " ";
   return s;
  }

void CreateButton(string name, int x, int y, int w, int h, string text, color bg)
  {
   string full = DB_PREFIX + name;
   if(ObjectFind(0, full) >= 0)
      return;
   ObjectCreate(0, full, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, full, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, full, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, full, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, full, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, full, OBJPROP_YSIZE, h);
   ObjectSetString(0, full, OBJPROP_TEXT, text);
   ObjectSetString(0, full, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, full, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, full, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, full, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, full, OBJPROP_BORDER_COLOR, C'70,70,80');
   ObjectSetInteger(0, full, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, full, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, full, OBJPROP_ZORDER, 100);
  }

void CreateDashboard()
  {
   string bg = DB_PREFIX + "BG";
   if(ObjectFind(0, bg) < 0)
     {
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, InpDashboardX - 10);
      ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, InpDashboardY - 10);
      ObjectSetInteger(0, bg, OBJPROP_XSIZE, 280);
      ObjectSetInteger(0, bg, OBJPROP_YSIZE, 430);
      ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'12,12,16');
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bg, OBJPROP_COLOR, C'120,95,40');
      ObjectSetInteger(0, bg, OBJPROP_BACK, false);
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, bg, OBJPROP_ZORDER, 0);
     }

   string accent = DB_PREFIX + "Accent";
   if(ObjectFind(0, accent) < 0)
     {
      ObjectCreate(0, accent, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, accent, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, accent, OBJPROP_XDISTANCE, InpDashboardX - 10);
      ObjectSetInteger(0, accent, OBJPROP_YDISTANCE, InpDashboardY - 10);
      ObjectSetInteger(0, accent, OBJPROP_XSIZE, 280);
      ObjectSetInteger(0, accent, OBJPROP_YSIZE, 3);
      ObjectSetInteger(0, accent, OBJPROP_BGCOLOR, C'212,175,55');
      ObjectSetInteger(0, accent, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, accent, OBJPROP_COLOR, C'212,175,55');
      ObjectSetInteger(0, accent, OBJPROP_BACK, false);
      ObjectSetInteger(0, accent, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, accent, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, accent, OBJPROP_ZORDER, 1);
     }

   string icon = DB_PREFIX + "Icon";
   if(ObjectFind(0, icon) < 0)
     {
      ObjectCreate(0, icon, OBJ_BITMAP_LABEL, 0, 0, 0);
      ObjectSetInteger(0, icon, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, icon, OBJPROP_XDISTANCE, InpDashboardX - 6);
      ObjectSetInteger(0, icon, OBJPROP_YDISTANCE, InpDashboardY - 6);
      ObjectSetString(0, icon, OBJPROP_BMPFILE, "::Images\\FarhanFX_Icon.bmp");
      ObjectSetInteger(0, icon, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, icon, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, icon, OBJPROP_BACK, false);
      ObjectSetInteger(0, icon, OBJPROP_ZORDER, 2);
     }

   CreateButton("CloseBtn", InpDashboardX, InpDashboardY + 356, 260, 24, "X  CLOSE POSITION", C'120,20,20');
  }

void UpdateDashboard()
  {
   int x = InpDashboardX, lx = InpDashboardX + 2, y = InpDashboardY, lh = 15, lblW = 13;

   DbLabel("Title", x + 70, y, "MTF TREND", clrWhite, 9);
   y += lh;
   DbLabel("TitleBrand", x + 70, y, "FARHAN FX", C'212,175,55', 8);
   y += lh + 15;
   DbLabel("Version", lx, y, EA_BUILD_VERSION, clrGray, 7);
   y += lh + 6;

   bool loginOk = (InpExpectedLogin == 0 || AccountInfoInteger(ACCOUNT_LOGIN) == InpExpectedLogin);
   DbLabel("Login", lx, y, PadRight("Login", lblW) + IntegerToString((int)AccountInfoInteger(ACCOUNT_LOGIN)),
           loginOk ? clrSilver : clrRed, 8);
   y += lh;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyPL = equity - g_dayStartBalance;
   DbLabel("Balance", lx, y, PadRight("Balance", lblW) + "$" + DoubleToString(balance, 2), clrWhite, 8);
   y += lh;
   DbLabel("Equity", lx, y, PadRight("Equity", lblW) + "$" + DoubleToString(equity, 2), clrWhite, 8);
   y += lh;
   DbLabel("DailyPL", lx, y, PadRight("Daily P/L", lblW) + "$" + DoubleToString(dailyPL, 2),
           (dailyPL >= 0 ? clrLime : clrRed), 8);
   y += lh + 6;

   DbDivider("Div1", x, y, 260, C'55,55,65');
   y += 9;

   string alignText = (g_currentAlignment == TREND_BULL) ? "BULL" : (g_currentAlignment == TREND_BEAR) ? "BEAR" : "flat/mixed";
   color alignClr = (g_currentAlignment == TREND_BULL) ? clrLime : (g_currentAlignment == TREND_BEAR) ? clrRed : clrSilver;
   DbLabel("Align", lx, y, PadRight("Ribbon", lblW) + alignText, alignClr, 8);
   y += lh;
   DbLabel("Rsi", lx, y, PadRight("RSI", lblW) + DoubleToString(g_lastRsi, 1), clrSilver, 8);
   y += lh;
   DbLabel("SR", lx, y, PadRight("S/R", lblW) + "R " + DoubleToString(g_lastResistance, 2) + "  S " + DoubleToString(g_lastSupport, 2), clrSilver, 8);
   y += lh + 6;

   DbDivider("Div2", x, y, 260, C'55,55,65');
   y += 9;

   bool hasPosition = (g_posTicket != 0 && PositionSelectByTicket(g_posTicket));
   if(hasPosition)
     {
      long type = PositionGetInteger(POSITION_TYPE);
      bool isBuy = (type == POSITION_TYPE_BUY);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

      DbLabel("PosHdr", lx, y, (isBuy ? "OPEN: BUY" : "OPEN: SELL") + StringFormat("  %.2f lots", vol), C'0,170,220', 8);
      y += lh;
      DbLabel("PosEntry", lx, y, PadRight("Entry", lblW) + DoubleToString(entry, 2), clrWhite, 8);
      y += lh;
      DbLabel("PosSL", lx, y, PadRight("Stop Loss", lblW) + DoubleToString(sl, 2), clrRed, 8);
      y += lh;
      DbLabel("PosPL", lx, y, PadRight("Floating", lblW) + "$" + DoubleToString(profit, 2), (profit >= 0 ? clrLime : clrRed), 8);
      y += lh;

      int nextLevel = -1;
      for(int i = 0; i < 6; i++)
         if(!g_tpTaken[i]) { nextLevel = i; break; }
      string tpText = (nextLevel < 0) ? "all taken" : StringFormat("TP%d %.2f", nextLevel + 1, g_tpLevels[nextLevel]);
      DbLabel("PosTP", lx, y, PadRight("Next Target", lblW) + tpText, C'212,175,55', 8);
      y += lh + 6;
     }
   else
     {
      DbLabel("PosHdr", lx, y, "No open position", clrSilver, 8);
      y += lh + 6;
     }

   DbDivider("Div3", x, y, 260, C'55,55,65');
   y += 9;

   DbLabel("FilterHdr", lx, y, "FILTERS", C'0,170,220', 8);
   y += lh;
   long liveSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   int maxSpread = EffectiveMaxSpreadPoints();
   bool spreadBlocking = (liveSpread > maxSpread);
   DbLabel("Spread", lx, y, PadRight("Spread", lblW) + IntegerToString((int)liveSpread) + " / " + IntegerToString(maxSpread) + (spreadBlocking ? " (blocking)" : ""),
           spreadBlocking ? clrRed : clrSilver, 8);
   y += lh;
   bool dailyHit = DailyLossLimitHit();
   DbLabel("DailyLoss", lx, y, PadRight("Daily Loss", lblW) + (!InpUseDailyLossLimit ? "off" : (dailyHit ? "LIMIT HIT" : "ok")),
           dailyHit ? clrRed : clrSilver, 8);
   y += lh;
   bool streakHit = ConsecutiveLossLimitHit();
   DbLabel("Streak", lx, y, PadRight("Loss Streak", lblW) + IntegerToString(g_consecutiveLosses) + "/" + IntegerToString(InpMaxConsecutiveLosses) + (streakHit ? " (paused)" : ""),
           streakHit ? clrRed : clrSilver, 8);
   y += lh;
   bool licenseOk = LicenseOk();
   DbLabel("License", lx, y, PadRight("License", lblW) + (licenseOk ? "OK" : "INVALID (no new trades)"),
           licenseOk ? clrLime : clrRed, 8);
   y += lh + 10;

   ChartRedraw();
  }
//+------------------------------------------------------------------+
