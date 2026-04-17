//+------------------------------------------------------------------+
//|  ScalpingGridEA_GOLD.mq5                                         |
//|  Gold Scalping Grid EA — XAUUSD v4.0                             |
//|  Timeframe: M5  |  Symbol: XAUUSD                                |
//|                                                                  |
//|  Entrées: 5 confluences (EMA200 H1, EMA9/21 M5, RSI7,           |
//|           Stoch(5,3,3), Bollinger Bands)                         |
//|  Sorties rapides:                                                |
//|   - TP individuel serré ($1.80)                                  |
//|   - Basket TP ($4.00 profit total)                               |
//|   - Sortie temporelle (max 20 min par position)                  |
//|   - Breakeven rapide (dès $0.80 de profit)                       |
//|   - Signal inverse EMA croise contre la position                 |
//|   - Trailing serré ($0.80 start, $0.40 step)                     |
//+------------------------------------------------------------------+
#property copyright "ScalpingGridEA_GOLD v4"
#property version   "4.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
CPositionInfo pos;

//──────────────────────────────────────────────────────────────────
input group "=== INDICATEURS ==="
input int    EMA_Fast          = 9;
input int    EMA_Slow          = 21;
input int    EMA_Trend         = 200;    // H1 — biais tendance
input int    RSI_Period        = 7;
input double RSI_Buy           = 40.0;
input double RSI_Sell          = 60.0;
input int    Stoch_K           = 5;
input int    Stoch_D           = 3;
input int    Stoch_Slow        = 3;
input double Stoch_Buy         = 35.0;
input double Stoch_Sell        = 65.0;
input int    BB_Period         = 20;
input double BB_Dev            = 2.0;
input double BB_EntryPct       = 0.80;   // % bande requise pour entrée
input int    ATR_Period        = 14;

input group "=== GRID ==="
input bool   UseATRGrid        = true;
input double ATR_GridMult      = 0.25;
input double GridStep_USD      = 1.50;
input int    MaxGridLevels     = 4;
input double LotBase           = 0.01;
input double LotMultiplier     = 1.3;
input bool   UseAntiMart       = false;

input group "=== SORTIES RAPIDES ==="
input double TP_USD            = 1.80;   // TP par position ($)
input double BasketTP_USD      = 4.00;   // TP panier total ($)
input double SL_USD            = 7.00;   // SL urgence ($)
input int    MaxMinutesOpen    = 20;     // Ferme la position après X min
input bool   UseBreakeven      = true;   // Breakeven automatique
input double BE_Trigger_USD    = 0.80;   // Active BE quand profit > $
input double BE_Buffer_USD     = 0.20;   // Verrouille $ au-dessus du BE
input bool   UseTrailing       = true;   // Trailing stop
input double Trail_Start_USD   = 0.80;   // Active trailing après ($)
input double Trail_Step_USD    = 0.40;   // Pas du trailing ($)
input bool   UseSignalExit     = true;   // Sort si EMA recroise contre pos
input bool   UseEOD            = true;   // Ferme tout en fin de session
input int    EOD_Hour          = 21;     // Heure UTC fermeture journalière

input group "=== RISQUE ==="
input double MaxDD_Pct         = 15.0;
input double MaxSpread_USD     = 0.40;
input double ATR_SpikeRatio    = 2.2;
input int    MaxPositions      = 8;
input int    MagicNumber       = 30047;

input group "=== SESSIONS (UTC) ==="
input bool   UseSessions       = true;
input int    London_Open       = 8;
input int    London_Close      = 17;
input int    NY_Open           = 13;
input int    NY_Close          = 22;
input bool   TradeAsia         = false;
input int    Asia_Open         = 1;
input int    Asia_Close        = 7;

input group "=== AFFICHAGE ==="
input bool   Dashboard         = true;

//──────────────────────────────────────────────────────────────────
double   g_pt;
int      g_digits;
bool     g_gridBuy  = false;
bool     g_gridSell = false;
double   g_gridBase = 0.0;

int h_emaFast, h_emaSlow, h_emaTrend;
int h_rsi, h_stoch, h_bb, h_atr, h_atrH1;

double   g_startBal;
int      g_trades   = 0;
int      g_wins     = 0;
double   g_profit   = 0.0;
double   g_maxDD    = 0.0;
double   g_peakEq   = 0.0;
datetime g_lastBar  = 0;

