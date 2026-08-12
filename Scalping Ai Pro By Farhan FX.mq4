//+------------------------------------------------------------------+
//|                                      GoldDualBasketDCA.mq4        |
//|  MT4 port of the MT5 EA "Scalping Ai Pro By Farhan FX" (v4).      |
//|  XAUUSD M1 dual-basket grid/DCA EA. Simultaneous BUY + SELL       |
//|  baskets - MT4 accounts inherently allow this (no netting/hedging|
//|  mode concept like MT5, so no account-mode check is needed here).|
//|  Each basket targets a floating-profit dollar amount, closes,    |
//|  and immediately reopens. On a $-price adverse move past the     |
//|  last leg, adds a martingale DCA leg, capped at a max legs/      |
//|  basket. ATR-spike + higher-timeframe trend filters gate DCA     |
//|  adds. No stop-loss anywhere, ever - per explicit, repeated user |
//|  request (always martingale an against-trend basket until it    |
//|  hits its profit target, no exceptions, no pauses). An account   |
//|  login allow-list guards against the wrong-account incident seen |
//|  on this user's other bots.                                     |
//|                                                                    |
//|  2026-08-12: ported from the MT5 version. One feature could NOT   |
//|  be carried over: the News Filter. MT5 has a built-in economic    |
//|  calendar (CalendarValueHistory/CalendarEventById) that MT4 does  |
//|  not have - there is no native equivalent, so it's simply absent  |
//|  here rather than faked with something unreliable. Everything     |
//|  else (basket logic, DCA/martingale, ATR-spike filter, trend      |
//|  filter, no-SL policy, dashboard) matches the MT5 version          |
//|  exactly. See the MT5 file's own header/ml\learnings.md for the   |
//|  full history of how this EA got here.                            |
//+------------------------------------------------------------------+
#property copyright "FarhanFX Algo"
#property version   "1.00"
#property strict
#property description "Dual-basket (buy+sell) grid/DCA EA for XAUUSD M1 - MT4 port."

// Bump this on every change that gets deployed anywhere (local or VPS).
// Simple v1, v2, v3... (matches the MT5 file's convention). This MT4 port
// starts its own count at v1 - it mirrors MT5 v4's behavior (minus the
// News Filter, see header above) but is tracked as its own file/lineage.
#define EA_BUILD_VERSION "v1"

#define SIDE_BUY  0
#define SIDE_SELL 1

input group "=== Account & Basic Settings ==="
input int      InpMagicNumber        = 20270115;  // Magic Number
input long     InpExpectedLogin      = 416045126; // Account Login (0 = skip check)
input int      InpMaxSpreadPoints    = 300;       // Max Spread (points)
input int      InpSlippagePoints     = 50;        // Slippage (points)

input group "=== Basket & Profit Target ==="
input double   InpInitialLot            = 0.02;   // Initial Lot Size
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

input group "=== Dashboard ==="
input bool     InpShowDashboard = true;   // Show Dashboard
input int      InpDashboardX    = 10;     // Dashboard X Position
input int      InpDashboardY    = 20;     // Dashboard Y Position
input bool     InpSetWhiteChartTheme = true; // White Chart Theme

struct SBasket
  {
   int      legCount;
   double   totalLots;
   double   floatingPL;
   double   weightedAvgEntry;
   int      lastLegTicket;
   double   lastLegEntry;
   double   lastLegLots;
   datetime lastLegTime;
  };

SBasket g_buyBasket, g_sellBasket;

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
   if(InpExpectedLogin != 0 && AccountNumber() != InpExpectedLogin)
     {
      PrintFormat("GoldDualBasketDCA: connected account %d does not match InpExpectedLogin %d. Refusing to run.",
                  AccountNumber(), (int)InpExpectedLogin);
      return(INIT_FAILED);
     }

   if(InpSetWhiteChartTheme)
      ApplyWhiteChartTheme();

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

