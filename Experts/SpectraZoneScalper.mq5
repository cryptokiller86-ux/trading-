//+------------------------------------------------------------------+
//|                    Spectra Zone Scalper                          |
//|              Reproduction basée sur la stratégie publique        |
//|         Zone Recovery + Multi-Indicator Scalper for XAUUSD       |
//+------------------------------------------------------------------+
#property copyright   "Reproduction - Allan Munene Mutiiria Strategy"
#property version     "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

CTrade         trade;
CPositionInfo  posInfo;
COrderInfo     orderInfo;

//--- Paramètres d'entrée
input group "=== PARAMETRES GENERAUX ==="
input string   InpSymbol          = "XAUUSD";      // Symbole (défaut XAUUSD)
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M5;    // Timeframe principal
input ENUM_TIMEFRAMES InpTF2       = PERIOD_M15;   // Timeframe confirmation 2
input ENUM_TIMEFRAMES InpTF3       = PERIOD_H1;    // Timeframe confirmation 3

input group "=== GESTION DU RISQUE ==="
input double   InpLotSize          = 0.01;         // Taille du lot initial
input double   InpRiskPercent      = 1.0;          // Risque par trade (%)
input bool     InpAutoLot          = true;         // Lot automatique selon risque
input double   InpTakeProfit       = 30.0;         // Take Profit (points)
input double   InpStopLoss         = 50.0;         // Stop Loss (points)
input double   InpTrailingStop     = 15.0;         // Trailing Stop (points)
input double   InpTrailingStep     = 5.0;          // Pas du Trailing (points)
input int      InpMaxTrades        = 5;            // Trades max simultanés
input double   InpMaxDrawdown      = 20.0;         // Drawdown max (%)
input int      InpMaxMinutes       = 30;           // Durée max d'un trade (min)

input group "=== ZONE RECOVERY ==="
input bool     InpZoneRecovery     = true;         // Activer Zone Recovery
input double   InpZoneSize         = 20.0;         // Taille de la zone (points)
input double   InpRecoveryLotMult  = 1.5;          // Multiplicateur lot recovery
input int      InpMaxRecovery      = 4;            // Niveaux recovery max
input double   InpRecoveryTP       = 10.0;         // TP recovery (points)

input group "=== INDICATEURS RSI ==="
input int      InpRSIPeriod        = 14;           // Période RSI
input double   InpRSIOverbought    = 70.0;         // RSI surachat
input double   InpRSIOversold      = 30.0;         // RSI survente
input double   InpRSIBuyLevel      = 40.0;         // RSI niveau achat
input double   InpRSISellLevel     = 60.0;         // RSI niveau vente

input group "=== INDICATEURS STOCHASTIC ==="
input int      InpStochK           = 14;           // Stochastic %K
input int      InpStochD           = 3;            // Stochastic %D
input int      InpStochSlowing     = 3;            // Stochastic slowing
input double   InpStochOverbought  = 80.0;         // Stoch surachat
input double   InpStochOversold    = 20.0;         // Stoch survente

input group "=== INDICATEURS CCI ==="
input int      InpCCIPeriod        = 20;           // Période CCI
input double   InpCCIBuyLevel      = -100.0;       // CCI niveau achat
input double   InpCCISellLevel     = 100.0;        // CCI niveau vente

input group "=== INDICATEURS ADX ==="
input int      InpADXPeriod        = 14;           // Période ADX
input double   InpADXMinLevel      = 20.0;         // ADX niveau min (tendance)

input group "=== FILTRES ==="
input bool     InpTradeMonday      = true;         // Trader Lundi
input bool     InpTradeTuesday     = true;         // Trader Mardi
input bool     InpTradeWednesday   = true;         // Trader Mercredi
input bool     InpTradeThursday    = true;         // Trader Jeudi
input bool     InpTradeFriday      = true;         // Trader Vendredi
input int      InpStartHour        = 2;            // Heure début (serveur)
input int      InpEndHour          = 22;           // Heure fin (serveur)
input int      InpMagicNumber      = 202501;       // Magic Number