//──────────────────────────────────────────────────────────────────
int OnInit()
  {
   string s = _Symbol;
   if(StringFind(s,"XAU") < 0 && StringFind(s,"GOLD") < 0)
     { Alert("EA réservé XAUUSD. Symbole actuel: ",s); return INIT_FAILED; }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   g_pt = _Point; g_digits = _Digits;

   h_emaFast  = iMA(_Symbol, PERIOD_M5, EMA_Fast,  0, MODE_EMA, PRICE_CLOSE);
   h_emaSlow  = iMA(_Symbol, PERIOD_M5, EMA_Slow,  0, MODE_EMA, PRICE_CLOSE);
   h_emaTrend = iMA(_Symbol, PERIOD_H1, EMA_Trend, 0, MODE_EMA, PRICE_CLOSE);
   h_rsi      = iRSI(_Symbol,   PERIOD_M5, RSI_Period, PRICE_CLOSE);
   h_bb       = iBands(_Symbol, PERIOD_M5, BB_Period, 0, BB_Dev, PRICE_CLOSE);
   h_atr      = iATR(_Symbol,   PERIOD_M5, ATR_Period);
   h_atrH1    = iATR(_Symbol,   PERIOD_H1, ATR_Period);
   h_stoch    = iStochastic(_Symbol, PERIOD_M5, Stoch_K, Stoch_D, Stoch_Slow,
                             MODE_SMA, STO_LOWHIGH);

   if(h_emaFast==INVALID_HANDLE || h_emaSlow==INVALID_HANDLE ||
      h_emaTrend==INVALID_HANDLE|| h_rsi==INVALID_HANDLE     ||
      h_bb==INVALID_HANDLE      || h_atr==INVALID_HANDLE     ||
      h_atrH1==INVALID_HANDLE   || h_stoch==INVALID_HANDLE)
     { Print("ERREUR: handles indicateurs"); return INIT_FAILED; }

   g_startBal = AccountInfoDouble(ACCOUNT_BALANCE);
   g_peakEq   = g_startBal;
   Print("GOLD Grid EA v4 | Balance: ", g_startBal);
   return INIT_SUCCEEDED;
  }