void ScanBasket(int side, SBasket &b)
  {
   ResetBasket(b);
   int wantType = (side == SIDE_BUY) ? OP_BUY : OP_SELL;
   double sumPriceLots = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderSymbol() != Symbol())
         continue;
      if(OrderMagicNumber() != InpMagicNumber)
         continue;
      if(OrderType() != wantType)
         continue;

      double   lots    = OrderLots();
      double   entry   = OrderOpenPrice();
      double   profit  = OrderProfit() + OrderSwap() + OrderCommission();
      datetime t       = OrderOpenTime();

      b.legCount++;
      b.totalLots  += lots;
      b.floatingPL += profit;
      sumPriceLots += entry * lots;

      if(t >= b.lastLegTime)
        {
         b.lastLegTime   = t;
         b.lastLegEntry  = entry;
         b.lastLegLots   = lots;
         b.lastLegTicket = OrderTicket();
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

void ManageBasketExits(int side)
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
      CloseBasket(side, StringFormat("BASKET TARGET HIT (floatingPL=%.2f >= target=%.2f)", b.floatingPL, target));
  }

void CloseBasket(int side, string reason)
  {
   int wantType = (side == SIDE_BUY) ? OP_BUY : OP_SELL;
   int closedCount = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderSymbol() != Symbol())
         continue;
      if(OrderMagicNumber() != InpMagicNumber)
         continue;
      if(OrderType() != wantType)
         continue;

      double closePrice = (wantType == OP_BUY) ? MarketInfo(Symbol(), MODE_BID) : MarketInfo(Symbol(), MODE_ASK);
      int ticket = OrderTicket();
      double lots = OrderLots();
      if(OrderClose(ticket, lots, closePrice, InpSlippagePoints, clrNONE))
         closedCount++;
      else
         PrintFormat("GoldDualBasketDCA: failed to close ticket %d (%s): err=%d", ticket, reason, GetLastError());
     }

   if(closedCount > 0)
      PrintFormat("GoldDualBasketDCA: %s basket closed (%d leg(s)) - %s",
                  (side == SIDE_BUY ? "BUY" : "SELL"), closedCount, reason);
  }

//+------------------------------------------------------------------+
//| Entries: bootstrap (empty basket) and DCA (adverse move)          |
//+------------------------------------------------------------------+
void ManageBasketEntries(int side)
  {
   SBasket b;
   if(side == SIDE_BUY)
      b = g_buyBasket;
   else
      b = g_sellBasket;

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

   double bid = MarketInfo(Symbol(), MODE_BID);
   double ask = MarketInfo(Symbol(), MODE_ASK);

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
     }
  }

double NextLotSize(int legCount, double previousLegLots)
  {
   double raw = InpInitialLot * MathPow(InpLotMultiplier, legCount);

   double minLot  = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot  = MarketInfo(Symbol(), MODE_MAXLOT);
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);

   double lots = MathRound(raw / lotStep) * lotStep;
   // Rounding can collapse two consecutive legs to the same step (e.g. 1.5x
   // growth on a 0.01 step) - guarantee monotonic martingale growth anyway.
   if(legCount > 0 && lots <= previousLegLots)
      lots = previousLegLots + lotStep;

   lots = MathMax(minLot, MathMin(maxLot, lots));
   return NormalizeDouble(lots, 2);
  }

void OpenLeg(int side, int legIndexForSizing, double previousLegLots)
  {
   double lots = NextLotSize(legIndexForSizing, previousLegLots);
   if(lots <= 0)
      return;

   string comment = StringFormat("FarhanFx-%s-leg%d", (side == SIDE_BUY ? "buy" : "sell"), legIndexForSizing + 1);
   int ticket;

   // No stop-loss on any leg, ever - per explicit, repeated request. Basket
   // exits only happen via the profit target in ManageBasketExits().
   if(side == SIDE_BUY)
     {
      double price = MarketInfo(Symbol(), MODE_ASK);
      ticket = OrderSend(Symbol(), OP_BUY, lots, price, InpSlippagePoints, 0, 0, comment, InpMagicNumber, 0, clrBlue);
     }
   else
     {
      double price = MarketInfo(Symbol(), MODE_BID);
      ticket = OrderSend(Symbol(), OP_SELL, lots, price, InpSlippagePoints, 0, 0, comment, InpMagicNumber, 0, clrRed);
     }

   if(ticket < 0)
      PrintFormat("GoldDualBasketDCA: %s leg open failed (lot=%.2f): err=%d",
                  (side == SIDE_BUY ? "BUY" : "SELL"), lots, GetLastError());
  }

