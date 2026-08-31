//+------------------------------------------------------------------+
//|                                      GoldDualBasketDCA.mq5        |
//|  XAUUSD M1 dual-basket grid/DCA EA. Simultaneous BUY + SELL       |
//|  baskets (requires a hedging-mode account), each targeting a      |
//|  floating-profit dollar amount, then closing and immediately      |
//|  reopening. On a $-price adverse move past the last leg, adds a   |
//|  martingale DCA leg - no total-leg cap. ATR-spike, higher-        |
//|  timeframe trend, and economic-news filters gate DCA adds.        |
//|  No stop-loss anywhere, ever, and no cap on how many legs a       |
//|  basket can take on - per explicit, repeated user request (always |
//|  martingale an against-trend basket until it hits its profit      |
//|  target, no exceptions, no pauses). Confirmed 2026-08-24 as a      |
//|  final decision, not a default: a real $20,000 backtest reproduced |
//|  the same account-blowing mechanism as this EA's real 2026-08-24   |
//|  live incident (unlimited legs into a sustained one-direction      |
//|  move exhausts margin before a basket can average back to profit) |
//|  - the user saw that result and chose to keep unlimited legs      |
//|  anyway, risk understood and accepted. See ml\learnings.md.       |
//|  An account login allow-list guards against the wrong-account     |
//|  incident seen on this user's other bots.                         |
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
#define EA_BUILD_VERSION "v36"

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

input group "=== Account & Basic Settings ==="
input ulong    InpMagicNumber        = 20270115;  // Magic Number
input long     InpExpectedLogin      = 0;         // Account Login (0 = skip check - client sets their own)
input ENUM_BROKER_PRESET InpBrokerPreset = BROKER_CUSTOM;   // Broker Preset (auto-sets Max Spread)
input ENUM_ACCOUNT_TYPE  InpAccountType  = ACCOUNT_TYPE_USD; // Account Type (scales Max Spread for cent accounts)
input int      InpMaxSpreadPoints    = 300;       // Max Spread (points) - used when Broker Preset = Custom

