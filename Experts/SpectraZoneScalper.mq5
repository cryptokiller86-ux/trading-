//+------------------------------------------------------------------+
//|                    Spectra Zone Scalper v2.0                     |
//|              Trend Following + Mean Reversion Hybrid              |
//|         Version corrigée après backtest catastrophique           |
//+------------------------------------------------------------------+
#property copyright   "Spectra Zone Scalper v2 - Corrected"
#property version     "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade         trade;
CPositionInfo  posInfo;

//--- Paramètres d'entrée
input group "=== TIMEFRAMES ==="
input ENUM_TIMEFRAMES InpEntryTF    = PERIOD_M5;     // TF entrée
input ENUM_TIMEFRAMES InpTrendTF    = PERIOD_H1;     // TF tendance

input group "=== GESTION DU RISQUE (CRITIQUE) ==="
input double   InpRiskPercent       = 0.5;           // Risque par trade (%) - PRUDENT
input double   InpStopLossPoints    = 200;           // SL en points (XAUUSD: 200pts=2$)
input double   InpTPMultiplier      = 2.0;           // TP = SL × multiplier (R:R 1:2)
input double   InpTrailingStart     = 100;           // Activation trailing (points profit)
input double   InpTrailingStop      = 80;            // Distance trailing (points)
input int      InpMaxTrades         = 1;             // 1 trade à la fois (sécurité)
input double   InpMaxDailyLoss      = 3.0;           // Perte max journalière (%)
input int      InpMaxLossesPerDay   = 3;             // Pertes consécutives max / jour

input group "=== FILTRES ==="
input double   InpMaxSpreadPoints   = 50;            // Spread max (XAUUSD: 50pts=0.5$)
input double   InpMinATR            = 100;           // ATR min (volatilité min)
input int      InpATRPeriod         = 14;            // Période ATR
input int      InpStartHour         = 8;             // Heure début (Londres)
input int      InpEndHour           = 20;            // Heure fin (NY close)
input bool     InpAvoidFriday       = true;          // Pas de trade vendredi PM

input group "=== INDICATEURS TENDANCE (H1) ==="
input int      InpEMAFast           = 21;            // EMA rapide
input int      InpEMASlow           = 50;            // EMA lente
input int      InpADXPeriod         = 14;            // ADX période
input double   InpADXMin            = 22.0;          // ADX min pour trade

input group "=== INDICATEURS ENTREE (M5) ==="
input int      InpRSIPeriod         = 14;            // RSI période
input double   InpRSIBuyMax         = 60.0;          // RSI < 60 pour BUY (pullback up)
input double   InpRSIBuyMin         = 35.0;          // RSI > 35 pour BUY
input double   InpRSISellMin        = 40.0;          // RSI > 40 pour SELL (pullback down)
input double   InpRSISellMax        = 65.0;          // RSI < 65 pour SELL
input int      InpStochK            = 14;
input int      InpStochD            = 3;
input int      InpStochSlowing      = 3;

input group "=== ZONE RECOVERY (DESACTIVE PAR DEFAUT) ==="
input bool     InpZoneRecovery      = false;         // ATTENTION: martingale dangereuse
input double   InpRecoveryLotMult   = 1.3;
input int      InpMaxRecovery       = 2;

input group "=== DIVERS ==="
input int      InpMagicNumber       = 202502;
input bool     InpShowDashboard     = true;

//--- Handles indicateurs
int hEMAFast, hEMASlow, hADX_H1;
int hRSI_M5, hStoch_M5, hATR_M5;

double g_point;
int    g_digits;

//--- Stats journalières
datetime g_todayStart = 0;
int      g_lossesToday = 0;
double   g_dailyStartBalance = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   hEMAFast  = iMA(_Symbol, InpTrendTF, InpEMAFast, 0, MODE_EMA, PRICE_CLOSE);
   hEMASlow  = iMA(_Symbol, InpTrendTF, InpEMASlow, 0, MODE_EMA, PRICE_CLOSE);
   hADX_H1   = iADX(_Symbol, InpTrendTF, InpADXPeriod);
   hRSI_M5   = iRSI(_Symbol, InpEntryTF, InpRSIPeriod, PRICE_CLOSE);
   hStoch_M5 = iStochastic(_Symbol, InpEntryTF, InpStochK, InpStochD, InpStochSlowing, MODE_SMA, STO_LOWHIGH);
   hATR_M5   = iATR(_Symbol, InpEntryTF, InpATRPeriod);

   if(hEMAFast == INVALID_HANDLE || hEMASlow == INVALID_HANDLE ||
      hADX_H1 == INVALID_HANDLE || hRSI_M5 == INVALID_HANDLE ||
      hStoch_M5 == INVALID_HANDLE || hATR_M5 == INVALID_HANDLE) {
      Print("Erreur init indicateurs");
      return INIT_FAILED;
   }

   ResetDailyStats();

   Print("Spectra Zone Scalper v2 initialisé - logique corrigée");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hEMAFast); IndicatorRelease(hEMASlow);
   IndicatorRelease(hADX_H1);  IndicatorRelease(hRSI_M5);
   IndicatorRelease(hStoch_M5); IndicatorRelease(hATR_M5);
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick()
{
   CheckNewDay();

   if(InpShowDashboard) DrawDashboard();
   if(!IsNewBar()) return;

   ManageTrailing();

   if(!IsTradingAllowed()) return;
   if(!CheckDailyLimits()) return;
   if(!CheckSpread()) return;
   if(!CheckVolatility()) return;
   if(CountMyTrades() >= InpMaxTrades) return;

   int trend = GetTrend();
   if(trend == 0) return;

   int signal = GetEntrySignal(trend);
   if(signal != 0) OpenTrade(signal);
}