//──────────────────────────────────────────────────────────────────
void OnDeinit(const int reason)
  {
   IndicatorRelease(h_emaFast); IndicatorRelease(h_emaSlow);
   IndicatorRelease(h_emaTrend);IndicatorRelease(h_rsi);
   IndicatorRelease(h_bb);      IndicatorRelease(h_atr);
   IndicatorRelease(h_atrH1);   IndicatorRelease(h_stoch);
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

   //─── Protection drawdown max ────────────────────────────────
   if(ddPct >= MaxDD_Pct) { CloseAll("MAX DRAWDOWN"); return; }

   //─── Fermeture fin de journée ────────────────────────────────
   if(UseEOD)
     {
      MqlDateTime dt; TimeToStruct(TimeGMT(), dt);
      if(dt.hour >= EOD_Hour) { if(CountAll()>0) CloseAll("FIN JOURNEE"); return; }
     }

   //─── Gestion des positions ouvertes (chaque tick) ────────────
   ManageBreakeven();
   ManageTrailing();
   ManageTimeExit();
   if(UseSignalExit) ManageSignalExit();
   CheckBasketTP();

   //─── Signaux d'entrée : 1 fois par barre M5 ──────────────────
   datetime barNow = iTime(_Symbol, PERIOD_M5, 0);
   if(barNow == g_lastBar) { if(Dashboard) ShowPanel(equity,balance,ddPct); return; }
   g_lastBar = barNow;

   //─── Filtres pré-entrée ───────────────────────────────────────
   double spreadUSD = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * g_pt;
   if(spreadUSD > MaxSpread_USD) return;
   if(UseSessions && !InSession())  return;
   if(CountAll() >= MaxPositions)   return;

   //─── Lecture des indicateurs (barre [1] = dernière barre fermée)
   double emaF[3],emaS[3],emaT[3],rsi[3],sk[3],sd[3],bbU[3],bbL[3],bbM[3],aM5[3],aH1[3];
   if(CopyBuffer(h_emaFast, 0,1,3,emaF) <3) return;
   if(CopyBuffer(h_emaSlow, 0,1,3,emaS) <3) return;
   if(CopyBuffer(h_emaTrend,0,1,3,emaT) <3) return;
   if(CopyBuffer(h_rsi,     0,1,3,rsi)  <3) return;
   if(CopyBuffer(h_stoch,   0,1,3,sk)   <3) return;
   if(CopyBuffer(h_stoch,   1,1,3,sd)   <3) return;
   if(CopyBuffer(h_bb,      1,1,3,bbU)  <3) return;
   if(CopyBuffer(h_bb,      2,1,3,bbL)  <3) return;
   if(CopyBuffer(h_bb,      0,1,3,bbM)  <3) return;
   if(CopyBuffer(h_atr,     0,1,3,aM5)  <3) return;
   if(CopyBuffer(h_atrH1,   0,1,3,aH1)  <3) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double mid = (ask + bid) / 2.0;

   //─── Guard spike de volatilité ────────────────────────────────
   double atrRatio = (aH1[0]>0.0) ? (aM5[0]*12.0)/aH1[0] : 1.0;
   if(atrRatio > ATR_SpikeRatio) { if(Dashboard) ShowPanel(equity,balance,ddPct); return; }

   //─── Step grille dynamique ────────────────────────────────────
   double gridStep = UseATRGrid
                     ? MathMax(aM5[0] * ATR_GridMult * 100.0, 0.80)
                     : GridStep_USD;

   //═══════════════════════════════════════════════════════════════
   //  SIGNAUX
   //═══════════════════════════════════════════════════════════════

   // 1. Biais H1
   bool h1Bull = mid > emaT[0];
   bool h1Bear = mid < emaT[0];

   // 2. Croisement EMA frais (sur barre fermée)
   bool crossUp   = emaF[0]>emaS[0] && emaF[1]<=emaS[1];
   bool crossDown = emaF[0]<emaS[0] && emaF[1]>=emaS[1];

   // 3. RSI
   bool rsiBull = rsi[0] < RSI_Buy;
   bool rsiBear = rsi[0] > RSI_Sell;

   // 4. Stochastic croisement en zone extrême
   bool stochUp   = sk[0]>sd[0] && sk[1]<=sd[1] && sk[0]<Stoch_Buy;
   bool stochDown = sk[0]<sd[0] && sk[1]>=sd[1] && sk[0]>Stoch_Sell;

   // 5. Prix à l'extrême des Bollinger Bands
   double bbRange = bbU[0] - bbL[0];
   bool atLowBB   = bbRange>0.0 && (ask-bbL[0])/bbRange < (1.0-BB_EntryPct);
   bool atHighBB  = bbRange>0.0 && (bbU[0]-bid)/bbRange < (1.0-BB_EntryPct);

   int buyLvl  = CountDir(POSITION_TYPE_BUY);
   int sellLvl = CountDir(POSITION_TYPE_SELL);

   //─── Ouverture premier niveau ─────────────────────────────────
   bool canBuy  = h1Bull && (crossUp||stochUp)   && rsiBull && atLowBB  && buyLvl==0 && sellLvl==0;
   bool canSell = h1Bear && (crossDown||stochDown)&& rsiBear && atHighBB && sellLvl==0 && buyLvl==0;

   if(canBuy)
     {
      if(OpenPos(ORDER_TYPE_BUY, CalcLot(0)))
        { g_gridBuy=true; g_gridSell=false; g_gridBase=ask; }
     }
   else if(canSell)
     {
      if(OpenPos(ORDER_TYPE_SELL, CalcLot(0)))
        { g_gridSell=true; g_gridBuy=false; g_gridBase=bid; }
     }

   //─── Niveaux de grille supplémentaires ────────────────────────
   if(g_gridBuy && buyLvl>0 && buyLvl<MaxGridLevels)
     {
      double lp = LastOpenPrice(POSITION_TYPE_BUY);
      if(lp>0.0 && (lp-ask)>=gridStep) OpenPos(ORDER_TYPE_BUY, CalcLot(buyLvl));
     }
   if(g_gridSell && sellLvl>0 && sellLvl<MaxGridLevels)
     {
      double lp = LastOpenPrice(POSITION_TYPE_SELL);
      if(lp>0.0 && (bid-lp)>=gridStep) OpenPos(ORDER_TYPE_SELL, CalcLot(sellLvl));
     }

   if(Dashboard) ShowPanel(equity,balance,ddPct);
  }

//══════════════════════════════════════════════════════════════════
//  SORTIE TEMPORELLE — ferme toute la grille si une position
//  dépasse MaxMinutesOpen (évite les positions dormantes)
//══════════════════════════════════════════════════════════════════
void ManageTimeExit()
  {
   datetime now = TimeCurrent();
   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol()!=_Symbol || pos.Magic()!=MagicNumber) continue;

      int ageMinutes = (int)((now - pos.Time()) / 60);
      if(ageMinutes >= MaxMinutesOpen)
        {
         //--- Ferme TOUTE la grille si une position expire
         CloseAll(StringFormat("TIMEOUT %d min", ageMinutes));
         return;
        }
     }
  }