input group "=== Basket & Profit Target ==="
input double   InpInitialLot            = 0.01;   // Initial Lot Size
input double   InpBasketProfitTargetUSD = 1.0;    // Take Profit ($) - grows a little every DCA leg (see GetProfitTarget())
// 2026-08-27: default raised 7->15 - the 17-config sweep (see
// ml/learnings.md) found 7 was one of the worst cycle lengths tested
// (blew the account net-negative on the August window); 15 was the
// tested baseline that survived, and 20/25 were only marginally
// different from it.
input int      InpMaxLegsPerBasket      = 15;     // Legs Per Sizing Cycle (lot size resets every N legs - keeps any single leg from hitting the broker's own max-lot cap; the basket itself has no total-leg cap - see the file header)
input double   InpCycleTargetGrowth     = 0.5;    // Target Growth Per Cycle (0.5 = +50%)
// 2026-08-24, explicit request: once a basket is genuinely underwater,
// its target should scale with HOW underwater it is, not just how many
// legs it's taken - "$5000 floating loss -> minimum $1000 profit before
// releasing" (a 20% ratio). See GetProfitTarget() - this becomes the
// dominant term once a basket is deep; the per-leg growth above still
// sets the (much smaller) target for early/shallow legs.
input double   InpTargetPercentOfFloatingLoss = 20.0; // Min Target As % Of Current Floating Loss (0 = off, use per-leg growth only)
// 2026-08-28, explicit request after the real 252424 stop-out (see
// ml/learnings.md): "with this much volume, didn't price come down even
// once - build a system that gets out easily, without a loss, once
// floating is high." The formula above does the OPPOSITE once a basket
// is deep - it demands MORE profit (20% of the floating loss) the worse
// things get, which is exactly wrong once total exposure is already
// dangerous: a basket carrying 30+ lots doesn't need a big dollar
// target, it needs to leave the instant it's not losing anymore, since
// waiting for a bigger target is what leaves it exposed for the broker's
// own stop-out to hit first. Once total basket volume crosses this
// threshold, the target drops to InpEmergencyExitTargetUSD (a small,
// still-no-loss number) instead of the 20%-of-floating-loss demand -
// only overrides the target when it would otherwise be LARGER, so this
// never demands more, only ever offers an earlier, easier exit.
input double   InpEmergencyExitVolumeLots = 20.0; // Emergency Exit: Total Basket Volume Threshold (lots, 0 = off)
input double   InpEmergencyExitTargetUSD  = 0.50; // Emergency Exit Target ($) - small but still > 0, never books an actual loss
// 2026-08-29, explicit request ("find some way, no matter what, without
// booking a loss") after both the lot cap and the emergency-exit target
// were shown (backtest + real live) to be unable to stop a genuinely
// one-directional, no-pullback move - because both still wait for a
// favorable tick, and the worst excursions found this project simply
// never give one. This is different in kind: it doesn't wait for
// anything or try to exit early - it just STOPS ADDING MORE RISK once
// total basket volume is already large, so a runaway move can no
// longer compound the exposure further no matter how long it keeps
// going. The basket does not close, no loss is booked - it just stops
// growing and waits (however long that takes) for its target, same as
// always. This turns an open-ended, unbounded worst case into a
// bounded one: past the cap, further adverse price movement costs a
// known, fixed rate ($ per point x capped volume) instead of an
// ever-accelerating one.
// 2026-08-29: swept 15/20/25/30/35/40/50/60 on both the full August
// window and the known 2026-08-24-27 stress window - first pass found
// a genuine plateau at 25-35, but that was against a BUGGY version of
// this check (see the bugfix note at the call site below): it compared
// the cap against volume BEFORE the next leg, letting one large
// (per-leg-capped, e.g. 17-lot) leg jump straight past the cap in a
// single addition. Confirmed on real 2026-07-01 CXM data - "cap 30,
// buggy" gave the IDENTICAL result to no cap at all. Fixed to check
// what the NEXT leg would bring the total to, then re-swept: 15-35 are
// now all WORSE than uncapped on the stress window (100-115% equity
// drawdown) - too tight, same "stuck longer" fragility as everywhere
// else in this project. The real plateau is 38-50 (all identical:
// stress-window equity drawdown 110.08% -> 79.08%, margin
// 0.29% -> 23.24%; full-month equity drawdown 40.62% -> 30.27%, net
// profit slightly improved). 60 is too loose (barely better than
// uncapped). Set to 40, the middle of the verified-correct plateau.
input double   InpMaxTotalBasketVolume = 40; // Max Total Basket Volume (lots, 0 = unlimited - stops adding NEW legs past this, existing legs untouched, no loss ever booked)
// 2026-08-31, explicit finding from a real live event (252424, same
// day): MT5's own margin stop-out does NOT necessarily close a whole
// basket at once - it closes legs one at a time (largest/most-losing
// first) until margin recovers, then stops. That real event closed
// 27.24 of 37.47 open lots, leaving 10.23 lots still open - which read
// as "under the 40-lot cap, room available" and let the EA immediately
// add ANOTHER 10.24-lot leg into the same still-adverse move, walking
// straight into a second stop-out minutes later that wiped the rest of
// the account. The volume cap alone has no memory of "this side just
// got stopped out" - it only sees current volume, which a partial
// stop-out can put right back under the cap. This cooldown gives that
// memory: once ANY leg on a side closes with DEAL_REASON_SO (the
// broker's own stop-out flag, not a string-matched comment), that
// whole side pauses - no bootstrap, no DCA-add - for this many hours,
// instead of immediately re-engaging into whatever just hurt it.
input int      InpStopOutCooldownHours = 24;  // Pause A Side After Its Own Stop-Out (hours, 0 = off)
input bool     InpUseServerSideTP       = true;   // Attach Real TP To Each Leg (fires on the broker's server, less slippage than the EA closing legs one-by-one)

input group "=== Margin Protection ==="
// 2026-08-31, explicit demand: every fix so far (per-leg lot cap, total
// basket volume cap, emergency exit target, stop-out cooldown) works by
// LIMITING EXPOSURE, an indirect proxy for margin safety - none of them
// look at the actual number that determines whether the broker forces a
// stop-out: live margin level. A cap tuned for one account size/balance
// (this project's 40-lot default was found on a ~$15-25k account) does
// not automatically stay safe on a different balance, leverage, or
// broker's own stop-out threshold. This is the direct fix: watch
// ACCOUNT_MARGIN_LEVEL itself (Equity/Margin x 100, the exact metric
// the broker's own stop-out compares against a threshold typically in
// the 20-50% range - this account's real stop-outs fired between 14%
// and 29%) and stop opening ANY new leg, on EITHER side, bootstrap or
// DCA, the moment margin level drops below a wide safety buffer above
// that zone. 200% default = roughly 7-14x the real observed stop-out
// range - existing legs are never touched, no loss is ever booked, this
// only ever refuses to add MORE risk once the account is already
// meaningfully margin-stressed, regardless of which basket or side
// caused it.
input double   InpMinMarginLevelPercent = 200.0; // Block New Legs Below This Margin Level % (0 = off)

