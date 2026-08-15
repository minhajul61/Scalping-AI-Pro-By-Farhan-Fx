//+------------------------------------------------------------------+
//|                                      GoldDualBasketDCA.mq5        |
//|  XAUUSD M1 dual-basket grid/DCA EA. Simultaneous BUY + SELL       |
//|  baskets (requires a hedging-mode account), each targeting a      |
//|  floating-profit dollar amount, then closing and immediately      |
//|  reopening. On a $-price adverse move past the last leg, adds a   |
//|  martingale DCA leg, capped at a max legs/basket. ATR-spike,      |
//|  higher-timeframe trend, and economic-news filters gate DCA adds. |
//|  No stop-loss anywhere, ever - per explicit, repeated user        |
//|  request (always martingale an against-trend basket until it     |
//|  hits its profit target, no exceptions, no pauses). An account    |
//|  login allow-list guards against the wrong-account incident seen  |
//|  on this user's other bots.                                      |
//|                                                                    |
//|  2026-08-12: simplified per explicit user request. Earlier         |
//|  versions of this EA also had a daily self-tuner, a historical     |
//|  market-regime detector, and a trained ML (ONNX) stuck-basket-     |
//|  risk filter - rule-based/statistical additions layered on top     |
//|  of the core logic below. All three, live-tested, changed          |
//|  behavior in ways the user found harder to predict, and the ML     |
//|  filter specifically sometimes deliberately paused martingale on   |
//|  a risk read - which conflicted with the user's actual             |
//|  requirement (always martingale through against-trend positions    |
//|  until profit, unconditionally). Removed rather than just          |
//|  disabled, so the input list matches exactly what the EA does.     |
//|  See ml\learnings.md in this project for the full history if       |
//|  this is ever revisited.                                          |
//|                                                                    |
//|  See E:\Straddle Ai Buy Sell Pending EA\StraddleAI_EA.mq5 for the  |
//|  anti-pattern this was built to avoid: uniform lot sizing, no     |
//|  per-basket cap, no floating-loss circuit breaker - an unlimited  |
//|  ladder that blew up a demo account.                              |
//+------------------------------------------------------------------+
#property copyright "FarhanFX Algo"
#property version   "1.00"
#property strict
#property description "Dual-basket (buy+sell) grid/DCA EA for XAUUSD M1. Requires a hedging-mode account."

// Bump this on every change that gets deployed anywhere (local or VPS) so the
// dashboard can show at a glance whether a given chart is running the latest
// version - this exact confusion (VPS silently running stale code) came up
// 2026-07-27 and cost a round of guessing from the leg-count alone. Simple
// v1, v2, v3... per explicit request (2026-08-12) - easier to compare at a
// glance than a date-based build string. Starts at v4, not v1 - counting
// the four builds already deployed today under the old date-based scheme
// (2026.08.12.1 through .4) as v1-v4, so this numbering continues from
// the real deployment history instead of resetting it.
#define EA_BUILD_VERSION "v11"

#include <Trade\Trade.mqh>

enum ENUM_BASKET_SIDE
  {
   SIDE_BUY  = 0,
   SIDE_SELL = 1
  };

// Different brokers (and even different account types on the SAME broker,
// e.g. Exness standard vs Exness Cent) quote gold with different point/tick
// scaling - the same real $ spread shows up as a very different raw "points"
// number depending on the symbol's digit precision. Max Spread is measured
// in raw points, so one fixed threshold doesn't travel well across brokers.
// This preset picks a known-good threshold automatically; "Custom" uses
// InpMaxSpreadPoints below directly, for anything not in this list (or if
// the preset's value turns out wrong for a specific account - the market
// changes, brokers change specs).
enum ENUM_BROKER_PRESET
  {
   BROKER_CUSTOM         = 0, // Custom (use Max Spread below)
   BROKER_EXNESS_STANDARD = 1, // Exness (XAUUSD, standard account)
   BROKER_EXNESS_CENT     = 2, // Exness (XAUUSDc, cent account)
   BROKER_CXM              = 3, // CXM Direct (XAUUSDp)
   BROKER_VANTAGE           = 4  // Vantage Markets
  };

input group "=== Account & Basic Settings ==="
input ulong    InpMagicNumber        = 20270115;  // Magic Number
input long     InpExpectedLogin      = 0;         // Account Login (0 = skip check - client sets their own)
input ENUM_BROKER_PRESET InpBrokerPreset = BROKER_CUSTOM; // Broker Preset (auto-sets Max Spread)
input int      InpMaxSpreadPoints    = 300;       // Max Spread (points) - used when Broker Preset = Custom

