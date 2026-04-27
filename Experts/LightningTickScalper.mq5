//+------------------------------------------------------------------+
//|                  Lightning Tick Scalper                          |
//|       Scalping ultra-rapide - positions simultanées              |
//|       Trades de quelques secondes, signaux M1 + tick volume      |
//+------------------------------------------------------------------+
#property copyright   "Lightning Tick Scalper"
#property version     "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade         trade;
CPositionInfo  posInfo;

//--- Paramètres
input group "=== EXECUTION ==="
input ENUM_TIMEFRAMES InpSignalTF = PERIOD_M1;       // TF signaux (M1 recommandé)
input bool     InpTickMode        = true;            // Trading sur chaque tick (true) ou par bougie (false)
input int      InpMaxSimultaneous = 5;               // Positions simultanées max
input int      InpCooldownMs      = 500;             // Délai min entre trades (millisecondes)

input group "=== SORTIE RAPIDE ==="
input double   InpTakeProfit      = 50;              // TP en points (XAUUSD: 50pts=0.50$)
input double   InpStopLoss        = 80;              // SL en points
input int      InpMaxHoldSeconds  = 60;              // Durée max d'un trade (secondes)
input bool     InpUseTrailing     = true;            // Trailing stop
input double   InpTrailingStart   = 20;              // Activation trailing (pts profit)
input double   InpTrailingStep    = 10;              // Distance trailing (pts)
input bool     InpBreakEven       = true;            // Break-even auto
input double   InpBreakEvenAt     = 15;              // Activation BE (pts profit)

input group "=== GESTION RISQUE ==="
input double   InpRiskPercent     = 0.3;             // Risque par trade (%)
input bool     InpAutoLot         = true;            // Lot auto selon risque
input double   InpFixedLot        = 0.01;            // Lot fixe si AutoLot=false
input double   InpMaxDailyLoss    = 5.0;             // Perte max journalière (%)
input double   InpMaxDrawdown     = 10.0;            // Drawdown max (%)

input group "=== FILTRES ==="
input double   InpMaxSpread       = 30;              // Spread max (points)
input double   InpMinATR          = 50;              // ATR M1 min (volatilité)
input int      InpATRPeriod       = 14;
input int      InpStartHour       = 7;               // Début (Londres ouverture)
input int      InpEndHour         = 21;              // Fin
input bool     InpAvoidNews       = true;            // Éviter news (utiliser un calendrier externe)

input group "=== SIGNAUX BOLLINGER + MOMENTUM ==="
input int      InpBBPeriod        = 20;              // Bollinger période
input double   InpBBDeviation     = 2.0;             // Bollinger écart-type
input int      InpRSIPeriod       = 7;               // RSI rapide
input double   InpRSIBuyTrig      = 30;              // RSI < 30 = signal BUY
input double   InpRSISellTrig     = 70;              // RSI > 70 = signal SELL
input int      InpVolumeAvgBars   = 10;              // Moyenne volume tick
input double   InpVolumeMult      = 1.5;             // Volume actuel > moyenne × X

input group "=== DIVERS ==="
input int      InpMagicNumber     = 999001;
input bool     InpShowDashboard   = true;

//--- Handles
int    hBB, hRSI, hATR;
double g_point;
int    g_digits;

//--- État
ulong  g_lastTradeTime = 0;
datetime g_dayStart   = 0;
double   g_dayStartBalance = 0;
double   g_initBalance = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   trade.SetAsyncMode(false);

   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_initBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   hBB  = iBands(_Symbol, InpSignalTF, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);
   hRSI = iRSI(_Symbol, InpSignalTF, InpRSIPeriod, PRICE_CLOSE);
   hATR = iATR(_Symbol, InpSignalTF, InpATRPeriod);

   if(hBB == INVALID_HANDLE || hRSI == INVALID_HANDLE || hATR == INVALID_HANDLE) {
      Print("Erreur init indicateurs");
      return INIT_FAILED;
   }

   ResetDay();
   Print("Lightning Tick Scalper initialisé");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hBB);
   IndicatorRelease(hRSI);
   IndicatorRelease(hATR);
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick()
{
   CheckNewDay();
   if(InpShowDashboard) DrawDashboard();

   ManageOpenTrades();
   CloseExpiredTrades();

   if(!IsTradingTime()) return;
   if(!CheckLimits()) return;
   if(!CheckSpread()) return;
   if(!CheckVolatility()) return;
   if(!CheckCooldown()) return;
   if(CountTrades() >= InpMaxSimultaneous) return;

   if(!InpTickMode && !IsNewBar()) return;

   int signal = GetSignal();
   if(signal != 0) ExecuteTrade(signal);
}

