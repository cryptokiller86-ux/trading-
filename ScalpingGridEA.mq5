//+------------------------------------------------------------------+
//|  ScalpingGridEA.mq5                                              |
//|  Grid Scalping EA — Ultra Profitable                             |
//|  Compatible: MT5                                                 |
//+------------------------------------------------------------------+
#property copyright "ScalpingGridEA"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>
#include <Indicators\Trend.mqh>

CTrade        trade;
CPositionInfo posInfo;
COrderInfo    orderInfo;

//--- Inputs: Grid
input group "=== GRID SETTINGS ==="
input double  GridStep        = 20.0;   // Grid step (points)
input int     MaxGridLevels   = 8;      // Max grid levels
input double  LotStart        = 0.01;   // Starting lot size
input double  LotMultiplier   = 1.5;    // Lot multiplier per level
input bool    UseAntiMartingale = false; // Anti-martingale mode

//--- Inputs: Scalping
input group "=== SCALPING SETTINGS ==="
input int     FastMA          = 8;      // Fast EMA period
input int     SlowMA          = 21;     // Slow EMA period
input int     RSI_Period      = 14;     // RSI period
input double  RSI_OB          = 70.0;   // RSI overbought
input double  RSI_OS          = 30.0;   // RSI oversold
input int     ATR_Period      = 14;     // ATR period

//--- Inputs: TP/SL
input group "=== TAKE PROFIT / STOP LOSS ==="
input double  TakeProfit_Points = 30.0; // TP per level (points)
input double  GridTP_Points     = 80.0; // Grid basket TP (points)
input double  StopLoss_Points   = 150.0;// Emergency SL (points)
input bool    UseTrailingStop   = true; // Trailing stop
input double  TrailStart        = 20.0; // Trail start (points)
input double  TrailStep         = 10.0; // Trail step (points)

//--- Inputs: Risk Management
input group "=== RISK MANAGEMENT ==="
input double  MaxDrawdownPct   = 15.0;  // Max drawdown % (closes all)
input double  RiskPerTrade     = 1.0;   // Risk % per trade (auto lot)
input bool    UseAutoLot       = false; // Auto lot sizing
input double  MaxSpread        = 20.0;  // Max spread (points)
input int     MagicNumber      = 78421; // Magic number

//--- Inputs: Sessions
input group "=== SESSION FILTER ==="
input bool    UseSessions      = true;  // Enable session filter
input int     LondonOpen       = 8;     // London open hour (UTC)
input int     LondonClose      = 17;    // London close hour (UTC)
input int     NYOpen           = 13;    // NY open hour (UTC)
input int     NYClose          = 22;    // NY close hour (UTC)

//--- Inputs: Display
input group "=== DISPLAY ==="
input bool    ShowDashboard    = true;  // Show dashboard panel

//--- Globals
double  g_point;
int     g_digits;
double  g_gridBase = 0.0;
bool    g_gridBuy  = false;
bool    g_gridSell = false;

int     g_fastMA_handle;
int     g_slowMA_handle;
int     g_rsi_handle;
int     g_atr_handle;

