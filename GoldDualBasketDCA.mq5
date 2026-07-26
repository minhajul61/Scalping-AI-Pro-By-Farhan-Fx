//+------------------------------------------------------------------+
//|                                      GoldDualBasketDCA.mq5        |
//|  XAUUSD M1 dual-basket grid/DCA EA. Simultaneous BUY + SELL       |
//|  baskets (requires a hedging-mode account), each targeting a      |
//|  floating-profit dollar amount, then closing and immediately      |
//|  reopening. On a $-price adverse move past the last leg, adds a   |
//|  martingale DCA leg, capped at a max legs/basket. ATR-spike       |
//|  ("news proxy") + higher-timeframe trend filters gate DCA adds.   |
//|  Basket-level hard stop-loss (with reopen cooldown), daily        |
//|  circuit breaker, and an account login allow-list guard against   |
//|  the wrong-account incident seen on this user's other bots.       |
//|                                                                    |
//|  Rule-based daily self-tuner ("AI brain" - no ML libraries exist  |
//|  in native MQL5): once per new day, reviews yesterday's closed    |
//|  trades and nudges DCA distance / lot multiplier / profit target  |
//|  within safe bounds. Conservative by design - it only ever widens |
//|  distance / lowers multiplier on trouble signals, never tightens  |
//|  risk just because a good day happened.                          |
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

#include <Trade\Trade.mqh>

enum ENUM_BASKET_SIDE
  {
   SIDE_BUY  = 0,
   SIDE_SELL = 1
  };

input group "=== Trade Settings ==="
input ulong    InpMagicNumber        = 20270115;  // Magic number (unique per EA/account)
input long     InpExpectedLogin      = 416045126; // Expected account login (0 = skip check)
input int      InpMaxSpreadPoints    = 300;       // Skip new entries if spread exceeds this (XAUUSD real spread on this
                                                   // Exness demo runs ~150-200 points at point=0.001 - the original 50
                                                   // default blocked every single entry, including the bootstrap leg,
                                                   // for the entire backtest. Confirmed via a real-tick visual test
                                                   // that showed 0 trades over a full week before this fix.

input group "=== Basket Core ==="
// InpInitialLot raised from 0.01: at the broker's 0.01 volume step, a 1.5x/1.3x
// multiplier applied to a 0.01 base lot rounds to the same +0.01-per-leg
// sequence regardless of the multiplier value (confirmed by direct calculation
// - legs 1-5 were IDENTICAL for 1.2x/1.3x/1.5x). The multiplier only starts to
// actually differentiate lot sizes once the base lot is large enough that a
// fractional multiple exceeds one volume step - hence 0.05 here. This also
// means running this EA meaningfully now needs a bigger account: the 5-leg
// worst-case (straight-line adverse, no bounce) floating loss at these
// settings is about -$195 (see InpBasketMaxLossUSD below), which needs a
// multi-thousand-dollar account to represent a sane risk fraction, not the
// $100 demo this was first tested on.
input double   InpInitialLot            = 0.05;   // Starting lot size per basket
input double   InpBasketProfitTargetUSD = 1.0;    // Close whole basket once floating profit reaches this ($)
input int      InpMaxLegsPerBasket      = 5;      // Hard cap on DCA legs per basket

input group "=== DCA / Martingale ==="
input double   InpDcaDistancePrice  = 3.0;        // Adverse move ($ price) past last leg before adding a DCA leg
input double   InpLotMultiplier     = 1.3;        // Martingale multiplier per DCA leg

input group "=== DCA Filters (volatility-spike \"news proxy\" + trend) ==="
input bool             InpUseAtrSpikeFilter = true;      // Skip DCA adds during a volatility spike (news proxy)
input int              InpAtrPeriod         = 14;        // ATR period (M1)
input int              InpAtrBaselineBars   = 20;         // Bars averaged to build the ATR baseline
input double           InpMaxAtrRatio       = 1.5;        // Current ATR must be <= baseline * this to allow a DCA add
input bool             InpUseTrendFilter    = true;       // Skip DCA adds fighting a strong higher-timeframe trend
input ENUM_TIMEFRAMES  InpTrendTF           = PERIOD_H1;  // Timeframe for the trend filter
input int              InpTrendMAPeriod     = 50;         // MA period for the trend filter