//+------------------------------------------------------------------+
void CheckNewDay()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime dayStart = StringToTime(StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));
   if(dayStart != g_todayStart) {
      g_todayStart = dayStart;
      g_lossesToday = 0;
      g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   }
}

void ResetDailyStats() {
   g_lossesToday = 0;
   g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
}

//+------------------------------------------------------------------+
bool IsNewBar()
{
   static datetime lastBar = 0;
   datetime cur = iTime(_Symbol, InpEntryTF, 0);
   if(cur == lastBar) return false;
   lastBar = cur;
   return true;
}

//+------------------------------------------------------------------+
bool IsTradingAllowed()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.hour < InpStartHour || dt.hour >= InpEndHour) return false;
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;
   if(InpAvoidFriday && dt.day_of_week == 5 && dt.hour >= 17) return false;
   return true;
}

//+------------------------------------------------------------------+
bool CheckDailyLimits()
{
   if(g_lossesToday >= InpMaxLossesPerDay) return false;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(g_dailyStartBalance > 0) {
      double dailyLoss = (g_dailyStartBalance - balance) / g_dailyStartBalance * 100.0;
      if(dailyLoss >= InpMaxDailyLoss) return false;
   }
   return true;
}

//+------------------------------------------------------------------+
bool CheckSpread()
{
   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / g_point;
   return spread <= InpMaxSpreadPoints;
}

//+------------------------------------------------------------------+
bool CheckVolatility()
{
   double atr = GetVal(hATR_M5, 0, 1);
   if(atr == EMPTY_VALUE) return false;
   return (atr / g_point) >= InpMinATR;
}

//+------------------------------------------------------------------+
double GetVal(int handle, int buffer, int shift)
{
   double arr[];
   ArraySetAsSeries(arr, true);
   if(CopyBuffer(handle, buffer, shift, 1, arr) <= 0) return EMPTY_VALUE;
   return arr[0];
}

//+------------------------------------------------------------------+
// Tendance basée sur EMA21/EMA50 H1 + ADX > 22
// +1 = uptrend, -1 = downtrend, 0 = pas de tendance claire
int GetTrend()
{
   double emaFast = GetVal(hEMAFast, 0, 1);
   double emaSlow = GetVal(hEMASlow, 0, 1);
   double adx     = GetVal(hADX_H1, 0, 1);

   if(emaFast == EMPTY_VALUE || emaSlow == EMPTY_VALUE || adx == EMPTY_VALUE) return 0;
   if(adx < InpADXMin) return 0;

   if(emaFast > emaSlow) return 1;
   if(emaFast < emaSlow) return -1;
   return 0;
}

//+------------------------------------------------------------------+
// Signal d'entrée : retracement RSI dans le sens de la tendance H1
// trend=+1 : on cherche BUY sur RSI bas (pullback bullish)
// trend=-1 : on cherche SELL sur RSI haut (pullback bearish)
int GetEntrySignal(int trend)
{
   double rsi   = GetVal(hRSI_M5, 0, 1);
   double rsiPrev = GetVal(hRSI_M5, 0, 2);
   double stochK = GetVal(hStoch_M5, 0, 1);
   double stochD = GetVal(hStoch_M5, 1, 1);
   double stochKp = GetVal(hStoch_M5, 0, 2);
   double stochDp = GetVal(hStoch_M5, 1, 2);

   if(rsi == EMPTY_VALUE || stochK == EMPTY_VALUE) return 0;

   // BUY: tendance up + RSI dans zone pullback + stoch croise haussier
   if(trend == 1) {
      bool rsiOK   = (rsi >= InpRSIBuyMin && rsi <= InpRSIBuyMax && rsi > rsiPrev);
      bool stochOK = (stochKp <= stochDp && stochK > stochD && stochK < 80);
      if(rsiOK && stochOK) return 1;
   }
   // SELL: tendance down + RSI dans zone pullback + stoch croise baissier
   if(trend == -1) {
      bool rsiOK   = (rsi >= InpRSISellMin && rsi <= InpRSISellMax && rsi < rsiPrev);
      bool stochOK = (stochKp >= stochDp && stochK < stochD && stochK > 20);
      if(rsiOK && stochOK) return -1;
   }
   return 0;
}