//--- Variables globales handles
int    hRSI_M, hRSI_M2, hRSI_M3;
int    hStoch_M, hStoch_M2, hStoch_M3;
int    hCCI_M, hCCI_M2, hCCI_M3;
int    hADX_M, hADX_M2, hADX_M3;
int    hAO_M;

double g_point;
int    g_digits;
double g_initialBalance;

//--- Structure Zone Recovery
struct ZoneRecoveryInfo {
   ulong  ticket;
   int    direction;    // 1=BUY, -1=SELL
   double entryPrice;
   double zoneHigh;
   double zoneLow;
   double lotSize;
   int    level;
   bool   active;
};

ZoneRecoveryInfo g_zones[];

//+------------------------------------------------------------------+
int OnInit()
{
   if(!InitIndicators()) {
      Print("Erreur initialisation indicateurs");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   g_point          = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits         = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   ArrayResize(g_zones, 0);

   Print("Spectra Zone Scalper initialisé sur ", _Symbol);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
bool InitIndicators()
{
   string sym = _Symbol;

   hRSI_M   = iRSI(sym, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
   hRSI_M2  = iRSI(sym, InpTF2, InpRSIPeriod, PRICE_CLOSE);
   hRSI_M3  = iRSI(sym, InpTF3, InpRSIPeriod, PRICE_CLOSE);

   hStoch_M  = iStochastic(sym, InpTimeframe, InpStochK, InpStochD, InpStochSlowing, MODE_SMA, STO_LOWHIGH);
   hStoch_M2 = iStochastic(sym, InpTF2, InpStochK, InpStochD, InpStochSlowing, MODE_SMA, STO_LOWHIGH);
   hStoch_M3 = iStochastic(sym, InpTF3, InpStochK, InpStochD, InpStochSlowing, MODE_SMA, STO_LOWHIGH);

   hCCI_M   = iCCI(sym, InpTimeframe, InpCCIPeriod, PRICE_TYPICAL);
   hCCI_M2  = iCCI(sym, InpTF2, InpCCIPeriod, PRICE_TYPICAL);
   hCCI_M3  = iCCI(sym, InpTF3, InpCCIPeriod, PRICE_TYPICAL);

   hADX_M   = iADX(sym, InpTimeframe, InpADXPeriod);
   hADX_M2  = iADX(sym, InpTF2, InpADXPeriod);
   hADX_M3  = iADX(sym, InpTF3, InpADXPeriod);

   hAO_M    = iAO(sym, InpTimeframe);

   if(hRSI_M == INVALID_HANDLE || hStoch_M == INVALID_HANDLE ||
      hCCI_M == INVALID_HANDLE || hADX_M == INVALID_HANDLE || hAO_M == INVALID_HANDLE)
      return false;

   return true;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hRSI_M);  IndicatorRelease(hRSI_M2);  IndicatorRelease(hRSI_M3);
   IndicatorRelease(hStoch_M); IndicatorRelease(hStoch_M2); IndicatorRelease(hStoch_M3);
   IndicatorRelease(hCCI_M);  IndicatorRelease(hCCI_M2);  IndicatorRelease(hCCI_M3);
   IndicatorRelease(hADX_M);  IndicatorRelease(hADX_M2);  IndicatorRelease(hADX_M3);
   IndicatorRelease(hAO_M);
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(!IsNewBar()) return;
   if(!IsTradingAllowed()) return;
   if(!CheckDrawdown()) return;

   ManageOpenTrades();

   if(InpZoneRecovery)
      ManageZoneRecovery();

   CloseOldTrades();

   int signal = GetSignal();
   if(signal != 0 && CountMyTrades() < InpMaxTrades)
      OpenTrade(signal);
}

//+------------------------------------------------------------------+
bool IsNewBar()
{
   static datetime lastBar = 0;
   datetime currentBar = iTime(_Symbol, InpTimeframe, 0);
   if(currentBar == lastBar) return false;
   lastBar = currentBar;
   return true;
}

//+------------------------------------------------------------------+
bool IsTradingAllowed()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   int hour = dt.hour;
   int dow  = dt.day_of_week;

   if(hour < InpStartHour || hour >= InpEndHour) return false;

   if(dow == 1 && !InpTradeMonday)    return false;
   if(dow == 2 && !InpTradeTuesday)   return false;
   if(dow == 3 && !InpTradeWednesday) return false;
   if(dow == 4 && !InpTradeThursday)  return false;
   if(dow == 5 && !InpTradeFriday)    return false;

   return true;
}

//+------------------------------------------------------------------+
bool CheckDrawdown()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance <= 0) return false;
   double dd = (balance - equity) / balance * 100.0;
   if(dd >= InpMaxDrawdown) {
      Print("Drawdown max atteint: ", DoubleToString(dd, 2), "% - trading suspendu");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
// Lecture valeur indicateur (buffer 0 = valeur principale)
double GetIndicatorValue(int handle, int buffer, int shift = 1)
{
   double arr[];
   ArraySetAsSeries(arr, true);
   if(CopyBuffer(handle, buffer, shift, 1, arr) <= 0) return EMPTY_VALUE;
   return arr[0];
}

//+------------------------------------------------------------------+
// Score de signal sur un timeframe : +1=buy, -1=sell, 0=neutre
int GetTimeframeScore(int rsiH, int stochH, int cciH, int adxH, int shift = 1)
{
   double rsi   = GetIndicatorValue(rsiH, 0, shift);
   double stochK = GetIndicatorValue(stochH, 0, shift);
   double cci   = GetIndicatorValue(cciH, 0, shift);
   double adx   = GetIndicatorValue(adxH, 0, shift);

   if(rsi == EMPTY_VALUE || stochK == EMPTY_VALUE || cci == EMPTY_VALUE || adx == EMPTY_VALUE)
      return 0;

   int buyScore  = 0;
   int sellScore = 0;

   // RSI
   if(rsi < InpRSIBuyLevel)  buyScore++;
   if(rsi > InpRSISellLevel) sellScore++;

   // Stochastic
   if(stochK < InpStochOversold)  buyScore++;
   if(stochK > InpStochOverbought) sellScore++;

   // CCI
   if(cci < InpCCIBuyLevel)  buyScore++;
   if(cci > InpCCISellLevel) sellScore++;

   // ADX filtre (tendance présente)
   if(adx < InpADXMinLevel) return 0;

   if(buyScore >= 2)  return 1;
   if(sellScore >= 2) return -1;
   return 0;
}

//+------------------------------------------------------------------+
// Signal global avec triple confirmation de timeframe
int GetSignal()
{
   int score1 = GetTimeframeScore(hRSI_M,  hStoch_M,  hCCI_M,  hADX_M);
   int score2 = GetTimeframeScore(hRSI_M2, hStoch_M2, hCCI_M2, hADX_M2);
   int score3 = GetTimeframeScore(hRSI_M3, hStoch_M3, hCCI_M3, hADX_M3);

   double ao = GetIndicatorValue(hAO_M, 0);
   int aoSignal = 0;
   if(ao > 0) aoSignal = 1;
   if(ao < 0) aoSignal = -1;

   int buyCount  = 0;
   int sellCount = 0;

   if(score1 == 1) buyCount++;  if(score1 == -1) sellCount++;
   if(score2 == 1) buyCount++;  if(score2 == -1) sellCount++;
   if(score3 == 1) buyCount++;  if(score3 == -1) sellCount++;
   if(aoSignal == 1) buyCount++; if(aoSignal == -1) sellCount++;

   // Strong signal : 3+ confirmations
   if(buyCount >= 3)  return 1;
   if(sellCount >= 3) return -1;
   return 0;
}

//+------------------------------------------------------------------+
double CalcLotSize(double slPoints)
{
   if(!InpAutoLot) return NormalizeLot(InpLotSize);

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0 || tickSize <= 0 || slPoints <= 0) return NormalizeLot(InpLotSize);

   double lotValue = (slPoints * g_point / tickSize) * tickValue;
   if(lotValue <= 0) return NormalizeLot(InpLotSize);

   return NormalizeLot(riskMoney / lotValue);
}

