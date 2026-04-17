//+------------------------------------------------------------------+
//|  ScalpingGridEA_GOLD.mq5                                         |
//|  Grid Scalping EA — XAUUSD Optimized                             |
//|  Compatible: MT5                                                 |
//|                                                                  |
//|  GOLD specifics:                                                 |
//|   - _Point = 0.01  (1 pip = $1 = 100 points)                    |
//|   - Typical daily range: $15-40 (1500-4000 pts)                 |
//|   - Higher spread: 20-50 pts normal                              |
//|   - ATR-dynamic grid spacing                                     |
//|   - H4 trend filter to avoid counter-trend grids                 |
//|   - Volatility spike guard (no entry when ATR > threshold)       |
//+------------------------------------------------------------------+
#property copyright "ScalpingGridEA_GOLD"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

CTrade        trade;
CPositionInfo posInfo;
COrderInfo    orderInfo;

//--- Inputs: Grid
input group "=== GRID SETTINGS ==="
input double  GridStep_Dollar   = 2.0;   // Grid step in USD (ex: 2.0 = $2)
input bool    UseATRGrid        = true;  // Dynamic grid step (ATR-based)
input double  ATRGridMultiplier = 0.30;  // ATR multiplier for grid step
input int     MaxGridLevels     = 6;     // Max grid levels
input double  LotStart          = 0.01;  // Starting lot size
input double  LotMultiplier     = 1.6;   // Lot multiplier per level
input bool    UseAntiMartingale = false; // Anti-martingale mode

//--- Inputs: Indicators
input group "=== INDICATORS ==="
input int     FastMA_Period     = 8;     // Fast EMA (M5)
input int     SlowMA_Period     = 21;    // Slow EMA (M5)
input int     TrendMA_Period    = 50;    // Trend EMA (H4 — direction filter)
input int     RSI_Period        = 14;    // RSI period
input double  RSI_OB            = 65.0;  // RSI overbought (gold: less strict)
input double  RSI_OS            = 35.0;  // RSI oversold   (gold: less strict)
input int     ATR_Period        = 14;    // ATR period (M5)
input double  ATR_MaxMultiplier = 2.5;   // Max ATR x avg = no entry (news guard)

//--- Inputs: TP/SL  (in USD, converted to points internally)
input group "=== TAKE PROFIT / STOP LOSS (USD) ==="
input double  TP_Dollar         = 3.0;   // TP per level ($)
input double  BasketTP_Dollar   = 10.0;  // Grid basket TP ($) — closes all
input double  SL_Dollar         = 20.0;  // Emergency SL per position ($)
input bool    UseTrailingStop   = true;  // Trailing stop
input double  TrailStart_Dollar = 2.5;   // Trail starts after ($)
input double  TrailStep_Dollar  = 1.0;   // Trail step ($)

//--- Inputs: Risk
input group "=== RISK MANAGEMENT ==="
input double  MaxDrawdownPct    = 12.0;  // Max drawdown % (closes all)
input bool    UseAutoLot        = false; // Auto lot (risk % per trade)
input double  RiskPercent       = 1.0;   // Risk % of balance per trade
input double  MaxSpread_Dollar  = 0.50;  // Max spread in $ (50 pts = $0.50)
input int     MagicNumber       = 99471; // Magic number (GOLD EA)
input int     MaxPositions      = 12;    // Hard cap total open positions

//--- Inputs: Sessions (UTC)
input group "=== SESSION FILTER ==="
input bool    UseSessions       = true;  // Enable session filter
input int     AsiaOpen          = 1;     // Tokyo open (UTC)
input int     AsiaClose         = 7;     // Tokyo close (UTC)
input int     LondonOpen        = 8;     // London open (UTC)
input int     LondonClose       = 17;    // London close (UTC)
input int     NYOpen            = 13;    // NY open (UTC)
input int     NYClose           = 22;    // NY close (UTC)
input bool    TradeAsia         = false; // Include Asian session (lower vol)

