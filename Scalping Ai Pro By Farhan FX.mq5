//+------------------------------------------------------------------+
//|                                      GoldDualBasketDCA.mq5        |
//|  XAUUSD M1 dual-basket grid/DCA EA. Simultaneous BUY + SELL       |
//|  baskets (requires a hedging-mode account), each targeting a      |
//|  floating-profit dollar amount, then closing and immediately      |
//|  reopening. On a $-price adverse move past the last leg, adds a   |
//|  martingale DCA leg, capped at a max legs/basket. ATR-spike       |
//|  ("news proxy") + higher-timeframe trend filters gate DCA adds.   |
//|  Basket-level hard stop-loss (with reopen cooldown) and an        |
//|  account login allow-list guard against the wrong-account         |
//|  incident seen on this user's other bots - both OFF by default,   |
//|  per explicit user request (no SL, always martingale against-     |
//|  trend positions until profit, no exceptions).                    |
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
// build - this exact confusion (VPS silently running stale code) came up
// 2026-07-27 and cost a round of guessing from the leg-count alone.
#define EA_BUILD_VERSION "2026.08.12.1"

#include <Trade\Trade.mqh>

enum ENUM_BASKET_SIDE
  {
   SIDE_BUY  = 0,
   SIDE_SELL = 1
  };

input group "=== Account & Basic Settings ==="
input ulong    InpMagicNumber        = 20270115;  // EA-r ID number - change korar dorkar nai
input long     InpExpectedLogin      = 416045126; // Tomar account number - na mille EA cholbe na (0 dile check off)
input int      InpMaxSpreadPoints    = 300;       // Spread eto point-er beshi hole notun trade nibe na

input group "=== Basket O Profit Target ==="
input double   InpInitialLot            = 0.02;   // Prothom trade koto lot-er
input double   InpBasketProfitTargetUSD = 2.0;    // Eto dollar profit hole basket close hobe (cycle barle target-o barbe)
input int      InpMaxLegsPerBasket      = 7;      // Eto DCA trade porjonto nibe, tarpor notun cycle shuru hobe (lot abar choto theke)
input int      InpAbsoluteMaxLegsPerBasket = 50;  // Emergency hard limit - eto beshi kokhono normally lagbe na
input double   InpCycleTargetGrowth     = 0.5;    // Protibar notun cycle shuru hole target koto % barbe (0.5 = +50%)

input group "=== DCA / Martingale (Against Gele) ==="
input double   InpDcaDistancePrice  = 3.0;        // Price koto dollar against gele porer DCA trade hobe
input double   InpLotMultiplier     = 2.0;        // Protibar lot koto gun barbe (2.0 = protibar dwigun)

input group "=== Filter (Kokhon DCA Add Korbe Na) ==="
input bool             InpUseAtrSpikeFilter = true;      // Hothat boro spike (news-er moto move) hole DCA add korbe na
input int              InpAtrPeriod         = 14;        // Volatility mapar candle shonkha
input int              InpAtrBaselineBars   = 20;        // "Normal" volatility bujhte koyta candle dekhbe
input double           InpMaxAtrRatio       = 1.5;       // Normal-er koto gun beshi hole "spike" bole dhorbe
input bool             InpUseTrendFilter    = true;      // Boro trend-er ULTO dike DCA add korbe na - sob shomoy trend-e trade
input ENUM_TIMEFRAMES  InpTrendTF           = PERIOD_H1; // Trend bujhte kon timeframe dekhbe
input int              InpTrendMAPeriod     = 50;        // Trend line-er length
input int              InpTrendAtrPeriod    = 14;        // Trend koto strong seta mapar volatility period
input double           InpTrendStrengthATRMult = 0.5;    // Trend koto strong hole "real trend" bole dhorbe

input group "=== Safety (Tomar Request-e Ekhon Sob OFF) ==="
input double   InpBasketMaxLossUSD        = 0.0;   // Basket SL - 0 mane bondho
input int      InpBasketSLCooldownMinutes = 0;     // SL hit hole abar shuru korar age koto minute wait
input bool     InpUseCatastrophicSL       = false; // Emergency backup SL - bondho, tumi bolechile SL lagbe na
input double   InpCatastrophicSLMultiple  = 2.0;   // (upore-r ta ON thakle koto dure emergency SL boshbe)
input bool     InpUseDailyLimit         = false;  // Daily loss limit - bondho
input double   InpDailyMaxLossPercent   = 0.0;    // (upore-r ta ON thakle koto % loss-e daily stop hobe)
input bool     InpDailyLimitForceCloses = true;   // (upore-r ta ON thakle open trade-o close kore debe kina)

input group "=== Dashboard ==="
input bool     InpShowDashboard = true;   // Chart-e info panel dekhabe kina
input int      InpDashboardX    = 10;     // Panel-er position - left theke koto dure
input int      InpDashboardY    = 20;     // Panel-er position - upor theke koto dure
input bool     InpSetWhiteChartTheme = true; // Chart background shada kore debe

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

int    g_dayStartDateCode = -1;
double g_dayStartBalance  = 0.0;

