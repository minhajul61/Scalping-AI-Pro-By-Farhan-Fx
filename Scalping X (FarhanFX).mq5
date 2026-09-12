//+------------------------------------------------------------------+
//|                                   Scalping X (FarhanFX).mq5       |
//|  2026-09-12: a sibling product to "Scalping Ai Pro By Farhan FX"  |
//|  in this same project folder - a pure, exact port of a real       |
//|  competing EA's ("GoldTrap X", eagoldtrap.com) documented design, |
//|  built from its official Input Settings Guide PDF plus real       |
//|  trade-history analysis (account 256686): two-tier grid spacing   |
//|  (S1/S2), two-tier distance-from-average-entry TP (T1/T2), a      |
//|  plain lot multiplier capped by leg COUNT, not lot size (E1/N), a |
//|  persistent GlobalVariable equity-lock (R1), a max-basket-age     |
//|  exit that only ever fires non-negative (H1), and broker-session/ |
//|  H4-boundary/news-importance pause filters (F1/T3/T4, F4/N1/T5/   |
//|  T6, F5/T7/T8). Originally forked from the sibling EA's codebase  |
//|  with a togglable replica mode; per explicit request ("hubuhu     |
//|  kuno poribartan charai GoldTrap X-ke, amader kichu use korbe na" |
//|  - copy GoldTrap X exactly, use nothing of ours) the toggle and   |
//|  every piece of the sibling's own architecture (adaptive-ATR DCA  |
//|  distance, carryover-cycle lot growth, the flat $ profit target,  |
//|  the ATR-spike filter, server-clock trading hours, the daily      |
//|  equity-percent loss limit, the manual news-window block) were    |
//|  deleted entirely, not hidden. Only basic MT5 account plumbing    |
//|  (Magic/Login/Broker-preset/Max-Spread) and the on-chart status   |
//|  display are shared infrastructure, not the sibling's trading     |
//|  logic. Backtested (2026.08 alone, the full-replica combo before  |
//|  this pure-copy rewrite): net $124,363, 19.32% equity DD, Sharpe  |
//|  9.71 - the best single-window result found in this project's     |
//|  whole history. Same July weakness as everywhere else in this     |
//|  project (net -$30,558, 101.72% DD) with this account's real      |
//|  R1=100% setting, which is loose enough to barely limit worst-    |
//|  case loss - see ml/learnings.md's 2026-09-12 entries for the     |
//|  full comparison history.                                          |
//+------------------------------------------------------------------+
#property copyright "FarhanFX Algo"
#property version   "1.00"
#property strict
#property description "Dual-basket (buy+sell) grid/DCA EA for XAUUSD M1. Requires a hedging-mode account."

// Brand icon (Farhan FX mark), compiled directly into the .ex5 so a client
// deployment is always just the one file - no separate image to lose or
// forget to copy. Must exist at <data_folder>\MQL5\Images\FarhanFX_Icon.bmp
// on whichever machine compiles this (a copy lives in this repo's
// resources\ folder - copy it there before recompiling on a new machine).
#resource "\\Images\\FarhanFX_Icon.bmp"

// Same mark, larger, and pre-faded (RGB scaled to ~22% against pure black -
// not real alpha transparency, since MT5's 32-bit-BMP alpha support is
// inconsistent; this is a plain opaque BMP that just reads as a faint
// watermark against the chart's black background) - shown centered on the
// main chart, behind the candles. If the chart background is ever not
// pure black, this will show as a very faint dark rectangle instead of
// being fully invisible - acceptable trade-off for guaranteed rendering.
#resource "\\Images\\FarhanFX_Watermark.bmp"
#define WATERMARK_W 420
#define WATERMARK_H 310

// Bump this on every change that gets deployed anywhere (local or VPS) so the
// dashboard can show at a glance whether a given chart is running the latest
// version - this exact confusion (VPS silently running stale code) came up
// 2026-07-27 and cost a round of guessing from the leg-count alone. Simple
// v1, v2, v3... per explicit request (2026-08-12) - easier to compare at a
// glance than a date-based build string. Starts at v4, not v1 - counting
// the four builds already deployed today under the old date-based scheme
// (2026.08.12.1 through .4) as v1-v4, so this numbering continues from
// the real deployment history instead of resetting it.
#define EA_BUILD_VERSION "v1"

#include <Trade\Trade.mqh>

enum ENUM_BASKET_SIDE
  {
   SIDE_BUY  = 0,
   SIDE_SELL = 1
  };

// Two independent axes affect gold's point/tick scaling, and therefore what
// Max Spread threshold is actually correct:
// 1. Broker (Exness/CXM/Vantage/...) - each has its own base symbol spec.
// 2. Account type (standard-USD vs cent-USC) - a cent account quotes the
//    same real $ spread as a much bigger raw "points" number, regardless
//    of broker. Confirmed today on Exness: standard=300 was right, but the
//    cent account (XAUUSDc) needed 5000 for the exact same kind of real
//    spread - blocked every trade silently otherwise.
// Kept as two separate inputs (not one combined broker+type list) so the
// account-type scaling logic applies uniformly to every broker, not just
// the one it happened to be discovered on.
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

// 2026-09-12, explicit request ("hubuhu kuno poribartan charai GoldTrap
// X-ke, amader kichu use korbe na" - copy GoldTrap X exactly, with no
// changes, use nothing of ours): this file was originally forked from
// the sibling "Scalping Ai Pro By Farhan FX" EA with a togglable
// replica mode layered on top of that EA's own architecture. Per this
// explicit instruction, the toggle and every piece of that architecture
// (adaptive-ATR DCA distance, carryover-cycle lot growth, the flat $
// profit target, the ATR-spike filter, trading-hours-by-server-clock,
// the daily equity-percent loss limit, and the manual news-window
// block) have been deleted entirely - not hidden, not left as a
// fallback option. Every remaining input below is a direct port of a
// GoldTrap X input from its official Input Settings Guide PDF (letter
// code noted in each comment) plus real trade-history analysis of
// account 256686 - nothing here belongs to the sibling EA's own design.
// Only Magic Number/Login/Broker-preset/Max-Spread (basic MT5 account
// plumbing every EA needs regardless of strategy, not a trading-logic
// choice) and the Dashboard/Chart-Visuals display toggles (F2's
// intent - GoldTrap X shows its own on-chart status panel too, per the
// PDF, though its exact visual design isn't documented so this reuses
// this project's own dashboard renderer for that purpose) were kept as
// non-strategy infrastructure. See ml/learnings.md's 2026-09-12 entries
// for the full history (isolated-TP test, partial-combo test, and the
// full-replica backtest numbers) that led to this file existing at all.

input group "=== Account & Basic Settings ==="
input ulong    InpMagicNumber        = 20270200;  // Magic Number (deliberately different from the sibling "Scalping Ai Pro By Farhan FX" EA's 20270115, so both can run on the same account without colliding) - overridden per-side by InpGtMagicBuy/InpGtMagicSell below (M1/M2) once trading starts
input long     InpExpectedLogin      = 0;         // Account Login (0 = skip check - client sets their own)
input ENUM_BROKER_PRESET InpBrokerPreset = BROKER_CUSTOM;   // Broker Preset (auto-sets Max Spread)
input ENUM_ACCOUNT_TYPE  InpAccountType  = ACCOUNT_TYPE_USD; // Account Type (scales Max Spread for cent accounts)
input int      InpMaxSpreadPoints    = 300;       // Max Spread (points) - used when Broker Preset = Custom

input group "=== GoldTrap X - Core (V1, N, S1, S2, T1, T2, E1) ==="
input double   InpInitialLot         = 0.01;  // V1: Starting Lot For Every New Cycle
input int      InpGtMaxGridLegs      = 17;    // N: Maximum Legs Per Side (hard cap, matches this account's real setting)
input double   InpGtSpacingS1        = 1.10;  // S1: Grid Spacing While Side Has 1-5 Legs ($ price)
input double   InpGtSpacingS2        = 1.70;  // S2: Grid Spacing After The 5th Leg ($ price)
input double   InpGtTpSingleLeg      = 1.00;  // T1: Profit Target, Single-Leg Basket ($ price distance from entry)
input double   InpGtTpMultiLeg       = 0.30;  // T2: Basket Target, 2+ Legs ($ price distance from weighted avg entry)
input double   InpGtLotMultiplier    = 1.68;  // E1: Grid Lot Multiplier (applied to the latest leg, no reset)