//--- Inputs: Display
input group "=== DISPLAY ==="
input bool    ShowDashboard     = true;  // Show live dashboard

//--- Globals
double  g_point;
int     g_digits;
double  g_gridBase    = 0.0;
bool    g_gridBuy     = false;
bool    g_gridSell    = false;

int     g_fastMA_h;
int     g_slowMA_h;
int     g_trendMA_h;   // H4 EMA
int     g_rsi_h;
int     g_atr_h;
int     g_atrAvg_h;    // ATR on H1 to compute average (news guard)

double  g_startBalance;
int     g_totalTrades = 0;
int     g_totalWins   = 0;
double  g_totalProfit = 0.0;
double  g_maxDrawdown = 0.0;
double  g_peakEquity  = 0.0;

//+------------------------------------------------------------------+
int OnInit()
  {
   //--- Symbol guard: only XAUUSD or XAU*
   string sym = _Symbol;
   if(StringFind(sym, "XAU") < 0 && StringFind(sym, "GOLD") < 0)
     {
      MessageBox("This EA is designed for XAUUSD (GOLD) only.\nCurrent symbol: " + sym,
                 "Wrong Symbol", MB_ICONERROR);
      return INIT_FAILED;
     }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);  // Gold needs more slippage tolerance
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   g_point  = _Point;   // 0.01 for XAUUSD
   g_digits = _Digits;  // 2 for XAUUSD

   g_fastMA_h  = iMA(_Symbol, PERIOD_M5,  FastMA_Period,  0, MODE_EMA, PRICE_CLOSE);
   g_slowMA_h  = iMA(_Symbol, PERIOD_M5,  SlowMA_Period,  0, MODE_EMA, PRICE_CLOSE);
   g_trendMA_h = iMA(_Symbol, PERIOD_H4,  TrendMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   g_rsi_h     = iRSI(_Symbol, PERIOD_M5, RSI_Period, PRICE_CLOSE);
   g_atr_h     = iATR(_Symbol, PERIOD_M5, ATR_Period);
   g_atrAvg_h  = iATR(_Symbol, PERIOD_H1, ATR_Period);  // broader volatility context

   if(g_fastMA_h  == INVALID_HANDLE || g_slowMA_h == INVALID_HANDLE ||
      g_trendMA_h == INVALID_HANDLE || g_rsi_h    == INVALID_HANDLE ||
      g_atr_h     == INVALID_HANDLE || g_atrAvg_h == INVALID_HANDLE)
     {
      Print("ERROR: indicator handle creation failed.");
      return INIT_FAILED;
     }

   g_startBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_peakEquity   = g_startBalance;

   Print("ScalpingGridEA_GOLD ready | Balance: ", g_startBalance,
         " | Symbol: ", _Symbol);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(g_fastMA_h);
   IndicatorRelease(g_slowMA_h);
   IndicatorRelease(g_trendMA_h);
   IndicatorRelease(g_rsi_h);
   IndicatorRelease(g_atr_h);
   IndicatorRelease(g_atrAvg_h);
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double ddPct   = (g_peakEquity > 0.0) ? (g_peakEquity - equity) / g_peakEquity * 100.0 : 0.0;

   if(equity > g_peakEquity) g_peakEquity = equity;
   if(ddPct  > g_maxDrawdown) g_maxDrawdown = ddPct;

   //--- Hard drawdown cut
   if(ddPct >= MaxDrawdownPct)
     {
      CloseAllPositions("MAX DRAWDOWN");
      return;
     }

   //--- Max positions guard
   int totalPos = CountAllPositions();
   if(totalPos >= MaxPositions) return;

   //--- Spread check (in dollar terms)
   double spreadPts = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double spreadDollar = spreadPts * g_point;  // each point = $0.01 for XAUUSD
   if(spreadDollar > MaxSpread_Dollar)
      return;

   //--- Session filter
   if(UseSessions && !IsInSession())
      return;

   //--- Read indicators
   double fastMA[3], slowMA[3], trendMA[3], rsiVal[3], atr[3], atrH1[3];
   if(CopyBuffer(g_fastMA_h,  0, 0, 3, fastMA)  < 3) return;
   if(CopyBuffer(g_slowMA_h,  0, 0, 3, slowMA)  < 3) return;
   if(CopyBuffer(g_trendMA_h, 0, 0, 3, trendMA) < 3) return;
   if(CopyBuffer(g_rsi_h,     0, 0, 3, rsiVal)  < 3) return;
   if(CopyBuffer(g_atr_h,     0, 0, 3, atr)     < 3) return;
   if(CopyBuffer(g_atrAvg_h,  0, 0, 3, atrH1)   < 3) return;

   double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double midPrice = (ask + bid) / 2.0;

   //--- Volatility spike guard: if current ATR >> H1 ATR average, skip (news/spike)
   double atrRatio = (atrH1[0] > 0.0) ? (atr[0] * 12.0) / atrH1[0] : 1.0;
   if(atrRatio > ATR_MaxMultiplier)
      return;

   //--- Dynamic grid step based on ATR
   double gridStepDollar = UseATRGrid
                           ? atr[0] * ATRGridMultiplier * 100.0   // ATR in points * mult -> $
                           : GridStep_Dollar;
   gridStepDollar = MathMax(gridStepDollar, 0.50);  // minimum $0.50 grid step

   //--- Trend direction from H4
   bool h4Bull = midPrice > trendMA[0];
   bool h4Bear = midPrice < trendMA[0];

   //--- M5 signal
   bool m5Bull = fastMA[0] > slowMA[0] && fastMA[1] <= slowMA[1]; // fresh cross up
   bool m5Bear = fastMA[0] < slowMA[0] && fastMA[1] >= slowMA[1]; // fresh cross down

   //--- RSI confirmation
   bool rsiBuy  = rsiVal[0] < RSI_OS;
   bool rsiSell = rsiVal[0] > RSI_OB;

   int buyCount  = CountPositions(POSITION_TYPE_BUY);
   int sellCount = CountPositions(POSITION_TYPE_SELL);

   //--- Trailing stop
   if(UseTrailingStop)
      ManageTrailingStop();

   //--- Basket TP
   CheckBasketTP();

   //--- ─── ENTRY ────────────────────────────────────────────────
   //  Only open first level if:
   //    • H4 trend aligned
   //    • M5 EMA crossover (fresh signal) OR RSI at extreme
   //    • No existing grid in same direction
   // ──────────────────────────────────────────────────────────────

   bool canBuy  = h4Bull && (m5Bull || rsiBuy)  && buyCount  == 0 && sellCount == 0;
   bool canSell = h4Bear && (m5Bear || rsiSell) && sellCount == 0 && buyCount  == 0;

   if(canBuy)
     {
      double lot = CalculateLot(0);
      if(OpenPosition(ORDER_TYPE_BUY, lot))
        {
         g_gridBase = ask;
         g_gridBuy  = true;
         g_gridSell = false;
        }
     }
   else if(canSell)
     {
      double lot = CalculateLot(0);
      if(OpenPosition(ORDER_TYPE_SELL, lot))
        {
         g_gridBase = bid;
         g_gridBuy  = false;
         g_gridSell = true;
        }
     }

   //--- ─── GRID LEVELS ──────────────────────────────────────────
   if(g_gridBuy && buyCount > 0 && buyCount < MaxGridLevels)
     {
      double lastPrice = GetLastOpenPrice(POSITION_TYPE_BUY);
      if(lastPrice > 0.0 && (lastPrice - ask) >= gridStepDollar)
        {
         double lot = CalculateLot(buyCount);
         OpenPosition(ORDER_TYPE_BUY, lot);
        }
     }

   if(g_gridSell && sellCount > 0 && sellCount < MaxGridLevels)
     {
      double lastPrice = GetLastOpenPrice(POSITION_TYPE_SELL);
      if(lastPrice > 0.0 && (bid - lastPrice) >= gridStepDollar)
        {
         double lot = CalculateLot(sellCount);
         OpenPosition(ORDER_TYPE_SELL, lot);
        }
     }

   //--- Dashboard
   if(ShowDashboard)
      DrawDashboard(equity, balance, ddPct, buyCount, sellCount,
                    rsiVal[0], atr[0], gridStepDollar, atrRatio);
  }

