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

// Bump this on every change that gets deployed anywhere (local or VPS) so the
// dashboard can show at a glance whether a given chart is running the latest
// build - this exact confusion (VPS silently running stale code) came up
// 2026-07-27 and cost a round of guessing from the leg-count alone.
#define EA_BUILD_VERSION "2026.07.31.1"

#include <Trade\Trade.mqh>

enum ENUM_BASKET_SIDE
  {
   SIDE_BUY  = 0,
   SIDE_SELL = 1
  };

input group "=== Trade Settings ==="
input ulong    InpMagicNumber        = 20270115;  // ID number for this EA's trades (leave as is)
input long     InpExpectedLogin      = 416045126; // Your account number (0 = don't check)
input int      InpMaxSpreadPoints    = 300;       // Skip new trades if spread is too wide

input group "=== Basket Core ==="
input double   InpInitialLot            = 0.02;   // First trade size (lot)
input double   InpBasketProfitTargetUSD = 2.0;    // Close basket once it earns this much profit ($) - base value, grows per cycle (see below)
input int      InpMaxLegsPerBasket      = 7;      // Legs per DCA "cycle" - after this many, a new cycle starts (lot size resets) instead of stopping
input int      InpAbsoluteMaxLegsPerBasket = 50;  // Hard safety ceiling on total legs across all cycles (should rarely if ever be reached)
input double   InpCycleTargetGrowth     = 0.5;    // Each completed cycle raises the profit target by this fraction (e.g. 0.5 = +50% per cycle)

input group "=== DCA / Martingale ==="
input bool     InpUseAtrDcaDistance   = false;    // Auto-adjust DCA gap by volatility (off = use fixed $ gap below)
input double   InpDcaDistanceAtrMult  = 1.5;      // Only used if the above is ON: how wide the auto gap is
input double   InpDcaDistancePrice  = 3.0;        // Price move ($) before adding the next DCA trade
input double   InpLotMultiplier     = 1.5;        // How much bigger each new DCA trade is (1.5 = 50% bigger)


input group "=== DCA Filters (skip adding on bad conditions) ==="
input bool             InpUseAtrSpikeFilter = true;      // Don't add DCA trades during a sudden volatility spike
input int              InpAtrPeriod         = 14;        // Volatility measuring period (candles)
input int              InpAtrBaselineBars   = 20;         // Candles used to calculate "normal" volatility
input double           InpMaxAtrRatio       = 1.5;        // How many times above normal counts as a "spike"
input bool             InpUseTrendFilter    = true;       // Don't add DCA trades against a strong trend
input ENUM_TIMEFRAMES  InpTrendTF           = PERIOD_H1;  // Timeframe used to judge the trend
input int              InpTrendMAPeriod     = 50;         // Moving average length used for the trend check
input int              InpTrendAtrPeriod    = 14;         // Volatility period used to judge trend strength
input double           InpTrendStrengthATRMult = 0.5;     // How strong the trend must be before it blocks a trade

input group "=== Basket Safety ==="
input double   InpBasketMaxLossUSD        = 0.0;   // Force-close a basket at this loss ($) - 0 = OFF (turned off per request)
input int      InpBasketSLCooldownMinutes = 0;     // Wait this many minutes before reopening after a stop-loss - 0 = OFF (turned off per request)
input bool     InpUseCatastrophicSL       = true;  // Emergency backup stop-loss on every trade - ON (restored: this is what was quietly generating the earlier profit, see learnings.md)
input double   InpCatastrophicSLMultiple  = 2.0;   // How far away the emergency stop-loss sits

input group "=== Daily Stop (currently OFF per request) ==="
input bool     InpUseDailyLimit         = false;  // Stop trading for the day after a big loss - OFF (turned off per request)
input double   InpDailyMaxLossPercent   = 0.0;    // Daily loss limit (% of balance) - 0 = OFF (turned off per request, unused while the line above is OFF anyway)
input bool     InpDailyLimitForceCloses = true;   // Also close open trades when the daily limit hits (if ON above)

input group "=== Auto-Adjust Settings (AI Brain) ==="
input bool     InpUseIntradayBrake            = true;  // Auto slow-down (not a full stop) after a bad day so far
input double   InpIntradayBrakeLossPercent    = 3.0;    // Today's loss (%) that triggers the slow-down
input double   InpIntradayBrakeMultiplierCap  = 1.15;   // Smaller DCA growth allowed once slowed down
input double   InpIntradayBrakeDistanceMult   = 1.5;    // DCA gap gets this much wider once slowed down

