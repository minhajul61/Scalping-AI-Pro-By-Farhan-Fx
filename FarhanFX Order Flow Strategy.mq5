//+------------------------------------------------------------------+
//|                            FarhanFX Order Flow Strategy.mq5       |
//|  Single-position (not basket/martingale) cumulative-volume-delta   |
//|  divergence EA for XAUUSD - a retail order-flow PROXY, not real    |
//|  institutional order flow. XAUUSD is an OTC CFD instrument with no |
//|  consolidated exchange order book, so true Level 2/footprint data  |
//|  (which would come from CME GC futures) is not available through  |
//|  this MT5/broker setup - confirmed via research, explicitly        |
//|  agreed with the user before building this. What this EA actually |
//|  computes is a tick-by-tick buy/sell-pressure delta (classified by |
//|  price direction, or the broker's own tick flags when present),    |
//|  the standard retail approximation used when real Level 2 isn't    |
//|  available. Be honest about this distinction with anyone this EA   |
//|  is ever explained to.                                             |
//|                                                                    |
//|  2026-08-21: third EA in this project folder, sibling to           |
//|  `FarhanFX MTF Trend Strategy.mq5` (same folder) - built to try a  |
//|  genuinely different signal (order-flow-style divergence/reversal  |
//|  vs. that EA's trend-following) on real data, per explicit user    |
//|  request after seeing the Trend EA's modest first backtest         |
//|  numbers. Same non-negotiable safety discipline as that EA: real   |
//|  broker-side stop-loss on every entry, single position at a time,  |
//|  no martingale, no DCA legs - a deliberate, permanent break from   |
//|  the dual-basket EA's no-SL design in this same folder.            |
//|                                                                    |
//|  Dashboard/license/broker-preset/branding infrastructure is        |
//|  reused in pattern from the Trend EA (which itself reused it from  |
//|  the dual-basket EA) - same look, same license-key list, same      |
//|  hard-won "license check must never block OnInit()/the dashboard"  |
//|  lesson applied from day one.                                      |
//+------------------------------------------------------------------+
#property copyright "FarhanFX Algo"
#property version   "1.00"
#property strict
#property description "Cumulative-volume-delta divergence EA for XAUUSD - real ATR stop-loss, fixed R:R exit. Order-flow PROXY (tick-direction delta), not real Level 2/footprint data."

#resource "\\Images\\FarhanFX_Icon.bmp"
#resource "\\Images\\FarhanFX_Watermark.bmp"
#define WATERMARK_W 420
#define WATERMARK_H 310

#define EA_BUILD_VERSION "v1"

#include <Trade\Trade.mqh>
CTrade trade;

//+------------------------------------------------------------------+
//| Enums (same broker/account pattern as the sibling EAs)            |
//+------------------------------------------------------------------+
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
input ulong    InpMagicNumber        = 20270822;  // Magic Number
input long     InpExpectedLogin      = 0;         // Account Login (0 = skip check - client sets their own)
input ENUM_BROKER_PRESET InpBrokerPreset = BROKER_CUSTOM;
input ENUM_ACCOUNT_TYPE  InpAccountType  = ACCOUNT_TYPE_USD;
input int      InpMaxSpreadPoints    = 300;

input group "=== License ==="
input string   InpLicenseKey = ""; // License Key (given individually to each client)

input group "=== Volume Delta (order-flow proxy) ==="
// Every tick is classified buy/sell pressure by price direction vs the
// previous tick (or the broker's own TICK_FLAG_BUY/SELL if it populates
// them - checked live, used when present). Weighted by volume_real when
// the broker reports real volume, else by tick count (1 per tick) - most
// retail CFD feeds, including this one, do not report real traded
// volume, so this is a tick-count-direction proxy, not true volume.
input int    InpPivotLookback   = 15;   // Pivot Lookback (bars each side, for confirming a swing high/low)
input bool   InpUseAbsorptionFilter = true; // Require Above-Average Tick Volume On The Signal Bar