//══════════════════════════════════════════════════════════════════
//  BREAKEVEN — déplace le SL au prix d'entrée + buffer
//  dès que le profit dépasse BE_Trigger_USD
//══════════════════════════════════════════════════════════════════
void ManageBreakeven()
  {
   if(!UseBreakeven) return;
   double bufPts = BE_Buffer_USD / g_pt;

   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol()!=_Symbol || pos.Magic()!=MagicNumber) continue;

      double open    = pos.PriceOpen();
      double sl      = pos.StopLoss();
      double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double profit  = pos.Profit();

      if(pos.PositionType() == POSITION_TYPE_BUY)
        {
         double beSL = NormalizeDouble(open + bufPts * g_pt, g_digits);
         // Breakeven seulement si pas encore au BE et profit suffisant
         if(profit >= BE_Trigger_USD && (sl < beSL))
            trade.PositionModify(pos.Ticket(), beSL, pos.TakeProfit());
        }
      else
        {
         double beSL = NormalizeDouble(open - bufPts * g_pt, g_digits);
         if(profit >= BE_Trigger_USD && (sl == 0.0 || sl > beSL))
            trade.PositionModify(pos.Ticket(), beSL, pos.TakeProfit());
        }
     }
  }

//══════════════════════════════════════════════════════════════════
//  SORTIE SUR SIGNAL INVERSE — ferme la grille si EMA recroise
//  contre la direction ouverte (signal d'épuisement du mouvement)
//══════════════════════════════════════════════════════════════════
void ManageSignalExit()
  {
   if(CountAll() == 0) return;

   double emaF[2], emaS[2];
   if(CopyBuffer(h_emaFast, 0, 1, 2, emaF) < 2) return;
   if(CopyBuffer(h_emaSlow, 0, 1, 2, emaS) < 2) return;

   bool crossDown = emaF[0] < emaS[0] && emaF[1] >= emaS[1];
   bool crossUp   = emaF[0] > emaS[0] && emaF[1] <= emaS[1];

   if(g_gridBuy  && crossDown) CloseAll("SIGNAL INVERSE (cross down)");
   if(g_gridSell && crossUp)   CloseAll("SIGNAL INVERSE (cross up)");
  }

//══════════════════════════════════════════════════════════════════
//  TRAILING SERRÉ
//══════════════════════════════════════════════════════════════════
void ManageTrailing()
  {
   if(!UseTrailing) return;
   double startPts = Trail_Start_USD / g_pt;
   double stepPts  = Trail_Step_USD  / g_pt;

   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol()!=_Symbol || pos.Magic()!=MagicNumber) continue;

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

//══════════════════════════════════════════════════════════════════
//  TP PANIER — ferme tout quand le profit cumulé atteint BasketTP
//══════════════════════════════════════════════════════════════════
void CheckBasketTP()
  {
   if(CountAll() == 0) return;
   double avgOpen = AvgOpenPrice();
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   bool buyTP  = g_gridBuy  && (bid - avgOpen) >= BasketTP_USD;
   bool sellTP = g_gridSell && (avgOpen - ask)  >= BasketTP_USD;
   if(buyTP || sellTP) CloseAll("BASKET TP");
  }

//──────────────────────────────────────────────────────────────────
bool OpenPos(ENUM_ORDER_TYPE type, double lot)
  {
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double tpPts = TP_USD / g_pt;
   double slPts = SL_USD / g_pt;

   if(type == ORDER_TYPE_BUY)
     {
      double tp = NormalizeDouble(ask + tpPts * g_pt, g_digits);
      double sl = NormalizeDouble(ask - slPts * g_pt, g_digits);
      if(trade.Buy(lot, _Symbol, ask, sl, tp)) { g_trades++; return true; }
      Print("BUY echec: ", trade.ResultRetcodeDescription());
     }
   else
     {
      double tp = NormalizeDouble(bid - tpPts * g_pt, g_digits);
      double sl = NormalizeDouble(bid + slPts * g_pt, g_digits);
      if(trade.Sell(lot, _Symbol, bid, sl, tp)) { g_trades++; return true; }
      Print("SELL echec: ", trade.ResultRetcodeDescription());
     }
   return false;
  }

//──────────────────────────────────────────────────────────────────
double CalcLot(int level)
  {
   double lot = LotBase;
   if(UseAntiMart) for(int i=0;i<level;i++) lot=MathMax(lot/LotMultiplier,0.001);
   else            for(int i=0;i<level;i++) lot*=LotMultiplier;

   double minL=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxL=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double stp =SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   lot = MathMax(lot,minL); lot = MathMin(lot,maxL);
   lot = MathFloor(lot/stp)*stp;
   return NormalizeDouble(lot,2);
  }