input group "=== GoldTrap X - Protection & Execution (R1, P1, H1) ==="
input double   InpGtEquityLockPercent = 100.0; // R1: Equity Loss Limit, % Of Saved Baseline (close everything + persistent lock; 0 or below = off)
input int      InpGtMaxDeviationPoints = 3;   // P1: Max Execution Deviation (broker points)
input int      InpGtMaxBasketAgeHours = 0;    // H1: Max Basket Age, Hours (0 = off; after this, closes only once floating P/L is non-negative)

input group "=== GoldTrap X - Identity (M1, M2) ==="
input ulong    InpGtMagicBuy         = 837490;  // M1: Magic Number, BUY Side
input ulong    InpGtMagicSell        = 528101;  // M2: Magic Number, SELL Side

input group "=== GoldTrap X - Session, Daily & News (F1,T3,T4 / F3,DT1 / F4,N1,T5,T6) ==="
input bool     InpGtUseSessionFilter = true;  // F1: Pause New Cycles Near Broker Session Boundaries
input int      InpGtSessionCloseMinutes = 60; // T3: Minutes Before Session Close To Pause
input int      InpGtSessionOpenMinutes  = 60; // T4: Minutes After Session Open To Pause
input bool     InpGtUseDailyTarget   = false; // F3: Enable The Daily Profit Target
input double   InpGtDailyTargetAmount = 0;    // DT1: Daily Profit Target, Account Currency (0 = off even if F3 is true)
input bool     InpGtUseNewsFilter    = true;  // F4: Enable The MT5 Economic Calendar News Filter
input string   InpGtNewsCurrency     = "USD"; // News Currency (not a named PDF input - needed by MT5's calendar API to scope the check)
input ENUM_CALENDAR_EVENT_IMPORTANCE InpGtNewsMinPriority = CALENDAR_IMPORTANCE_MODERATE; // N1: Minimum News Priority To Block (matches "Medium" in the PDF)
input int      InpGtNewsMinutesBefore = 30;   // T5: Minutes Before A Qualifying News Event To Pause
input int      InpGtNewsMinutesAfter  = 30;   // T6: Minutes After A Qualifying News Event To Pause

input group "=== GoldTrap X - H4 Boundary (F5, T7, T8) ==="
input bool     InpGtUseH4BoundaryFilter = true; // F5: Pause New Cycles Near H4 Candle Boundaries (00/04/08/12/16/20 server time)
input int      InpGtH4CloseMinutes   = 15;    // T7: Minutes Before H4 Close To Pause
input int      InpGtH4OpenMinutes    = 15;    // T8: Minutes After H4 Open To Pause

input group "=== Dashboard (F2 - on-chart status display) ==="
input bool     InpShowDashboard = true;   // F2: Show On-Chart Status Panel
input int      InpDashboardX    = 10;     // Dashboard X Position
input int      InpDashboardY    = 20;     // Dashboard Y Position
input bool     InpSetWhiteChartTheme = false; // White Chart Theme (off = dark, matches the Farhan FX brand's black logo background)

input group "=== Chart Visuals ==="
input bool     InpShowLegMarkers    = true; // Show DCA Leg Markers On Chart
input bool     InpShowCloseMarkers  = true; // Show Basket-Closed Markers On Chart
input bool     InpShowChartWatermark = true; // Show Farhan FX Watermark On Main Chart

// Non-input constants this file's shared engine code still needs a
// value for, now fixed rather than user-facing since GoldTrap X has no
// equivalent concept to expose: TP is always attached server-side (its
// own basket-target mechanism assumes this), and a leg-open cascade
// guard stays on as a pure safety net (not part of GoldTrap X's own
// documented design, but removing it entirely would let a same-second
// duplicate-tick bug cascade legs with no brake at all - kept as
// infrastructure, not a strategy choice).
const bool     InpUseServerSideTP       = true;
const int      InpMinSecondsBetweenLegs = 5;

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
   long     lastLegTimeMsc;  // POSITION_TIME_MSC - millisecond precision, used to break ties when
                              // two legs open within the same second (POSITION_TIME alone can't tell
                              // them apart, which let the wrong leg's price get used as the DCA
                              // distance reference and let legs cascade far faster than intended -
                              // real incident, 2026-08-18, see ml/learnings.md)
   datetime firstLegTime;    // 2026-09-12: the OLDEST leg's open time (min POSITION_TIME, not max) -
                              // only used by the GoldTrap replica's H1 max-basket-age exit.
  };

SBasket g_buyBasket, g_sellBasket;

int    g_dayStartDateCode = -1;
double g_dayStartBalance  = 0.0;

// Watermark for LogRecentClosedDeals() - only deals strictly after this
// time get logged/re-checked, so a leg that already got logged once
// doesn't get logged again on the next OnTimer() pass.
datetime g_lastDealLogTime = 0;

#define DB_PREFIX  "GDSE_DB_"
#define MK_PREFIX  "GDSE_MK_"

// Names of the most recent basket-closed markers drawn on the chart, oldest
// first - capped (see DrawCloseMarker) so a long-running EA never leaves
// hundreds of these accumulating on the chart.
string g_closeMarkerNames[];

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

// Forces a pure-black chart background (not just "whatever this broker's
// default template happens to be", which turned out NOT to be pure black -
// it was a lighter charcoal/navy, which made the watermark bitmap below
// show up as an obviously visible dark box instead of blending in). The
// watermark's own pixels are pre-scaled against pure black in software
// (see FarhanFX_Watermark.bmp / PositionWatermark()), so this only blends
// correctly if the actual chart background really is (0,0,0).
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
// GoldTrap replica's M1/M2 - separate magic numbers per side, matching
// the real EA (which uses this to keep BUY-side and SELL-side positions
// independently identifiable). MagicForSide() is used everywhere a
// specific side's positions are opened/scanned; IsOurMagic() is for the
// handful of places that scan ALL of this EA's positions/deals
// regardless of side (position-restore-on-init, deal logging).
ulong MagicForSide(ENUM_BASKET_SIDE side)
  {
   return (side == SIDE_BUY) ? InpGtMagicBuy : InpGtMagicSell;
  }