//+------------------------------------------------------------------+
bool OpenPosition(ENUM_ORDER_TYPE type, double lot)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   //--- Convert $ values to points
   double tpPts = TP_Dollar / g_point;
   double slPts = SL_Dollar / g_point;

   double tp, sl;

   if(type == ORDER_TYPE_BUY)
     {
      tp = NormalizeDouble(ask + tpPts * g_point, g_digits);
      sl = NormalizeDouble(ask - slPts * g_point, g_digits);
      if(trade.Buy(lot, _Symbol, ask, sl, tp))
        {
         g_totalTrades++;
         return true;
        }
      Print("BUY failed: ", trade.ResultRetcodeDescription());
     }
   else if(type == ORDER_TYPE_SELL)
     {
      tp = NormalizeDouble(bid - tpPts * g_point, g_digits);
      sl = NormalizeDouble(bid + slPts * g_point, g_digits);
      if(trade.Sell(lot, _Symbol, bid, sl, tp))
        {
         g_totalTrades++;
         return true;
        }
      Print("SELL failed: ", trade.ResultRetcodeDescription());
     }
   return false;
  }

//+------------------------------------------------------------------+
double CalculateLot(int level)
  {
   double lot;

   if(UseAutoLot)
     {
      double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double slValue   = (SL_Dollar / g_point) * g_point / tickSize * tickValue;
      lot = (balance * RiskPercent / 100.0) / MathMax(slValue, 0.01);
     }
   else
     {
      lot = LotStart;
      if(UseAntiMartingale)
         for(int i = 0; i < level; i++) lot = MathMax(lot / LotMultiplier, 0.001);
      else
         for(int i = 0; i < level; i++) lot *= LotMultiplier;
     }

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);
   lot = MathFloor(lot / stepLot) * stepLot;

   return NormalizeDouble(lot, 2);
  }