input group "=== Basket & Profit Target ==="
input double   InpInitialLot            = 0.01;   // Initial Lot Size
input double   InpBasketProfitTargetUSD = 2.0;    // Take Profit ($) - grows each new cycle
input int      InpMaxLegsPerBasket      = 7;      // Max DCA Legs Per Cycle
input int      InpAbsoluteMaxLegsPerBasket = 50;  // Absolute Max Legs (emergency hard limit)
input double   InpCycleTargetGrowth     = 0.5;    // Target Growth Per Cycle (0.5 = +50%)

input group "=== DCA / Martingale ==="
input double   InpDcaDistancePrice  = 1.2;        // DCA Distance ($)
input double   InpLotMultiplier     = 2.0;        // Lot Multiplier

input group "=== Filters ==="
input bool             InpUseAtrSpikeFilter = true;      // Use ATR Spike Filter
input int              InpAtrPeriod         = 14;        // ATR Period
input int              InpAtrBaselineBars   = 20;        // ATR Baseline Bars
input double           InpMaxAtrRatio       = 1.5;       // Max ATR Ratio (spike threshold)
input bool             InpUseTrendFilter    = true;      // Use Trend Filter
input ENUM_TIMEFRAMES  InpTrendTF           = PERIOD_H1; // Trend Timeframe
input int              InpTrendMAPeriod     = 50;        // Trend MA Period
input int              InpTrendAtrPeriod    = 14;        // Trend ATR Period
input double           InpTrendStrengthATRMult = 0.5;    // Trend Strength (x ATR)
input bool             InpUseMultiTFTrend   = false;     // Require Multiple Timeframes To Agree
input ENUM_TIMEFRAMES  InpTrendTF2          = PERIOD_H4; // Second Trend Timeframe
input ENUM_TIMEFRAMES  InpTrendTF3          = PERIOD_D1; // Third Trend Timeframe

input group "=== News Filter ==="
input bool     InpUseNewsFilter       = true;   // Use News Filter (auto calendar - live/demo only)
input string   InpNewsCurrency        = "USD";  // News Currency
input int      InpNewsMinutesBefore   = 30;     // Minutes Before News
input int      InpNewsMinutesAfter    = 30;     // Minutes After News
input bool     InpUseManualNewsWindow = false;  // Also Block A Specific Date/Time
input string   InpManualNewsStart     = "";     // Manual Block Start (yyyy.mm.dd hh:mi)
input string   InpManualNewsEnd       = "";     // Manual Block End (yyyy.mm.dd hh:mi)

input group "=== Daily Profit Target ==="
input bool     InpUseDailyProfitTarget = false; // Stop New Trades After Reaching This Daily Profit
input double   InpDailyProfitTargetUSD = 50.0;  // Daily Profit Target ($) - resumes automatically next day

input group "=== Dashboard ==="
input bool     InpShowDashboard = true;   // Show Dashboard
input int      InpDashboardX    = 10;     // Dashboard X Position
input int      InpDashboardY    = 20;     // Dashboard Y Position
input bool     InpSetWhiteChartTheme = true; // White Chart Theme

CTrade trade;

struct SBasket
  {
   int      legCount;        // all legs: bootstrap + DCA
   double   totalLots;
   double   floatingPL;      // sum of POSITION_PROFIT + POSITION_SWAP across the basket's legs
   double   weightedAvgEntry;
   ulong    lastLegTicket;
   double   lastLegEntry;
   double   lastLegLots;
   datetime lastLegTime;
  };

SBasket g_buyBasket, g_sellBasket;

int g_atrHandle      = INVALID_HANDLE;
int g_trendMAHandle  = INVALID_HANDLE;
int g_trendAtrHandle = INVALID_HANDLE;
int g_trendMAHandle2  = INVALID_HANDLE; // only used if InpUseMultiTFTrend
int g_trendAtrHandle2 = INVALID_HANDLE;
int g_trendMAHandle3  = INVALID_HANDLE;
int g_trendAtrHandle3 = INVALID_HANDLE;

int    g_dayStartDateCode = -1;
double g_dayStartBalance  = 0.0;

#define DB_PREFIX  "GDSE_DB_"