bool IsOurMagic(long magic)
  {
   return magic == (long)InpGtMagicBuy || magic == (long)InpGtMagicSell;
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(InpExpectedLogin != 0 && AccountInfoInteger(ACCOUNT_LOGIN) != InpExpectedLogin)
     {
      PrintFormat("ScalpingX: connected account %d does not match InpExpectedLogin %d. Refusing to run.",
                  (int)AccountInfoInteger(ACCOUNT_LOGIN), (int)InpExpectedLogin);
      return(INIT_FAILED);
     }

   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Print("ScalpingX: account is not in hedging mode. This EA needs simultaneous buy+sell "
            "positions on the same symbol, which a netting account cannot hold. Refusing to run.");
      return(INIT_FAILED);
     }

   if(InpSetWhiteChartTheme)
      ApplyWhiteChartTheme();
   else
      ApplyBlackChartTheme(); // forces pure black - see comment on the function, this is what makes the watermark blend in correctly

   UpdateDayTracking();

   // Diagnostic only (does not affect trading) - confirms whether the
   // calendar is actually reachable at all, using a wide 7-day window
   // instead of the live filter's narrow before/after window. Without this,
   // "no news right now" and "calendar access silently broken" both look
   // identical (News: clear) - added 2026-08-13 specifically so this can be
   // verified right after attaching, instead of waiting to line up with a
   // real event's exact 30-min window.
   if(InpGtUseNewsFilter)
     {
      MqlCalendarValue diag[];
      int diagN = CalendarValueHistory(diag, TimeCurrent() - 7 * 24 * 3600, TimeCurrent() + 7 * 24 * 3600, NULL, InpGtNewsCurrency);
      if(diagN < 0)
         PrintFormat("ScalpingX: news calendar diagnostic FAILED (err=%d) - the News Filter will silently do nothing until this is fixed.",
                     GetLastError());
      else
         PrintFormat("ScalpingX: news calendar diagnostic OK - found %d %s event(s) in the past/next 7 days "
                     "(this check alone does not affect trading, it only confirms calendar access works).",
                     diagN, InpGtNewsCurrency);
     }

   if(InpShowDashboard)
     {
      CreateDashboard();
      EventSetTimer(1);
     }

   RestoreLegMarkersOnInit(); // reattach/restart: redraw markers for legs already open
   PositionWatermark();

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, DB_PREFIX);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   // Self-healing retry: re-checks/re-applies the shared TP on both baskets
   // once a second, in case a PositionModify() failed the first time (e.g.
   // a transient broker error) - cheap when nothing needs changing, since
   // ApplyBasketTP() skips any leg whose TP is already at the right price.
   RefreshBaskets();
   ApplyBasketTP(SIDE_BUY);
   ApplyBasketTP(SIDE_SELL);
   CleanupOrphanedLegMarkers(); // handles legs a server-side TP closed without going through CloseBasket()
   LogRecentClosedDeals();      // real profit/swap/commission per leg close, for verifying the slippage/commission theory with real data

   if(InpShowDashboard)
      UpdateDashboard();
  }

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_CHART_CHANGE)
     {
      PositionWatermark(); // window resized - keep the watermark centered
      return;
     }

   if(id != CHARTEVENT_OBJECT_CLICK)
      return;

   if(sparam == DB_PREFIX + "CloseAllBtn")
     {
      RefreshBaskets();
      CloseBasket(SIDE_BUY, "manual close all", g_buyBasket.floatingPL);
      CloseBasket(SIDE_SELL, "manual close all", g_sellBasket.floatingPL);
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      ChartRedraw();
     }
   else if(sparam == DB_PREFIX + "CloseBuyBtn")
     {
      RefreshBaskets();
      CloseBasket(SIDE_BUY, "manual close buy basket", g_buyBasket.floatingPL);
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      ChartRedraw();
     }
   else if(sparam == DB_PREFIX + "CloseSellBtn")
     {
      RefreshBaskets();
      CloseBasket(SIDE_SELL, "manual close sell basket", g_sellBasket.floatingPL);
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      ChartRedraw();
     }
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   RefreshBaskets();
   UpdateDayTracking();

   if(GtEquityLossLimitHit())
      GtTriggerEquityLock();

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
   b.lastLegTimeMsc   = 0;
   b.firstLegTime     = 0;
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
      if(PositionGetInteger(POSITION_MAGIC) != (long)MagicForSide(side))
         continue;
      if(PositionGetInteger(POSITION_TYPE) != wantType)
         continue;

      double   lots    = PositionGetDouble(POSITION_VOLUME);
      double   entry   = PositionGetDouble(POSITION_PRICE_OPEN);
      double   profit  = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      datetime t       = (datetime)PositionGetInteger(POSITION_TIME);
      long     tMsc    = (long)PositionGetInteger(POSITION_TIME_MSC);

      b.legCount++;
      b.totalLots  += lots;
      b.floatingPL += profit;
      sumPriceLots += entry * lots;
      if(b.firstLegTime == 0 || t < b.firstLegTime)
         b.firstLegTime = t;

      // Millisecond precision, not just POSITION_TIME (1-second resolution) -
      // two legs opening within the same second (this EA can do that; a
      // real incident on 2026-08-18 saw 7 legs open in ~9 seconds) used to
      // be indistinguishable by POSITION_TIME alone, which could pick the
      // WRONG leg as "most recent" and let the DCA-distance check compare
      // against a stale price - letting legs cascade far faster than
      // the DCA spacing (S1/S2) was ever meant to allow.
      if(tMsc >= b.lastLegTimeMsc)
        {
         b.lastLegTime    = t;
         b.lastLegTimeMsc = tMsc;
         b.lastLegEntry   = entry;
         b.lastLegLots    = lots;
         b.lastLegTicket  = ticket;
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
// GoldTrap X's T1 (single-position cycle) / T2 (2+ positions) - a fixed
// price DISTANCE from the basket's weighted average entry, not a flat $
// target. GetProfitTarget() returns the EQUIVALENT $ amount at the
// basket's CURRENT total lots (using tick_value/tick_size, so it matches
// POSITION_PROFIT/floatingPL the same way regardless of contract-size
// peculiarities on any given symbol/broker) purely so
// ManageBasketExits()'s tick-based floatingPL check stays consistent
// with the real price target - it is a derived number, not an
// independent setting.
double GetProfitTarget(const SBasket &b)
  {
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double distance   = (b.legCount <= 1) ? InpGtTpSingleLeg : InpGtTpMultiLeg;
   if(tickValue <= 0 || tickSize <= 0)
      return distance; // fallback - shouldn't happen on a real symbol
   double profitPerPriceUnitPerLot = tickValue / tickSize;
   return distance * b.totalLots * profitPerPriceUnitPerLot;
  }

// The price level at which this basket's combined floating P/L reaches
// GetProfitTarget(b) - a direct weightedAvgEntry +/- distance (T1/T2)
// lookup.
double BasketTargetPrice(ENUM_BASKET_SIDE side, const SBasket &b)
  {
   if(b.totalLots <= 0)
      return 0;
   double distance = (b.legCount <= 1) ? InpGtTpSingleLeg : InpGtTpMultiLeg;
   return (side == SIDE_BUY) ? (b.weightedAvgEntry + distance) : (b.weightedAvgEntry - distance);
  }

// Sets BasketTargetPrice() as a real broker-side TP on every open leg of
// this basket, so the close fires on the server the instant price reaches
// it - instead of the EA detecting "target hit" a tick late and then
// closing legs one-by-one itself (extra wall-clock time per leg, during
// which a fast/momentum move can push the price further away before later
// legs get their turn - this is the real source of the extra slippage
// noticed during momentum, more than commission alone). Every leg in a
// basket shares the same TP price, so in the normal case they all fire
// together on the server instead of sequentially.
//
// Re-applied whenever a leg opens (the only time weightedAvgEntry/
// totalLots/the cycle count can change) and again periodically from
// OnTimer() as a self-healing retry, in case a modify failed the first
// time (logged, never fatal - a failed TP just falls back to the existing
// tick-based close for that basket, it must never block trading since this
// EA has no SL to fall back on either).
void ApplyBasketTP(ENUM_BASKET_SIDE side)
  {
   if(!InpUseServerSideTP)
      return;

   SBasket b;
   if(side == SIDE_BUY)
      b = g_buyBasket;
   else
      b = g_sellBasket;

   if(b.legCount == 0)
      return;

   double tp = BasketTargetPrice(side, b);
   if(tp <= 0)
      return;

   long wantType = (side == SIDE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)MagicForSide(side))
         continue;
      if(PositionGetInteger(POSITION_TYPE) != wantType)
         continue;

      double currentTP = PositionGetDouble(POSITION_TP);
      if(MathAbs(currentTP - tp) < _Point) // already within a point of the right level - skip the modify call
         continue;

      if(!trade.PositionModify(ticket, 0, tp)) // 0 = no SL, per the standing no-SL-ever policy
         PrintFormat("ScalpingX: failed to set TP on ticket %d (target price %.2f): retcode=%d %s - tick-based close remains as backup",
                     (int)ticket, tp, trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
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
      CloseBasket(side, StringFormat("BASKET TARGET HIT (floatingPL=%.2f >= target=%.2f)", b.floatingPL, target), b.floatingPL);
      return;
     }
  }