//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / step) * step;
   return MathMax(minL, MathMin(maxL, lot));
}

//+------------------------------------------------------------------+
double CalcLot(double slPoints)
{
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0 || slPoints <= 0) return NormalizeLot(0.01);
   double lossPerLot = (slPoints * g_point / tickSize) * tickValue;
   if(lossPerLot <= 0) return NormalizeLot(0.01);
   return NormalizeLot(riskMoney / lossPerLot);
}

//+------------------------------------------------------------------+
int CountMyTrades()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber) n++;
   return n;
}

//+------------------------------------------------------------------+
void OpenTrade(int dir)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lot = CalcLot(InpStopLossPoints);
   double sl, tp, price;
   double tpPoints = InpStopLossPoints * InpTPMultiplier;

   if(dir == 1) {
      price = ask;
      sl    = NormalizeDouble(price - InpStopLossPoints * g_point, g_digits);
      tp    = NormalizeDouble(price + tpPoints * g_point, g_digits);
      if(trade.Buy(lot, _Symbol, price, sl, tp, "SZSv2_BUY"))
         Print("BUY @ ", price, " SL=", sl, " TP=", tp, " lot=", lot);
   } else {
      price = bid;
      sl    = NormalizeDouble(price + InpStopLossPoints * g_point, g_digits);
      tp    = NormalizeDouble(price - tpPoints * g_point, g_digits);
      if(trade.Sell(lot, _Symbol, price, sl, tp, "SZSv2_SELL"))
         Print("SELL @ ", price, " SL=", sl, " TP=", tp, " lot=", lot);
   }
}

//+------------------------------------------------------------------+
void ManageTrailing()
{
   if(InpTrailingStop <= 0) return;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagicNumber) continue;

      double openPrice = posInfo.PriceOpen();
      double sl        = posInfo.StopLoss();
      double tp        = posInfo.TakeProfit();

      if(posInfo.PositionType() == POSITION_TYPE_BUY) {
         double profit = (bid - openPrice) / g_point;
         if(profit >= InpTrailingStart) {
            double newSL = NormalizeDouble(bid - InpTrailingStop * g_point, g_digits);
            if(newSL > sl) trade.PositionModify(posInfo.Ticket(), newSL, tp);
         }
      } else {
         double profit = (openPrice - ask) / g_point;
         if(profit >= InpTrailingStart) {
            double newSL = NormalizeDouble(ask + InpTrailingStop * g_point, g_digits);
            if(sl == 0 || newSL < sl) trade.PositionModify(posInfo.Ticket(), newSL, tp);
         }
      }
   }
}

//+------------------------------------------------------------------+
// Track des pertes pour stop journalier
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD) {
      if(HistoryDealSelect(trans.deal)) {
         long magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
         long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
         double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                       + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                       + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
         if(magic == InpMagicNumber && entry == DEAL_ENTRY_OUT && profit < 0)
            g_lossesToday++;
      }
   }
}

//+------------------------------------------------------------------+
void DrawDashboard()
{
   double rsi    = GetVal(hRSI_M5, 0, 1);
   double adx    = GetVal(hADX_H1, 0, 1);
   double atr    = GetVal(hATR_M5, 0, 1);
   double ef     = GetVal(hEMAFast, 0, 1);
   double es     = GetVal(hEMASlow, 0, 1);
   int    trend  = GetTrend();
   int    sig    = (trend != 0) ? GetEntrySignal(trend) : 0;
   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / g_point;

   string trendTxt  = (trend == 1) ? "UPTREND" : (trend == -1) ? "DOWNTREND" : "RANGE/NO TRADE";
   string signalTxt = (sig == 1) ? ">> BUY SIGNAL <<" : (sig == -1) ? ">> SELL SIGNAL <<" : "Attente";

   Comment(
      "=== SPECTRA ZONE SCALPER v2 ===\n",
      "Tendance H1: ", trendTxt, "\n",
      "Signal M5:   ", signalTxt, "\n",
      "----------------------------\n",
      "EMA21 H1:    ", DoubleToString(ef, g_digits), "\n",
      "EMA50 H1:    ", DoubleToString(es, g_digits), "\n",
      "ADX H1:      ", DoubleToString(adx, 2), "\n",
      "RSI M5:      ", DoubleToString(rsi, 2), "\n",
      "ATR (pts):   ", DoubleToString(atr / g_point, 0), "\n",
      "Spread:      ", DoubleToString(spread, 0), " pts\n",
      "----------------------------\n",
      "Trades:      ", CountMyTrades(), "/", InpMaxTrades, "\n",
      "Pertes/jour: ", g_lossesToday, "/", InpMaxLossesPerDay, "\n",
      "Balance:     ", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2), "\n"
   );
}
//+------------------------------------------------------------------+