//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / stepLot) * stepLot;
   lot = MathMax(minLot, MathMin(maxLot, lot));
   return lot;
}

//+------------------------------------------------------------------+
bool HasOpenTrade(int direction)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(posInfo.SelectByIndex(i)) {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber) {
            if(direction == 1 && posInfo.PositionType() == POSITION_TYPE_BUY)  return true;
            if(direction == -1 && posInfo.PositionType() == POSITION_TYPE_SELL) return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
int CountMyTrades()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
            count++;
   }
   return count;
}

//+------------------------------------------------------------------+
void OpenTrade(int direction)
{
   if(HasOpenTrade(direction)) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl, tp, price;
   double lot = CalcLotSize(InpStopLoss);

   if(direction == 1) {
      price = ask;
      sl    = NormalizeDouble(price - InpStopLoss * g_point, g_digits);
      tp    = NormalizeDouble(price + InpTakeProfit * g_point, g_digits);
      if(trade.Buy(lot, _Symbol, price, sl, tp, "SZS_BUY")) {
         Print("BUY ouvert @ ", price, " lot=", lot);
         if(InpZoneRecovery) RegisterZone(trade.ResultOrder(), 1, price, lot);
      }
   } else {
      price = bid;
      sl    = NormalizeDouble(price + InpStopLoss * g_point, g_digits);
      tp    = NormalizeDouble(price - InpTakeProfit * g_point, g_digits);
      if(trade.Sell(lot, _Symbol, price, sl, tp, "SZS_SELL")) {
         Print("SELL ouvert @ ", price, " lot=", lot);
         if(InpZoneRecovery) RegisterZone(trade.ResultOrder(), -1, price, lot);
      }
   }
}