input group "=== Basket Safety ==="
// Sized to comfortably exceed the leg-5 worst-case (straight-line adverse,
// no bounce) floating loss of about -$195 at InpInitialLot=0.05/1.3x/5legs/
// $3 distance - see InpInitialLot comment above. Without this margin, the
// hard stop would fire before the last leg(s) ever got real room to work,
// same problem the original $15 default had at the smaller lot scale.
input double   InpBasketMaxLossUSD        = 220.0; // Force-close a basket if its floating loss reaches this ($)
input int      InpBasketSLCooldownMinutes = 30;    // Minutes to wait before reopening a basket after a hard-SL close
input bool     InpUseCatastrophicSL       = true;  // Attach a wide backstop SL to every leg (dead-man's switch)
input double   InpCatastrophicSLMultiple  = 2.0;   // Backstop SL = DcaDistance * (MaxLegs + this), beyond entry

input group "=== Daily Circuit Breaker ==="
input bool     InpUseDailyLimit         = true;   // Stop new entries past the daily loss limit
input double   InpDailyMaxLossPercent   = 2.0;    // Max daily loss (% of day-start balance)
input bool     InpDailyLimitForceCloses = true;   // Also force-close both baskets (not just halt new entries) on breach

input group "=== Self-Tuning AI Brain (rule-based, not ML) ==="
input bool     InpEnableSelfTuning = true;   // Daily parameter self-tuning from yesterday's trade history
input double   InpDcaDistanceMin   = 2.0;
input double   InpDcaDistanceMax   = 6.0;
input double   InpLotMultiplierMin = 1.2;
input double   InpLotMultiplierMax = 1.8;
input double   InpProfitTargetMin  = 0.5;
input double   InpProfitTargetMax  = 3.0;
input bool     InpResetTunedParams = false; // Wipe tuned values back to Inp* defaults on next init

input group "=== Dashboard ==="
input bool     InpShowDashboard = true;
input int      InpDashboardX    = 10;
input int      InpDashboardY    = 20;

CTrade trade;

struct SBasket
  {
   int      legCount;
   double   totalLots;
   double   floatingPL;      // sum of POSITION_PROFIT + POSITION_SWAP across the basket's legs
   double   weightedAvgEntry;
   ulong    lastLegTicket;
   double   lastLegEntry;
   double   lastLegLots;
   datetime lastLegTime;
  };

SBasket g_buyBasket, g_sellBasket;

int g_atrHandle     = INVALID_HANDLE;
int g_trendMAHandle = INVALID_HANDLE;

int    g_dayStartDateCode = -1;
double g_dayStartBalance  = 0.0;

datetime g_cooldownUntil[2] = {0, 0}; // indexed by ENUM_BASKET_SIDE

double g_tunedDcaDistance;
double g_tunedLotMultiplier;
double g_tunedProfitTarget;
int    g_lastTuneDateCode = -1;

#define GV_PREFIX  "GDSE_"
#define DB_PREFIX  "GDSE_DB_"

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
     }

   LoadTunedParams();
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
   MaybeRunDailySelfTune();

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

      double   lots   = PositionGetDouble(POSITION_VOLUME);
      double   entry  = PositionGetDouble(POSITION_PRICE_OPEN);
      double   profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      datetime t      = (datetime)PositionGetInteger(POSITION_TIME);

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
void ManageBasketExits(ENUM_BASKET_SIDE side)
  {
   SBasket b;
   if(side == SIDE_BUY)
      b = g_buyBasket;
   else
      b = g_sellBasket;

   if(b.legCount == 0)
      return;

   if(b.floatingPL >= g_tunedProfitTarget)
     {
      CloseBasket(side, StringFormat("BASKET TARGET HIT (floatingPL=%.2f >= target=%.2f)", b.floatingPL, g_tunedProfitTarget));
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
      OpenLeg(side, 0, 0);
      return;
     }

   if(b.legCount >= InpMaxLegsPerBasket)
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   bool adverse;
   if(side == SIDE_BUY)
      adverse = (bid <= b.lastLegEntry - g_tunedDcaDistance);
   else
      adverse = (ask >= b.lastLegEntry + g_tunedDcaDistance);

   if(!adverse)
      return;

   if(InpUseAtrSpikeFilter && IsAtrSpiking())
      return; // "news proxy" - don't average into a volatility spike

   if(InpUseTrendFilter && IsAgainstTrend(side))
      return; // don't keep averaging into a strong opposing higher-timeframe trend

   OpenLeg(side, b.legCount, b.lastLegLots);
  }

