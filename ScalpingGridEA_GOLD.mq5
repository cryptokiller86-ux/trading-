//+------------------------------------------------------------------+
//|  ScalpingGridEA_GOLD.mq5                                         |
//|  Gold Scalping Grid EA — XAUUSD Optimized v3.0                   |
//|  Timeframe: M5  |  Symbol: XAUUSD                                |
//|                                                                  |
//|  Strategy (research-backed consensus):                           |
//|   1. EMA 200 H1      → macro trend bias (long/short only)        |
//|   2. EMA 9/21 M5     → crossover entry trigger                   |
//|   3. RSI 7 M5        → momentum extreme confirmation             |
//|   4. Stochastic(5,3,3) M5 → fast overbought/oversold signal      |
//|   5. Bollinger Bands(20,2) M5 → price at band = high-prob entry  |
//|   6. ATR M5          → dynamic grid step + volatility guard       |
//|   7. London/NY overlap sessions only (13-17 UTC peak liquidity)  |
//|                                                                  |
//|  Designed for $300 micro accounts (0.01 lot base)                |
//+------------------------------------------------------------------+
#property copyright "ScalpingGridEA_GOLD v3"
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
CPositionInfo pos;

//──────────────────────────────────────────────────────────────────
//  INPUT PARAMETERS
//──────────────────────────────────────────────────────────────────

input group "=== INDICATORS ==="
input int    EMA_Fast          = 9;      // Fast EMA period (M5)
input int    EMA_Slow          = 21;     // Slow EMA period (M5)
input int    EMA_Trend         = 200;    // Trend EMA period (H1)
input int    RSI_Period        = 7;      // RSI period (7 = fast for gold)
input double RSI_Buy           = 40.0;   // RSI below = bullish momentum
input double RSI_Sell          = 60.0;   // RSI above = bearish momentum
input int    Stoch_K           = 5;      // Stochastic %K (5 = fast)
input int    Stoch_D           = 3;      // Stochastic %D
input int    Stoch_Slowing     = 3;      // Stochastic slowing
input double Stoch_Buy         = 35.0;   // Stoch below = oversold
input double Stoch_Sell        = 65.0;   // Stoch above = overbought
input int    BB_Period         = 20;     // Bollinger Bands period
input double BB_Deviation      = 2.0;    // Bollinger Bands deviation
input double BB_EntryPct       = 0.85;   // Price must be at 85% of band width
input int    ATR_Period        = 14;     // ATR period

input group "=== GRID SETTINGS ==="
input bool   UseATRGrid        = true;   // Dynamic grid step (ATR-based)
input double ATR_GridMult      = 0.25;   // ATR multiplier for grid step
input double GridStep_USD      = 1.50;   // Fixed grid step in $ (if !UseATRGrid)
input int    MaxGridLevels     = 4;      // Max grid levels (4 = safe for $300)
input double LotBase           = 0.01;   // Base lot (minimum = 0.01)
input double LotMultiplier     = 1.3;    // Lot multiplier per grid level
input bool   UseAntiMart       = false;  // Anti-martingale (divide instead)

input group "=== TAKE PROFIT / STOP LOSS (USD) ==="
input double TP_USD            = 2.50;   // TP per position ($)
input double BasketTP_USD      = 6.00;   // Close all when total basket profit ($)
input double SL_USD            = 8.00;   // Emergency SL per position ($)
input bool   UseTrailing       = true;   // Trailing stop
input double Trail_Start_USD   = 1.50;   // Trail activates after ($) in profit
input double Trail_Step_USD    = 0.80;   // Trail step ($)
input bool   UseEndOfDayClose  = true;   // Close all before end of NY session
input int    EOD_CloseHour     = 21;     // Close all at this UTC hour

input group "=== RISK MANAGEMENT ==="
input double MaxDD_Pct         = 15.0;   // Max drawdown % → close all
input double MaxSpread_USD     = 0.40;   // Max spread in $ (40 pts)
input double ATR_SpikeRatio    = 2.2;    // Skip entry if ATR > ratio * ATR_H1
input int    MaxTotalPositions = 8;      // Hard cap open positions
input int    MagicNumber       = 30047;  // EA magic number