input bool     InpUseStuckBasketRelief   = true;  // Let a maxed-out basket accept a smaller profit to get out (instead of waiting forever)
input double   InpStuckBasketHours       = 4.0;   // Hours stuck at max DCA trades before the target starts shrinking
input double   InpStuckBasketDecayHours  = 8.0;   // Hours over which the target shrinks from full down to the floor below
input double   InpStuckBasketTargetFloor = 0.0;   // Smallest target ($) it will shrink to - 0 = will accept breakeven

input group "=== Market Regime Detection (AI Brain) ==="
// Rule-based, not ML - there is no native MQL5 library that "learns" from
// history in the trained-model sense. This loads years of daily history,
// computes where TODAY's trend-strength and volatility rank against that
// whole history (a percentile), and classifies today as trending/ranging/
// volatile - then nudges DCA distance/lot growth accordingly. It changes
// how much today's readings are trusted, not what will happen next.
input bool     InpUseRegimeDetection         = true;  // Compare today's conditions against years of history to classify the regime
input int      InpRegimeHistoryYears         = 5;     // How many years of daily history to use as the comparison baseline
input double   InpRegimeTrendPercentile      = 70.0;  // Trend strength must rank above this percentile (vs history) to call today "trending"
input double   InpRegimeVolPercentile        = 80.0;  // Volatility (ATR) must rank above this percentile (vs history) to call today "volatile"
input double   InpRegimeTrendingDcaDistanceMult = 1.3; // Widen DCA distance by this much when the regime is trending
input double   InpRegimeRangingDcaDistanceMult  = 0.85;// Tighten DCA distance by this much when the regime is ranging (this EA's best case)
input double   InpRegimeVolatileLotMultCap      = 1.2; // Cap the lot growth multiplier to this when the regime is volatile

input bool     InpEnableSelfTuning = true;   // Let the EA auto-adjust its own settings daily from results
input double   InpDcaDistanceMin   = 2.0;   // Auto-tuning: smallest DCA gap ($) it may use
input double   InpDcaDistanceMax   = 6.0;   // Auto-tuning: largest DCA gap ($) it may use
input double   InpDcaAtrMultMin    = 1.0;   // Auto-tuning: smallest auto-gap multiplier it may use
input double   InpDcaAtrMultMax    = 3.0;   // Auto-tuning: largest auto-gap multiplier it may use
input double   InpLotMultiplierMin = 1.2;   // Auto-tuning: smallest DCA size growth it may use
input double   InpLotMultiplierMax = 1.8;   // Auto-tuning: largest DCA size growth it may use
input double   InpProfitTargetMin  = 0.5;   // Auto-tuning: smallest profit target ($) it may use
input double   InpProfitTargetMax  = 3.0;   // Auto-tuning: largest profit target ($) it may use
input int      InpMaxLegsFloor        = 2;    // Auto-tuning will never drop max DCA trades below this
input int      InpLegStatMinSample    = 8;     // Min past baskets needed before auto-tuning trusts the win rate
input double   InpLegStatWinRateFloor = 0.30;  // Win rate below this lowers the max DCA trades allowed
input double   InpLegStatWinRateCeil  = 0.70;  // Win rate above this raises the max DCA trades allowed back up
input bool     InpResetTunedParams = false; // Reset all auto-tuned values back to the defaults above

input group "=== Dashboard ==="
input bool     InpShowDashboard = true;   // Show the on-chart info panel
input int      InpDashboardX    = 10;     // Panel position - distance from left edge
input int      InpDashboardY    = 20;     // Panel position - distance from top edge
input bool     InpSetWhiteChartTheme = true; // Set the chart background to white (the dashboard panel stays dark/readable on top)

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

enum ENUM_MARKET_REGIME
  {
   REGIME_RANGING  = 0,
   REGIME_TRENDING = 1,
   REGIME_VOLATILE = 2
  };

int g_atrHandle      = INVALID_HANDLE;
int g_trendMAHandle  = INVALID_HANDLE;
int g_trendAtrHandle = INVALID_HANDLE;
int g_regimeAtrHandle = INVALID_HANDLE; // D1, used only for regime detection's historical baseline
int g_regimeMaHandle  = INVALID_HANDLE; // D1

ENUM_MARKET_REGIME g_currentRegime         = REGIME_RANGING;
double             g_regimeDcaDistanceMult = 1.0;
double             g_regimeLotMultiplierCap = 999.0;
double             g_regimeTrendPercentileNow = 0.0;
double             g_regimeVolPercentileNow   = 0.0;
int                g_lastRegimeDateCode = -1;
bool               g_regimeDetectionActive = false; // InpUseRegimeDetection, downgraded to false at runtime if setup fails