// Switches the chart itself to a white background - the dashboard panel
// below draws its own dark box on top (fixed OBJPROP_BGCOLOR), so it stays
// readable regardless of this setting.
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

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(InpExpectedLogin != 0 && AccountInfoInteger(ACCOUNT_LOGIN) != InpExpectedLogin)
     {
      PrintFormat("GoldDualBasketDCA: connected account %d does not match InpExpectedLogin %d. Refusing to run.",
                  (int)AccountInfoInteger(ACCOUNT_LOGIN), (int)InpExpectedLogin);
      return(INIT_FAILED);
     }

   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Print("GoldDualBasketDCA: account is not in hedging mode. This EA needs simultaneous buy+sell "
            "positions on the same symbol, which a netting account cannot hold. Refusing to run.");
      return(INIT_FAILED);
     }

   if(InpSetWhiteChartTheme)
      ApplyWhiteChartTheme();

   g_atrHandle = iATR(_Symbol, PERIOD_M1, InpAtrPeriod);
   if(g_atrHandle == INVALID_HANDLE)
     {
      Print("GoldDualBasketDCA: ATR handle creation failed.");
      return(INIT_FAILED);
     }

   if(InpUseTrendFilter)
     {
      g_trendMAHandle = iMA(_Symbol, InpTrendTF, InpTrendMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
      if(g_trendMAHandle == INVALID_HANDLE)
        {
         Print("GoldDualBasketDCA: trend MA handle creation failed.");
         return(INIT_FAILED);
        }

      g_trendAtrHandle = iATR(_Symbol, InpTrendTF, InpTrendAtrPeriod);
      if(g_trendAtrHandle == INVALID_HANDLE)
        {
         Print("GoldDualBasketDCA: trend ATR handle creation failed.");
         return(INIT_FAILED);
        }

      if(InpUseMultiTFTrend)
        {
         g_trendMAHandle2  = iMA(_Symbol, InpTrendTF2, InpTrendMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
         g_trendAtrHandle2 = iATR(_Symbol, InpTrendTF2, InpTrendAtrPeriod);
         g_trendMAHandle3  = iMA(_Symbol, InpTrendTF3, InpTrendMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
         g_trendAtrHandle3 = iATR(_Symbol, InpTrendTF3, InpTrendAtrPeriod);
         if(g_trendMAHandle2 == INVALID_HANDLE || g_trendAtrHandle2 == INVALID_HANDLE ||
            g_trendMAHandle3 == INVALID_HANDLE || g_trendAtrHandle3 == INVALID_HANDLE)
           {
            Print("GoldDualBasketDCA: multi-timeframe trend handle creation failed.");
            return(INIT_FAILED);
           }
        }
     }

   UpdateDayTracking();

   // Diagnostic only (does not affect trading) - confirms whether the
   // calendar is actually reachable at all, using a wide 7-day window
   // instead of the live filter's narrow before/after window. Without this,
   // "no news right now" and "calendar access silently broken" both look
   // identical (News: clear) - added 2026-08-13 specifically so this can be
   // verified right after attaching, instead of waiting to line up with a
   // real event's exact 30-min window.
   if(InpUseNewsFilter)
     {
      MqlCalendarValue diag[];
      int diagN = CalendarValueHistory(diag, TimeCurrent() - 7 * 24 * 3600, TimeCurrent() + 7 * 24 * 3600, NULL, InpNewsCurrency);
      if(diagN < 0)
         PrintFormat("GoldDualBasketDCA: news calendar diagnostic FAILED (err=%d) - the News Filter will silently do nothing until this is fixed.",
                     GetLastError());
      else
         PrintFormat("GoldDualBasketDCA: news calendar diagnostic OK - found %d %s event(s) in the past/next 7 days "
                     "(this check alone does not affect trading, it only confirms calendar access works).",
                     diagN, InpNewsCurrency);
     }

   if(InpShowDashboard)
     {
      CreateDashboard();
      EventSetTimer(1);
     }

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   if(g_trendMAHandle != INVALID_HANDLE)
      IndicatorRelease(g_trendMAHandle);
   if(g_trendAtrHandle != INVALID_HANDLE)
      IndicatorRelease(g_trendAtrHandle);
   if(g_trendMAHandle2 != INVALID_HANDLE)
      IndicatorRelease(g_trendMAHandle2);
   if(g_trendAtrHandle2 != INVALID_HANDLE)
      IndicatorRelease(g_trendAtrHandle2);
   if(g_trendMAHandle3 != INVALID_HANDLE)
      IndicatorRelease(g_trendMAHandle3);
   if(g_trendAtrHandle3 != INVALID_HANDLE)
      IndicatorRelease(g_trendAtrHandle3);
   EventKillTimer();
   ObjectsDeleteAll(0, DB_PREFIX);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   if(InpShowDashboard)
      UpdateDashboard();
  }

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id != CHARTEVENT_OBJECT_CLICK)
      return;

   if(sparam == DB_PREFIX + "CloseAllBtn")
     {
      CloseBasket(SIDE_BUY, "manual close all");
      CloseBasket(SIDE_SELL, "manual close all");
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      ChartRedraw();
     }
   else if(sparam == DB_PREFIX + "CloseBuyBtn")
     {
      CloseBasket(SIDE_BUY, "manual close buy basket");
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      ChartRedraw();
     }
   else if(sparam == DB_PREFIX + "CloseSellBtn")
     {
      CloseBasket(SIDE_SELL, "manual close sell basket");
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      ChartRedraw();
     }
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   RefreshBaskets();
   UpdateDayTracking();

   ManageBasketExits(SIDE_BUY);
   ManageBasketExits(SIDE_SELL);

   RefreshBaskets(); // re-scan after any exits this tick before deciding on entries/DCA

   if(SpreadIsAcceptable())
     {
      ManageBasketEntries(SIDE_BUY);
      ManageBasketEntries(SIDE_SELL);
     }

   if(InpShowDashboard)
      UpdateDashboard();
  }