input group "=== DCA / Martingale ==="
input double   InpDcaDistancePrice  = 1.2;        // DCA Distance ($)
input double   InpLotMultiplier     = 2.0;        // Lot Multiplier
input int      InpMinSecondsBetweenLegs = 5;      // Min Seconds Between Legs (safety net vs a cascade - 0 disables)
// 2026-08-28, explicit request after root-causing the 58% equity
// drawdown (a 2.5-minute spike that fired 9 back-to-back doublings, see
// ml/learnings.md): two independent, more targeted safety nets than
// InpMinSecondsBetweenLegs, tested against the same window. Result:
// InpMaxLegsPerBar backfired badly at every value tried (same
// mechanism as slowing InpMinSecondsBetweenLegs down - both throttle
// the fast re-averaging this design depends on to recover quickly) -
// stays off (0) by default. InpMaxSingleLegLot=17 genuinely improved
// BOTH net profit and equity drawdown together (58.03% -> 42.73%) -
// set as the new default.
input int      InpMaxLegsPerBar     = 0;          // Max DCA Legs Per M1 Bar (0 = unlimited - tested, made things worse, left off)
input double   InpMaxSingleLegLot   = 17;         // Max Single-Leg Lot Size (0 = unlimited - caps martingale growth without slowing the add cadence)

input group "=== Filters ==="
input bool             InpUseAtrSpikeFilter = true;      // Use ATR Spike Filter
input int              InpAtrPeriod         = 14;        // ATR Period
input int              InpAtrBaselineBars   = 20;        // ATR Baseline Bars
input double           InpMaxAtrRatio       = 1.5;       // Max ATR Ratio (spike threshold)
// 2026-08-27: default flipped true->false - the 17-config sweep found
// disabling the trend filter entirely gave BOTH the highest net profit
// AND the lowest equity drawdown (58.03% vs. 75.09% with it on) on the
// August 2026 window - counterintuitive (the filter exists to avoid
// fighting a strong move) and only tested on one month so far; a
// second month's data wasn't available at good tick quality to
// cross-check it (see ml/learnings.md, 2026-08-27 entries). Still the
// best real evidence available at the time this default was set.
input bool             InpUseTrendFilter    = false;     // Use Trend Filter
input ENUM_TIMEFRAMES  InpTrendTF           = PERIOD_H1; // Trend Timeframe
input int              InpTrendMAPeriod     = 50;        // Trend MA Period
input int              InpTrendAtrPeriod    = 14;        // Trend ATR Period
input double           InpTrendStrengthATRMult = 0.5;    // Trend Strength (x ATR)
input bool             InpUseMultiTFTrend   = true;      // Require Multiple Timeframes To Agree (2026-08-21: default on - "trend filter valo vabe kaj kore" - H1+H4+D1 must all agree, not just H1)
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

input group "=== Trading Hours ==="
// 2026-08-21, explicit request: new entries only from this hour onward each
// day (broker/server time, i.e. the same clock TimeCurrent() already uses
// everywhere else in this EA) - blocked before it, resumes automatically
// at the same hour the next day. Existing baskets keep being managed
// (closed at target, etc.) at any hour - this only gates NEW entries,
// same non-blocking pattern as every other gate in this EA.
input bool     InpUseTradingHours   = true; // Only Trade After This Hour Each Day
// 2026-08-29, explicit request: start trading 3h30m after the weekly
// market open (IST 3:30 AM), i.e. IST 07:00 - added minute precision
// since the hour-only input couldn't land on a half-hour IST time.
// CXM Direct's server clock is assumed GMT+3 (the standard MT5-broker
// convention, same as Exness/IC Markets) - NOT independently confirmed
// for this specific broker/account. IST = GMT+5:30, so IST 07:00 =
// server 04:30, which is what these two defaults are set to. If the
// real offset turns out to be different, these two inputs are exactly
// what needs adjusting - tell the actual broker-time-vs-IST difference
// once and both values get corrected precisely, no other code changes.
input int      InpTradingStartHour   = 4;    // Trading Start Hour (0-23, broker/server time)
input int      InpTradingStartMinute = 30;   // Trading Start Minute (0-59, broker/server time)

input group "=== Daily Profit Target ==="
input bool     InpUseDailyProfitTarget = false; // Stop New Trades After Reaching This Daily Profit
input double   InpDailyProfitTargetUSD = 50.0;  // Daily Profit Target ($) - resumes automatically next day