int    g_dayStartDateCode = -1;
double g_dayStartBalance  = 0.0;
bool   g_intradayBrakeActive = false; // AI brain's soft de-risk for the rest of today, reset on day rollover

datetime g_cooldownUntil[2] = {0, 0}; // indexed by ENUM_BASKET_SIDE

double g_tunedDcaDistance;   // fixed-$ mode (InpUseAtrDcaDistance = false)
double g_tunedDcaAtrMult;    // ATR mode (InpUseAtrDcaDistance = true) - the "smart" default
double g_tunedLotMultiplier;
double g_tunedProfitTarget;
int    g_tunedMaxLegs;      // max legs cap, adapted from real per-leg-depth win/loss history
int    g_lastTuneDateCode = -1;

#define GV_PREFIX  "GDSE_"
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

   g_regimeDetectionActive = InpUseRegimeDetection;
   if(g_regimeDetectionActive)
     {
      g_regimeAtrHandle = iATR(_Symbol, PERIOD_D1, InpTrendAtrPeriod);
      g_regimeMaHandle  = iMA(_Symbol, PERIOD_D1, InpTrendMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
      if(g_regimeAtrHandle == INVALID_HANDLE || g_regimeMaHandle == INVALID_HANDLE)
        {
         Print("GoldDualBasketDCA: regime detection handle creation failed - disabling regime detection.");
         g_regimeDetectionActive = false;
        }
     }

   LoadTunedParams();
   UpdateDayTracking();
   MaybeUpdateMarketRegime();

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
   if(g_regimeAtrHandle != INVALID_HANDLE)
      IndicatorRelease(g_regimeAtrHandle);
   if(g_regimeMaHandle != INVALID_HANDLE)
      IndicatorRelease(g_regimeMaHandle);
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
   CheckIntradayBrake();
   MaybeUpdateMarketRegime();
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
//+------------------------------------------------------------------+
//| Stuck-basket relief: a basket at max DCA legs with nowhere left   |
//| to add and no bounce in sight would otherwise just sit open        |
//| indefinitely waiting for the full target. Once it's been maxed     |
//| out and stuck for InpStuckBasketHours, linearly shrink the         |
//| required profit down toward InpStuckBasketTargetFloor over the     |
//| next InpStuckBasketDecayHours - so it takes the first real exit    |
//| opportunity instead of holding out for the original target.        |
//| This does NOT guarantee an exit: price still has to come back up   |
//| to at least the floor for this to fire at all.                     |
//+------------------------------------------------------------------+
// The target is not a flat number - it scales with how many full DCA cycles
// this basket has already gone through (0 cycles = base target; each
// completed cycle raises it by InpCycleTargetGrowth). A basket that has
// survived several cycles has more capital and more adverse distance
// behind it, so it demands proportionally more profit before it's worth
// closing, rather than settling for the same small target regardless of
// how much risk is currently open.
double GetBaseProfitTarget(const SBasket &b)
  {
   int completedCycles = (g_tunedMaxLegs > 0) ? (b.legCount / g_tunedMaxLegs) : 0;
   return g_tunedProfitTarget * (1.0 + completedCycles * InpCycleTargetGrowth);
  }

double GetEffectiveProfitTarget(const SBasket &b)
  {
   double target = GetBaseProfitTarget(b);
   if(!InpUseStuckBasketRelief || b.legCount < g_tunedMaxLegs || b.lastLegTime == 0)
      return target;

   double hoursStuck = (double)(TimeCurrent() - b.lastLegTime) / 3600.0;
   if(hoursStuck <= InpStuckBasketHours)
      return target;

   double decayHours = MathMax(InpStuckBasketDecayHours, 0.01);
   double progress = (hoursStuck - InpStuckBasketHours) / decayHours;
   if(progress > 1.0)
      progress = 1.0;

   double eased = target - (target - InpStuckBasketTargetFloor) * progress;
   return MathMax(eased, InpStuckBasketTargetFloor);
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

   double effTarget = GetEffectiveProfitTarget(b);
   if(b.floatingPL >= effTarget)
     {
      string tag = (effTarget < g_tunedProfitTarget - 0.001) ? "BASKET TARGET HIT (stuck-basket relief)" : "BASKET TARGET HIT";
      CloseBasket(side, StringFormat("%s (floatingPL=%.2f >= target=%.2f, full target=%.2f)",
                                      tag, b.floatingPL, effTarget, g_tunedProfitTarget));
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
      // this is what let earlier testing repeatedly run BUY baskets to their
      // hard-SL: DCA was trend-filtered, but the doomed bootstrap entry that
      // started each of those baskets was not.
      if(InpUseTrendFilter && IsAgainstTrend(side))
         return;
      OpenLeg(side, 0, 0);
      return;
     }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double dcaDistance = GetCurrentDcaDistance();

   bool adverse;
   if(side == SIDE_BUY)
      adverse = (bid <= b.lastLegEntry - dcaDistance);
   else
      adverse = (ask >= b.lastLegEntry + dcaDistance);

   if(adverse && b.legCount < InpAbsoluteMaxLegsPerBasket)
     {
      if(InpUseAtrSpikeFilter && IsAtrSpiking())
         return; // "news proxy" - don't average into a volatility spike
      if(InpUseTrendFilter && IsAgainstTrend(side))
         return; // don't keep averaging into a strong opposing higher-timeframe trend

      // Cycling: once a full cycle (g_tunedMaxLegs) is used up, the next leg
      // restarts lot sizing from InpInitialLot instead of continuing to
      // compound the multiplier indefinitely - keeps a basket that's been
      // going against for a long time from ever needing an unaffordable lot
      // size, while still letting it keep averaging if price keeps moving.
      int legIndexForSizing = b.legCount % g_tunedMaxLegs;
      OpenLeg(side, legIndexForSizing, b.lastLegLots);
      return;
     }
  }

double NextLotSize(int legCount, double previousLegLots)
  {
   double raw = InpInitialLot * MathPow(EffectiveLotMultiplier(), legCount);

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
                          ? GetCurrentDcaDistance() * (InpMaxLegsPerBasket + InpCatastrophicSLMultiple)
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
//| DCA distance - "smart"/adaptive when InpUseAtrDcaDistance is on:   |
//| scales with current M1 ATR instead of a fixed $ amount, so it     |
//| widens automatically in a genuinely more volatile market and      |
//| tightens in a quiet one, rather than needing a human to guess a   |
//| single $ figure that fits every condition.                        |
//+------------------------------------------------------------------+
double GetCurrentDcaDistance()
  {
   double dist;
   if(!InpUseAtrDcaDistance)
      dist = g_tunedDcaDistance;
   else
     {
      double atrBuf[1];
      if(CopyBuffer(g_atrHandle, 0, 1, 1, atrBuf) <= 0 || atrBuf[0] <= 0)
         dist = g_tunedDcaDistance; // fallback if ATR unavailable this tick
      else
         dist = atrBuf[0] * g_tunedDcaAtrMult;
     }

   if(g_intradayBrakeActive)
      dist *= InpIntradayBrakeDistanceMult;

   if(g_regimeDetectionActive)
      dist *= g_regimeDcaDistanceMult;

   return dist;
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
//| Market regime detection - rule-based, not ML. Loads years of daily |
//| history and asks: where does TODAY's trend-strength/volatility     |
//| rank against that whole history (a percentile)? This changes how   |
//| much today's readings are trusted (wider DCA distance when today   |
//| looks like a rare, strongly-trending day vs history; tighter when  |
//| today looks like an ordinary ranging day), not what happens next - |
//| no native MQL5 library "learns" a predictive model from history.   |
//+------------------------------------------------------------------+
double PercentileRankOf(const double &arr[], int count, double value)
  {
   if(count <= 0)
      return 50.0;
   int countBelowOrEqual = 0;
   for(int i = 0; i < count; i++)
      if(arr[i] <= value)
         countBelowOrEqual++;
   return 100.0 * countBelowOrEqual / count;
  }

void UpdateMarketRegime()
  {
   if(!g_regimeDetectionActive)
      return;

   int requested = InpRegimeHistoryYears * 365;
   int available = iBars(_Symbol, PERIOD_D1);
   int n = MathMin(requested, available - 5); // leave a small margin for the indicator warm-up
   if(n < 60)
     {
      Print("GoldDualBasketDCA: not enough D1 history yet for regime detection (need 60+, have ", n, ") - skipping today.");
      return;
     }

   double atrHist[], maHist[], closeHist[];
   ArraySetAsSeries(atrHist, true);
   ArraySetAsSeries(maHist, true);
   ArraySetAsSeries(closeHist, true);

   if(CopyBuffer(g_regimeAtrHandle, 0, 1, n, atrHist) < n)
      return;
   if(CopyBuffer(g_regimeMaHandle, 0, 1, n, maHist) < n)
      return;
   if(CopyClose(_Symbol, PERIOD_D1, 1, n, closeHist) < n)
      return;

   double trendStrengthHist[];
   ArrayResize(trendStrengthHist, n);
   for(int i = 0; i < n; i++)
      trendStrengthHist[i] = (atrHist[i] > 0) ? MathAbs(closeHist[i] - maHist[i]) / atrHist[i] : 0;

   double todayTrendStrength = trendStrengthHist[0]; // most recent CLOSED daily bar (shift 1)
   double todayAtr           = atrHist[0];

   g_regimeTrendPercentileNow = PercentileRankOf(trendStrengthHist, n, todayTrendStrength);
   g_regimeVolPercentileNow   = PercentileRankOf(atrHist, n, todayAtr);

   ENUM_MARKET_REGIME newRegime;
   if(g_regimeTrendPercentileNow >= InpRegimeTrendPercentile)
      newRegime = REGIME_TRENDING;
   else if(g_regimeVolPercentileNow >= InpRegimeVolPercentile)
      newRegime = REGIME_VOLATILE;
   else
      newRegime = REGIME_RANGING;

   g_currentRegime = newRegime;
   if(newRegime == REGIME_TRENDING)
     {
      g_regimeDcaDistanceMult  = InpRegimeTrendingDcaDistanceMult;
      g_regimeLotMultiplierCap = 999.0;
     }
   else if(newRegime == REGIME_RANGING)
     {
      g_regimeDcaDistanceMult  = InpRegimeRangingDcaDistanceMult;
      g_regimeLotMultiplierCap = 999.0;
     }
   else // REGIME_VOLATILE
     {
      g_regimeDcaDistanceMult  = 1.0;
      g_regimeLotMultiplierCap = InpRegimeVolatileLotMultCap;
     }

   string regimeName = (newRegime == REGIME_TRENDING) ? "TRENDING" : (newRegime == REGIME_VOLATILE) ? "VOLATILE" : "RANGING";
   string msg = StringFormat("AI BRAIN regime detection (vs %d years / %d daily bars): trend-strength at %.1f pct, "
                              "volatility at %.1f pct -> regime=%s (DCA distance x%.2f, lot mult cap %.2f)",
                              InpRegimeHistoryYears, n, g_regimeTrendPercentileNow, g_regimeVolPercentileNow,
                              regimeName, g_regimeDcaDistanceMult, g_regimeLotMultiplierCap);
   Print("GoldDualBasketDCA: " + msg);
   WriteTuningLog(msg);
  }

void MaybeUpdateMarketRegime()
  {
   if(!g_regimeDetectionActive)
      return;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int todayCode = dt.year * 10000 + dt.mon * 100 + dt.day;
   if(todayCode == g_lastRegimeDateCode)
      return; // already recalculated today

   UpdateMarketRegime();
   g_lastRegimeDateCode = todayCode;
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
      if(g_intradayBrakeActive)
        {
         g_intradayBrakeActive = false;
         Print("GoldDualBasketDCA: AI BRAIN intraday soft-brake reset for the new day.");
        }
     }
  }

// Soft, non-closing de-risk: engages once per day, the moment today's
// floating loss crosses the threshold, and stays on (no un-braking mid-day
// even if equity recovers) until the next day's rollover resets it. This is
// deliberately one-directional within a day - flapping on/off as equity
// wobbles around the threshold would be noise, not a real risk decision.
void CheckIntradayBrake()
  {
   if(!InpUseIntradayBrake || g_intradayBrakeActive || g_dayStartBalance <= 0)
      return;

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double changePct = (equity - g_dayStartBalance) / g_dayStartBalance * 100.0;

   if(changePct <= -InpIntradayBrakeLossPercent)
     {
      g_intradayBrakeActive = true;
      string msg = StringFormat("AI BRAIN intraday soft-brake engaged: today's P/L %.2f%% <= -%.2f%% - "
                                 "lot multiplier capped to %.2f, DCA distance x%.2f for the rest of today",
                                 changePct, InpIntradayBrakeLossPercent, InpIntradayBrakeMultiplierCap,
                                 InpIntradayBrakeDistanceMult);
      Print("GoldDualBasketDCA: " + msg);
      WriteTuningLog(msg);
     }
  }

double EffectiveLotMultiplier()
  {
   double mult = g_tunedLotMultiplier;
   if(g_intradayBrakeActive)
      mult = MathMin(mult, InpIntradayBrakeMultiplierCap);
   if(g_regimeDetectionActive)
      mult = MathMin(mult, g_regimeLotMultiplierCap);
   return mult;
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
      GlobalVariableDel(GVName("DcaAtrMult"));
      GlobalVariableDel(GVName("LotMultiplier"));
      GlobalVariableDel(GVName("ProfitTarget"));
      GlobalVariableDel(GVName("MaxLegs"));
      GlobalVariableDel(GVName("LastTuneDate"));
      for(int i = 1; i <= InpMaxLegsPerBasket; i++)
        {
         GlobalVariableDel(GVName("LegWins" + IntegerToString(i)));
         GlobalVariableDel(GVName("LegLosses" + IntegerToString(i)));
        }
     }

   g_tunedDcaDistance   = GlobalVariableCheck(GVName("DcaDistance"))
                          ? GlobalVariableGet(GVName("DcaDistance")) : InpDcaDistancePrice;
   g_tunedDcaAtrMult    = GlobalVariableCheck(GVName("DcaAtrMult"))
                          ? GlobalVariableGet(GVName("DcaAtrMult")) : InpDcaDistanceAtrMult;
   g_tunedLotMultiplier = GlobalVariableCheck(GVName("LotMultiplier"))
                          ? GlobalVariableGet(GVName("LotMultiplier")) : InpLotMultiplier;
   g_tunedProfitTarget  = GlobalVariableCheck(GVName("ProfitTarget"))
                          ? GlobalVariableGet(GVName("ProfitTarget")) : InpBasketProfitTargetUSD;
   g_tunedMaxLegs       = GlobalVariableCheck(GVName("MaxLegs"))
                          ? (int)GlobalVariableGet(GVName("MaxLegs")) : InpMaxLegsPerBasket;
   g_lastTuneDateCode   = GlobalVariableCheck(GVName("LastTuneDate"))
                          ? (int)GlobalVariableGet(GVName("LastTuneDate")) : -1;
  }

void SaveTunedParams()
  {
   GlobalVariableSet(GVName("DcaDistance"), g_tunedDcaDistance);
   GlobalVariableSet(GVName("DcaAtrMult"), g_tunedDcaAtrMult);
   GlobalVariableSet(GVName("LotMultiplier"), g_tunedLotMultiplier);
   GlobalVariableSet(GVName("ProfitTarget"), g_tunedProfitTarget);
   GlobalVariableSet(GVName("MaxLegs"), g_tunedMaxLegs);
   GlobalVariableSet(GVName("LastTuneDate"), g_lastTuneDateCode);
  }

// Persistent (not reset daily) per-leg-depth win/loss counters - the "deep"
// part of the AI brain: real accumulated history of whether reaching a
// given leg depth actually tends to recover, not just yesterday's snapshot.
double GetLegStat(string kind, int legs)
  {
   string name = GVName((kind == "win" ? "LegWins" : "LegLosses") + IntegerToString(legs));
   return GlobalVariableCheck(name) ? GlobalVariableGet(name) : 0;
  }

void IncrementLegStat(string kind, int legs)
  {
   string name = GVName((kind == "win" ? "LegWins" : "LegLosses") + IntegerToString(legs));
   GlobalVariableSet(name, GetLegStat(kind, legs) + 1);
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

      // Deep AI brain: record real, persistent win/loss history at this
      // exact leg depth, regardless of whether it happens to be today's
      // active cap - this builds up a genuine track record over many days.
      int legsCapped = (int)MathMin(legs, InpMaxLegsPerBasket);
      IncrementLegStat(sumProfit >= 0 ? "win" : "loss", legsCapped);

      idx = j + 1;
     }

   double oldDist = InpUseAtrDcaDistance ? g_tunedDcaAtrMult : g_tunedDcaDistance;
   double oldMult = g_tunedLotMultiplier, oldTarget = g_tunedProfitTarget;
   int    oldMaxLegs = g_tunedMaxLegs;
   bool changed = false;

   if(maxedTotal > 0 && maxedAndLost >= MathMax(1, maxedTotal / 2))
     {
      if(InpUseAtrDcaDistance)
         g_tunedDcaAtrMult = MathMin(InpDcaAtrMultMax, g_tunedDcaAtrMult + 0.10);
      else
         g_tunedDcaDistance = MathMin(InpDcaDistanceMax, g_tunedDcaDistance + 0.20);
      g_tunedLotMultiplier = MathMax(InpLotMultiplierMin, g_tunedLotMultiplier - 0.05);
      changed = true;
     }

   if(cycleCount >= 20 && targetHitCount > 0 && (totalTargetGapSum / targetHitCount) < 0.05)
     {
      g_tunedProfitTarget = MathMin(InpProfitTargetMax, g_tunedProfitTarget + 0.20);
      changed = true;
     }

   // Deep AI brain: adjust the max-legs cap itself from real, persistent
   // (all-time, not just yesterday) win/loss history at the CURRENT cap's
   // leg depth. Requires a real sample size before trusting it either way -
   // small samples are noise, not evidence. Reducing needs a poor win rate;
   // increasing needs a strong one; either way it never leaves
   // [InpMaxLegsFloor, InpMaxLegsPerBasket].
   double wins   = GetLegStat("win", g_tunedMaxLegs);
   double losses = GetLegStat("loss", g_tunedMaxLegs);
   double sample = wins + losses;
   string legStatNote = "";
   if(sample >= InpLegStatMinSample)
     {
      double winRate = wins / sample;
      if(winRate < InpLegStatWinRateFloor && g_tunedMaxLegs > InpMaxLegsFloor)
        {
         g_tunedMaxLegs--;
         changed = true;
         legStatNote = StringFormat(" | leg-depth %d win rate %.0f%% (n=%.0f) below floor - max legs reduced",
                                     oldMaxLegs, winRate * 100, sample);
        }
      else if(winRate > InpLegStatWinRateCeil && g_tunedMaxLegs < InpMaxLegsPerBasket)
        {
         g_tunedMaxLegs++;
         changed = true;
         legStatNote = StringFormat(" | leg-depth %d win rate %.0f%% (n=%.0f) above ceiling - max legs increased",
                                     oldMaxLegs, winRate * 100, sample);
        }
     }

   double newDist = InpUseAtrDcaDistance ? g_tunedDcaAtrMult : g_tunedDcaDistance;
   string distLabel = InpUseAtrDcaDistance ? "DcaAtrMult" : "DcaDistance";
   string logMsg = StringFormat("Self-tune %s: cycles=%d maxedTotal=%d maxedAndLost=%d targetHits=%d | "
                                 "%s %.2f->%.2f LotMultiplier %.2f->%.2f ProfitTarget %.2f->%.2f MaxLegs %d->%d%s%s",
                                 TimeToString(fromTime, TIME_DATE), cycleCount, maxedTotal, maxedAndLost, targetHitCount,
                                 distLabel, oldDist, newDist, oldMult, g_tunedLotMultiplier, oldTarget, g_tunedProfitTarget,
                                 oldMaxLegs, g_tunedMaxLegs,
                                 changed ? "" : " | no change (no clear trouble signal)", legStatNote);

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
      ObjectSetInteger(0, bg, OBJPROP_YSIZE, 560);
      ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'12,12,16');
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bg, OBJPROP_COLOR, C'70,70,80');
      ObjectSetInteger(0, bg, OBJPROP_BACK, false);
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, bg, OBJPROP_ZORDER, 0);
     }

   CreateButton("CloseAllBtn", InpDashboardX, InpDashboardY + 486, 260, 24, "X  CLOSE ALL", C'120,20,20');
   CreateButton("CloseBuyBtn", InpDashboardX, InpDashboardY + 514, 126, 22, "Close BUY", C'20,80,20');
   CreateButton("CloseSellBtn", InpDashboardX + 134, InpDashboardY + 514, 126, 22, "Close SELL", C'20,80,20');
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
           (g_tunedMaxLegs > 0 ? g_buyBasket.legCount % g_tunedMaxLegs : g_buyBasket.legCount), g_tunedMaxLegs,
           (g_tunedMaxLegs > 0 ? g_buyBasket.legCount / g_tunedMaxLegs + 1 : 1)), C'0,170,220', 8);
   y += lh;
   DbLabel("BuyAvg", lx, y, PadRight("Avg Entry", lblW) + DoubleToString(g_buyBasket.weightedAvgEntry, 2), clrWhite, 8);
   y += lh;
   DbLabel("BuyPL", lx, y, PadRight("Floating", lblW) + "$" + DoubleToString(g_buyBasket.floatingPL, 2),
           (g_buyBasket.floatingPL >= 0 ? clrLime : clrRed), 8);
   y += lh;
   double buyToTarget = GetEffectiveProfitTarget(g_buyBasket) - g_buyBasket.floatingPL;
   double buyToDca = (g_buyBasket.legCount > 0)
                      ? (SymbolInfoDouble(_Symbol, SYMBOL_BID) - (g_buyBasket.lastLegEntry - GetCurrentDcaDistance())) : 0;
   DbLabel("BuyToTarget", lx, y, PadRight("To Target", lblW) + "$" + DoubleToString(buyToTarget, 2), clrSilver, 8);
   y += lh;
   DbLabel("BuyToDca", lx, y, PadRight("To DCA", lblW) + "$" + DoubleToString(buyToDca, 2), clrSilver, 8);
   y += lh + 6;

   DbDivider("Div2", x, y, 260, C'55,55,65');
   y += 9;

   DbLabel("SellHdr", lx, y, StringFormat("SELL BASKET (leg %d/%d, cycle %d)",
           (g_tunedMaxLegs > 0 ? g_sellBasket.legCount % g_tunedMaxLegs : g_sellBasket.legCount), g_tunedMaxLegs,
           (g_tunedMaxLegs > 0 ? g_sellBasket.legCount / g_tunedMaxLegs + 1 : 1)), C'0,170,220', 8);
   y += lh;
   DbLabel("SellAvg", lx, y, PadRight("Avg Entry", lblW) + DoubleToString(g_sellBasket.weightedAvgEntry, 2), clrWhite, 8);
   y += lh;
   DbLabel("SellPL", lx, y, PadRight("Floating", lblW) + "$" + DoubleToString(g_sellBasket.floatingPL, 2),
           (g_sellBasket.floatingPL >= 0 ? clrLime : clrRed), 8);
   y += lh;
   double sellToTarget = GetEffectiveProfitTarget(g_sellBasket) - g_sellBasket.floatingPL;
   double sellToDca = (g_sellBasket.legCount > 0)
                       ? ((g_sellBasket.lastLegEntry + GetCurrentDcaDistance()) - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) : 0;
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
   y += lh;
   DbLabel("Brake", lx, y, PadRight("Soft Brake", lblW) + (InpUseIntradayBrake ? (g_intradayBrakeActive ? "ON (de-risked today)" : "off (normal)") : "disabled"),
           g_intradayBrakeActive ? clrOrange : clrSilver, 8);
   y += lh;
   string regimeText = !g_regimeDetectionActive ? "disabled"
                        : (g_currentRegime == REGIME_TRENDING) ? "TRENDING"
                        : (g_currentRegime == REGIME_VOLATILE) ? "VOLATILE" : "RANGING";
   color regimeColor = (g_currentRegime == REGIME_TRENDING) ? C'0,170,220'
                        : (g_currentRegime == REGIME_VOLATILE) ? clrOrange : clrLime;
   DbLabel("Regime", lx, y, PadRight("Regime", lblW) + regimeText, g_regimeDetectionActive ? regimeColor : clrSilver, 8);
   y += lh + 6;

   DbDivider("Div4", x, y, 260, C'55,55,65');
   y += 9;

   DbLabel("TuneHdr", lx, y, "SELF-TUNED PARAMS", C'0,170,220', 8);
   y += lh;
   string dcaDistText = InpUseAtrDcaDistance
                         ? DoubleToString(g_tunedDcaAtrMult, 2) + "x ATR ($" + DoubleToString(GetCurrentDcaDistance(), 2) + ")"
                         : "$" + DoubleToString(g_tunedDcaDistance, 2);
   DbLabel("TuneDist", lx, y, PadRight("DCA Dist", lblW) + dcaDistText, clrWhite, 8);
   y += lh;
   DbLabel("TuneMult", lx, y, PadRight("Multiplier", lblW) + DoubleToString(g_tunedLotMultiplier, 2) + "x", clrWhite, 8);
   y += lh;
   DbLabel("TuneTarget", lx, y, PadRight("Target", lblW) + "$" + DoubleToString(g_tunedProfitTarget, 2), clrWhite, 8);
   y += lh;
   DbLabel("TuneMaxLegs", lx, y, PadRight("Max Legs", lblW) + IntegerToString(g_tunedMaxLegs) + " (ceil " +
           IntegerToString(InpMaxLegsPerBasket) + ")", clrWhite, 8);
   y += lh;
   DbLabel("LastTune", lx, y, PadRight("Last Tune", lblW) + (g_lastTuneDateCode > 0 ? IntegerToString(g_lastTuneDateCode) : "never"), clrSilver, 8);

   ChartRedraw();
  }
//+------------------------------------------------------------------+