double  g_startBalance;
int     g_totalTrades    = 0;
int     g_totalWins      = 0;
double  g_totalProfit    = 0.0;
double  g_maxDrawdown    = 0.0;
double  g_peakEquity     = 0.0;

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   g_point  = _Point;
   g_digits = _Digits;

   g_fastMA_handle = iMA(_Symbol, PERIOD_CURRENT, FastMA, 0, MODE_EMA, PRICE_CLOSE);
   g_slowMA_handle = iMA(_Symbol, PERIOD_CURRENT, SlowMA, 0, MODE_EMA, PRICE_CLOSE);
   g_rsi_handle    = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
   g_atr_handle    = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

   if(g_fastMA_handle == INVALID_HANDLE || g_slowMA_handle == INVALID_HANDLE ||
      g_rsi_handle == INVALID_HANDLE    || g_atr_handle == INVALID_HANDLE)
     {
      Print("ERROR: Failed to create indicator handles.");
      return INIT_FAILED;
     }

   g_startBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_peakEquity   = g_startBalance;

   Print("ScalpingGridEA initialized. Balance: ", g_startBalance);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(g_fastMA_handle);
   IndicatorRelease(g_slowMA_handle);
   IndicatorRelease(g_rsi_handle);
   IndicatorRelease(g_atr_handle);
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   //--- Drawdown protection (hard stop)
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double ddPct    = (g_peakEquity - equity) / g_peakEquity * 100.0;

   if(equity > g_peakEquity) g_peakEquity = equity;
   if(ddPct > g_maxDrawdown) g_maxDrawdown = ddPct;

   if(ddPct >= MaxDrawdownPct)
     {
      CloseAllPositions("MAX DRAWDOWN HIT");
      return;
     }

   //--- Spread check
   double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * g_point;
   if(spread > MaxSpread * g_point)
      return;

   //--- Session filter
   if(UseSessions && !IsInSession())
      return;

   //--- Indicator values
   double fastMA[2], slowMA[2], rsiVal[2], atrVal[2];
   if(CopyBuffer(g_fastMA_handle, 0, 0, 2, fastMA) < 2) return;
   if(CopyBuffer(g_slowMA_handle, 0, 0, 2, slowMA) < 2) return;
   if(CopyBuffer(g_rsi_handle,    0, 0, 2, rsiVal) < 2) return;
   if(CopyBuffer(g_atr_handle,    0, 0, 2, atrVal) < 2) return;

   bool bullish = fastMA[0] > slowMA[0];
   bool bearish = fastMA[0] < slowMA[0];
   bool rsiBuy  = rsiVal[0] < RSI_OS;
   bool rsiSell = rsiVal[0] > RSI_OB;

   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double atr  = atrVal[0];

   //--- Count open grid positions
   int buyCount  = CountPositions(POSITION_TYPE_BUY);
   int sellCount = CountPositions(POSITION_TYPE_SELL);

   //--- Trailing stop management
   if(UseTrailingStop)
      ManageTrailingStop();

   //--- Grid basket TP check
   CheckBasketTP();

   //--- Entry logic: Open first level
   if(buyCount == 0 && bullish && rsiBuy)
     {
      double lot = CalculateLot(0);
      if(OpenPosition(ORDER_TYPE_BUY, lot, TakeProfit_Points, StopLoss_Points))
        {
         g_gridBase  = ask;
         g_gridBuy   = true;
         g_gridSell  = false;
        }
     }
   else if(sellCount == 0 && bearish && rsiSell)
     {
      double lot = CalculateLot(0);
      if(OpenPosition(ORDER_TYPE_SELL, lot, TakeProfit_Points, StopLoss_Points))
        {
         g_gridBase  = bid;
         g_gridBuy   = false;
         g_gridSell  = true;
        }
     }

   //--- Grid: add levels BUY
   if(g_gridBuy && buyCount > 0 && buyCount < MaxGridLevels)
     {
      double lastBuyPrice = GetLastOpenPrice(POSITION_TYPE_BUY);
      if(lastBuyPrice > 0.0 && (lastBuyPrice - ask) >= GridStep * g_point)
        {
         double lot = CalculateLot(buyCount);
         OpenPosition(ORDER_TYPE_BUY, lot, TakeProfit_Points, StopLoss_Points);
        }
     }

   //--- Grid: add levels SELL
   if(g_gridSell && sellCount > 0 && sellCount < MaxGridLevels)
     {
      double lastSellPrice = GetLastOpenPrice(POSITION_TYPE_SELL);
      if(lastSellPrice > 0.0 && (bid - lastSellPrice) >= GridStep * g_point)
        {
         double lot = CalculateLot(sellCount);
         OpenPosition(ORDER_TYPE_SELL, lot, TakeProfit_Points, StopLoss_Points);
        }
     }

   //--- Dashboard
   if(ShowDashboard)
      DrawDashboard(equity, balance, ddPct, buyCount, sellCount, rsiVal[0], atr);
  }

//+------------------------------------------------------------------+
bool OpenPosition(ENUM_ORDER_TYPE type, double lot,
                  double tpPoints, double slPoints)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double tp, sl;

   if(type == ORDER_TYPE_BUY)
     {
      tp = NormalizeDouble(ask + tpPoints * g_point, g_digits);
      sl = NormalizeDouble(ask - slPoints * g_point, g_digits);
      if(trade.Buy(lot, _Symbol, ask, sl, tp))
        {
         g_totalTrades++;
         return true;
        }
     }
   else if(type == ORDER_TYPE_SELL)
     {
      tp = NormalizeDouble(bid - tpPoints * g_point, g_digits);
      sl = NormalizeDouble(bid + slPoints * g_point, g_digits);
      if(trade.Sell(lot, _Symbol, bid, sl, tp))
        {
         g_totalTrades++;
         return true;
        }
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
      double slValue   = StopLoss_Points * g_point / tickSize * tickValue;
      lot = (balance * RiskPerTrade / 100.0) / slValue;
     }
   else
     {
      lot = LotStart;
      if(UseAntiMartingale)
         for(int i = 0; i < level; i++) lot /= LotMultiplier;
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
   double totalProfit = 0.0;
   int    totalPos    = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i))
        {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
           {
            totalProfit += posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
            totalPos++;
           }
        }
     }

   if(totalPos <= 0) return;

   double avgOpen   = GetAverageOpenPrice();
   double ask       = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double basketTPVal = GridTP_Points * g_point;

   bool buyBasketTP  = g_gridBuy  && (bid - avgOpen) >= basketTPVal;
   bool sellBasketTP = g_gridSell && (avgOpen - ask) >= basketTPVal;

   if(buyBasketTP || sellBasketTP)
      CloseAllPositions("BASKET TP HIT");
  }