double NextLotSize(int legCount, double previousLegLots)
  {
   double raw = InpInitialLot * MathPow(g_tunedLotMultiplier, legCount);

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
                          ? g_tunedDcaDistance * (InpMaxLegsPerBasket + InpCatastrophicSLMultiple)
                          : 0;

   double price, sl;
   bool ok;
   string comment = StringFormat("GDSE-%s-leg%d", (side == SIDE_BUY ? "buy" : "sell"), legIndexForSizing + 1);

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

// Trend on InpTrendTF via a simple MA: last closed candle above the MA = uptrend
// (1), below = downtrend (-1), unavailable/filter off = 0.
int GetTrend()
  {
   if(!InpUseTrendFilter || g_trendMAHandle == INVALID_HANDLE)
      return 0;

   double maBuf[1];
   if(CopyBuffer(g_trendMAHandle, 0, 1, 1, maBuf) <= 0)
      return 0;

   double closePrice = iClose(_Symbol, InpTrendTF, 1);
   if(closePrice > maBuf[0])
      return 1;
   if(closePrice < maBuf[0])
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
//| Self-tuning "AI brain" - rule-based, bounded, conservative daily   |
//| nudges from yesterday's closed-trade history. No ML libraries      |
//| exist in native MQL5, so this is a deliberate, auditable heuristic |
//| rather than a trained model - confirmed acceptable with the user.  |
//+------------------------------------------------------------------+
string GVName(string paramName)
  {
   return GV_PREFIX + IntegerToString((long)InpMagicNumber) + "_" + paramName;
  }

void LoadTunedParams()
  {
   if(InpResetTunedParams)
     {
      GlobalVariableDel(GVName("DcaDistance"));
      GlobalVariableDel(GVName("LotMultiplier"));
      GlobalVariableDel(GVName("ProfitTarget"));
      GlobalVariableDel(GVName("LastTuneDate"));
     }

   g_tunedDcaDistance   = GlobalVariableCheck(GVName("DcaDistance"))
                          ? GlobalVariableGet(GVName("DcaDistance")) : InpDcaDistancePrice;
   g_tunedLotMultiplier = GlobalVariableCheck(GVName("LotMultiplier"))
                          ? GlobalVariableGet(GVName("LotMultiplier")) : InpLotMultiplier;
   g_tunedProfitTarget  = GlobalVariableCheck(GVName("ProfitTarget"))
                          ? GlobalVariableGet(GVName("ProfitTarget")) : InpBasketProfitTargetUSD;
   g_lastTuneDateCode   = GlobalVariableCheck(GVName("LastTuneDate"))
                          ? (int)GlobalVariableGet(GVName("LastTuneDate")) : -1;
  }

void SaveTunedParams()
  {
   GlobalVariableSet(GVName("DcaDistance"), g_tunedDcaDistance);
   GlobalVariableSet(GVName("LotMultiplier"), g_tunedLotMultiplier);
   GlobalVariableSet(GVName("ProfitTarget"), g_tunedProfitTarget);
   GlobalVariableSet(GVName("LastTuneDate"), g_lastTuneDateCode);
  }

void WriteTuningLog(string msg)
  {
   int handle = FileOpen("GoldDualBasketDCA_tuning_log.txt", FILE_READ | FILE_WRITE | FILE_TXT | FILE_SHARE_READ | FILE_ANSI);
   if(handle == INVALID_HANDLE)
     {
      Print("GoldDualBasketDCA: failed to open tuning log file.");
      return;
     }
   FileSeek(handle, 0, SEEK_END);
   FileWriteString(handle, TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES) + " - " + msg + "\r\n");
   FileClose(handle);
  }

void MaybeRunDailySelfTune()
  {
   if(!InpEnableSelfTuning)
      return;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int todayCode = dt.year * 10000 + dt.mon * 100 + dt.day;

   if(todayCode == g_lastTuneDateCode)
      return; // already tuned today

   datetime todayStart     = StringToTime(StringFormat("%04d.%02d.%02d 00:00:00", dt.year, dt.mon, dt.day));
   datetime yesterdayStart = todayStart - 24 * 60 * 60;

   RunDailySelfTune(yesterdayStart, todayStart);

   g_lastTuneDateCode = todayCode;
   SaveTunedParams();
  }

// Groups yesterday's closing deals into basket-close "cycles" (consecutive
// same-direction closing deals within ~2 seconds belong to one CloseBasket()
// call), then applies small, bounded, conservative nudges. Biased toward
// de-risking: widening distance / lowering multiplier needs real trouble
// evidence; nothing here ever tightens risk just because a day went well.
void RunDailySelfTune(datetime fromTime, datetime toTime)
  {
   if(!HistorySelect(fromTime, toTime))
     {
      Print("GoldDualBasketDCA: self-tune - HistorySelect failed for yesterday's range.");
      return;
     }

   int total = HistoryDealsTotal();
   ulong    dealTickets[];
   datetime dealTimes[];
   double   dealProfits[];
   long     dealTypes[];
   ArrayResize(dealTickets, total);
   ArrayResize(dealTimes, total);
   ArrayResize(dealProfits, total);
   ArrayResize(dealTypes, total);

   int n = 0;
   for(int i = 0; i < total; i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol)
         continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != (long)InpMagicNumber)
         continue;
      if((int)HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;

      dealTickets[n] = ticket;
      dealTimes[n]   = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
      dealProfits[n] = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                       + HistoryDealGetDouble(ticket, DEAL_SWAP)
                       + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      dealTypes[n]   = HistoryDealGetInteger(ticket, DEAL_TYPE);
      n++;
     }

   int    maxedTotal = 0, maxedAndLost = 0, cycleCount = 0, targetHitCount = 0;
   double totalTargetGapSum = 0;

   int idx = 0;
   while(idx < n)
     {
      int    j         = idx;
      double sumProfit = dealProfits[idx];
      int    legs      = 1;
      while(j + 1 < n && dealTypes[j + 1] == dealTypes[idx] && (dealTimes[j + 1] - dealTimes[j]) <= 2)
        {
         j++;
         sumProfit += dealProfits[j];
         legs++;
        }

      cycleCount++;
      if(legs >= InpMaxLegsPerBasket)
        {
         maxedTotal++;
         if(sumProfit < 0)
            maxedAndLost++;
        }
      if(sumProfit >= 0 && sumProfit < g_tunedProfitTarget * 1.5)
        {
         targetHitCount++;
         totalTargetGapSum += (sumProfit - g_tunedProfitTarget);
        }

      idx = j + 1;
     }

   double oldDist = g_tunedDcaDistance, oldMult = g_tunedLotMultiplier, oldTarget = g_tunedProfitTarget;
   bool changed = false;

   if(maxedTotal > 0 && maxedAndLost >= MathMax(1, maxedTotal / 2))
     {
      g_tunedDcaDistance   = MathMin(InpDcaDistanceMax, g_tunedDcaDistance + 0.20);
      g_tunedLotMultiplier = MathMax(InpLotMultiplierMin, g_tunedLotMultiplier - 0.05);
      changed = true;
     }

   if(cycleCount >= 20 && targetHitCount > 0 && (totalTargetGapSum / targetHitCount) < 0.05)
     {
      g_tunedProfitTarget = MathMin(InpProfitTargetMax, g_tunedProfitTarget + 0.20);
      changed = true;
     }

   string logMsg = StringFormat("Self-tune %s: cycles=%d maxedTotal=%d maxedAndLost=%d targetHits=%d | "
                                 "DcaDistance %.2f->%.2f LotMultiplier %.2f->%.2f ProfitTarget %.2f->%.2f%s",
                                 TimeToString(fromTime, TIME_DATE), cycleCount, maxedTotal, maxedAndLost, targetHitCount,
                                 oldDist, g_tunedDcaDistance, oldMult, g_tunedLotMultiplier, oldTarget, g_tunedProfitTarget,
                                 changed ? "" : " | no change (no clear trouble signal)");

   Print("GoldDualBasketDCA: " + logMsg);
   WriteTuningLog(logMsg);
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
      ObjectSetInteger(0, bg, OBJPROP_YSIZE, 430);
      ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'12,12,16');
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bg, OBJPROP_COLOR, C'70,70,80');
      ObjectSetInteger(0, bg, OBJPROP_BACK, false);
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, bg, OBJPROP_ZORDER, 0);
     }

   CreateButton("CloseAllBtn", InpDashboardX, InpDashboardY + 360, 260, 24, "X  CLOSE ALL", C'120,20,20');
   CreateButton("CloseBuyBtn", InpDashboardX, InpDashboardY + 388, 126, 22, "Close BUY", C'20,80,20');
   CreateButton("CloseSellBtn", InpDashboardX + 134, InpDashboardY + 388, 126, 22, "Close SELL", C'20,80,20');
  }