//+------------------------------------------------------------------+
void RegisterZone(ulong ticket, int dir, double price, double lot)
{
   int idx = ArraySize(g_zones);
   ArrayResize(g_zones, idx + 1);
   g_zones[idx].ticket     = ticket;
   g_zones[idx].direction  = dir;
   g_zones[idx].entryPrice = price;
   g_zones[idx].zoneHigh   = price + InpZoneSize * g_point;
   g_zones[idx].zoneLow    = price - InpZoneSize * g_point;
   g_zones[idx].lotSize    = lot;
   g_zones[idx].level      = 0;
   g_zones[idx].active     = true;
}

//+------------------------------------------------------------------+
void ManageZoneRecovery()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   for(int i = 0; i < ArraySize(g_zones); i++) {
      if(!g_zones[i].active) continue;
      if(g_zones[i].level >= InpMaxRecovery) continue;

      if(!PositionSelectByTicket(g_zones[i].ticket)) {
         g_zones[i].active = false;
         continue;
      }

      double curPrice = (g_zones[i].direction == 1) ? bid : ask;
      bool needRecovery = false;

      if(g_zones[i].direction == 1 && curPrice < g_zones[i].zoneLow)
         needRecovery = true;
      if(g_zones[i].direction == -1 && curPrice > g_zones[i].zoneHigh)
         needRecovery = true;

      if(needRecovery) {
         double recLot = NormalizeLot(g_zones[i].lotSize * InpRecoveryLotMult);
         double recTP, recSL;
         int recDir = -g_zones[i].direction;

         if(recDir == 1) {
            recTP = NormalizeDouble(ask + InpRecoveryTP * g_point, g_digits);
            recSL = NormalizeDouble(ask - InpStopLoss * g_point, g_digits);
            if(trade.Buy(recLot, _Symbol, ask, recSL, recTP, "SZS_REC_BUY")) {
               g_zones[i].level++;
               g_zones[i].direction  = recDir;
               g_zones[i].ticket     = trade.ResultOrder();
               g_zones[i].entryPrice = ask;
               g_zones[i].zoneHigh   = ask + InpZoneSize * g_point;
               g_zones[i].zoneLow    = ask - InpZoneSize * g_point;
               g_zones[i].lotSize    = recLot;
               Print("Zone Recovery BUY niveau ", g_zones[i].level, " lot=", recLot);
            }
         } else {
            recTP = NormalizeDouble(bid - InpRecoveryTP * g_point, g_digits);
            recSL = NormalizeDouble(bid + InpStopLoss * g_point, g_digits);
            if(trade.Sell(recLot, _Symbol, bid, recSL, recTP, "SZS_REC_SELL")) {
               g_zones[i].level++;
               g_zones[i].direction  = recDir;
               g_zones[i].ticket     = trade.ResultOrder();
               g_zones[i].entryPrice = bid;
               g_zones[i].zoneHigh   = bid + InpZoneSize * g_point;
               g_zones[i].zoneLow    = bid - InpZoneSize * g_point;
               g_zones[i].lotSize    = recLot;
               Print("Zone Recovery SELL niveau ", g_zones[i].level, " lot=", recLot);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
void ManageOpenTrades()
{
   if(InpTrailingStop <= 0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagicNumber) continue;

      ulong ticket = posInfo.Ticket();
      double sl    = posInfo.StopLoss();
      double newSL;

      if(posInfo.PositionType() == POSITION_TYPE_BUY) {
         newSL = NormalizeDouble(bid - InpTrailingStop * g_point, g_digits);
         if(newSL > sl + InpTrailingStep * g_point)
            trade.PositionModify(ticket, newSL, posInfo.TakeProfit());
      } else {
         newSL = NormalizeDouble(ask + InpTrailingStop * g_point, g_digits);
         if(newSL < sl - InpTrailingStep * g_point || sl == 0)
            trade.PositionModify(ticket, newSL, posInfo.TakeProfit());
      }
   }
}

//+------------------------------------------------------------------+
void CloseOldTrades()
{
   if(InpMaxMinutes <= 0) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagicNumber) continue;

      datetime openTime = (datetime)posInfo.Time();
      int elapsedMin = (int)((TimeCurrent() - openTime) / 60);

      if(elapsedMin >= InpMaxMinutes) {
         trade.PositionClose(posInfo.Ticket(), 10);
         Print("Trade fermé (timeout ", InpMaxMinutes, "min): ticket=", posInfo.Ticket());
      }
   }
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD) {
      for(int i = 0; i < ArraySize(g_zones); i++) {
         if(g_zones[i].ticket == trans.order && trans.deal_type == DEAL_TYPE_BUY)
            g_zones[i].active = false;
      }
   }
}