void CloseBasket(ENUM_BASKET_SIDE side, string reason, double displayProfit = 0.0)
  {
   long wantType = (side == SIDE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   int closedCount = 0;
   double lastClosePrice = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)MagicForSide(side))
         continue;
      if(PositionGetInteger(POSITION_TYPE) != wantType)
         continue;

      lastClosePrice = PositionGetDouble(POSITION_PRICE_CURRENT);

      if(trade.PositionClose(ticket))
        {
         closedCount++;
         DeleteLegMarker(side, ticket);
        }
      else
         PrintFormat("ScalpingX: failed to close ticket %d (%s): retcode=%d %s",
                     (int)ticket, reason, trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }

   if(closedCount > 0)
     {
      PrintFormat("ScalpingX: %s basket closed (%d leg(s)) - %s",
                  (side == SIDE_BUY ? "BUY" : "SELL"), closedCount, reason);
      DrawCloseMarker(side, lastClosePrice, displayProfit);
     }
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

   if(GtInSessionBoundaryPause())
      return; // GoldTrap replica's F1/T3/T4 - near the broker's own session boundary

   if(GtInH4BoundaryPause())
      return; // GoldTrap replica's F5/T7/T8 - near an H4 candle boundary

   if(DailyTargetHit())
      return; // today's profit target already reached (F3/DT1) - resumes automatically at the next day rollover

   if(GtEquityLocked())
      return; // GoldTrap replica's R1 equity-lock has fired - permanently refuses new entries until manually reset (see GtEquityLocked())

   if(GtMaxBasketAgeExit(side, b))
      return; // this basket just force-closed on its H1 age limit - don't also try to add a leg to it this same tick

   if(b.legCount == 0)
     {
      OpenLeg(side, 0, 0);
      RefreshBaskets(); // pick up the leg just opened before computing its TP
      ApplyBasketTP(side);
      return;
     }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double dcaDist = GetEffectiveDcaDistance(b.legCount);
   bool adverse;
   if(side == SIDE_BUY)
      adverse = (bid <= b.lastLegEntry - dcaDist);
   else
      adverse = (ask >= b.lastLegEntry + dcaDist);

   // Temporary diagnostic (2026-08-18) - a live demo cascade wasn't explained
   // by the millisecond-tie-break fix alone (gaps were >= the cooldown, but
   // still far under the DCA spacing (S1/S2)), so log the exact numbers behind
   // every DCA trigger until the real cause is confirmed from real data
   // instead of guessed at again.
   if(adverse)
      PrintFormat("ScalpingX: DCA-DIAG %s adverse=true bid=%.3f ask=%.3f lastLegEntry=%.3f dcaDistanceInput=%.3f legCount=%d lastLegTime=%s",
                  (side == SIDE_BUY ? "BUY" : "SELL"), bid, ask, b.lastLegEntry, dcaDist, b.legCount,
                  TimeToString(b.lastLegTime, TIME_SECONDS));

   if(adverse) // no leg-count cap - see file header, this is a confirmed final decision
     {
      // Safety net, independent of whatever caused the adverse check to
      // pass: never add a leg faster than this after the previous one,
      // full stop. Catches both a genuinely fast/volatile market AND any
      // future timing edge case in the adverse check itself (one such case
      // - same-second leg ties - already found and fixed 2026-08-18; this
      // cooldown means a *similar* bug can't cascade into many legs in a
      // few seconds again even if it existed).
      if(InpMinSecondsBetweenLegs > 0 && (TimeCurrent() - b.lastLegTime) < InpMinSecondsBetweenLegs)
         return;

      // E1: plain geometric growth, never resets, capped by leg COUNT
      // (N / InpGtMaxGridLegs) rather than lot size - matches GoldTrap
      // X's real design exactly (no reset-cycle/carryover concept at
      // all in its documented behaviour).
      if(b.legCount >= InpGtMaxGridLegs)
         return; // grid depth cap reached - no more adds until this basket closes
      int    legIndexForSizing = b.legCount;
      double prospectiveLot    = NextLotSize(legIndexForSizing, b.lastLegLots);

      OpenLeg(side, legIndexForSizing, b.lastLegLots);
      RefreshBaskets(); // pick up the new leg + updated avg entry before recomputing the shared TP
      ApplyBasketTP(side);
      return;
     }
  }

// E1 (grid lot multiplier) - no reset, no cap by lot size (GoldTrap X
// caps by leg COUNT instead, checked at the call site before this is
// even called).
double NextLotSize(int legCount, double previousLegLots)
  {
   double raw = InpInitialLot * MathPow(InpGtLotMultiplier, legCount);

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
   string comment = StringFormat("ScalpingX-%s-leg%d", (side == SIDE_BUY ? "buy" : "sell"), legIndexForSizing + 1);

   // GoldTrap replica uses separate magic numbers per side (M1/M2) - set
   // right before sending, since CTrade's magic is one shared stateful
   // value, not per-call.
   trade.SetExpertMagicNumber(MagicForSide(side));
   if(InpGtMaxDeviationPoints > 0)
      trade.SetDeviationInPoints(InpGtMaxDeviationPoints);

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
      PrintFormat("ScalpingX: %s leg open failed (lot=%.2f): retcode=%d %s",
                  (side == SIDE_BUY ? "BUY" : "SELL"), lots, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   else
      DrawLegMarker(side, trade.ResultOrder(), legIndexForSizing + 1, price, lots);
  }

//+------------------------------------------------------------------+
//| Chart visuals - cosmetic only, never read by any trading logic.   |
//| Leg markers are 1:1 with a position ticket and deleted the moment |
//| that position closes, so they never accumulate; close markers are |
//| capped at the most recent 20 for the same reason.                 |
//+------------------------------------------------------------------+
string LegMarkerName(ENUM_BASKET_SIDE side, ulong posTicket)
  {
   return MK_PREFIX + "LEG_" + (side == SIDE_BUY ? "B_" : "S_") + IntegerToString((int)posTicket);
  }

void DrawLegMarker(ENUM_BASKET_SIDE side, ulong posTicket, int legNumber, double price, double lots)
  {
   if(!InpShowLegMarkers || posTicket == 0)
      return;

   string name = LegMarkerName(side, posTicket);
   color  clr  = (side == SIDE_BUY) ? C'0,170,220' : C'230,140,0';
   string text = StringFormat("%s%d %.2f", (side == SIDE_BUY ? "B" : "S"), legNumber, lots);

   ObjectCreate(0, name, OBJ_TEXT, 0, TimeCurrent(), price);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 7);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, side == SIDE_BUY ? ANCHOR_UPPER : ANCHOR_LOWER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 40);
  }

void DeleteLegMarker(ENUM_BASKET_SIDE side, ulong posTicket)
  {
   ObjectDelete(0, LegMarkerName(side, posTicket));
  }

void DrawCloseMarker(ENUM_BASKET_SIDE side, double price, double profit)
  {
   if(!InpShowCloseMarkers)
      return;

   string name = MK_PREFIX + "CLOSE_" + IntegerToString((int)TimeCurrent()) + "_" + (side == SIDE_BUY ? "B" : "S");
   color  clr  = (profit >= 0) ? clrLime : clrRed;
   string text = StringFormat("%s +$%.2f", (side == SIDE_BUY ? "BUY closed" : "SELL closed"), profit);

   ObjectCreate(0, name, OBJ_TEXT, 0, TimeCurrent(), price);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, side == SIDE_BUY ? ANCHOR_UPPER : ANCHOR_LOWER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 40);

   int sz = ArraySize(g_closeMarkerNames);
   ArrayResize(g_closeMarkerNames, sz + 1);
   g_closeMarkerNames[sz] = name;
   if(ArraySize(g_closeMarkerNames) > 20)
     {
      ObjectDelete(0, g_closeMarkerNames[0]);
      ArrayRemove(g_closeMarkerNames, 0, 1);
     }
  }