//+------------------------------------------------------------------+
void CheckBasketTP()
  {
   int totalPos = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i) &&
         posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
         totalPos++;
     }
   if(totalPos == 0) return;

   double avgOpen = GetAverageOpenPrice();
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   bool buyHit  = g_gridBuy  && (bid - avgOpen) >= BasketTP_Dollar;
   bool sellHit = g_gridSell && (avgOpen - ask)  >= BasketTP_Dollar;

   if(buyHit || sellHit)
      CloseAllPositions("BASKET TP");
  }

//+------------------------------------------------------------------+
void ManageTrailingStop()
  {
   double trailStartPts = TrailStart_Dollar / g_point;
   double trailStepPts  = TrailStep_Dollar  / g_point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != MagicNumber) continue;

      double openPrice = posInfo.PriceOpen();
      double sl        = posInfo.StopLoss();
      double ask       = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
        {
         if((bid - openPrice) >= trailStartPts * g_point)
           {
            double newSL = NormalizeDouble(bid - trailStepPts * g_point, g_digits);
            if(sl == 0.0 || newSL > sl + trailStepPts * g_point)
               trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
           }
        }
      else
        {
         if((openPrice - ask) >= trailStartPts * g_point)
           {
            double newSL = NormalizeDouble(ask + trailStepPts * g_point, g_digits);
            if(sl == 0.0 || newSL < sl - trailStepPts * g_point)
               trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
           }
        }
     }
  }