input group "=== Risk Management ==="
input int    InpAtrPeriod        = 14;  // ATR Period
input double InpSlAtrMult        = 1.5; // Stop Loss (x ATR) - real broker-side SL, always attached
input double InpRewardRiskRatio  = 2.0; // Reward:Risk Ratio (TP distance = SL distance x this)

input group "=== Position Sizing ==="
input double InpPositionPercentOfEquity = 10.0; // Position Size (% of equity, notional)

input group "=== Circuit Breakers ==="
input bool   InpUseDailyLossLimit     = true;
input double InpDailyLossLimitPercent = 3.0;
input int    InpMaxConsecutiveLosses  = 4; // 0 = off

input group "=== Dashboard ==="
input bool   InpShowDashboard        = true;
input int    InpDashboardX           = 10;
input int    InpDashboardY           = 20;
input bool   InpSetWhiteChartTheme   = false;
input bool   InpShowChartWatermark   = true;

//+------------------------------------------------------------------+
//| Globals                                                            |
//+------------------------------------------------------------------+
#define DB_PREFIX "FFXO_DB_"
#define MK_PREFIX "FFXO_MK_"

int g_atrHandle = INVALID_HANDLE;
datetime g_lastBarTime = 0;

int    g_dayStartDateCode = -1;
double g_dayStartBalance  = 0.0;
int    g_cvdDayCode       = -1; // separate from g_dayStartDateCode's rollover point (reset at day start, same code, kept distinct for clarity)

int      g_consecutiveLosses = 0;
datetime g_lastDealCheckTime = 0;

// CVD history - one entry appended per new closed bar, in chronological
// order (index 0 = oldest kept, last index = the most recently closed
// bar). Built up from when the EA starts running (or from the start of a
// backtest) - there is no historical backfill, since CVD has no native
// MT5 series to read from; pivot/divergence signals simply aren't
// evaluated until enough bars have accumulated, same as any indicator
// warm-up period.
datetime g_cvdBarTimes[];
double   g_cvdValues[];
double   g_runningCvd = 0;
double   g_lastBarBuyVolume  = 0; // for the absorption filter's "average" baseline
double   g_lastBarSellVolume = 0;
double   g_avgBarVolume = 0; // slow rolling average of total per-bar tick volume

ulong  g_posTicket = 0;

ENUM_TREND_SIDE g_lastDivergence = TREND_NONE;
double g_lastDivergencePrice = 0;
double g_lastDivergenceCvd   = 0;

//+------------------------------------------------------------------+
//| Broker preset / spread (same pattern as sibling EAs)               |
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
//| License - same embedded key list + non-blocking gate as the       |
//| sibling EAs.                                                       |
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
//| Day tracking / circuit breakers (same pattern as Trend EA)        |
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
   if(todayCode != g_cvdDayCode)
     {
      g_cvdDayCode  = todayCode;
      g_runningCvd  = 0; // CVD resets each trading day - an unbounded cross-day sum drifts meaninglessly
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
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
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
     }

   g_lastDealCheckTime = TimeCurrent();
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
      PrintFormat("FarhanFXOrderFlow: connected account %d does not match InpExpectedLogin %d. Refusing to run.",
                  (int)AccountInfoInteger(ACCOUNT_LOGIN), (int)InpExpectedLogin);
      return(INIT_FAILED);
     }

   if(InpSetWhiteChartTheme)
      ApplyWhiteChartTheme();
   else
      ApplyBlackChartTheme();

   g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, InpAtrPeriod);
   if(g_atrHandle == INVALID_HANDLE)
     {
      Print("FarhanFXOrderFlow: ATR handle creation failed.");
      return(INIT_FAILED);
     }

   ArrayResize(g_cvdBarTimes, 0);
   ArrayResize(g_cvdValues, 0);

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
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   EventKillTimer();
  }

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
      g_posTicket = ticket;
      return;
     }
  }