input group "=== Daily Loss Limit ==="
// Research into what separates surviving martingale/grid EAs from ones
// that blow up consistently names one feature above the others: "a hard
// stop loss enforced at the portfolio level - if cumulative drawdown
// hits the defined threshold, all positions close and the EA stops."
// This EA had a daily PROFIT target (above) but nothing on the loss
// side until now - added 2026-08-21. Off by default since it's new
// behavior that didn't exist before; the user should turn it on
// deliberately, not have it silently change how live accounts behave.
// Unlike DailyTargetHit() (which deliberately uses realized balance so
// it doesn't flicker on floating P/L noise), this checks EQUITY - a
// martingale basket's actual danger is in floating loss building up
// before anything is realized, so the whole point of this circuit
// breaker is to react to that, not wait for it to become permanent.
input bool     InpUseDailyLossLimit     = false; // Force-Close Everything If Daily Loss Hits This %
input double   InpDailyLossLimitPercent = 5.0;   // Daily Loss Limit (% of day-start balance, checked against live equity)

input group "=== Dashboard ==="
input bool     InpShowDashboard = true;   // Show Dashboard
input int      InpDashboardX    = 10;     // Dashboard X Position
input int      InpDashboardY    = 20;     // Dashboard Y Position
input bool     InpSetWhiteChartTheme = false; // White Chart Theme (off = dark, matches the Farhan FX brand's black logo background)

input group "=== Chart Visuals ==="
input bool     InpShowLegMarkers    = true; // Show DCA Leg Markers On Chart
input bool     InpShowCloseMarkers  = true; // Show Basket-Closed Markers On Chart
input bool     InpShowChartWatermark = true; // Show Farhan FX Watermark On Main Chart

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
   int      legsThisBar;     // 2026-08-28: how many of this basket's legs opened within the
                              // current M1 bar - feeds InpMaxLegsPerBar, a targeted brake on
                              // the multi-doublings-within-one-bar pattern behind the
                              // 2026-08-26 58% equity drawdown, without slowing normal
                              // spread-out DCA (see ml/learnings.md).
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
bool   g_dailyLossLimitLoggedToday = false;

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
   else
      ApplyBlackChartTheme(); // forces pure black - see comment on the function, this is what makes the watermark blend in correctly

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

   RestoreLegMarkersOnInit(); // reattach/restart: redraw markers for legs already open
   PositionWatermark();

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

   if(DailyLossLimitHit())
      ForceCloseOnDailyLossLimit();

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
   b.legsThisBar      = 0;
  }