//+------------------------------------------------------------------+
//| Basket scanning - rebuilt fresh every tick, never persisted, so   |
//| an EA/terminal restart mid-cycle reconstructs exact state from    |
//| the server with zero reconciliation logic.                       |
//+------------------------------------------------------------------+
void ResetBasket(SBasket &b)
  {
   b.legCount         = 0;
   b.totalLots        = 0;
   b.floatingPL       = 0;
   b.weightedAvgEntry = 0;
   b.lastLegTicket    = 0;
   b.lastLegEntry     = 0;
   b.lastLegLots      = 0;
   b.lastLegTime      = 0;
  }

void ScanBasket(ENUM_BASKET_SIDE side, SBasket &b)
  {
   ResetBasket(b);
   long wantType = (side == SIDE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   double sumPriceLots = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
         continue;
      if(PositionGetInteger(POSITION_TYPE) != wantType)
         continue;

      double   lots    = PositionGetDouble(POSITION_VOLUME);
      double   entry   = PositionGetDouble(POSITION_PRICE_OPEN);
      double   profit  = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      datetime t       = (datetime)PositionGetInteger(POSITION_TIME);

      b.legCount++;
      b.totalLots  += lots;
      b.floatingPL += profit;
      sumPriceLots += entry * lots;

      if(t >= b.lastLegTime)
        {
         b.lastLegTime   = t;
         b.lastLegEntry  = entry;
         b.lastLegLots   = lots;
         b.lastLegTicket = ticket;
        }
     }

   if(b.totalLots > 0)
      b.weightedAvgEntry = sumPriceLots / b.totalLots;
  }

void RefreshBaskets()
  {
   ScanBasket(SIDE_BUY, g_buyBasket);
   ScanBasket(SIDE_SELL, g_sellBasket);
  }

//+------------------------------------------------------------------+
//| Exits: profit target only - no stop-loss, ever, per explicit      |
//| request.                                                           |
//+------------------------------------------------------------------+
// The target is not a flat number - it scales with how many full DCA cycles
// this basket has already gone through (0 cycles = base target; each
// completed cycle raises it by InpCycleTargetGrowth). A basket that has
// survived several cycles has more capital and more adverse distance
// behind it, so it demands proportionally more profit before it's worth
// closing - this is the "if it martingales, try for more profit" behavior.
double GetProfitTarget(const SBasket &b)
  {
   int completedCycles = (InpMaxLegsPerBasket > 0) ? (b.legCount / InpMaxLegsPerBasket) : 0;
   return InpBasketProfitTargetUSD * (1.0 + completedCycles * InpCycleTargetGrowth);
  }

void ManageBasketExits(ENUM_BASKET_SIDE side)
  {
   SBasket b;
   if(side == SIDE_BUY)
      b = g_buyBasket;
   else
      b = g_sellBasket;

   if(b.legCount == 0)
      return;

   double target = GetProfitTarget(b);
   if(b.floatingPL >= target)
     {
      CloseBasket(side, StringFormat("BASKET TARGET HIT (floatingPL=%.2f >= target=%.2f)", b.floatingPL, target));
      return;
     }
  }