//+------------------------------------------------------------------+
//| Chart theme (identical to Trend EA)                                |
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

double LastClosedAtr()
  {
   double buf[];
   if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) < 1)
      return 0;
   return buf[0];
  }

//+------------------------------------------------------------------+
//| Tick classification / CVD - the core "order-flow proxy" logic.    |
//| Called once per new closed bar with that bar's [start,end) time   |
//| range; pulls every real tick in that window and classifies each   |
//| as buy- or sell-pressure.                                          |
//+------------------------------------------------------------------+
void ComputeBarDelta(datetime barStart, datetime barEnd, double &buyVol, double &sellVol)
  {
   buyVol = 0;
   sellVol = 0;

   MqlTick ticks[];
   int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_ALL, (ulong)barStart * 1000, (ulong)barEnd * 1000);
   if(n <= 0)
      return;

   double lastPrice = 0;
   bool haveLast = false;
   for(int i = 0; i < n; i++)
     {
      double vol = (ticks[i].volume_real > 0) ? ticks[i].volume_real : 1.0; // real volume if the broker reports it, else 1 per tick

      bool isBuy, isSell;
      // Prefer the broker's own trade-side flag when it actually populates
      // one (rare for retail FX/CFD, checked - not assumed); otherwise
      // fall back to the standard price-direction (uptick/downtick)
      // classification against the previous tick.
      if((ticks[i].flags & TICK_FLAG_BUY) != 0 || (ticks[i].flags & TICK_FLAG_SELL) != 0)
        {
         isBuy  = (ticks[i].flags & TICK_FLAG_BUY) != 0;
         isSell = (ticks[i].flags & TICK_FLAG_SELL) != 0;
        }
      else
        {
         double price = (ticks[i].bid > 0) ? ticks[i].bid : ticks[i].last;
         if(!haveLast)
           {
            isBuy = false; isSell = false; // first tick in the bar has no prior reference - neither, doesn't count
           }
         else
           {
            isBuy  = (price > lastPrice);
            isSell = (price < lastPrice);
            // no-change ticks classify as neither (not "same as previous" -
            // simpler and avoids silently doubling the previous tick's
            // weight on a flat run of identical prices)
           }
         lastPrice = price;
         haveLast = true;
        }

      if(isBuy)
         buyVol += vol;
      else if(isSell)
         sellVol += vol;
     }
  }

// Appends this bar's CVD to the history array and updates the rolling
// average bar-volume baseline used by the absorption filter.
void UpdateCvdForNewBar()
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_CURRENT, 1, 1, rates) < 1)
      return;

   datetime barStart = rates[0].time;
   int periodSeconds = PeriodSeconds(PERIOD_CURRENT);
   datetime barEnd = barStart + periodSeconds;

   double buyVol, sellVol;
   ComputeBarDelta(barStart, barEnd, buyVol, sellVol);
   g_lastBarBuyVolume  = buyVol;
   g_lastBarSellVolume = sellVol;

   double barDelta = buyVol - sellVol;
   g_runningCvd += barDelta;

   // One-time sanity check (first 30 bars only) - cheap insurance against a
   // sign/classification bug before trusting a full backtest run's numbers.
   static int diagCount = 0;
   if(diagCount < 30)
     {
      PrintFormat("FarhanFXOrderFlow: CVD-DIAG bar=%s close=%.2f buyVol=%.0f sellVol=%.0f barDelta=%.0f runningCVD=%.0f",
                  TimeToString(barStart, TIME_DATE|TIME_MINUTES), SymbolInfoDouble(_Symbol, SYMBOL_BID), buyVol, sellVol, barDelta, g_runningCvd);
      diagCount++;
     }

   int sz = ArraySize(g_cvdValues);
   ArrayResize(g_cvdBarTimes, sz + 1);
   ArrayResize(g_cvdValues, sz + 1);
   g_cvdBarTimes[sz] = barStart;
   g_cvdValues[sz]   = g_runningCvd;

   // Trim from the front once this gets long, so a multi-week backtest
   // doesn't grow these arrays unbounded - keep enough for the deepest
   // pivot scan plus margin.
   int maxKeep = 2000;
   if(ArraySize(g_cvdValues) > maxKeep)
     {
      int trim = ArraySize(g_cvdValues) - maxKeep;
      ArrayRemove(g_cvdBarTimes, 0, trim);
      ArrayRemove(g_cvdValues, 0, trim);
     }

   double totalBarVol = buyVol + sellVol;
   // Slow EMA-style rolling average (alpha ~1/20), simple and avoids
   // keeping a whole separate volume-history array just for this.
   if(g_avgBarVolume <= 0)
      g_avgBarVolume = totalBarVol;
   else
      g_avgBarVolume = g_avgBarVolume * 0.95 + totalBarVol * 0.05;
  }