void ScanBasket(ENUM_BASKET_SIDE side, SBasket &b)
  {
   ResetBasket(b);
   long wantType = (side == SIDE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   double sumPriceLots = 0;
   datetime curBarOpen = iTime(_Symbol, PERIOD_M1, 0);

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
      long     tMsc    = (long)PositionGetInteger(POSITION_TIME_MSC);

      b.legCount++;
      b.totalLots  += lots;
      b.floatingPL += profit;
      sumPriceLots += entry * lots;
      if(t >= curBarOpen)
         b.legsThisBar++;

      // Millisecond precision, not just POSITION_TIME (1-second resolution) -
      // two legs opening within the same second (this EA can do that; a
      // real incident on 2026-08-18 saw 7 legs open in ~9 seconds) used to
      // be indistinguishable by POSITION_TIME alone, which could pick the
      // WRONG leg as "most recent" and let the DCA-distance check compare
      // against a stale price - letting legs cascade far faster than
      // InpDcaDistancePrice was ever meant to allow.
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
// The target is not a flat number - it ramps up a little with EVERY DCA
// leg (2026-08-21, replaced the old once-per-full-cycle step function per
// explicit request: "target barbe protita DCA-te, cycle sesh hole na"). A
// basket that has taken on more legs has more capital and more adverse
// distance behind it, so it demands proportionally more profit before
// it's worth closing - same "martingale harder, want more profit"
// intent as before, just smooth instead of a sawtooth that only jumped
// once every InpMaxLegsPerBasket legs and then reset flat.
//
// Same overall growth RATE as before (InpCycleTargetGrowth per
// InpMaxLegsPerBasket legs), just spread evenly instead of dumped all at
// once at the cycle boundary - and unlike the old version, it never
// resets: legs 8, 9, 15, 30... keep compounding the target higher,
// reflecting that a basket that's genuinely survived that many legs has
// taken on real risk the flat/sawtooth version understated.
// The very first (bootstrap) leg always stays at the flat base - growth
// only starts from the first DCA add onward.
//
// 2026-08-24, explicit request: on top of the per-leg growth above, once
// a basket is genuinely underwater the target must scale with HOW deep
// it is, not just how many legs it took to get there - "$5000 floating
// loss -> minimum $1000 profit before releasing" (InpTargetPercentOfFloatingLoss,
// a 20% ratio by default). Two legs can both be "leg 6" with wildly
// different floating loss depending on how far price ran, and the old
// leg-count-only formula charged them the same target - this fixes that.
// The final target is whichever of the two is larger: the per-leg
// baseline still governs early/shallow legs (floating loss is small or
// even positive there, so the % term is near zero), while the floating-
// loss term takes over and dominates once a basket is deep underwater.
double GetProfitTarget(const SBasket &b)
  {
   double baseline;
   if(InpMaxLegsPerBasket <= 0 || b.legCount <= 1)
      baseline = InpBasketProfitTargetUSD;
   else
     {
      double growthPerLeg = InpCycleTargetGrowth / InpMaxLegsPerBasket;
      int legsPastFirst = b.legCount - 1;
      baseline = InpBasketProfitTargetUSD * (1.0 + legsPastFirst * growthPerLeg);
     }

   double floatingLossBased = 0;
   if(InpTargetPercentOfFloatingLoss > 0 && b.floatingPL < 0)
      floatingLossBased = MathAbs(b.floatingPL) * (InpTargetPercentOfFloatingLoss / 100.0);

   double target = MathMax(baseline, floatingLossBased);

   // Emergency exit: once total volume is already dangerous, stop
   // demanding more profit to release it - offer the smaller
   // (never-a-loss) target instead, so any small favorable move takes
   // it, rather than holding out for a bigger target that may never
   // come before the broker's own margin stop-out does. Only ever
   // LOWERS the target (MathMin), never raises it above what the
   // formula above already asked for.
   if(InpEmergencyExitVolumeLots > 0 && b.totalLots >= InpEmergencyExitVolumeLots)
      target = MathMin(target, InpEmergencyExitTargetUSD);

   return target;
  }

// The price level at which this basket's combined floating P/L (summed
// across every leg, using each leg's real entry price and volume - exactly
// what ScanBasket() already computes into weightedAvgEntry/totalLots)
// reaches GetProfitTarget(b). Same math the EA already uses on every tick
// to decide "target hit", just solved for price instead of re-evaluated
// tick by tick. Ignores swap (unknown ahead of time, accrues gradually and
// is usually tiny next to the target) - that's fine, this price only needs
// to be close; ManageBasketExits()'s tick-based floatingPL check (which
// does include swap) remains the final authority and stays in place
// unchanged as a backup.
//
// Uses SYMBOL_TRADE_TICK_VALUE / SYMBOL_TRADE_TICK_SIZE to convert the $
// target into a price distance, NOT SYMBOL_TRADE_CONTRACT_SIZE directly -
// found the hard way (2026-08-16, live on CXM demo) that contract size
// alone can disagree with how the broker's server actually computes
// POSITION_PROFIT (cent-account quirks etc.), which put the first version
// of this TP $100 away from entry instead of ~$1-2. tick_value/tick_size
// is the same per-price-unit-per-lot profit rate the broker itself uses,
// so it matches POSITION_PROFIT/floatingPL by construction regardless of
// contract-size peculiarities on any given symbol/broker.
double BasketTargetPrice(ENUM_BASKET_SIDE side, const SBasket &b)
  {
   if(b.totalLots <= 0)
      return 0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0)
      return 0;
   double profitPerPriceUnitPerLot = tickValue / tickSize;
   double priceDistance = GetProfitTarget(b) / (b.totalLots * profitPerPriceUnitPerLot);
   return (side == SIDE_BUY) ? (b.weightedAvgEntry + priceDistance) : (b.weightedAvgEntry - priceDistance);
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
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
         continue;
      if(PositionGetInteger(POSITION_TYPE) != wantType)
         continue;

      double currentTP = PositionGetDouble(POSITION_TP);
      if(MathAbs(currentTP - tp) < _Point) // already within a point of the right level - skip the modify call
         continue;

      if(!trade.PositionModify(ticket, 0, tp)) // 0 = no SL, per the standing no-SL-ever policy
         PrintFormat("GoldDualBasketDCA: failed to set TP on ticket %d (target price %.2f): retcode=%d %s - tick-based close remains as backup",
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
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
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
         PrintFormat("GoldDualBasketDCA: failed to close ticket %d (%s): retcode=%d %s",
                     (int)ticket, reason, trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }

   if(closedCount > 0)
     {
      PrintFormat("GoldDualBasketDCA: %s basket closed (%d leg(s)) - %s",
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

   if(IsBeforeTradingStart())
      return; // before InpTradingStartHour - existing baskets still manage/close normally, only new entries pause

   if(IsNewsBlackout())
      return; // paused around medium/high-impact news (calendar and/or manual window), both bootstrap and DCA-adds

   if(DailyTargetHit())
      return; // today's profit target already reached - resumes automatically at the next day rollover

   if(DailyLossLimitHit())
      return; // today's loss limit hit - OnTick() also force-closes both baskets, see there

   if(HadRecentStopOut(side))
      return; // this side was force-closed by the broker's own margin stop-out recently - pause it
              // (both bootstrap and DCA-adds) instead of immediately re-engaging into whatever hurt it

   if(MarginLevelTooLow())
      return; // account-wide margin is already stressed - refuse ANY new leg, either side, until
              // it recovers (existing legs untouched, no loss booked) - see InpMinMarginLevelPercent

   if(b.legCount == 0)
     {
      // Don't even start a basket fighting a strong higher-timeframe trend -
      // the doomed bootstrap entry itself is what runs a basket into trouble,
      // not just the DCA-adds after it.
      if(InpUseTrendFilter && IsAgainstTrend(side))
         return;
      OpenLeg(side, 0, 0);
      RefreshBaskets(); // pick up the leg just opened before computing its TP
      ApplyBasketTP(side);
      return;
     }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   bool adverse;
   if(side == SIDE_BUY)
      adverse = (bid <= b.lastLegEntry - InpDcaDistancePrice);
   else
      adverse = (ask >= b.lastLegEntry + InpDcaDistancePrice);

   // Temporary diagnostic (2026-08-18) - a live demo cascade wasn't explained
   // by the millisecond-tie-break fix alone (gaps were >= the cooldown, but
   // still far under InpDcaDistancePrice), so log the exact numbers behind
   // every DCA trigger until the real cause is confirmed from real data
   // instead of guessed at again.
   if(adverse)
      PrintFormat("GoldDualBasketDCA: DCA-DIAG %s adverse=true bid=%.3f ask=%.3f lastLegEntry=%.3f dcaDistanceInput=%.3f legCount=%d lastLegTime=%s",
                  (side == SIDE_BUY ? "BUY" : "SELL"), bid, ask, b.lastLegEntry, InpDcaDistancePrice, b.legCount,
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
      if(InpMaxLegsPerBar > 0 && b.legsThisBar >= InpMaxLegsPerBar)
         return; // this bar already used its quota - the next leg waits for the bar to close, per explicit request
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

      // 2026-08-29 bugfix: the total-volume cap MUST be checked against
      // what the NEXT leg would bring the total to, not just the volume
      // already open - checking b.totalLots alone let a single large
      // (per-leg-capped, e.g. 17-lot) leg jump straight past the total
      // cap in one shot, since the pre-leg volume could still be under
      // the threshold right up until that one leg pushed it far over.
      // Confirmed on real 2026-07-01 CXM data: with the cap "active" but
      // checked the old way, the exact same -$23,828.73 result occurred
      // as with no cap at all - leg 12 (17 lots) fired at a pre-leg
      // total of 19.2, jumping straight to 36.2, blowing through a
      // supposed 30-lot cap entirely unchecked. Now computes the
      // prospective lot size first and blocks if THAT would breach the
      // cap - this leg's addition is what has to stay under the limit,
      // not just the state before it.
      double prospectiveLot = NextLotSize(legIndexForSizing, b.lastLegLots);
      if(InpMaxTotalBasketVolume > 0 && (b.totalLots + prospectiveLot) > InpMaxTotalBasketVolume)
         return; // this leg would breach the total-volume cap - stop growing, existing legs keep waiting for target, no loss booked

      OpenLeg(side, legIndexForSizing, b.lastLegLots);
      RefreshBaskets(); // pick up the new leg + updated avg entry before recomputing the shared TP
      ApplyBasketTP(side);
      return;
     }
  }

double NextLotSize(int legCount, double previousLegLots)
  {
   double raw = InpInitialLot * MathPow(InpLotMultiplier, legCount);

   // 2026-08-28: caps exponential martingale growth without touching the
   // add cadence - a basket that hits the cap during a fast spike still
   // adds legs on the same schedule, just at a flat (then +1 step per
   // leg, since the monotonic-growth guarantee below still applies) size
   // instead of doubling every time. Directly targets the mechanism
   // behind the 2026-08-26 58% equity drawdown (9 doublings, 0.62->163.82
   // lots, in 2.5 minutes) - see ml/learnings.md.
   if(InpMaxSingleLegLot > 0)
      raw = MathMin(raw, InpMaxSingleLegLot);

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
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
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
      if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != (long)InpMagicNumber)
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

      PrintFormat("GoldDualBasketDCA: %s closed (deal #%d) - profit=%.2f swap=%.2f commission=%.2f net=%.2f",
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
//| Stop-out cooldown - see the 2026-08-31 explicit-request comment   |
//| above InpStopOutCooldownHours for the real live incident this     |
//| was built for.                                                    |
//+------------------------------------------------------------------+
// Scans closed deals for this symbol+magic within the cooldown window
// for one whose DEAL_REASON is DEAL_REASON_SO (the broker's own stop-
// out flag - not a string match on the comment, which is broker/locale
// dependent and was only used for this file's own logging/diagnosis,
// never as a detection mechanism until now). A DEAL_TYPE_BUY closing
// deal means a SELL position was stopped out, and vice versa - same
// inverted mapping ManageBasketEntries()/ScanBasket() already use.
// Cached, not re-scanned every call: this is checked from
// ManageBasketEntries() on every tick, and a full HistorySelect() +
// HistoryDealsTotal() loop over a whole day's deals (an active DCA
// basket can produce thousands) on every single tick would be wasteful
// - the underlying answer only changes at most once every few seconds
// (right after an actual stop-out), so a short cache is free accuracy-
// wise and saves real CPU.
datetime g_lastStopOutScan = 0;
bool     g_stopOutCooldownBuy = false;
bool     g_stopOutCooldownSell = false;
#define STOP_OUT_SCAN_INTERVAL_SEC 10

void RefreshStopOutCooldowns()
  {
   if(TimeCurrent() - g_lastStopOutScan < STOP_OUT_SCAN_INTERVAL_SEC)
      return;
   g_lastStopOutScan = TimeCurrent();
   g_stopOutCooldownBuy = false;
   g_stopOutCooldownSell = false;
   if(InpStopOutCooldownHours <= 0)
      return;
   datetime from = TimeCurrent() - InpStopOutCooldownHours * 3600;
   if(!HistorySelect(from, TimeCurrent()))
      return;
   int total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol)
         continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != (long)InpMagicNumber)
         continue;
      if((ENUM_DEAL_REASON)HistoryDealGetInteger(ticket, DEAL_REASON) != DEAL_REASON_SO)
         continue;
      ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket, DEAL_TYPE);
      if(dealType == DEAL_TYPE_BUY)
         g_stopOutCooldownSell = true;  // a buy deal closes a sell position
      else if(dealType == DEAL_TYPE_SELL)
         g_stopOutCooldownBuy = true;   // a sell deal closes a buy position
      if(g_stopOutCooldownBuy && g_stopOutCooldownSell)
         break; // both sides already confirmed, no need to keep scanning
     }
  }

bool HadRecentStopOut(ENUM_BASKET_SIDE side)
  {
   if(InpStopOutCooldownHours <= 0)
      return false;
   RefreshStopOutCooldowns();
   return (side == SIDE_BUY) ? g_stopOutCooldownBuy : g_stopOutCooldownSell;
  }

//+------------------------------------------------------------------+
//| Margin protection - see InpMinMarginLevelPercent's comment for    |
//| the full 2026-08-31 explicit-request context.                     |
//+------------------------------------------------------------------+
// ACCOUNT_MARGIN_LEVEL is exactly Equity/Margin*100 - the same number
// the broker's own stop-out logic compares against its own threshold.
// With zero open positions MT5 reports margin level as 0 (nothing to
// divide by) - that must NOT read as "critically low," so this only
// engages once real margin is actually in use.
bool MarginLevelTooLow()
  {
   if(InpMinMarginLevelPercent <= 0)
      return false;
   double marginUsed  = AccountInfoDouble(ACCOUNT_MARGIN);
   double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   if(marginUsed <= 0)
      return false; // no open exposure at all - nothing to be stressed about
   return(marginLevel < InpMinMarginLevelPercent);
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
      g_dailyLossLimitLoggedToday = false; // new day - the loss-limit force-close can fire (and log) again if needed
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

// Blocks new entries before InpTradingStartHour each day - existing
// baskets keep being managed regardless (same non-blocking gate pattern
// as every other check here). No "end hour" - once past the start hour,
// stays open for the rest of that day; resets automatically at midnight
// server time since the hour check is re-evaluated fresh every call.
bool IsBeforeTradingStart()
  {
   if(!InpUseTradingHours)
      return false;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.hour != InpTradingStartHour)
      return(dt.hour < InpTradingStartHour);
   return(dt.min < InpTradingStartMinute); // same hour - minute decides
  }

// Equity-based, on purpose - see the input group comment above for why
// this deliberately does NOT use the same realized-balance-only approach
// as DailyTargetHit(). Once true, ManageBasketEntries() halts new entries
// (existing non-blocking gate pattern) and OnTick() additionally force-
// closes both baskets - the two together are what actually cap the day's
// worst case, not just stop it from getting worse via new legs.
bool DailyLossLimitHit()
  {
   if(!InpUseDailyLossLimit || g_dayStartBalance <= 0)
      return false;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPct = (g_dayStartBalance - equity) / g_dayStartBalance * 100.0;
   return(lossPct >= InpDailyLossLimitPercent);
  }

// Called every tick once DailyLossLimitHit() is true - closes both
// baskets outright (not just "stop adding new legs", which is what the
// non-blocking ManageBasketEntries() gate already does on its own).
// Idempotent: once there's nothing left to close, CloseBasket() is a
// harmless no-op, so calling this repeatedly every tick for the rest of
// the day is fine - only logs once per day via g_dailyLossLimitLoggedToday.
void ForceCloseOnDailyLossLimit()
  {
   if(!g_dailyLossLimitLoggedToday)
     {
      PrintFormat("GoldDualBasketDCA: DAILY LOSS LIMIT HIT (%.1f%% of day-start balance) - force-closing both baskets.",
                  InpDailyLossLimitPercent);
      g_dailyLossLimitLoggedToday = true;
     }
   RefreshBaskets();
   CloseBasket(SIDE_BUY, "daily loss limit hit", g_buyBasket.floatingPL);
   CloseBasket(SIDE_SELL, "daily loss limit hit", g_sellBasket.floatingPL);
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
   DbLabel("Title", x + 70, y, "SCALPING AI PRO", clrWhite, 9);
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
   string dailyTargetText = !InpUseDailyProfitTarget ? "off"
                             : dailyTargetHit ? "HIT (paused today)"
                             : "$" + DoubleToString(dailyPL, 2) + " / $" + DoubleToString(InpDailyProfitTargetUSD, 2);
   DbLabel("DailyTarget", lx, y, PadRight("Daily Target", lblW) + dailyTargetText,
           dailyTargetHit ? clrLime : clrSilver, 8);
   y += lh;
   bool dailyLossHit = DailyLossLimitHit();
   double dailyLossPct = (g_dayStartBalance > 0) ? (g_dayStartBalance - equity) / g_dayStartBalance * 100.0 : 0;
   string dailyLossText = !InpUseDailyLossLimit ? "off"
                           : dailyLossHit ? "HIT (baskets closed)"
                           : DoubleToString(dailyLossPct, 1) + "% / " + DoubleToString(InpDailyLossLimitPercent, 1) + "%";
   DbLabel("DailyLoss", lx, y, PadRight("Daily Loss Limit", lblW) + dailyLossText,
           dailyLossHit ? clrRed : clrSilver, 8);
   y += lh;
   bool beforeStart = IsBeforeTradingStart();
   string tradingHoursText = !InpUseTradingHours ? "off"
                              : beforeStart ? StringFormat("before %02d:%02d (paused)", InpTradingStartHour, InpTradingStartMinute)
                              : StringFormat("open (from %02d:%02d)", InpTradingStartHour, InpTradingStartMinute);
   DbLabel("TradingHours", lx, y, PadRight("Trading Hours", lblW) + tradingHoursText,
           beforeStart ? clrOrange : clrSilver, 8);
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
                      ? (SymbolInfoDouble(_Symbol, SYMBOL_BID) - (g_buyBasket.lastLegEntry - InpDcaDistancePrice)) : 0;
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
                       ? ((g_sellBasket.lastLegEntry + InpDcaDistancePrice) - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) : 0;
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
   y += lh;
   bool buyStopOutCooldown  = HadRecentStopOut(SIDE_BUY);
   bool sellStopOutCooldown = HadRecentStopOut(SIDE_SELL);
   string soText = (InpStopOutCooldownHours <= 0) ? "off"
                   : (buyStopOutCooldown && sellStopOutCooldown) ? "BUY+SELL paused"
                   : buyStopOutCooldown  ? "BUY paused"
                   : sellStopOutCooldown ? "SELL paused"
                   : "clear";
   DbLabel("StopOutCooldown", lx, y, PadRight("SO Cooldown", lblW) + soText,
           (buyStopOutCooldown || sellStopOutCooldown) ? clrOrange : clrSilver, 8);
   y += lh;
   bool marginTooLow = MarginLevelTooLow();
   double liveMarginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   string marginText = (InpMinMarginLevelPercent <= 0) ? "off"
                        : (AccountInfoDouble(ACCOUNT_MARGIN) <= 0) ? "no exposure"
                        : DoubleToString(liveMarginLevel, 0) + "% / " + DoubleToString(InpMinMarginLevelPercent, 0) + "%"
                          + (marginTooLow ? " (blocking)" : "");
   DbLabel("MarginGuard", lx, y, PadRight("Margin Guard", lblW) + marginText,
           marginTooLow ? clrRed : clrSilver, 8);
   y += lh;

   y += 10;

   ChartRedraw();
  }
//+------------------------------------------------------------------+