input group "=== SESSIONS (UTC) ==="
input bool   UseSessions       = true;   // Session filter
input int    London_Open       = 8;      // London open
input int    London_Close      = 17;     // London close
input int    NY_Open           = 13;     // New York open
input int    NY_Close          = 22;     // New York close
input bool   TradeAsia         = false;  // Asian session (quieter gold)
input int    Asia_Open         = 1;
input int    Asia_Close        = 7;

input group "=== DISPLAY ==="
input bool   Dashboard         = true;   // Show live panel

//──────────────────────────────────────────────────────────────────
//  GLOBALS
//──────────────────────────────────────────────────────────────────
double g_pt;
int    g_digits;
bool   g_gridBuy  = false;
bool   g_gridSell = false;
double g_gridBase = 0.0;

int h_emaFast, h_emaSlow, h_emaTrend;
int h_rsi, h_stochK, h_stochD;
int h_bb_upper, h_bb_lower, h_bb_mid;
int h_atr, h_atrH1;
int h_bb;

double  g_startBal;
int     g_trades    = 0;
int     g_wins      = 0;
double  g_profit    = 0.0;
double  g_maxDD     = 0.0;
double  g_peakEq    = 0.0;
datetime g_lastBar  = 0;   // bar-open signal filter

//──────────────────────────────────────────────────────────────────
int OnInit()
  {
   string s = _Symbol;
   if(StringFind(s,"XAU") < 0 && StringFind(s,"GOLD") < 0)
     {
      Alert("EA is for XAUUSD only. Current: ", s);
      return INIT_FAILED;
     }
   if(Period() != PERIOD_M5)
      Print("WARNING: EA is optimized for M5. Current TF may give suboptimal results.");

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   g_pt     = _Point;
   g_digits = _Digits;

   //--- Indicator handles
   h_emaFast  = iMA(_Symbol, PERIOD_M5, EMA_Fast,  0, MODE_EMA, PRICE_CLOSE);
   h_emaSlow  = iMA(_Symbol, PERIOD_M5, EMA_Slow,  0, MODE_EMA, PRICE_CLOSE);
   h_emaTrend = iMA(_Symbol, PERIOD_H1, EMA_Trend, 0, MODE_EMA, PRICE_CLOSE);
   h_rsi      = iRSI(_Symbol, PERIOD_M5, RSI_Period, PRICE_CLOSE);
   h_bb       = iBands(_Symbol, PERIOD_M5, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
   h_atr      = iATR(_Symbol, PERIOD_M5, ATR_Period);
   h_atrH1    = iATR(_Symbol, PERIOD_H1, ATR_Period);

   //--- Stochastic: buffer 0 = %K, buffer 1 = %D
   h_stochK   = iStochastic(_Symbol, PERIOD_M5, Stoch_K, Stoch_D, Stoch_Slowing,
                              MODE_SMA, STO_LOWHIGH);

   if(h_emaFast == INVALID_HANDLE || h_emaSlow  == INVALID_HANDLE ||
      h_emaTrend== INVALID_HANDLE || h_rsi      == INVALID_HANDLE ||
      h_bb      == INVALID_HANDLE || h_atr      == INVALID_HANDLE ||
      h_atrH1   == INVALID_HANDLE || h_stochK   == INVALID_HANDLE)
     {
      Print("FATAL: indicator handle error");
      return INIT_FAILED;
     }

   g_startBal = AccountInfoDouble(ACCOUNT_BALANCE);
   g_peakEq   = g_startBal;

   Print("GOLD Grid EA v3 | Balance: ", g_startBal,
         " ", AccountInfoString(ACCOUNT_CURRENCY));
   return INIT_SUCCEEDED;
  }

//──────────────────────────────────────────────────────────────────
void OnDeinit(const int reason)
  {
   IndicatorRelease(h_emaFast); IndicatorRelease(h_emaSlow);
   IndicatorRelease(h_emaTrend);IndicatorRelease(h_rsi);
   IndicatorRelease(h_bb);      IndicatorRelease(h_atr);
   IndicatorRelease(h_atrH1);   IndicatorRelease(h_stochK);
   Comment("");
  }

//──────────────────────────────────────────────────────────────────
void OnTick()
  {
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double ddPct   = (g_peakEq > 0.0) ? (g_peakEq - equity) / g_peakEq * 100.0 : 0.0;
   if(equity > g_peakEq) g_peakEq = equity;
   if(ddPct  > g_maxDD)  g_maxDD  = ddPct;

   //--- Hard drawdown cut
   if(ddPct >= MaxDD_Pct)
     {
      CloseAll("MAX DRAWDOWN");
      return;
     }

   //--- End-of-day close
   if(UseEndOfDayClose)
     {
      MqlDateTime dt;
      TimeToStruct(TimeGMT(), dt);
      if(dt.hour >= EOD_CloseHour)
        {
         if(CountAll() > 0) CloseAll("END OF DAY");
         return;
        }
     }

   //--- Trailing stop (runs every tick)
   if(UseTrailing) ManageTrail();

   //--- Basket TP (runs every tick)
   CheckBasketTP();

   //--- Everything below: once per new bar only
   datetime barTime = iTime(_Symbol, PERIOD_M5, 0);
   if(barTime == g_lastBar) goto _dashboard;
   g_lastBar = barTime;

   //--- Spread guard
   double spreadUSD = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * g_pt;
   if(spreadUSD > MaxSpread_USD) goto _dashboard;

   //--- Session guard
   if(UseSessions && !InSession()) goto _dashboard;

   //--- Max positions guard
   if(CountAll() >= MaxTotalPositions) goto _dashboard;

   //--- Read all indicators (bar [0] = current closed bar for signals)
   {
      double emaF[3], emaS[3], emaT[3];
      double rsi[3], stochK[3], stochD[3];
      double bbU[3], bbL[3], bbM[3];
      double atrM5[3], atrH1[3];

      if(CopyBuffer(h_emaFast,  0,1,3,emaF)   < 3) goto _dashboard;
      if(CopyBuffer(h_emaSlow,  0,1,3,emaS)   < 3) goto _dashboard;
      if(CopyBuffer(h_emaTrend, 0,1,3,emaT)   < 3) goto _dashboard;
      if(CopyBuffer(h_rsi,      0,1,3,rsi)    < 3) goto _dashboard;
      if(CopyBuffer(h_stochK,   0,1,3,stochK) < 3) goto _dashboard;
      if(CopyBuffer(h_stochK,   1,1,3,stochD) < 3) goto _dashboard;
      if(CopyBuffer(h_bb,       1,1,3,bbU)    < 3) goto _dashboard; // upper
      if(CopyBuffer(h_bb,       2,1,3,bbL)    < 3) goto _dashboard; // lower
      if(CopyBuffer(h_bb,       0,1,3,bbM)    < 3) goto _dashboard; // middle
      if(CopyBuffer(h_atr,      0,1,3,atrM5)  < 3) goto _dashboard;
      if(CopyBuffer(h_atrH1,    0,1,3,atrH1)  < 3) goto _dashboard;

      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double mid = (ask + bid) / 2.0;

      //--- Volatility spike guard
      double atrRatio = (atrH1[0] > 0.0) ? (atrM5[0] * 12.0) / atrH1[0] : 1.0;
      if(atrRatio > ATR_SpikeRatio) goto _dashboard;

      //--- Dynamic grid step
      double gridStep = UseATRGrid
                        ? MathMax(atrM5[0] * ATR_GridMult * 100.0, 0.80)
                        : GridStep_USD;

      //═══════════════════════════════════════════════════════
      //  SIGNAL LOGIC — 5-condition confluence
      //═══════════════════════════════════════════════════════

      // 1. H1 trend direction
      bool h1Bull = mid > emaT[0];
      bool h1Bear = mid < emaT[0];

      // 2. M5 EMA crossover (fresh: prev bar[1] not crossed, bar[0] crossed)
      bool crossUp   = (emaF[0] > emaS[0]) && (emaF[1] <= emaS[1]);
      bool crossDown = (emaF[0] < emaS[0]) && (emaF[1] >= emaS[1]);

      // 3. RSI momentum (bar[0])
      bool rsiBull = rsi[0] < RSI_Buy;
      bool rsiBear = rsi[0] > RSI_Sell;

      // 4. Stochastic (5,3,3) — %K cross above %D in oversold / below in overbought
      bool stochCrossUp   = (stochK[0] > stochD[0]) && (stochK[1] <= stochD[1])
                            && stochK[0] < Stoch_Buy;
      bool stochCrossDown = (stochK[0] < stochD[0]) && (stochK[1] >= stochD[1])
                            && stochK[0] > Stoch_Sell;

      // 5. Bollinger Band — price near lower band for BUY, upper for SELL
      double bbRange  = bbU[0] - bbL[0];
      bool   atLowBB  = (bbRange > 0.0) && (ask - bbL[0]) / bbRange < (1.0 - BB_EntryPct);
      bool   atHighBB = (bbRange > 0.0) && (bbU[0] - bid) / bbRange < (1.0 - BB_EntryPct);

      int buyCount  = CountDir(POSITION_TYPE_BUY);
      int sellCount = CountDir(POSITION_TYPE_SELL);

      //--- Entry: all 5 conditions + no opposite grid open
      bool buySignal  = h1Bull && (crossUp  || stochCrossUp)
                        && rsiBull && atLowBB
                        && buyCount == 0 && sellCount == 0;

      bool sellSignal = h1Bear && (crossDown || stochCrossDown)
                        && rsiBear && atHighBB
                        && sellCount == 0 && buyCount == 0;

      //--- Open first level
      if(buySignal)
        {
         double lot = CalcLot(0);
         if(OpenPos(ORDER_TYPE_BUY, lot))
           { g_gridBuy = true; g_gridSell = false; g_gridBase = ask; }
        }
      else if(sellSignal)
        {
         double lot = CalcLot(0);
         if(OpenPos(ORDER_TYPE_SELL, lot))
           { g_gridSell = true; g_gridBuy = false; g_gridBase = bid; }
        }

      //--- Grid: add BUY levels
      if(g_gridBuy && buyCount > 0 && buyCount < MaxGridLevels)
        {
         double lastP = LastOpenPrice(POSITION_TYPE_BUY);
         if(lastP > 0.0 && (lastP - ask) >= gridStep)
           {
            double lot = CalcLot(buyCount);
            OpenPos(ORDER_TYPE_BUY, lot);
           }
        }

      //--- Grid: add SELL levels
      if(g_gridSell && sellCount > 0 && sellCount < MaxGridLevels)
        {
         double lastP = LastOpenPrice(POSITION_TYPE_SELL);
         if(lastP > 0.0 && (bid - lastP) >= gridStep)
           {
            double lot = CalcLot(sellCount);
            OpenPos(ORDER_TYPE_SELL, lot);
           }
        }

      //--- Dashboard data capture
      if(Dashboard)
         DrawPanel(equity, balance, ddPct, buyCount, sellCount,
                   rsi[0], atrM5[0], stochK[0], gridStep, atrRatio,
                   h1Bull, h1Bear);
      return;
   }

   _dashboard:
   if(Dashboard)
     {
      double eq2 = AccountInfoDouble(ACCOUNT_EQUITY);
      double ba2 = AccountInfoDouble(ACCOUNT_BALANCE);
      double dd2 = (g_peakEq > 0.0) ? (g_peakEq - eq2) / g_peakEq * 100.0 : 0.0;
      DrawPanel(eq2, ba2, dd2,
                CountDir(POSITION_TYPE_BUY), CountDir(POSITION_TYPE_SELL),
                0, 0, 0, 0, 0, false, false);
     }
  }

//──────────────────────────────────────────────────────────────────
bool OpenPos(ENUM_ORDER_TYPE type, double lot)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double tpPts = TP_USD / g_pt;
   double slPts = SL_USD / g_pt;
   double tp, sl;

   if(type == ORDER_TYPE_BUY)
     {
      tp = NormalizeDouble(ask + tpPts * g_pt, g_digits);
      sl = NormalizeDouble(ask - slPts * g_pt, g_digits);
      if(trade.Buy(lot, _Symbol, ask, sl, tp))
        { g_trades++; return true; }
      Print("BUY failed: ", trade.ResultRetcodeDescription());
     }
   else
     {
      tp = NormalizeDouble(bid - tpPts * g_pt, g_digits);
      sl = NormalizeDouble(bid + slPts * g_pt, g_digits);
      if(trade.Sell(lot, _Symbol, bid, sl, tp))
        { g_trades++; return true; }
      Print("SELL failed: ", trade.ResultRetcodeDescription());
     }
   return false;
  }