//+------------------------------------------------------------------+
void CloseAllPositions(string reason)
  {
   Print("[GOLD EA] CloseAll -> ", reason);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i) &&
         posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
         trade.PositionClose(posInfo.Ticket());
     }
   g_gridBuy  = false;
   g_gridSell = false;
   g_gridBase = 0.0;
  }

//+------------------------------------------------------------------+
int CountPositions(ENUM_POSITION_TYPE type)
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i) &&
         posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber &&
         posInfo.PositionType() == type)
         count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
int CountAllPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i) &&
         posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
         count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
double GetLastOpenPrice(ENUM_POSITION_TYPE type)
  {
   double   lastPrice = 0.0;
   datetime lastTime  = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i) &&
         posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber &&
         posInfo.PositionType() == type && posInfo.Time() >= lastTime)
        {
         lastTime  = posInfo.Time();
         lastPrice = posInfo.PriceOpen();
        }
     }
   return lastPrice;
  }

//+------------------------------------------------------------------+
double GetAverageOpenPrice()
  {
   double vol = 0.0, wsum = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i) &&
         posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
        {
         wsum += posInfo.PriceOpen() * posInfo.Volume();
         vol  += posInfo.Volume();
        }
     }
   return (vol > 0.0) ? wsum / vol : 0.0;
  }

//+------------------------------------------------------------------+
bool IsInSession()
  {
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int h = dt.hour;

   bool asia   = TradeAsia && (h >= AsiaOpen   && h < AsiaClose);
   bool london = (h >= LondonOpen && h < LondonClose);
   bool ny     = (h >= NYOpen     && h < NYClose);

   return (asia || london || ny);
  }

//+------------------------------------------------------------------+
void DrawDashboard(double equity, double balance, double ddPct,
                   int buyLvl, int sellLvl, double rsi,
                   double atr, double gridStep, double atrRatio)
  {
   string cur    = AccountInfoString(ACCOUNT_CURRENCY);
   double profit = equity - balance;
   string profStr = StringFormat("%s%.2f %s", profit >= 0 ? "+" : "", profit, cur);

   string dash = "";
   dash += "══════════════════════════════\n";
   dash += "   SCALPING GRID EA — GOLD\n";
   dash += "══════════════════════════════\n";
   dash += StringFormat("  Balance    : %9.2f %s\n", balance, cur);
   dash += StringFormat("  Equity     : %9.2f %s\n", equity,  cur);
   dash += StringFormat("  P&L        : %s\n",        profStr);
   dash += StringFormat("  Drawdown   : %5.2f%%  (max %.2f%%)\n", ddPct, g_maxDrawdown);
   dash += "──────────────────────────────\n";
   dash += StringFormat("  BUY  grid  : %d / %d levels\n", buyLvl,  MaxGridLevels);
   dash += StringFormat("  SELL grid  : %d / %d levels\n", sellLvl, MaxGridLevels);
   dash += StringFormat("  Grid step  : $%.2f\n", gridStep);
   dash += StringFormat("  ATR (M5)   : $%.2f\n", atr * 100.0);
   dash += StringFormat("  ATR ratio  : %.2fx %s\n", atrRatio,
                        atrRatio > ATR_MaxMultiplier ? "<<BLOCKED>>" : "OK");
   dash += StringFormat("  RSI        : %.1f\n", rsi);
   dash += "──────────────────────────────\n";
   dash += StringFormat("  Trades     : %d  (wins: %d)\n", g_totalTrades, g_totalWins);
   dash += StringFormat("  Session    : %s\n", IsInSession() ? "ACTIVE" : "CLOSED");
   dash += StringFormat("  Spread     : $%.2f\n",
                        (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * g_point);
   dash += "══════════════════════════════";

   Comment(dash);
  }

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
     {
      if(HistoryDealSelect(trans.deal))
        {
         double p = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
         if(p != 0.0)
           {
            g_totalProfit += p;
            if(p > 0.0) g_totalWins++;
           }
        }
     }
  }
//+------------------------------------------------------------------+