//+------------------------------------------------------------------+
// Affichage dashboard sur le graphique
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
}

//+------------------------------------------------------------------+
double GetRSI()  { return GetIndicatorValue(hRSI_M, 0); }
double GetADX()  { return GetIndicatorValue(hADX_M, 0); }
double GetCCI()  { return GetIndicatorValue(hCCI_M, 0); }
double GetAO()   { return GetIndicatorValue(hAO_M,  0); }

//+------------------------------------------------------------------+
// Dashboard visuel sur le graphique
void DrawDashboard()
{
   double rsi   = GetRSI();
   double adx   = GetADX();
   double cci   = GetCCI();
   double ao    = GetAO();
   int    sig   = GetSignal();
   int    trades = CountMyTrades();
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dd = (balance > 0) ? (balance - equity) / balance * 100.0 : 0;

   string sigText = (sig == 1) ? "STRONG BUY" : (sig == -1) ? "STRONG SELL" : "NEUTRE";
   color  sigColor = (sig == 1) ? clrLime : (sig == -1) ? clrRed : clrGray;

   Comment(
      "=== SPECTRA ZONE SCALPER ===\n",
      "Signal:    ", sigText, "\n",
      "RSI(14):   ", DoubleToString(rsi, 2), "\n",
      "ADX(14):   ", DoubleToString(adx, 2), "\n",
      "CCI(20):   ", DoubleToString(cci, 2), "\n",
      "AO:        ", DoubleToString(ao, 2), "\n",
      "Trades:    ", trades, "/", InpMaxTrades, "\n",
      "Drawdown:  ", DoubleToString(dd, 2), "%\n",
      "Equity:    ", DoubleToString(equity, 2), "\n",
      "Balance:   ", DoubleToString(balance, 2), "\n"
   );
}

//+------------------------------------------------------------------+
// Appel dashboard à chaque tick
void OnTick_Dashboard() { DrawDashboard(); }
//+------------------------------------------------------------------+