datetime g_cooldownUntil[2] = {0, 0}; // indexed by ENUM_BASKET_SIDE

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
     }

   UpdateDayTracking();

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

   bool dailyHalt = (InpUseDailyLimit && DailyLimitHit());

   if(!dailyHalt && SpreadIsAcceptable())
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
//| Exits: profit target and basket-level hard stop-loss              |
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

   if(InpBasketMaxLossUSD > 0 && b.floatingPL <= -InpBasketMaxLossUSD)
     {
      CloseBasket(side, StringFormat("BASKET SL HIT (floatingPL=%.2f <= -%.2f)", b.floatingPL, InpBasketMaxLossUSD));
      g_cooldownUntil[side] = TimeCurrent() + InpBasketSLCooldownMinutes * 60;
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

   if(TimeCurrent() < g_cooldownUntil[side])
      return;

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

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double backstopDist = InpUseCatastrophicSL
                          ? InpDcaDistancePrice * (InpMaxLegsPerBasket + InpCatastrophicSLMultiple)
                          : 0;

   double price, sl;
   bool ok;
   string comment = StringFormat("FarhanFx-%s-leg%d", (side == SIDE_BUY ? "buy" : "sell"), legIndexForSizing + 1);

   if(side == SIDE_BUY)
     {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl    = (backstopDist > 0) ? NormalizeDouble(price - backstopDist, digits) : 0;
      ok    = trade.Buy(lots, _Symbol, price, sl, 0, comment);
     }
   else
     {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl    = (backstopDist > 0) ? NormalizeDouble(price + backstopDist, digits) : 0;
      ok    = trade.Sell(lots, _Symbol, price, sl, 0, comment);
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

// Trend on InpTrendTF via MA + ATR-scaled strength gate: last closed candle
// must sit at least InpTrendStrengthATRMult ATRs away from the MA to count
// as trending (1=up, -1=down); anything closer is treated as noise/no-trend
// (0). A raw close-vs-MA check flips sign on ordinary chop, which would
// block far more entries than intended - the ATR margin only catches
// genuinely sustained, strong moves, which is what actually ran baskets to
// their hard-SL in earlier testing.
int GetTrend()
  {
   if(!InpUseTrendFilter || g_trendMAHandle == INVALID_HANDLE || g_trendAtrHandle == INVALID_HANDLE)
      return 0;

   double maBuf[1], atrBuf[1];
   if(CopyBuffer(g_trendMAHandle, 0, 1, 1, maBuf) <= 0)
      return 0;
   if(CopyBuffer(g_trendAtrHandle, 0, 1, 1, atrBuf) <= 0 || atrBuf[0] <= 0)
      return 0;

   double closePrice = iClose(_Symbol, InpTrendTF, 1);
   double margin = atrBuf[0] * InpTrendStrengthATRMult;

   if(closePrice > maBuf[0] + margin)
      return 1;
   if(closePrice < maBuf[0] - margin)
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

//+------------------------------------------------------------------+
//| Spread / daily circuit breaker                                    |
//+------------------------------------------------------------------+
bool SpreadIsAcceptable()
  {
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return(spread <= InpMaxSpreadPoints);
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

bool DailyLimitHit()
  {
   if(g_dayStartBalance <= 0)
      return false;

   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double changePct  = (equity - g_dayStartBalance) / g_dayStartBalance * 100.0;
   bool   hit        = (changePct <= -InpDailyMaxLossPercent);

   if(hit && InpDailyLimitForceCloses)
     {
      CloseBasket(SIDE_BUY, "daily loss limit force-close");
      CloseBasket(SIDE_SELL, "daily loss limit force-close");
     }

   return hit;
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
      ObjectSetInteger(0, bg, OBJPROP_YSIZE, 445);
      ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'12,12,16');
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bg, OBJPROP_COLOR, C'70,70,80');
      ObjectSetInteger(0, bg, OBJPROP_BACK, false);
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, bg, OBJPROP_ZORDER, 0);
     }

   CreateButton("CloseAllBtn", InpDashboardX, InpDashboardY + 371, 260, 24, "X  CLOSE ALL", C'120,20,20');
   CreateButton("CloseBuyBtn", InpDashboardX, InpDashboardY + 399, 126, 22, "Close BUY", C'20,80,20');
   CreateButton("CloseSellBtn", InpDashboardX + 134, InpDashboardY + 399, 126, 22, "Close SELL", C'20,80,20');
  }

void UpdateDashboard()
  {
   RefreshBaskets();

   int x = InpDashboardX, lx = InpDashboardX + 2, y = InpDashboardY, lh = 15, lblW = 12;

   DbLabel("Title", x, y, "SCALPING AI PRO BY FARHAN FX", clrWhite, 9);
   y += lh;
   DbLabel("Version", lx, y, "Build " + EA_BUILD_VERSION, clrGray, 7);
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
   bool atrSpiking = InpUseAtrSpikeFilter && IsAtrSpiking();
   DbLabel("AtrSpike", lx, y, PadRight("ATR Spike", lblW) + (InpUseAtrSpikeFilter ? (atrSpiking ? "YES (blocking)" : "no") : "off"),
           atrSpiking ? clrOrange : clrSilver, 8);
   y += lh;
   int trend = GetTrend();
   string trendText = (trend == 1) ? "UP" : (trend == -1) ? "DOWN" : "flat/off";
   DbLabel("Trend", lx, y, PadRight("HTF Trend", lblW) + trendText, clrSilver, 8);
   y += lh;
   bool hedgingOk = ((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   DbLabel("Hedging", lx, y, PadRight("Hedging", lblW) + (hedgingOk ? "OK" : "FAIL"), hedgingOk ? clrLime : clrRed, 8);
   y += lh + 10;

   ChartRedraw();
  }
//+------------------------------------------------------------------+