//+------------------------------------------------------------------+
//| DCA filters                                                       |
//+------------------------------------------------------------------+
bool IsAtrSpiking()
  {
   double current = iATR(Symbol(), PERIOD_M1, InpAtrPeriod, 1);
   double sum = 0;
   for(int i = 2; i <= InpAtrBaselineBars + 1; i++)
      sum += iATR(Symbol(), PERIOD_M1, InpAtrPeriod, i);
   double baseline = sum / InpAtrBaselineBars;

   if(baseline <= 0)
      return false;

   return(current > baseline * InpMaxAtrRatio);
  }

// Trend on InpTrendTF via MA + ATR-scaled strength gate: last closed candle
// must sit at least InpTrendStrengthATRMult ATRs away from the MA to count
// as trending (1=up, -1=down); anything closer is treated as noise/no-trend
// (0). A raw close-vs-MA check flips sign on ordinary chop, which would
// block far more entries than intended - the ATR margin only catches
// genuinely sustained, strong moves.
int GetTrend()
  {
   if(!InpUseTrendFilter)
      return 0;

   double ma  = iMA(Symbol(), InpTrendTF, InpTrendMAPeriod, 0, MODE_SMA, PRICE_CLOSE, 1);
   double atr = iATR(Symbol(), InpTrendTF, InpTrendAtrPeriod, 1);
   if(atr <= 0)
      return 0;

   double closePrice = iClose(Symbol(), InpTrendTF, 1);
   double margin = atr * InpTrendStrengthATRMult;

   if(closePrice > ma + margin)
      return 1;
   if(closePrice < ma - margin)
      return -1;
   return 0;
  }

bool IsAgainstTrend(int side)
  {
   int trend = GetTrend();
   if(side == SIDE_BUY)
      return(trend == -1);
   return(trend == 1);
  }

//+------------------------------------------------------------------+
//| Spread / day tracking                                             |
//+------------------------------------------------------------------+
bool SpreadIsAcceptable()
  {
   double spread = MarketInfo(Symbol(), MODE_SPREAD);
   return(spread <= InpMaxSpreadPoints);
  }

void UpdateDayTracking()
  {
   datetime now = TimeCurrent();
   int todayCode = TimeYear(now) * 10000 + TimeMonth(now) * 100 + TimeDay(now);
   if(todayCode != g_dayStartDateCode)
     {
      g_dayStartDateCode = todayCode;
      g_dayStartBalance  = AccountBalance();
     }
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

   CreateButton("CloseAllBtn", InpDashboardX, InpDashboardY + 356, 260, 24, "X  CLOSE ALL", C'120,20,20');
   CreateButton("CloseBuyBtn", InpDashboardX, InpDashboardY + 384, 126, 22, "Close BUY", C'20,80,20');
   CreateButton("CloseSellBtn", InpDashboardX + 134, InpDashboardY + 384, 126, 22, "Close SELL", C'20,80,20');
  }

void UpdateDashboard()
  {
   RefreshBaskets();

   int x = InpDashboardX, lx = InpDashboardX + 2, y = InpDashboardY, lh = 15, lblW = 12;

   DbLabel("Title", x, y, "SCALPING AI PRO BY FARHAN FX", clrWhite, 9);
   y += lh;
   DbLabel("Version", lx, y, EA_BUILD_VERSION + " (MT4)", clrGray, 7);
   y += lh + 6;

   bool loginOk = (InpExpectedLogin == 0 || AccountNumber() == InpExpectedLogin);
   DbLabel("Login", lx, y, PadRight("Login", lblW) + IntegerToString(AccountNumber()),
           loginOk ? clrSilver : clrRed, 8);
   y += lh;

   double balance = AccountBalance();
   double equity  = AccountEquity();
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
                      ? (MarketInfo(Symbol(), MODE_BID) - (g_buyBasket.lastLegEntry - InpDcaDistancePrice)) : 0;
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
                       ? ((g_sellBasket.lastLegEntry + InpDcaDistancePrice) - MarketInfo(Symbol(), MODE_ASK)) : 0;
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
   y += lh + 10;

   ChartRedraw();
  }
//+------------------------------------------------------------------+