// Rebuilds leg markers for positions that were already open when the EA
// (re)attached - chart objects aren't remembered across EA restarts, so
// without this an existing basket's legs would show no markers until they
// next close. Parses the leg number back out of OpenLeg()'s own comment
// format ("FarhanFx-buy-legN" / "FarhanFx-sell-legN"); falls back to "?" if
// a position's comment doesn't match (e.g. opened manually, not by this EA).
void RestoreLegMarkersOnInit()
  {
   if(!InpShowLegMarkers)
      return;

   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(!IsOurMagic(PositionGetInteger(POSITION_MAGIC)))
         continue;

      long type = PositionGetInteger(POSITION_TYPE);
      ENUM_BASKET_SIDE side = (type == POSITION_TYPE_BUY) ? SIDE_BUY : SIDE_SELL;
      string comment = PositionGetString(POSITION_COMMENT);
      int legTag = StringFind(comment, "-leg");
      int legNumber = 1;
      if(legTag >= 0)
         legNumber = (int)StringToInteger(StringSubstr(comment, legTag + 4));

      DrawLegMarker(side, ticket, legNumber, PositionGetDouble(POSITION_PRICE_OPEN), PositionGetDouble(POSITION_VOLUME));
     }
  }

// A leg's marker is normally deleted inside CloseBasket()'s own loop - but
// a server-side TP (see ApplyBasketTP()) closes a position without the EA
// ever calling CloseBasket() for it, so that path can leave an orphaned
// marker sitting on the chart forever. Called periodically (OnTimer(), not
// every tick - cheap either way, but no need for tick frequency) to sweep
// every leg-marker object and delete any whose position no longer exists.
void CleanupOrphanedLegMarkers()
  {
   string prefixB = MK_PREFIX + "LEG_B_";
   string prefixS = MK_PREFIX + "LEG_S_";
   for(int i = ObjectsTotal(0, 0, OBJ_TEXT) - 1; i >= 0; i--)
     {
      string name = ObjectName(0, i, 0, OBJ_TEXT);
      string ticketStr;
      if(StringFind(name, prefixB) == 0)
         ticketStr = StringSubstr(name, StringLen(prefixB));
      else if(StringFind(name, prefixS) == 0)
         ticketStr = StringSubstr(name, StringLen(prefixS));
      else
         continue;

      ulong ticket = (ulong)StringToInteger(ticketStr);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         ObjectDelete(0, name);
     }
  }

// Logs the real, broker-confirmed profit/swap/commission for every leg
// close since the last check (whichever path closed it - CloseBasket()'s
// own market orders or a server-side TP), so the actual gap between what
// the EA expected and what was really realized is visible in the Experts
// log instead of guessed at. This is exactly the data needed to confirm
// whether InpUseServerSideTP actually reduces the momentum/slippage gap
// reported 2026-08-16, and separately how much commission alone costs per
// leg - both were previously invisible (MQL5 has no live-commission field
// on an open position; it only exists after the deal closes, which is
// exactly what this reads). Called from OnTimer(), not every tick.
void LogRecentClosedDeals()
  {
   datetime from = (g_lastDealLogTime > 0) ? g_lastDealLogTime : (TimeCurrent() - 300);
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
      if(!IsOurMagic(HistoryDealGetInteger(dealTicket, DEAL_MAGIC)))
         continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;

      datetime dealTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
      if(dealTime <= g_lastDealLogTime)
         continue; // already logged on a previous pass

      double profit     = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
      double swap        = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
      double commission = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      long   dealType   = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
      // The closing deal's type is the opposite of the position it closed:
      // a SELL deal closes a BUY leg, a BUY deal closes a SELL leg.
      string closedSide = (dealType == DEAL_TYPE_SELL) ? "BUY leg" : "SELL leg";

      PrintFormat("ScalpingX: %s closed (deal #%d) - profit=%.2f swap=%.2f commission=%.2f net=%.2f",
                  closedSide, (int)dealTicket, profit, swap, commission, profit + swap + commission);
     }

   g_lastDealLogTime = TimeCurrent();
  }

// Centers the watermark on the currently-visible chart window. Chart-window
// (label-anchored) objects don't move on their own when the window is
// resized, so this is re-called from OnChartEvent() on CHARTEVENT_CHART_CHANGE
// as well as once from OnInit() - it does not need to run every tick.
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
      ObjectSetInteger(0, name, OBJPROP_BACK, true); // behind candles, in front of the plain chart background
      ObjectSetInteger(0, name, OBJPROP_ZORDER, -100);
     }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, wx);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, wy);
  }

//+------------------------------------------------------------------+
//| DCA filters                                                       |
//+------------------------------------------------------------------+
// 2026-09-07: the stop-out-cooldown (RefreshStopOutCooldowns/
// HadRecentStopOut, built after a real 2026-08-31 live incident where a
// partial stop-out immediately re-triggered a second one) and margin-
// level guard (MarginLevelTooLow, built after the same incident to
// watch ACCOUNT_MARGIN_LEVEL directly) were removed here by explicit
// request, alongside InpMaxTotalBasketVolume above. Recoverable from
// git history if a future decision wants any of them back - see
// ml/learnings.md's 2026-08-29/2026-08-31/2026-09 entries for the real
// incidents that motivated each one.
// S1 (while adding leg 1-5) vs S2 (leg 6 onward) - matches GoldTrap X's
// "S1 for 1 to 5 positions, S2 after the fifth position" spec exactly.
double GetEffectiveDcaDistance(int legCount)
  {
   return (legCount < 5) ? InpGtSpacingS1 : InpGtSpacingS2;
  }

// 2026-09-07: GetTrendOnTF()/GetTrend()/IsAgainstTrend()/IsWithTrend()
// removed here by explicit request, after a July cross-check showed the
// whole trend-filter idea doesn't hold up (see the input-block comment
// near the old InpUseTrendFilter declaration, and ml/learnings.md's
// 2026-09-07 entries, for the full before/after numbers). Recoverable
// from git history if a future idea wants to revisit trend-gating with
// better evidence.

// F4/N1/T5/T6: uses MT5's built-in economic calendar (no external
// service needed - the terminal syncs it automatically while connected,
// live/demo only). Blocks new trades and DCA-adds from T5 minutes
// before a qualifying-priority (N1) InpGtNewsCurrency event until T6
// minutes after it. Does not touch already-open positions or profit-
// target closes - only pauses new adds.
// CONFIRMED (2026-08-13, standalone diagnostic script): CalendarValueHistory
// returns err=4014 (ERR_FUNCTION_NOT_ALLOWED) inside the Strategy Tester for
// every date range tried, including dates well within the account's own
// history - this is a genuine MT5 platform restriction on calendar
// functions in the Tester, not a data-availability issue or a bug here.
// This check is real and works live/demo; it cannot be exercised or
// validated via backtesting at all.
bool IsNewsBlackout()
  {
   if(!InpGtUseNewsFilter)
      return false;

   datetime from = TimeCurrent() - InpGtNewsMinutesAfter * 60;
   datetime to   = TimeCurrent() + InpGtNewsMinutesBefore * 60;

   MqlCalendarValue values[];
   int n = CalendarValueHistory(values, from, to, NULL, InpGtNewsCurrency);
   if(n <= 0)
      return false;

   // N1 ("minimum event priority to block") - matches its documented
   // behaviour ("Selecting Low blocks low, medium and high events, so
   // it is most restrictive").
   for(int i = 0; i < n; i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev))
         continue;
      if(ev.importance >= InpGtNewsMinPriority)
         return true;
     }
   return false;
  }

// GoldTrap replica's F1/T3/T4: pause new cycles within InpGtSessionCloseMinutes
// of the broker's own trading-session close, or within InpGtSessionOpenMinutes
// after it opens - reads the real session times from the symbol's own
// specification (SymbolInfoSessionTrade) rather than assuming a fixed
// server-time window, so it follows whatever this broker's actual XAUUSD
// session boundaries are. Fails open (returns false, does not block) if
// the broker doesn't expose session data for today rather than guessing.
bool GtInSessionBoundaryPause()
  {
   if(!InpGtUseSessionFilter)
      return false;

   MqlDateTime dtNow;
   TimeToStruct(TimeCurrent(), dtNow);
   ENUM_DAY_OF_WEEK dow = (ENUM_DAY_OF_WEEK)dtNow.day_of_week;

   datetime sessFrom, sessTo;
   if(!SymbolInfoSessionTrade(_Symbol, dow, 0, sessFrom, sessTo))
      return false;

   int nowSec  = dtNow.hour * 3600 + dtNow.min * 60 + dtNow.sec;
   int fromSec = (int)sessFrom;
   int toSec   = (int)sessTo;

   int minsToClose    = (toSec - nowSec) / 60;
   int minsSinceOpen  = (nowSec - fromSec) / 60;

   if(minsToClose >= 0 && minsToClose <= InpGtSessionCloseMinutes)
      return true;
   if(minsSinceOpen >= 0 && minsSinceOpen <= InpGtSessionOpenMinutes)
      return true;
   return false;
  }