//──────────────────────────────────────────────────────────────────
double CalcLot(int level)
  {
   double lot = LotBase;
   if(UseAntiMart)
      for(int i = 0; i < level; i++) lot = MathMax(lot / LotMultiplier, 0.001);
   else
      for(int i = 0; i < level; i++) lot *= LotMultiplier;

   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathMax(lot, minL);
   lot = MathMin(lot, maxL);
   lot = MathFloor(lot / step) * step;
   return NormalizeDouble(lot, 2);
  }

//──────────────────────────────────────────────────────────────────
void CheckBasketTP()
  {
   double totalP = 0.0;
   int    cnt    = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      if(pos.SelectByIndex(i) && pos.Symbol()==_Symbol && pos.Magic()==MagicNumber)
        { totalP += pos.Profit() + pos.Swap() + pos.Commission(); cnt++; }
     }
   if(cnt == 0) return;

   double avgOpen = AvgOpenPrice();
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   bool buyTP  = g_gridBuy  && (bid - avgOpen) >= BasketTP_USD;
   bool sellTP = g_gridSell && (avgOpen - ask)  >= BasketTP_USD;

   if(buyTP || sellTP) CloseAll("BASKET TP");
  }

//──────────────────────────────────────────────────────────────────
void ManageTrail()
  {
   double startPts = Trail_Start_USD / g_pt;
   double stepPts  = Trail_Step_USD  / g_pt;

   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != _Symbol || pos.Magic() != MagicNumber) continue;

      double open = pos.PriceOpen();
      double sl   = pos.StopLoss();
      double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      if(pos.PositionType() == POSITION_TYPE_BUY)
        {
         if((bid - open) >= startPts * g_pt)
           {
            double nsl = NormalizeDouble(bid - stepPts * g_pt, g_digits);
            if(sl == 0.0 || nsl > sl + stepPts * g_pt)
               trade.PositionModify(pos.Ticket(), nsl, pos.TakeProfit());
           }
        }
      else
        {
         if((open - ask) >= startPts * g_pt)
           {
            double nsl = NormalizeDouble(ask + stepPts * g_pt, g_digits);
            if(sl == 0.0 || nsl < sl - stepPts * g_pt)
               trade.PositionModify(pos.Ticket(), nsl, pos.TakeProfit());
           }
        }
     }
  }