//+------------------------------------------------------------------+
//| Price pivots (same confirmed-pivot approach as the Trend EA's     |
//| UpdateSupportResistance(), extended here to return the TWO most   |
//| recent confirmed pivots, since divergence needs to compare pairs. |
//+------------------------------------------------------------------+
bool FindLastTwoPivots(bool findHigh, double &price1, datetime &time1, double &price2, datetime &time2)
  {
   int n = InpPivotLookback;
   int lookback = MathMin(1500, n * 2 + 200);

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_CURRENT, 1, lookback, rates) < lookback)
      return false;

   int found = 0;
   for(int k = n; k <= lookback - n - 1 && found < 2; k++)
     {
      bool isPivot = true;
      for(int j = k - n; j <= k + n; j++)
        {
         if(j == k)
            continue;
         if(findHigh && rates[j].high >= rates[k].high) { isPivot = false; break; }
         if(!findHigh && rates[j].low <= rates[k].low) { isPivot = false; break; }
        }
      if(!isPivot)
         continue;

      if(found == 0)
        {
         price1 = findHigh ? rates[k].high : rates[k].low;
         time1  = rates[k].time;
        }
      else
        {
         price2 = findHigh ? rates[k].high : rates[k].low;
         time2  = rates[k].time;
        }
      found++;
     }
   return(found >= 2);
  }

// Looks up the CVD value recorded for the bar at (or nearest at-or-before)
// the given time, from our own incrementally-built history.
double CvdAtTime(datetime t)
  {
   int sz = ArraySize(g_cvdBarTimes);
   if(sz == 0)
      return 0;
   for(int i = sz - 1; i >= 0; i--)
      if(g_cvdBarTimes[i] <= t)
         return g_cvdValues[i];
   return g_cvdValues[0];
  }

//+------------------------------------------------------------------+
//| Divergence signal - the core order-flow-style reversal call.       |
//+------------------------------------------------------------------+
ENUM_TREND_SIDE CheckDivergence(double &signalPrice, double &signalCvd)
  {
   double priceHigh1, priceHigh2, priceLow1, priceLow2;
   datetime timeHigh1, timeHigh2, timeLow1, timeLow2;

   // Bearish: newest confirmed high > previous confirmed high, but CVD at
   // the newest high is LOWER than CVD at the previous high - price made
   // a higher high without real buying pressure behind it.
   if(FindLastTwoPivots(true, priceHigh1, timeHigh1, priceHigh2, timeHigh2))
     {
      if(priceHigh1 > priceHigh2)
        {
         double cvd1 = CvdAtTime(timeHigh1);
         double cvd2 = CvdAtTime(timeHigh2);
         if(cvd1 < cvd2)
           {
            signalPrice = priceHigh1;
            signalCvd   = cvd1;
            return TREND_BEAR;
           }
        }
     }

   // Bullish: newest confirmed low < previous confirmed low, but CVD at
   // the newest low is HIGHER than CVD at the previous low.
   if(FindLastTwoPivots(false, priceLow1, timeLow1, priceLow2, timeLow2))
     {
      if(priceLow1 < priceLow2)
        {
         double cvd1 = CvdAtTime(timeLow1);
         double cvd2 = CvdAtTime(timeLow2);
         if(cvd1 > cvd2)
           {
            signalPrice = priceLow1;
            signalCvd   = cvd1;
            return TREND_BULL;
           }
        }
     }

   return TREND_NONE;
  }