void CloseBasket(ENUM_BASKET_SIDE side, string reason)
  {
   long wantType = (side == SIDE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   int closedCount = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
         continue;
      if(PositionGetInteger(POSITION_TYPE) != wantType)
         continue;

      if(trade.PositionClose(ticket))
         closedCount++;
      else
         PrintFormat("GoldDualBasketDCA: failed to close ticket %d (%s): retcode=%d %s",
                     (int)ticket, reason, trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }

   if(closedCount > 0)
      PrintFormat("GoldDualBasketDCA: %s basket closed (%d leg(s)) - %s",
                  (side == SIDE_BUY ? "BUY" : "SELL"), closedCount, reason);
  }

//+------------------------------------------------------------------+
//| Entries: bootstrap (empty basket) and DCA (adverse move)          |
//+------------------------------------------------------------------+
void ManageBasketEntries(ENUM_BASKET_SIDE side)
  {
   SBasket b;
   if(side == SIDE_BUY)
      b = g_buyBasket;
   else
      b = g_sellBasket;

   if(IsNewsBlackout())
      return; // paused around medium/high-impact news (calendar and/or manual window), both bootstrap and DCA-adds

   if(DailyTargetHit())
      return; // today's profit target already reached - resumes automatically at the next day rollover

   if(b.legCount == 0)
     {
      // Don't even start a basket fighting a strong higher-timeframe trend -
      // the doomed bootstrap entry itself is what runs a basket into trouble,
      // not just the DCA-adds after it.
      if(InpUseTrendFilter && IsAgainstTrend(side))
         return;
      OpenLeg(side, 0, 0);
      return;
     }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   bool adverse;
   if(side == SIDE_BUY)
      adverse = (bid <= b.lastLegEntry - InpDcaDistancePrice);
   else
      adverse = (ask >= b.lastLegEntry + InpDcaDistancePrice);

   if(adverse && b.legCount < InpAbsoluteMaxLegsPerBasket)
     {
      if(InpUseAtrSpikeFilter && IsAtrSpiking())
         return; // "news proxy" - don't average into a volatility spike
      if(InpUseTrendFilter && IsAgainstTrend(side))
         return; // don't keep averaging into a strong opposing higher-timeframe trend

      // Cycling: once a full cycle (InpMaxLegsPerBasket) is used up, the next
      // leg restarts lot sizing from InpInitialLot instead of continuing to
      // compound the multiplier indefinitely - keeps a basket that's been
      // going against for a long time from ever needing an unaffordable lot
      // size, while still letting it keep averaging (unconditionally, no
      // pause) if price keeps moving, per explicit request.
      int legIndexForSizing = b.legCount % InpMaxLegsPerBasket;
      OpenLeg(side, legIndexForSizing, b.lastLegLots);
      return;
     }
  }

double NextLotSize(int legCount, double previousLegLots)
  {
   double raw = InpInitialLot * MathPow(InpLotMultiplier, legCount);

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   double lots = MathRound(raw / lotStep) * lotStep;
   // Rounding can collapse two consecutive legs to the same step (e.g. 1.5x
   // growth on a 0.01 step) - guarantee monotonic martingale growth anyway.
   if(legCount > 0 && lots <= previousLegLots)
      lots = previousLegLots + lotStep;

   lots = MathMax(minLot, MathMin(maxLot, lots));
   return NormalizeDouble(lots, 2);
  }

void OpenLeg(ENUM_BASKET_SIDE side, int legIndexForSizing, double previousLegLots)
  {
   double lots = NextLotSize(legIndexForSizing, previousLegLots);
   if(lots <= 0)
      return;

   double price;
   bool ok;
   string comment = StringFormat("FarhanFx-%s-leg%d", (side == SIDE_BUY ? "buy" : "sell"), legIndexForSizing + 1);

   // No stop-loss on any leg, ever - per explicit, repeated request. Basket
   // exits only happen via the profit target in ManageBasketExits().
   if(side == SIDE_BUY)
     {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      ok    = trade.Buy(lots, _Symbol, price, 0, 0, comment);
     }
   else
     {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      ok    = trade.Sell(lots, _Symbol, price, 0, 0, comment);
     }

   if(!ok)
      PrintFormat("GoldDualBasketDCA: %s leg open failed (lot=%.2f): retcode=%d %s",
                  (side == SIDE_BUY ? "BUY" : "SELL"), lots, trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| DCA filters                                                       |
//+------------------------------------------------------------------+
bool IsAtrSpiking()
  {
   double atrSeries[];
   ArraySetAsSeries(atrSeries, true);
   int n = InpAtrBaselineBars + 1;
   if(CopyBuffer(g_atrHandle, 0, 1, n, atrSeries) < n)
      return false;

   double current = atrSeries[0];
   double sum = 0;
   for(int i = 1; i < n; i++)
      sum += atrSeries[i];
   double baseline = sum / (n - 1);

   if(baseline <= 0)
      return false;

   return(current > baseline * InpMaxAtrRatio);
  }

// Trend on one timeframe via MA + ATR-scaled strength gate: last closed
// candle must sit at least InpTrendStrengthATRMult ATRs away from the MA to
// count as trending (1=up, -1=down); anything closer is treated as noise/
// no-trend (0). A raw close-vs-MA check flips sign on ordinary chop, which
// would block far more entries than intended - the ATR margin only catches
// genuinely sustained, strong moves, which is what actually ran baskets to
// their hard-SL in earlier testing.
int GetTrendOnTF(int maHandle, int atrHandle, ENUM_TIMEFRAMES tf)
  {
   if(maHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
      return 0;

   double maBuf[1], atrBuf[1];
   if(CopyBuffer(maHandle, 0, 1, 1, maBuf) <= 0)
      return 0;
   if(CopyBuffer(atrHandle, 0, 1, 1, atrBuf) <= 0 || atrBuf[0] <= 0)
      return 0;

   double closePrice = iClose(_Symbol, tf, 1);
   double margin = atrBuf[0] * InpTrendStrengthATRMult;

   if(closePrice > maBuf[0] + margin)
      return 1;
   if(closePrice < maBuf[0] - margin)
      return -1;
   return 0;
  }

// InpUseMultiTFTrend requires InpTrendTF + InpTrendTF2 + InpTrendTF3 to all
// agree before calling it a real trend - a single-timeframe read can call
// "trending" on a move that's just noise one level up/down; requiring
// confluence across three timeframes is a stricter, more reliable signal,
// at the cost of blocking (calling flat/0) more often.
int GetTrend()
  {
   if(!InpUseTrendFilter)
      return 0;

   int t1 = GetTrendOnTF(g_trendMAHandle, g_trendAtrHandle, InpTrendTF);
   if(!InpUseMultiTFTrend)
      return t1;

   int t2 = GetTrendOnTF(g_trendMAHandle2, g_trendAtrHandle2, InpTrendTF2);
   int t3 = GetTrendOnTF(g_trendMAHandle3, g_trendAtrHandle3, InpTrendTF3);

   if(t1 == 1 && t2 == 1 && t3 == 1)
      return 1;
   if(t1 == -1 && t2 == -1 && t3 == -1)
      return -1;
   return 0;
  }

bool IsAgainstTrend(ENUM_BASKET_SIDE side)
  {
   int trend = GetTrend();
   if(side == SIDE_BUY)
      return(trend == -1);
   return(trend == 1);
  }

// Uses MT5's built-in economic calendar (no external service needed - the
// terminal syncs it automatically while connected, live/demo only). Blocks
// new trades and DCA-adds from InpNewsMinutesBefore before a medium/high-
// impact InpNewsCurrency event until InpNewsMinutesAfter after it. Does not
// touch already-open positions or profit-target closes - only pauses new
// adds.
// CONFIRMED (2026-08-13, standalone diagnostic script): CalendarValueHistory
// returns err=4014 (ERR_FUNCTION_NOT_ALLOWED) inside the Strategy Tester for
// every date range tried, including dates well within the account's own
// history - this is a genuine MT5 platform restriction on calendar
// functions in the Tester, not a data-availability issue or a bug here.
// This check is real and works live/demo; it cannot be exercised or
// validated via backtesting at all. Use IsManualNewsBlackout() below to
// test "what if trading paused around this specific news window" in the
// Tester instead.
bool IsCalendarNewsBlackout()
  {
   if(!InpUseNewsFilter)
      return false;

   datetime from = TimeCurrent() - InpNewsMinutesAfter * 60;
   datetime to   = TimeCurrent() + InpNewsMinutesBefore * 60;

   MqlCalendarValue values[];
   int n = CalendarValueHistory(values, from, to, NULL, InpNewsCurrency);
   if(n <= 0)
      return false;

   for(int i = 0; i < n; i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev))
         continue;
      if(ev.importance == CALENDAR_IMPORTANCE_MODERATE || ev.importance == CALENDAR_IMPORTANCE_HIGH)
         return true;
     }
   return false;
  }

// A fixed date/time window to also treat as a news blackout, independent of
// the (Tester-unusable) calendar check above. Two real uses: (1) testing
// the effect of avoiding a specific known news event in the Strategy
// Tester, since the calendar can't be exercised there at all; (2) live/
// demo, as a manual belt-and-braces block around a known major release the
// automatic calendar check might miss or mistime.
bool IsManualNewsBlackout()
  {
   if(!InpUseManualNewsWindow || InpManualNewsStart == "" || InpManualNewsEnd == "")
      return false;

   datetime blockStart = StringToTime(InpManualNewsStart);
   datetime blockEnd   = StringToTime(InpManualNewsEnd);
   if(blockStart == 0 || blockEnd == 0 || blockEnd <= blockStart)
      return false;

   datetime now = TimeCurrent();
   return(now >= blockStart && now <= blockEnd);
  }

bool IsNewsBlackout()
  {
   return IsCalendarNewsBlackout() || IsManualNewsBlackout();
  }

//+------------------------------------------------------------------+
//| Spread / daily circuit breaker                                    |
//+------------------------------------------------------------------+
// Verification status of each preset, honestly tracked (2026-08-14):
// - BROKER_EXNESS_STANDARD (300): live-tested all day on a real Exness
//   demo, XAUUSD 3-decimal - real spread observed ~168 points, comfortably
//   under this.
// - BROKER_EXNESS_CENT (5000): live-tested on a real Exness account,
//   XAUUSDc - confirmed working after raising from 300 (which silently
//   blocked every trade).
// - BROKER_CXM (300): NOT independently verified this session - based on
//   a different project's historical measurement (CXM Direct XAUUSDp,
//   2-decimal, ~7 points for a $0.07 spread), suggesting 300 should be
//   generous, not confirmed fresh today.
// - BROKER_VANTAGE (300): NOT verified at all - no real Vantage broker
//   account spread has been measured; this is a placeholder guess pending
//   a real demo account test.
int EffectiveMaxSpreadPoints()
  {
   switch(InpBrokerPreset)
     {
      case BROKER_EXNESS_STANDARD: return 300;
      case BROKER_EXNESS_CENT:     return 5000;
      case BROKER_CXM:             return 300;  // not independently verified this session
      case BROKER_VANTAGE:         return 300;  // not verified at all - placeholder
      default:                     return InpMaxSpreadPoints; // BROKER_CUSTOM
     }
  }

bool SpreadIsAcceptable()
  {
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return(spread <= EffectiveMaxSpreadPoints());
  }

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

// Realized (closed) profit only - today's balance vs balance at today's
// rollover - not floating equity, so this doesn't flicker true/false as
// open baskets' floating P/L wobbles. Once true, stays true for the rest
// of the day (UpdateDayTracking() resets g_dayStartBalance at the next
// day rollover, which is what makes this resume automatically).
bool DailyTargetHit()
  {
   if(!InpUseDailyProfitTarget || g_dayStartBalance <= 0)
      return false;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   return((balance - g_dayStartBalance) >= InpDailyProfitTargetUSD);
  }

//+------------------------------------------------------------------+
//| Dashboard                                                          |
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
      ObjectSetInteger(0, bg, OBJPROP_YSIZE, 490);
      ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'12,12,16');
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bg, OBJPROP_COLOR, C'70,70,80');
      ObjectSetInteger(0, bg, OBJPROP_BACK, false);
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, bg, OBJPROP_ZORDER, 0);
     }

   CreateButton("CloseAllBtn", InpDashboardX, InpDashboardY + 416, 260, 24, "X  CLOSE ALL", C'120,20,20');
   CreateButton("CloseBuyBtn", InpDashboardX, InpDashboardY + 444, 126, 22, "Close BUY", C'20,80,20');
   CreateButton("CloseSellBtn", InpDashboardX + 134, InpDashboardY + 444, 126, 22, "Close SELL", C'20,80,20');
  }