void CloseAll(string reason)
  {
   Print("[GOLD EA] Fermeture: ", reason);
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(pos.SelectByIndex(i) && pos.Symbol()==_Symbol && pos.Magic()==MagicNumber)
         trade.PositionClose(pos.Ticket());
   g_gridBuy=false; g_gridSell=false; g_gridBase=0.0;
  }

int CountDir(ENUM_POSITION_TYPE t)
  {
   int c=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(pos.SelectByIndex(i) && pos.Symbol()==_Symbol &&
         pos.Magic()==MagicNumber && pos.PositionType()==t) c++;
   return c;
  }

int CountAll()
  {
   int c=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(pos.SelectByIndex(i) && pos.Symbol()==_Symbol && pos.Magic()==MagicNumber) c++;
   return c;
  }

double LastOpenPrice(ENUM_POSITION_TYPE t)
  {
   double p=0.0; datetime ts=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(pos.SelectByIndex(i) && pos.Symbol()==_Symbol &&
         pos.Magic()==MagicNumber && pos.PositionType()==t && pos.Time()>=ts)
        { ts=pos.Time(); p=pos.PriceOpen(); }
   return p;
  }

double AvgOpenPrice()
  {
   double w=0.0,v=0.0;
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(pos.SelectByIndex(i) && pos.Symbol()==_Symbol && pos.Magic()==MagicNumber)
        { w+=pos.PriceOpen()*pos.Volume(); v+=pos.Volume(); }
   return (v>0.0)?w/v:0.0;
  }

bool InSession()
  {
   MqlDateTime dt; TimeToStruct(TimeGMT(),dt); int h=dt.hour;
   return (TradeAsia&&h>=Asia_Open&&h<Asia_Close)
       || (h>=London_Open&&h<London_Close)
       || (h>=NY_Open&&h<NY_Close);
  }

//──────────────────────────────────────────────────────────────────
void ShowPanel(double eq, double bal, double dd)
  {
   // Calcul âge de la position la plus vieille
   datetime now = TimeCurrent();
   int oldestMin = 0;
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(pos.SelectByIndex(i) && pos.Symbol()==_Symbol && pos.Magic()==MagicNumber)
        { int age=(int)((now-pos.Time())/60); if(age>oldestMin) oldestMin=age; }

   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   double pnl = eq - bal;
   string buyStatus  = g_gridBuy  ? StringFormat("BUY  x%d / %d", CountDir(POSITION_TYPE_BUY),  MaxGridLevels) : "---";
   string sellStatus = g_gridSell ? StringFormat("SELL x%d / %d", CountDir(POSITION_TYPE_SELL), MaxGridLevels) : "---";

   string s="";
   s+="══════════════════════════════════\n";
   s+="   GOLD GRID SCALPER v4.0\n";
   s+="══════════════════════════════════\n";
   s+=StringFormat("  Balance  : %8.2f %s\n", bal, cur);
   s+=StringFormat("  Equity   : %8.2f %s\n", eq,  cur);
   s+=StringFormat("  P&L open : %s%.2f %s\n", pnl>=0?"+":"", pnl, cur);
   s+=StringFormat("  Drawdown : %.2f%%  (max %.2f%%)\n", dd, g_maxDD);
   s+="──────────────────────────────────\n";
   s+=StringFormat("  Grille   : %s\n", buyStatus);
   s+=StringFormat("  Grille   : %s\n", sellStatus);
   s+=StringFormat("  Age pos  : %d min / %d min max\n", oldestMin, MaxMinutesOpen);
   s+=StringFormat("  Basket TP: $%.2f\n", BasketTP_USD);
   s+="──────────────────────────────────\n";
   s+=StringFormat("  Trades   : %d  gains: %d\n", g_trades, g_wins);
   s+=StringFormat("  Session  : %s\n", InSession()?"ACTIVE":"FERMEE");
   s+=StringFormat("  Spread   : $%.2f\n",(double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)*g_pt);
   s+="══════════════════════════════════";
   Comment(s);
  }

//──────────────────────────────────────────────────────────────────
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &req,
                        const MqlTradeResult  &res)
  {
   if(trans.type==TRADE_TRANSACTION_DEAL_ADD && HistoryDealSelect(trans.deal))
     {
      double p=HistoryDealGetDouble(trans.deal,DEAL_PROFIT);
      if(p!=0.0){ g_profit+=p; if(p>0.0) g_wins++; }
     }
  }
//──────────────────────────────────────────────────────────────────