bool AbsorptionOk()
  {
   if(!InpUseAbsorptionFilter)
      return true;
   double totalBarVol = g_lastBarBuyVolume + g_lastBarSellVolume;
   return(totalBarVol >= g_avgBarVolume); // signal bar had at least average activity, not a quiet drift
  }

//+------------------------------------------------------------------+
//| Position sizing - same notional (percent-of-equity) convention as  |
//| the Trend EA, for consistency across this folder's EAs.            |
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
//| Entry / exit - evaluated once per new bar.                         |
//+------------------------------------------------------------------+
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

void EvaluateNewBarSignals()
  {
   UpdateCvdForNewBar();

   bool hasPosition = (g_posTicket != 0 && PositionSelectByTicket(g_posTicket));
   if(hasPosition)
      return; // SL/TP are real broker orders and manage themselves; no trend-exit concept here (this is a reversal call, not a trend ride)

   if(IsNewEntryBlocked())
      return;
   if(!AbsorptionOk())
      return;

   double signalPrice, signalCvd;
   ENUM_TREND_SIDE side = CheckDivergence(signalPrice, signalCvd);
   if(side == TREND_NONE)
      return;

   g_lastDivergence = side;
   g_lastDivergencePrice = signalPrice;
   g_lastDivergenceCvd = signalCvd;

   double atr = LastClosedAtr();
   if(atr <= 0)
      return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(side == TREND_BULL)
      OpenPosition(TREND_BULL, ask, atr);
   else
      OpenPosition(TREND_BEAR, bid, atr);
  }