//+------------------------------------------------------------------+
void ManageTrailingStop()
  {
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
         double newSL = bid - TrailStep * g_point;
         if((bid - openPrice) >= TrailStart * g_point)
           {
            if(sl == 0.0 || newSL > sl + TrailStep * g_point)
               trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
           }
        }
      else if(posInfo.PositionType() == POSITION_TYPE_SELL)
        {
         double newSL = ask + TrailStep * g_point;
         if((openPrice - ask) >= TrailStart * g_point)
           {
            if(sl == 0.0 || newSL < sl - TrailStep * g_point)
               trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
           }
        }
     }
  }

//+------------------------------------------------------------------+
void CloseAllPositions(string reason)
  {
   Print("CloseAll: ", reason);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i))
        {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
            trade.PositionClose(posInfo.Ticket());
        }
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
      if(posInfo.SelectByIndex(i))
        {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber &&
            posInfo.PositionType() == type)
            count++;
        }
     }
   return count;
  }

//+------------------------------------------------------------------+
double GetLastOpenPrice(ENUM_POSITION_TYPE type)
  {
   double lastPrice = 0.0;
   datetime lastTime = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i))
        {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber &&
            posInfo.PositionType() == type)
           {
            if(posInfo.Time() >= lastTime)
              {
               lastTime  = posInfo.Time();
               lastPrice = posInfo.PriceOpen();
              }
           }
        }
     }
   return lastPrice;
  }

//+------------------------------------------------------------------+
double GetAverageOpenPrice()
  {
   double totalVolume = 0.0;
   double weightedSum = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i))
        {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
           {
            double vol = posInfo.Volume();
            weightedSum  += posInfo.PriceOpen() * vol;
            totalVolume  += vol;
           }
        }
     }
   return (totalVolume > 0.0) ? weightedSum / totalVolume : 0.0;
  }

//+------------------------------------------------------------------+
bool IsInSession()
  {
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int hour = dt.hour;

   bool inLondon = (hour >= LondonOpen && hour < LondonClose);
   bool inNY     = (hour >= NYOpen     && hour < NYClose);

   return (inLondon || inNY);
  }

//+------------------------------------------------------------------+
void DrawDashboard(double equity, double balance,
                   double ddPct, int buyCount, int sellCount,
                   double rsi, double atr)
  {
   string dash = "";
   dash += "════════════════════════════\n";
   dash += "   SCALPING GRID EA v2.0\n";
   dash += "════════════════════════════\n";
   dash += StringFormat("  Balance  : %.2f %s\n", balance,   AccountInfoString(ACCOUNT_CURRENCY));
   dash += StringFormat("  Equity   : %.2f %s\n", equity,    AccountInfoString(ACCOUNT_CURRENCY));
   dash += StringFormat("  Profit   : %.2f %s\n", equity - balance, AccountInfoString(ACCOUNT_CURRENCY));
   dash += StringFormat("  Drawdown : %.2f%%\n",  ddPct);
   dash += "────────────────────────────\n";
   dash += StringFormat("  BUY  lvls: %d / %d\n", buyCount,  MaxGridLevels);
   dash += StringFormat("  SELL lvls: %d / %d\n", sellCount, MaxGridLevels);
   dash += StringFormat("  RSI      : %.1f\n",    rsi);
   dash += StringFormat("  ATR      : %.5f\n",    atr);
   dash += "────────────────────────────\n";
   dash += StringFormat("  Trades   : %d\n",      g_totalTrades);
   dash += StringFormat("  Max DD   : %.2f%%\n",  g_maxDrawdown);
   dash += StringFormat("  Session  : %s\n",      IsInSession() ? "ACTIVE" : "CLOSED");
   dash += "════════════════════════════";

   Comment(dash);
  }

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
     {
      if(trans.deal_type == DEAL_TYPE_BUY || trans.deal_type == DEAL_TYPE_SELL)
        {
         HistoryDealSelect(trans.deal);
         double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
         if(profit != 0.0)
           {
            g_totalProfit += profit;
            if(profit > 0.0) g_totalWins++;
           }
        }
     }
  }
//+------------------------------------------------------------------+