// GoldTrap replica's F5/T7/T8: pause new cycles near each H4 candle
// boundary (00:00, 04:00, 08:00, 12:00, 16:00, 20:00 server time, per
// the PDF) - computed directly from server time, not iTime(), so it
// doesn't depend on the chart's own period.
bool GtInH4BoundaryPause()
  {
   if(!InpGtUseH4BoundaryFilter)
      return false;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int nowMinOfDay     = dt.hour * 60 + dt.min;
   int boundaryBefore  = (dt.hour / 4) * 4 * 60;
   int boundaryAfter   = boundaryBefore + 240;
   int minsSinceOpen   = nowMinOfDay - boundaryBefore;
   int minsToClose     = boundaryAfter - nowMinOfDay;

   if(minsSinceOpen <= InpGtH4OpenMinutes)
      return true;
   if(minsToClose <= InpGtH4CloseMinutes)
      return true;
   return false;
  }

//+------------------------------------------------------------------+
//| Spread / daily circuit breaker                                    |
//+------------------------------------------------------------------+
// Verification status, honestly tracked (2026-08-14) - IMPORTANT: cent-
// account scaling is broker-specific, NOT a universal multiplier. Each
// broker's own symbol/point convention decides this independently; an
// earlier version of this function applied one shared x17 factor to every
// broker's cent account, which turned out wrong the moment it was actually
// tested (see CXM below) - kept as a cautionary note.
// - Exness standard (300): live-tested all day on a real Exness demo,
//   XAUUSD 3-decimal - real spread observed ~168 points, comfortably
//   under this.
// - Exness cent (5000): live-tested on a real Exness account, XAUUSDc -
//   confirmed working after raising from 300 (which silently blocked
//   every trade). A big scale-up for this broker's cent symbol.
// - CXM standard (300) and CXM cent (300, i.e. NO scale-up needed): live-
//   tested on a real CXM Direct demo account (252424, XAUUSDc) - real
//   spread observed = 24 points, comfortably under the base 300. CXM's
//   cent symbol does not need the Exness-style multiplier at all.
// - Vantage cent (300, i.e. NO scale-up needed either): live-tested on a
//   real Vantage account (34580461, XAUUSD.sc, cent/USC) - real spread
//   observed = 33 points, comfortably under 300. Same pattern as CXM -
//   Exness is the outlier that actually needs a much bigger threshold,
//   not the norm.
// - Vantage standard (300): NOT independently verified - the account
//   tested was cent-type; assumed safe by the same margin logic as
//   Exness/CXM standard accounts, not confirmed with real data.
int EffectiveMaxSpreadPoints()
  {
   bool cent = (InpAccountType == ACCOUNT_TYPE_USC);
   switch(InpBrokerPreset)
     {
      case BROKER_EXNESS:  return cent ? 5000 : 300; // both verified today
      case BROKER_CXM:     return 300;               // verified today - same threshold works for both account types
      case BROKER_VANTAGE: return 300;               // cent verified today (33 pts); standard not independently tested but same threshold expected
      default:              return InpMaxSpreadPoints; // BROKER_CUSTOM
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

// F3/DT1: realized (closed) profit only - today's balance vs balance at
// today's rollover - not floating equity, so this doesn't flicker
// true/false as open baskets' floating P/L wobbles. Once true, stays
// true for the rest of the day (UpdateDayTracking() resets
// g_dayStartBalance at the next day rollover, which is what makes this
// resume automatically) - matches GoldTrap X's documented F3/DT1
// behaviour ("stops new cycles, but never abandons an active basket").
bool DailyTargetHit()
  {
   if(!InpGtUseDailyTarget || InpGtDailyTargetAmount <= 0 || g_dayStartBalance <= 0)
      return false;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   return((balance - g_dayStartBalance) >= InpGtDailyTargetAmount);
  }

//+------------------------------------------------------------------+
//| GoldTrap replica: R1 equity-lock. GlobalVariable-persisted, exactly |
//| matching the real EA's documented behaviour - "closes managed      |
//| positions and pending orders, then stores a persistent lock in MT5 |
//| Global Variables. Restarting the EA does not automatically remove  |
//| that lock." The equity baseline itself is also GlobalVariable-     |
//| persisted (saved once, the first time this ever runs, per the      |
//| PDF's "R1 uses a stored equity baseline") - not reset daily like    |
//| our own InpDailyLossLimit's day-start balance.                     |
//+------------------------------------------------------------------+
string GtBaselineVarName() { return "GTReplica_" + IntegerToString(InpMagicNumber) + "_" + _Symbol + "_EquityBaseline"; }
string GtLockVarName()     { return "GTReplica_" + IntegerToString(InpMagicNumber) + "_" + _Symbol + "_Locked"; }

bool GtEquityLocked()
  {
   if(InpGtEquityLockPercent <= 0)
      return false;
   string lockVar = GtLockVarName();
   return(GlobalVariableCheck(lockVar) && GlobalVariableGet(lockVar) > 0);
  }

bool GtEquityLossLimitHit()
  {
   if(InpGtEquityLockPercent <= 0)
      return false;
   if(GtEquityLocked())
      return true; // already locked from an earlier tick/session - stays true until manually reset

   string baseVar = GtBaselineVarName();
   double baseline;
   if(GlobalVariableCheck(baseVar))
      baseline = GlobalVariableGet(baseVar);
   else
     {
      baseline = AccountInfoDouble(ACCOUNT_EQUITY);
      GlobalVariableSet(baseVar, baseline);
     }
   if(baseline <= 0)
      return false;
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPct = (baseline - equity) / baseline * 100.0;
   return(lossPct >= InpGtEquityLockPercent);
  }

void GtTriggerEquityLock()
  {
   if(!GtEquityLocked())
     {
      PrintFormat("ScalpingX: GoldTrap replica R1 EQUITY LOCK TRIGGERED (>= %.1f%% loss from saved baseline) - closing everything, persistent lock set.",
                  InpGtEquityLockPercent);
      GlobalVariableSet(GtLockVarName(), 1);
     }
   RefreshBaskets();
   CloseBasket(SIDE_BUY, "GoldTrap replica R1 equity-lock", g_buyBasket.floatingPL);
   CloseBasket(SIDE_SELL, "GoldTrap replica R1 equity-lock", g_sellBasket.floatingPL);
  }

// GoldTrap replica: H1 max basket age - "After the time is reached, the
// EA closes only when basket floating result is non-negative" (per the
// PDF). Uses firstLegTime (the OLDEST leg, not lastLegTime) so the age
// clock starts at bootstrap, not at the most recent DCA-add. Never
// closes at a loss, same as every other exit in this EA - it just waits
// longer for a non-negative moment once the age threshold has passed,
// rather than forcing one.
bool GtMaxBasketAgeExit(ENUM_BASKET_SIDE side, const SBasket &b)
  {
   if(InpGtMaxBasketAgeHours <= 0)
      return false;
   if(b.legCount == 0 || b.firstLegTime == 0)
      return false;
   double ageHours = (double)(TimeCurrent() - b.firstLegTime) / 3600.0;
   if(ageHours < InpGtMaxBasketAgeHours || b.floatingPL < 0)
      return false;
   CloseBasket(side, StringFormat("GoldTrap replica H1 max-basket-age exit (%.1fh, non-negative floating)", ageHours), b.floatingPL);
   return true;
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

// 2026-08-24: every property here used to be set only inside the
// ObjectCreate-once block below - fine the very first time an EA is
// attached, but this chart has been running the SAME EA (same object
// names) continuously since v15/v16 without ever detaching, and this
// function is called again on every OnInit (every recompile/restart).
// Since ObjectFind() found the button already existing, none of these
// properties were ever re-applied - a live chart could easily still be
// showing colors/sizes from many versions ago, invisible to every later
// code change. Now everything re-applies every call; only the one-time
// ObjectCreate stays gated.
void CreateButton(string name, int x, int y, int w, int h, string text, color bg)
  {
   string full = DB_PREFIX + name;
   if(ObjectFind(0, full) < 0)
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

// A tinted "card" rectangle behind a block of dashboard lines - purely a
// visual grouping cue (BUY/SELL/FILTERS each get their own subtly-tinted
// panel instead of floating text with no container). Low ZORDER so
// DbLabel() text (ZORDER 100) always draws on top of it regardless of
// call order.
void DbCard(string name, int x, int y, int w, int h, color bg, color border)
  {
   string full = DB_PREFIX + name;
   if(ObjectFind(0, full) < 0)
      ObjectCreate(0, full, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, full, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, full, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, full, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, full, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, full, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, full, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, full, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, full, OBJPROP_COLOR, border);
   ObjectSetInteger(0, full, OBJPROP_BACK, false);
   ObjectSetInteger(0, full, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, full, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, full, OBJPROP_ZORDER, 10);
  }

// 2026-08-24: full visual redesign, prompted directly by the user's own
// live screenshot ("does this look like a professional dashboard?").
// Two real problems, not just one:
// 1. The old panel background (C'12,12,16') was nearly indistinguishable
//    from the chart's own pure-black background (ApplyBlackChartTheme())
//    - so the "card" existed in code but was effectively invisible,
//    leaving text floating directly over candles with no container.
// 2. Every property here (colors, sizes) was only ever set once, inside
//    an ObjectFind()-gated "create if missing" block - correct for a
//    brand-new chart, but this exact chart has had the EA attached
//    continuously since v15/v16 and never removed, so on every later
//    recompile these lines were skipped entirely (object already
//    existed) and the panel kept showing whatever colors/sizes existed
//    weeks ago, invisible to every visual change made since. Every
//    property below now re-applies on every call (only ObjectCreate
//    itself stays gated) so a restart/recompile always shows the
//    current code's actual intended look, not a stale leftover.
void CreateDashboard()
  {
   // 2026-08-24: widened 300->340 (and every child element to match) -
   // a live screenshot showed the License line's value text running
   // past the panel's right edge onto the chart. That specific string
   // was also shortened (see the License DbLabel call below), but this
   // extra margin covers any other value text that gets long later.
   int px = InpDashboardX - 10, py = InpDashboardY - 10, pw = 340, ph = 605;

   string bg = DB_PREFIX + "BG";
   if(ObjectFind(0, bg) < 0)
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, px);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, py);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE, pw);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, ph);
   ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'21,23,30'); // clearly lighter than pure-black chart bg - reads as an actual card now
   ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, bg, OBJPROP_COLOR, C'212,175,55'); // full-brightness gold frame, brand accent
   ObjectSetInteger(0, bg, OBJPROP_BACK, false);
   ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, bg, OBJPROP_ZORDER, 0);

   // Header strip - a distinct band behind the icon/title/version block so
   // "who this is" (brand) reads as visually separate from "what it's
   // doing" (live data), same header-bar convention as most trading
   // dashboards (mirrors the tradinjournal.com-style panel already used
   // on this user's web dashboard project).
   string hdr = DB_PREFIX + "HeaderStrip";
   if(ObjectFind(0, hdr) < 0)
      ObjectCreate(0, hdr, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, hdr, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, hdr, OBJPROP_XDISTANCE, px + 2);
   ObjectSetInteger(0, hdr, OBJPROP_YDISTANCE, py + 2);
   ObjectSetInteger(0, hdr, OBJPROP_XSIZE, pw - 4);
   ObjectSetInteger(0, hdr, OBJPROP_YSIZE, 66);
   ObjectSetInteger(0, hdr, OBJPROP_BGCOLOR, C'42,34,14'); // dark warm gold-brown, distinct from the body
   ObjectSetInteger(0, hdr, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, hdr, OBJPROP_COLOR, C'42,34,14');
   ObjectSetInteger(0, hdr, OBJPROP_BACK, false);
   ObjectSetInteger(0, hdr, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, hdr, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, hdr, OBJPROP_ZORDER, 1);

   // Thin gold accent strip along the very top edge - purely cosmetic
   // branding, on top of the header strip.
   string accent = DB_PREFIX + "Accent";
   if(ObjectFind(0, accent) < 0)
      ObjectCreate(0, accent, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, accent, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, accent, OBJPROP_XDISTANCE, px);
   ObjectSetInteger(0, accent, OBJPROP_YDISTANCE, py);
   ObjectSetInteger(0, accent, OBJPROP_XSIZE, pw);
   ObjectSetInteger(0, accent, OBJPROP_YSIZE, 3);
   ObjectSetInteger(0, accent, OBJPROP_BGCOLOR, C'212,175,55'); // gold
   ObjectSetInteger(0, accent, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, accent, OBJPROP_COLOR, C'212,175,55');
   ObjectSetInteger(0, accent, OBJPROP_BACK, false);
   ObjectSetInteger(0, accent, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, accent, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, accent, OBJPROP_ZORDER, 2);

   string icon = DB_PREFIX + "Icon";
   if(ObjectFind(0, icon) < 0)
      ObjectCreate(0, icon, OBJ_BITMAP_LABEL, 0, 0, 0);
   ObjectSetInteger(0, icon, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, icon, OBJPROP_XDISTANCE, InpDashboardX - 6);
   ObjectSetInteger(0, icon, OBJPROP_YDISTANCE, InpDashboardY - 6);
   ObjectSetString(0, icon, OBJPROP_BMPFILE, "::Images\\FarhanFX_Icon.bmp");
   ObjectSetInteger(0, icon, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, icon, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, icon, OBJPROP_BACK, false);
   ObjectSetInteger(0, icon, OBJPROP_ZORDER, 3);

   CreateButton("CloseAllBtn", InpDashboardX, InpDashboardY + 521, 320, 24, "X  CLOSE ALL", C'120,20,20');
   CreateButton("CloseBuyBtn", InpDashboardX, InpDashboardY + 549, 156, 22, "Close BUY", C'20,80,20');
   CreateButton("CloseSellBtn", InpDashboardX + 164, InpDashboardY + 549, 156, 22, "Close SELL", C'20,80,20');
  }