void UpdateDashboard()
  {
   RefreshBaskets();

   int x = InpDashboardX, lx = InpDashboardX + 2, y = InpDashboardY, lh = 15, lblW = 12;

   DbLabel("Title", x, y, "GOLD DUAL BASKET DCA", clrWhite, 9);
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

   DbLabel("BuyHdr", lx, y, StringFormat("BUY BASKET  (%d/%d legs)", g_buyBasket.legCount, InpMaxLegsPerBasket), C'0,170,220', 8);
   y += lh;
   DbLabel("BuyAvg", lx, y, PadRight("Avg Entry", lblW) + DoubleToString(g_buyBasket.weightedAvgEntry, 2), clrWhite, 8);
   y += lh;
   DbLabel("BuyPL", lx, y, PadRight("Floating", lblW) + "$" + DoubleToString(g_buyBasket.floatingPL, 2),
           (g_buyBasket.floatingPL >= 0 ? clrLime : clrRed), 8);
   y += lh;
   double buyToTarget = g_tunedProfitTarget - g_buyBasket.floatingPL;
   double buyToDca = (g_buyBasket.legCount > 0)
                      ? (SymbolInfoDouble(_Symbol, SYMBOL_BID) - (g_buyBasket.lastLegEntry - g_tunedDcaDistance)) : 0;
   DbLabel("BuyToTarget", lx, y, PadRight("To Target", lblW) + "$" + DoubleToString(buyToTarget, 2), clrSilver, 8);
   y += lh;
   DbLabel("BuyToDca", lx, y, PadRight("To DCA", lblW) + "$" + DoubleToString(buyToDca, 2), clrSilver, 8);
   y += lh + 6;

   DbDivider("Div2", x, y, 260, C'55,55,65');
   y += 9;

   DbLabel("SellHdr", lx, y, StringFormat("SELL BASKET (%d/%d legs)", g_sellBasket.legCount, InpMaxLegsPerBasket), C'0,170,220', 8);
   y += lh;
   DbLabel("SellAvg", lx, y, PadRight("Avg Entry", lblW) + DoubleToString(g_sellBasket.weightedAvgEntry, 2), clrWhite, 8);
   y += lh;
   DbLabel("SellPL", lx, y, PadRight("Floating", lblW) + "$" + DoubleToString(g_sellBasket.floatingPL, 2),
           (g_sellBasket.floatingPL >= 0 ? clrLime : clrRed), 8);
   y += lh;
   double sellToTarget = g_tunedProfitTarget - g_sellBasket.floatingPL;
   double sellToDca = (g_sellBasket.legCount > 0)
                       ? ((g_sellBasket.lastLegEntry + g_tunedDcaDistance) - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) : 0;
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
   y += lh + 6;

   DbDivider("Div4", x, y, 260, C'55,55,65');
   y += 9;

   DbLabel("TuneHdr", lx, y, "SELF-TUNED PARAMS", C'0,170,220', 8);
   y += lh;
   DbLabel("TuneDist", lx, y, PadRight("DCA Dist", lblW) + "$" + DoubleToString(g_tunedDcaDistance, 2), clrWhite, 8);
   y += lh;
   DbLabel("TuneMult", lx, y, PadRight("Multiplier", lblW) + DoubleToString(g_tunedLotMultiplier, 2) + "x", clrWhite, 8);
   y += lh;
   DbLabel("TuneTarget", lx, y, PadRight("Target", lblW) + "$" + DoubleToString(g_tunedProfitTarget, 2), clrWhite, 8);
   y += lh;
   DbLabel("LastTune", lx, y, PadRight("Last Tune", lblW) + (g_lastTuneDateCode > 0 ? IntegerToString(g_lastTuneDateCode) : "never"), clrSilver, 8);

   ChartRedraw();
  }
//+------------------------------------------------------------------+