void UpdateDashboard()
  {
   RefreshBaskets();

   int x = InpDashboardX, lx = InpDashboardX + 2, y = InpDashboardY, lh = 15, lblW = 12;

   DbLabel("Title", x, y, "SCALPING AI PRO BY FARHAN FX", clrWhite, 9);
   y += lh;
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
   y += lh;
   bool dailyTargetHit = DailyTargetHit();
   string dailyTargetText = !InpUseDailyProfitTarget ? "off"
                             : dailyTargetHit ? "HIT (paused today)"
                             : "$" + DoubleToString(dailyPL, 2) + " / $" + DoubleToString(InpDailyProfitTargetUSD, 2);
   DbLabel("DailyTarget", lx, y, PadRight("Daily Target", lblW) + dailyTargetText,
           dailyTargetHit ? clrLime : clrSilver, 8);
   y += lh + 6;

   DbDivider("Div1", x, y, 260, C'55,55,65');
   y += 9;

   DbLabel("BuyHdr", lx, y, StringFormat("BUY BASKET  (leg %d/%d, cycle %d)",
           (InpMaxLegsPerBasket > 0 ? g_buyBasket.legCount % InpMaxLegsPerBasket : g_buyBasket.legCount), InpMaxLegsPerBasket,
           (InpMaxLegsPerBasket > 0 ? g_buyBasket.legCount / InpMaxLegsPerBasket + 1 : 1)), C'0,170,220', 8);
   y += lh;
   DbLabel("BuyAvg", lx, y, PadRight("Avg Entry", lblW) + DoubleToString(g_buyBasket.weightedAvgEntry, 2), clrWhite, 8);
   y += lh;
   DbLabel("BuyPL", lx, y, PadRight("Floating", lblW) + "$" + DoubleToString(g_buyBasket.floatingPL, 2),
           (g_buyBasket.floatingPL >= 0 ? clrLime : clrRed), 8);
   y += lh;
   double buyToTarget = GetProfitTarget(g_buyBasket) - g_buyBasket.floatingPL;
   double buyToDca = (g_buyBasket.legCount > 0)
                      ? (SymbolInfoDouble(_Symbol, SYMBOL_BID) - (g_buyBasket.lastLegEntry - InpDcaDistancePrice)) : 0;
   DbLabel("BuyToTarget", lx, y, PadRight("To Target", lblW) + "$" + DoubleToString(buyToTarget, 2), clrSilver, 8);
   y += lh;
   DbLabel("BuyToDca", lx, y, PadRight("To DCA", lblW) + "$" + DoubleToString(buyToDca, 2), clrSilver, 8);
   y += lh + 6;

   DbDivider("Div2", x, y, 260, C'55,55,65');
   y += 9;

   DbLabel("SellHdr", lx, y, StringFormat("SELL BASKET (leg %d/%d, cycle %d)",
           (InpMaxLegsPerBasket > 0 ? g_sellBasket.legCount % InpMaxLegsPerBasket : g_sellBasket.legCount), InpMaxLegsPerBasket,
           (InpMaxLegsPerBasket > 0 ? g_sellBasket.legCount / InpMaxLegsPerBasket + 1 : 1)), C'0,170,220', 8);
   y += lh;
   DbLabel("SellAvg", lx, y, PadRight("Avg Entry", lblW) + DoubleToString(g_sellBasket.weightedAvgEntry, 2), clrWhite, 8);
   y += lh;
   DbLabel("SellPL", lx, y, PadRight("Floating", lblW) + "$" + DoubleToString(g_sellBasket.floatingPL, 2),
           (g_sellBasket.floatingPL >= 0 ? clrLime : clrRed), 8);
   y += lh;
   double sellToTarget = GetProfitTarget(g_sellBasket) - g_sellBasket.floatingPL;
   double sellToDca = (g_sellBasket.legCount > 0)
                       ? ((g_sellBasket.lastLegEntry + InpDcaDistancePrice) - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) : 0;
   DbLabel("SellToTarget", lx, y, PadRight("To Target", lblW) + "$" + DoubleToString(sellToTarget, 2), clrSilver, 8);
   y += lh;
   DbLabel("SellToDca", lx, y, PadRight("To DCA", lblW) + "$" + DoubleToString(sellToDca, 2), clrSilver, 8);
   y += lh + 6;

   DbDivider("Div3", x, y, 260, C'55,55,65');
   y += 9;

   DbLabel("FilterHdr", lx, y, "FILTERS", C'0,170,220', 8);
   y += lh;
   long liveSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   int  maxSpread   = EffectiveMaxSpreadPoints();
   bool spreadBlocking = (liveSpread > maxSpread);
   DbLabel("Spread", lx, y, PadRight("Spread", lblW) + IntegerToString((int)liveSpread) + " / " + IntegerToString(maxSpread) + (spreadBlocking ? " (blocking)" : ""),
           spreadBlocking ? clrRed : clrSilver, 8);
   y += lh;
   bool atrSpiking = InpUseAtrSpikeFilter && IsAtrSpiking();
   DbLabel("AtrSpike", lx, y, PadRight("ATR Spike", lblW) + (InpUseAtrSpikeFilter ? (atrSpiking ? "YES (blocking)" : "no") : "off"),
           atrSpiking ? clrOrange : clrSilver, 8);
   y += lh;
   int trend = GetTrend();
   string trendText = (trend == 1) ? "UP" : (trend == -1) ? "DOWN" : "flat/off";
   DbLabel("Trend", lx, y, PadRight("HTF Trend", lblW) + trendText, clrSilver, 8);
   y += lh;
   bool newsBlackout = IsNewsBlackout();
   bool newsFilterOn = (InpUseNewsFilter || InpUseManualNewsWindow);
   DbLabel("News", lx, y, PadRight("News", lblW) + (newsFilterOn ? (newsBlackout ? "YES (blocking)" : "clear") : "off"),
           newsBlackout ? clrOrange : clrSilver, 8);
   y += lh;
   bool hedgingOk = ((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   DbLabel("Hedging", lx, y, PadRight("Hedging", lblW) + (hedgingOk ? "OK" : "FAIL"), hedgingOk ? clrLime : clrRed, 8);
   y += lh + 10;

   ChartRedraw();
  }
//+------------------------------------------------------------------+