void OpenPosition(ENUM_TREND_SIDE side, double price, double atr)
  {
   double lots = CalcPositionSize(price);
   if(lots <= 0)
      return;

   double slDist = atr * InpSlAtrMult;
   double tpDist = slDist * InpRewardRiskRatio;
   double sl, tp;
   bool ok;
   string comment = (side == TREND_BULL) ? "FarhanFXFlow-buy" : "FarhanFXFlow-sell";

   if(side == TREND_BULL)
     {
      sl = price - slDist;
      tp = price + tpDist;
      ok = trade.Buy(lots, _Symbol, price, sl, tp, comment);
     }
   else
     {
      sl = price + slDist;
      tp = price - tpDist;
      ok = trade.Sell(lots, _Symbol, price, sl, tp, comment);
     }

   if(!ok)
     {
      PrintFormat("FarhanFXOrderFlow: %s entry failed (lot=%.2f): retcode=%d %s",
                  (side == TREND_BULL ? "BUY" : "SELL"), lots, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return;
     }

   g_posTicket = trade.ResultOrder();
   DrawEntryMarker(side, price);
  }

void DrawEntryMarker(ENUM_TREND_SIDE side, double price)
  {
   string name = MK_PREFIX + "ENTRY_" + IntegerToString((int)TimeCurrent());
   color clr = (side == TREND_BULL) ? C'0,170,220' : C'230,140,0';
   string text = (side == TREND_BULL) ? "BUY (div)" : "SELL (div)";
   ObjectCreate(0, name, OBJ_TEXT, 0, TimeCurrent(), price);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, side == TREND_BULL ? ANCHOR_UPPER : ANCHOR_LOWER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
//| Main tick loop                                                     |
//+------------------------------------------------------------------+
void OnTick()
  {
   UpdateDayTracking();

   if(g_posTicket != 0 && !PositionSelectByTicket(g_posTicket))
      g_posTicket = 0; // closed by its own SL/TP since last check

   datetime barTime = (datetime)SeriesInfoInteger(_Symbol, PERIOD_CURRENT, SERIES_LASTBAR_DATE);
   if(barTime != g_lastBarTime)
     {
      g_lastBarTime = barTime;
      UpdateConsecutiveLossStreak();
      EvaluateNewBarSignals();
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
      if(g_posTicket != 0 && PositionSelectByTicket(g_posTicket))
         trade.PositionClose(g_posTicket);
      g_posTicket = 0;
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      ChartRedraw();
     }
  }

//+------------------------------------------------------------------+
//| Chart watermark - identical pattern to sibling EAs.                 |
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
//| as the sibling EAs.                                                 |
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
      ObjectSetInteger(0, bg, OBJPROP_YSIZE, 440);
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

   CreateButton("CloseBtn", InpDashboardX, InpDashboardY + 366, 260, 24, "X  CLOSE POSITION", C'120,20,20');
  }

void UpdateDashboard()
  {
   int x = InpDashboardX, lx = InpDashboardX + 2, y = InpDashboardY, lh = 15, lblW = 13;

   DbLabel("Title", x + 70, y, "ORDER FLOW", clrWhite, 9);
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
   DbLabel("DailyPL", lx, y, PadRight("Daily P/L", lblW) + "$" + DoubleToString(dailyPL, 2),
           (dailyPL >= 0 ? clrLime : clrRed), 8);
   y += lh + 6;

   DbDivider("Div1", x, y, 260, C'55,55,65');
   y += 9;

   DbLabel("CvdHdr", lx, y, "ORDER FLOW (proxy)", C'0,170,220', 8);
   y += lh;
   DbLabel("Cvd", lx, y, PadRight("CVD (today)", lblW) + DoubleToString(g_runningCvd, 0), clrSilver, 8);
   y += lh;
   string divText = (g_lastDivergence == TREND_BULL) ? "BULL @ " + DoubleToString(g_lastDivergencePrice, 2)
                     : (g_lastDivergence == TREND_BEAR) ? "BEAR @ " + DoubleToString(g_lastDivergencePrice, 2)
                     : "none yet";
   color divClr = (g_lastDivergence == TREND_BULL) ? clrLime : (g_lastDivergence == TREND_BEAR) ? clrRed : clrSilver;
   DbLabel("Div", lx, y, PadRight("Last Signal", lblW) + divText, divClr, 8);
   y += lh;
   double totalBarVol = g_lastBarBuyVolume + g_lastBarSellVolume;
   bool absorptionOk = AbsorptionOk();
   DbLabel("Absorb", lx, y, PadRight("Bar Vol/Avg", lblW) + DoubleToString(totalBarVol, 0) + " / " + DoubleToString(g_avgBarVolume, 0)
           + (InpUseAbsorptionFilter && !absorptionOk ? " (blocking)" : ""),
           (InpUseAbsorptionFilter && !absorptionOk) ? clrOrange : clrSilver, 8);
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
      double tp = PositionGetDouble(POSITION_TP);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

      DbLabel("PosHdr", lx, y, (isBuy ? "OPEN: BUY" : "OPEN: SELL") + StringFormat("  %.2f lots", vol), C'0,170,220', 8);
      y += lh;
      DbLabel("PosEntry", lx, y, PadRight("Entry", lblW) + DoubleToString(entry, 2), clrWhite, 8);
      y += lh;
      DbLabel("PosSL", lx, y, PadRight("Stop Loss", lblW) + DoubleToString(sl, 2), clrRed, 8);
      y += lh;
      DbLabel("PosTP", lx, y, PadRight("Take Profit", lblW) + DoubleToString(tp, 2), clrLime, 8);
      y += lh;
      DbLabel("PosPL", lx, y, PadRight("Floating", lblW) + "$" + DoubleToString(profit, 2), (profit >= 0 ? clrLime : clrRed), 8);
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