void UpdateDashboard()
  {
   RefreshBaskets();

   // lblW must be >= the longest label text below ("Daily Loss Limit" = 17
   // chars) or PadRight() silently adds zero spaces once a label already
   // meets/exceeds the width, running straight into its value with no gap
   // (caught live 2026-08-24: "Daily Targetoff", "Trading Hoursopen ...").
   int x = InpDashboardX, lx = InpDashboardX + 2, y = InpDashboardY, lh = 15, lblW = 18;

   // 2026-08-24: the section "cards" MUST be created before any of this
   // section's DbLabel() calls, not after - caught live from the user's
   // own screenshot (card boxes were hiding almost all the text behind
   // them). MT5 draws overlapping anchored objects (OBJ_LABEL vs
   // OBJ_RECTANGLE_LABEL) in the order they were first added to the
   // chart's object list, NOT strictly by OBJPROP_ZORDER as this file
   // originally assumed - whichever object is created first paints
   // first, and later-created objects paint on top regardless of
   // ZORDER. Drawing every card here, up front, guarantees the labels
   // (added afterwards, below) are always the ones created later and so
   // always paint on top. The y-offsets are hardcoded from the exact,
   // deterministic row layout below (this dashboard never changes which
   // rows it draws, so these never drift) - see the matching DbDivider
   // calls further down for the same numbers used unlabeled.
   DbCard("BuyCard", x - 4, InpDashboardY + 173, 328, 113, C'14,26,20', C'40,70,55');
   DbCard("SellCard", x - 4, InpDashboardY + 278, 328, 113, C'28,16,14', C'80,45,40');
   // Height 122->107: shrunk by one row (lh=15) after the License row
   // was removed below (2026-08-27, license input+display deleted
   // entirely - see the file's git history if this is ever revisited).
   // Height 107->122->137: two more rows added below (2026-08-31,
   // stop-out cooldown + margin guard status lines).
   DbCard("FilterCard", x - 4, InpDashboardY + 383, 328, 137, C'16,20,28', C'50,60,75');

   // Icon (created once in CreateDashboard()) sits at (x-6, y-6), 64x47px -
   // text starts to its right, then drops back to the full-width left
   // margin once the icon's height has cleared.
   DbLabel("Title", x + 70, y, "SCALPING X", clrWhite, 9);
   y += lh;
   // Own line, not packed onto the title line - a fixed pixel offset for a
   // second same-line label overlapped the first on real hardware (font
   // rendering/DPI varies), so this stacks instead of guessing a width.
   DbLabel("TitleBrand", x + 70, y, "FARHAN FX", C'212,175,55', 8); // gold - brand accent
   y += lh + 15; // extra clearance so later lines start below the icon, not beside it
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
   string dailyTargetText = (!InpGtUseDailyTarget || InpGtDailyTargetAmount <= 0) ? "off"
                             : dailyTargetHit ? "HIT (paused today)"
                             : "$" + DoubleToString(dailyPL, 2) + " / $" + DoubleToString(InpGtDailyTargetAmount, 2);
   DbLabel("DailyTarget", lx, y, PadRight("Daily Target (F3/DT1)", lblW) + dailyTargetText,
           dailyTargetHit ? clrLime : clrSilver, 8);
   y += lh;
   bool sessionPause = GtInSessionBoundaryPause();
   bool h4Pause      = GtInH4BoundaryPause();
   string pauseText = (sessionPause && h4Pause) ? "session + H4 boundary"
                       : sessionPause ? "session boundary (F1)"
                       : h4Pause      ? "H4 boundary (F5)"
                       : "clear";
   DbLabel("BoundaryPause", lx, y, PadRight("Boundary Pause", lblW) + pauseText,
           (sessionPause || h4Pause) ? clrOrange : clrSilver, 8);
   y += lh;
   bool equityLocked = GtEquityLocked();
   string equityLockText = (InpGtEquityLockPercent <= 0) ? "off"
                            : equityLocked ? "LOCKED (see Journal)"
                            : "armed at " + DoubleToString(InpGtEquityLockPercent, 1) + "%";
   DbLabel("EquityLock", lx, y, PadRight("Equity Lock (R1)", lblW) + equityLockText,
           equityLocked ? clrRed : clrSilver, 8);
   y += lh + 6;

   DbDivider("Div1", x, y, 320, C'55,55,65');
   y += 9;

   // 2026-08-24: was "(leg X/7, cycle N)" - the "/7" is the lot-sizing
   // cycle length (InpMaxLegsPerBasket - lot resets every N legs so no
   // single leg balloons to the broker's max-lot limit), NOT a cap on
   // how many legs the basket can take - but the user read it as a cap
   // and, reasonably, objected ("unlimited martingale bolechi, tao
   // dekhacche"). There has been no leg-count cap since v23 (the only
   // toggle that ever capped legs was deleted then). Now shows the
   // plain running total with an explicit "(unlimited)" tag so it can't
   // be misread as a ceiling.
   DbLabel("BuyHdr", lx, y, StringFormat("BUY BASKET  (%d legs, unlimited)", g_buyBasket.legCount), C'110,210,140', 8); // soft green - "buy" at a glance
   y += lh;
   DbLabel("BuyAvg", lx, y, PadRight("Avg Entry", lblW) + DoubleToString(g_buyBasket.weightedAvgEntry, 2), clrWhite, 8);
   y += lh;
   string buyTpText = !InpUseServerSideTP ? "off" : (g_buyBasket.legCount > 0 ? DoubleToString(BasketTargetPrice(SIDE_BUY, g_buyBasket), 2) : "-");
   DbLabel("BuyTP", lx, y, PadRight("TP Price", lblW) + buyTpText, C'212,175,55', 8);
   y += lh;
   DbLabel("BuyPL", lx, y, PadRight("Floating", lblW) + "$" + DoubleToString(g_buyBasket.floatingPL, 2),
           (g_buyBasket.floatingPL >= 0 ? clrLime : clrRed), 8);
   y += lh;
   double buyToTarget = GetProfitTarget(g_buyBasket) - g_buyBasket.floatingPL;
   double buyToDca = (g_buyBasket.legCount > 0)
                      ? (SymbolInfoDouble(_Symbol, SYMBOL_BID) - (g_buyBasket.lastLegEntry - GetEffectiveDcaDistance(g_buyBasket.legCount))) : 0;
   DbLabel("BuyToTarget", lx, y, PadRight("To Target", lblW) + "$" + DoubleToString(buyToTarget, 2), clrSilver, 8);
   y += lh;
   DbLabel("BuyToDca", lx, y, PadRight("To DCA", lblW) + "$" + DoubleToString(buyToDca, 2), clrSilver, 8);
   y += lh + 6;

   DbDivider("Div2", x, y, 320, C'55,55,65');
   y += 9;

   DbLabel("SellHdr", lx, y, StringFormat("SELL BASKET (%d legs, unlimited)", g_sellBasket.legCount), C'230,120,90', 8); // soft red/orange - "sell" at a glance
   y += lh;
   DbLabel("SellAvg", lx, y, PadRight("Avg Entry", lblW) + DoubleToString(g_sellBasket.weightedAvgEntry, 2), clrWhite, 8);
   y += lh;
   string sellTpText = !InpUseServerSideTP ? "off" : (g_sellBasket.legCount > 0 ? DoubleToString(BasketTargetPrice(SIDE_SELL, g_sellBasket), 2) : "-");
   DbLabel("SellTP", lx, y, PadRight("TP Price", lblW) + sellTpText, C'212,175,55', 8);
   y += lh;
   DbLabel("SellPL", lx, y, PadRight("Floating", lblW) + "$" + DoubleToString(g_sellBasket.floatingPL, 2),
           (g_sellBasket.floatingPL >= 0 ? clrLime : clrRed), 8);
   y += lh;
   double sellToTarget = GetProfitTarget(g_sellBasket) - g_sellBasket.floatingPL;
   double sellToDca = (g_sellBasket.legCount > 0)
                       ? ((g_sellBasket.lastLegEntry + GetEffectiveDcaDistance(g_sellBasket.legCount)) - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) : 0;
   DbLabel("SellToTarget", lx, y, PadRight("To Target", lblW) + "$" + DoubleToString(sellToTarget, 2), clrSilver, 8);
   y += lh;
   DbLabel("SellToDca", lx, y, PadRight("To DCA", lblW) + "$" + DoubleToString(sellToDca, 2), clrSilver, 8);
   y += lh + 6;

   DbDivider("Div3", x, y, 320, C'55,55,65');
   y += 9;

   DbLabel("FilterHdr", lx, y, "FILTERS", C'0,170,220', 8);
   y += lh;
   long liveSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   int  maxSpread   = EffectiveMaxSpreadPoints();
   bool spreadBlocking = (liveSpread > maxSpread);
   DbLabel("Spread", lx, y, PadRight("Spread", lblW) + IntegerToString((int)liveSpread) + " / " + IntegerToString(maxSpread) + (spreadBlocking ? " (blocking)" : ""),
           spreadBlocking ? clrRed : clrSilver, 8);
   y += lh;
   bool newsBlackout = IsNewsBlackout();
   DbLabel("News", lx, y, PadRight("News (F4/N1)", lblW) + (InpGtUseNewsFilter ? (newsBlackout ? "YES (blocking)" : "clear") : "off"),
           newsBlackout ? clrOrange : clrSilver, 8);
   y += lh;
   bool hedgingOk = ((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   DbLabel("Hedging", lx, y, PadRight("Hedging", lblW) + (hedgingOk ? "OK" : "FAIL"), hedgingOk ? clrLime : clrRed, 8);
   y += lh;

   y += 10;

   ChartRedraw();
  }
//+------------------------------------------------------------------+