//+------------------------------------------------------------------+
bool IsNewBar()
{
   static datetime lastBar = 0;
   datetime cur = iTime(_Symbol, InpSignalTF, 0);
   if(cur == lastBar) return false;
   lastBar = cur;
   return true;
}

//+------------------------------------------------------------------+
void CheckNewDay()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime ds = StringToTime(StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));
   if(ds != g_dayStart) {
      g_dayStart = ds;
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   }
}

void ResetDay() {
   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
}

//+------------------------------------------------------------------+
bool IsTradingTime()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;
   if(dt.hour < InpStartHour || dt.hour >= InpEndHour) return false;
   return true;
}

//+------------------------------------------------------------------+
bool CheckLimits()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   // Drawdown total
   if(g_initBalance > 0) {
      double dd = (g_initBalance - equity) / g_initBalance * 100.0;
      if(dd >= InpMaxDrawdown) return false;
   }
   // Perte journalière
   if(g_dayStartBalance > 0) {
      double dl = (g_dayStartBalance - equity) / g_dayStartBalance * 100.0;
      if(dl >= InpMaxDailyLoss) return false;
   }
   return true;
}

//+------------------------------------------------------------------+
bool CheckSpread()
{
   double sp = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / g_point;
   return sp <= InpMaxSpread;
}

//+------------------------------------------------------------------+
bool CheckVolatility()
{
   double atr = GetVal(hATR, 0, 1);
   if(atr == EMPTY_VALUE) return false;
   return (atr / g_point) >= InpMinATR;
}

//+------------------------------------------------------------------+
bool CheckCooldown()
{
   ulong now = GetMicrosecondCount() / 1000;
   if(now - g_lastTradeTime < (ulong)InpCooldownMs) return false;
   return true;
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
// Volume pic = volume actuel > moyenne × multiplicateur
bool VolumeSpike()
{
   long vols[];
   ArraySetAsSeries(vols, true);
   if(CopyTickVolume(_Symbol, InpSignalTF, 0, InpVolumeAvgBars + 1, vols) <= 0) return false;

   long curVol = vols[0];
   long sum = 0;
   for(int i = 1; i <= InpVolumeAvgBars; i++) sum += vols[i];
   double avg = (double)sum / InpVolumeAvgBars;
   if(avg <= 0) return false;
   return curVol >= avg * InpVolumeMult;
}

//+------------------------------------------------------------------+
// Signal: prix touche BB extérieur + RSI extrême + volume pic
int GetSignal()
{
   double bbUp   = GetVal(hBB, 1, 0);
   double bbLow  = GetVal(hBB, 2, 0);
   double rsi    = GetVal(hRSI, 0, 0);
   if(bbUp == EMPTY_VALUE || rsi == EMPTY_VALUE) return 0;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   bool volOK = VolumeSpike();

   // BUY: prix sous BB low + RSI survente + volume
   if(bid <= bbLow && rsi <= InpRSIBuyTrig && volOK) return 1;

   // SELL: prix au-dessus BB up + RSI surachat + volume
   if(ask >= bbUp && rsi >= InpRSISellTrig && volOK) return -1;

   return 0;
}

//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / st) * st;
   return MathMax(mn, MathMin(mx, lot));
}

double CalcLot()
{
   if(!InpAutoLot) return NormalizeLot(InpFixedLot);
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk      = balance * InpRiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0) return NormalizeLot(InpFixedLot);
   double lossPerLot = (InpStopLoss * g_point / tickSize) * tickValue;
   if(lossPerLot <= 0) return NormalizeLot(InpFixedLot);
   return NormalizeLot(risk / lossPerLot);
}

//+------------------------------------------------------------------+
int CountTrades()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber) n++;
   return n;
}