//──────────────────────────────────────────────────────────────────
void CloseAll(string reason)
  {
   Print("[GOLD EA] CloseAll: ", reason);
   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      if(pos.SelectByIndex(i) && pos.Symbol()==_Symbol && pos.Magic()==MagicNumber)
         trade.PositionClose(pos.Ticket());
     }
   g_gridBuy = false; g_gridSell = false; g_gridBase = 0.0;
  }

//──────────────────────────────────────────────────────────────────
int CountDir(ENUM_POSITION_TYPE t)
  {
   int c = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(pos.SelectByIndex(i) && pos.Symbol()==_Symbol &&
         pos.Magic()==MagicNumber && pos.PositionType()==t) c++;
   return c;
  }

int CountAll()
  {
   int c = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(pos.SelectByIndex(i) && pos.Symbol()==_Symbol && pos.Magic()==MagicNumber) c++;
   return c;
  }

double LastOpenPrice(ENUM_POSITION_TYPE t)
  {
   double p = 0.0; datetime ts = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(pos.SelectByIndex(i) && pos.Symbol()==_Symbol &&
         pos.Magic()==MagicNumber && pos.PositionType()==t && pos.Time()>=ts)
        { ts = pos.Time(); p = pos.PriceOpen(); }
   return p;
  }

double AvgOpenPrice()
  {
   double w = 0.0, v = 0.0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(pos.SelectByIndex(i) && pos.Symbol()==_Symbol && pos.Magic()==MagicNumber)
        { w += pos.PriceOpen() * pos.Volume(); v += pos.Volume(); }
   return (v > 0.0) ? w / v : 0.0;
  }