//+------------------------------------------------------------------+
void ExecuteTrade(int dir)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lot = CalcLot();
   double sl, tp, price;

   if(dir == 1) {
      price = ask;
      sl = NormalizeDouble(price - InpStopLoss * g_point, g_digits);
      tp = NormalizeDouble(price + InpTakeProfit * g_point, g_digits);
      if(trade.Buy(lot, _Symbol, price, sl, tp, "LTS_BUY")) {
         g_lastTradeTime = GetMicrosecondCount() / 1000;
         Print("BUY @ ", price, " lot=", lot, " positions=", CountTrades());
      }
   } else {
      price = bid;
      sl = NormalizeDouble(price + InpStopLoss * g_point, g_digits);
      tp = NormalizeDouble(price - InpTakeProfit * g_point, g_digits);
      if(trade.Sell(lot, _Symbol, price, sl, tp, "LTS_SELL")) {
         g_lastTradeTime = GetMicrosecondCount() / 1000;
         Print("SELL @ ", price, " lot=", lot, " positions=", CountTrades());
      }
   }
}

//+------------------------------------------------------------------+
void ManageOpenTrades()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagicNumber) continue;

      ulong  ticket = posInfo.Ticket();
      double openP  = posInfo.PriceOpen();
      double sl     = posInfo.StopLoss();
      double tp     = posInfo.TakeProfit();

      if(posInfo.PositionType() == POSITION_TYPE_BUY) {
         double profit = (bid - openP) / g_point;

         // Break-even
         if(InpBreakEven && profit >= InpBreakEvenAt && (sl < openP || sl == 0)) {
            double newSL = NormalizeDouble(openP + 1 * g_point, g_digits);
            if(newSL > sl) trade.PositionModify(ticket, newSL, tp);
         }
         // Trailing
         if(InpUseTrailing && profit >= InpTrailingStart) {
            double newSL = NormalizeDouble(bid - InpTrailingStep * g_point, g_digits);
            if(newSL > sl) trade.PositionModify(ticket, newSL, tp);
         }
      } else {
         double profit = (openP - ask) / g_point;

         if(InpBreakEven && profit >= InpBreakEvenAt && (sl > openP || sl == 0)) {
            double newSL = NormalizeDouble(openP - 1 * g_point, g_digits);
            if(sl == 0 || newSL < sl) trade.PositionModify(ticket, newSL, tp);
         }
         if(InpUseTrailing && profit >= InpTrailingStart) {
            double newSL = NormalizeDouble(ask + InpTrailingStep * g_point, g_digits);
            if(sl == 0 || newSL < sl) trade.PositionModify(ticket, newSL, tp);
         }
      }
   }
}

//+------------------------------------------------------------------+
// Ferme les trades qui dépassent la durée max
void CloseExpiredTrades()
{
   if(InpMaxHoldSeconds <= 0) return;
   datetime now = TimeCurrent();

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagicNumber) continue;

      datetime opened = (datetime)posInfo.Time();
      if((int)(now - opened) >= InpMaxHoldSeconds) {
         trade.PositionClose(posInfo.Ticket(), 30);
         Print("Position fermée (timeout ", InpMaxHoldSeconds, "s) ticket=", posInfo.Ticket());
      }
   }
}

//+------------------------------------------------------------------+
void DrawDashboard()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sp  = (ask - bid) / g_point;
   double rsi = GetVal(hRSI, 0, 0);
   double bbU = GetVal(hBB, 1, 0);
   double bbL = GetVal(hBB, 2, 0);
   double atr = GetVal(hATR, 0, 1);
   bool   vol = VolumeSpike();
   int    sig = GetSignal();
   string sigT = (sig == 1) ? ">> BUY <<" : (sig == -1) ? ">> SELL <<" : "Attente";

   Comment(
      "=== LIGHTNING TICK SCALPER ===\n",
      "Signal:        ", sigT, "\n",
      "------------------------------\n",
      "Spread:        ", DoubleToString(sp, 0), " pts (max ", InpMaxSpread, ")\n",
      "ATR M1:        ", DoubleToString(atr / g_point, 0), " pts (min ", InpMinATR, ")\n",
      "RSI(", InpRSIPeriod, "):       ", DoubleToString(rsi, 1), "\n",
      "BB Upper:      ", DoubleToString(bbU, g_digits), "\n",
      "BB Lower:      ", DoubleToString(bbL, g_digits), "\n",
      "Volume Spike:  ", (vol ? "OUI" : "NON"), "\n",
      "------------------------------\n",
      "Positions:     ", CountTrades(), "/", InpMaxSimultaneous, "\n",
      "Equity:        ", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2), "\n",
      "Balance:       ", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2), "\n"
   );
}
//+------------------------------------------------------------------+