bool InSession()
  {
   MqlDateTime dt; TimeToStruct(TimeGMT(), dt); int h = dt.hour;
   bool asia   = TradeAsia && h >= Asia_Open   && h < Asia_Close;
   bool london = h >= London_Open && h < London_Close;
   bool ny     = h >= NY_Open     && h < NY_Close;
   return asia || london || ny;
  }

//──────────────────────────────────────────────────────────────────
void DrawPanel(double eq, double bal, double dd,
               int buyLvl, int sellLvl,
               double rsi, double atr, double stoch,
               double gridStep, double atrRatio,
               bool h1Bull, bool h1Bear)
  {
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   double pnl = eq - bal;
   string pnlStr = StringFormat("%s%.2f", pnl >= 0 ? "+" : "", pnl);
   string bias = h1Bull ? "BULLISH" : (h1Bear ? "BEARISH" : "NEUTRAL");

   string s = "";
   s += "════════════════════════════════\n";
   s += "    GOLD GRID SCALPER v3.0\n";
   s += "════════════════════════════════\n";
   s += StringFormat("  Balance  : %9.2f %s\n",  bal, cur);
   s += StringFormat("  Equity   : %9.2f %s\n",  eq,  cur);
   s += StringFormat("  P&L      : %s %s\n",      pnlStr, cur);
   s += StringFormat("  Drawdown : %5.2f%%  (max: %.2f%%)\n", dd, g_maxDD);
   s += "────────────────────────────────\n";
   s += StringFormat("  H1 Bias  : %s (EMA%d)\n",  bias, EMA_Trend);
   s += StringFormat("  RSI(7)   : %.1f\n",         rsi);
   s += StringFormat("  Stoch    : %.1f\n",          stoch);
   s += StringFormat("  ATR M5   : $%.2f\n",         atr * 100.0);
   s += StringFormat("  ATR ratio: %.2fx %s\n",      atrRatio,
                     atrRatio > ATR_SpikeRatio ? "BLOCKED(news)" : "OK");
   s += "────────────────────────────────\n";
   s += StringFormat("  BUY  grid: %d / %d levels\n", buyLvl,  MaxGridLevels);
   s += StringFormat("  SELL grid: %d / %d levels\n", sellLvl, MaxGridLevels);
   s += StringFormat("  Grid step: $%.2f\n",           gridStep);
   s += StringFormat("  Basket TP: $%.2f\n",           BasketTP_USD);
   s += "────────────────────────────────\n";
   s += StringFormat("  Trades   : %d  (wins: %d)\n",  g_trades, g_wins);
   s += StringFormat("  Session  : %s\n",               InSession() ? "ACTIVE" : "CLOSED");
   s += StringFormat("  Spread   : $%.2f\n",
                     (double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD) * g_pt);
   s += "════════════════════════════════";
   Comment(s);
  }

//──────────────────────────────────────────────────────────────────
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &req,
                        const MqlTradeResult      &res)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD && HistoryDealSelect(trans.deal))
     {
      double p = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
      if(p != 0.0) { g_profit += p; if(p > 0.0) g_wins++; }
     }
  }
//──────────────────────────────────────────────────────────────────
