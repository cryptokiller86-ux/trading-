//+------------------------------------------------------------------+
//|  GoldMicroScalper.mq5  — XAUUSD M1  v6.0                        |
//|  Scalping agressif micro-profits en rafale                       |
//|  Timeframe conseillé : M1                                        |
//+------------------------------------------------------------------+
#property copyright "GoldMicroScalper v6"
#property version   "6.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
CTrade trade;
CPositionInfo pos;

//──────────────────────────────────────────────────────────────────
input group "=== SIGNAL ==="
input int    EMA_Fast        = 5;      // EMA rapide (M1)
input int    EMA_Slow        = 13;     // EMA lente  (M1)
input int    RSI_Period      = 7;      // RSI court = réactif
input double RSI_Buy         = 48.0;   // RSI > X → autoriser BUY
input double RSI_Sell        = 52.0;   // RSI < X → autoriser SELL

input group "=== TRADES ==="
input int    TradesParSignal = 2;      // Trades ouverts simultanément
input double Lot             = 0.01;   // Taille lot fixe

input group "=== SORTIES ==="
input double TP_Dollar       = 1.50;   // TP par trade ($)
input double SL_Dollar       = 4.50;   // SL par trade ($) — ratio 1:3
input double BasketTP_Dollar = 4.00;   // Ferme tout si profit cumulé ($)
input double BasketSL_Dollar = 10.0;   // Ferme tout si perte cumulée ($)
input int    MaxMinutes      = 15;     // Timeout max par trade (min)
input double BETrigger       = 0.80;   // Breakeven dès ($) profit

input group "=== FILTRE ==="
input double MaxSpread       = 2.00;   // Spread max autorisé ($)
input double MaxDD           = 20.0;   // Drawdown max compte (%)
input int    EOD_Hour        = 22;     // Fermeture fin de journée UTC
input int    MagicNumber     = 66601;

input group "=== AFFICHAGE ==="
input bool   ShowLogs        = true;   // Logs dans Journal MT5

//──────────────────────────────────────────────────────────────────
double   g_pt;
int      g_digits;
int      h_fast, h_slow, h_rsi;
double   g_peak  = 0;
double   g_maxDD = 0;
int      g_trades = 0;
int      g_wins   = 0;
datetime g_lastBar = 0;
bool     g_hasBuy  = false;
bool     g_hasSell = false;

//──────────────────────────────────────────────────────────────────
int OnInit()
  {
   if(StringFind(_Symbol,"XAU")<0 && StringFind(_Symbol,"GOLD")<0)
     { Alert("Attacher sur XAUUSD uniquement !"); return INIT_FAILED; }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   g_pt     = _Point;
   g_digits = _Digits;

   h_fast = iMA(_Symbol, PERIOD_M1, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   h_slow = iMA(_Symbol, PERIOD_M1, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   h_rsi  = iRSI(_Symbol, PERIOD_M1, RSI_Period, PRICE_CLOSE);

   if(h_fast==INVALID_HANDLE || h_slow==INVALID_HANDLE || h_rsi==INVALID_HANDLE)
     { Print("ERREUR handles indicateurs"); return INIT_FAILED; }

   g_peak = AccountInfoDouble(ACCOUNT_BALANCE);
   Print("=== GoldMicroScalper v6 démarré | ",_Symbol," | Balance: ",g_peak," ===");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int r)
  {
   IndicatorRelease(h_fast);
   IndicatorRelease(h_slow);
   IndicatorRelease(h_rsi);
   Comment("");
  }

//──────────────────────────────────────────────────────────────────
void OnTick()
  {
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(eq > g_peak) g_peak = eq;
   double dd = (g_peak > 0) ? (g_peak - eq) / g_peak * 100.0 : 0;
   if(dd > g_maxDD) g_maxDD = dd;

   //--- Protection drawdown global
   if(dd >= MaxDD) { CloseAll("DRAWDOWN MAX"); return; }

   //--- Fermeture fin de journée
   MqlDateTime dt; TimeToStruct(TimeGMT(), dt);
   if(dt.hour >= EOD_Hour) { if(NbOpen()>0) CloseAll("FIN JOURNEE"); return; }

   //--- Gestion des positions ouvertes (chaque tick)
   DoBreakeven();
   DoTimeout();
   DoBasketClose();

   //--- Signaux : une fois par nouvelle bougie M1
   datetime bar = iTime(_Symbol, PERIOD_M1, 0);
   if(bar == g_lastBar) { Afficher(eq, bal, dd); return; }
   g_lastBar = bar;

   //--- Filtre spread
   double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * g_pt;
   if(spread > MaxSpread)
     { Log("Spread bloquant: $"+DoubleToString(spread,2)); return; }

   //--- Indicateurs sur bougie fermée [1]
   double fast[2], slow[2], rsi[2];
   if(CopyBuffer(h_fast, 0, 1, 2, fast) < 2) return;
   if(CopyBuffer(h_slow, 0, 1, 2, slow) < 2) return;
   if(CopyBuffer(h_rsi,  0, 1, 2, rsi)  < 2) return;

   bool emaBull = fast[0] > slow[0];
   bool emaBear = fast[0] < slow[0];
   bool rsiBull = rsi[0]  > RSI_Buy;
   bool rsiBear = rsi[0]  < RSI_Sell;

   int nBuy  = NbDir(POSITION_TYPE_BUY);
   int nSell = NbDir(POSITION_TYPE_SELL);

   Log(StringFormat("M1 | EMA:%s RSI:%.1f | BUY:%d SELL:%d | Spread:$%.2f",
       emaBull?"↑":"↓", rsi[0], nBuy, nSell, spread));

   //--- ENTREE BUY : EMA haussier + RSI confirmé + pas déjà de BUY
   if(emaBull && rsiBull && nBuy == 0)
     {
      int opened = 0;
      for(int k = 0; k < TradesParSignal; k++)
         if(DoBuy()) opened++;
      if(opened > 0) { g_hasBuy = true; Log(">> "+IntegerToString(opened)+" BUY ouverts"); }
     }

   //--- ENTREE SELL : EMA baissier + RSI confirmé + pas déjà de SELL
   if(emaBear && rsiBear && nSell == 0)
     {
      int opened = 0;
      for(int k = 0; k < TradesParSignal; k++)
         if(DoSell()) opened++;
      if(opened > 0) { g_hasSell = true; Log(">> "+IntegerToString(opened)+" SELL ouverts"); }
     }

   Afficher(eq, bal, dd);
  }

//══════════════════════════════════════════════════════════════════
//  BREAKEVEN — verrouille dès BETrigger $ de profit
//══════════════════════════════════════════════════════════════════
void DoBreakeven()
  {
   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol()!=_Symbol || pos.Magic()!=MagicNumber) continue;
      if(pos.Profit() < BETrigger) continue;

      double open = pos.PriceOpen();
      double sl   = pos.StopLoss();

      if(pos.PositionType() == POSITION_TYPE_BUY)
        {
         double beSL = NormalizeDouble(open + 5*g_pt, g_digits);  // +$0.05 au-dessus entrée
         if(sl < beSL) trade.PositionModify(pos.Ticket(), beSL, pos.TakeProfit());
        }
      else
        {
         double beSL = NormalizeDouble(open - 5*g_pt, g_digits);
         if(sl == 0 || sl > beSL) trade.PositionModify(pos.Ticket(), beSL, pos.TakeProfit());
        }
     }
  }

//══════════════════════════════════════════════════════════════════
//  TIMEOUT — ferme par direction si trop vieux
//══════════════════════════════════════════════════════════════════
void DoTimeout()
  {
   datetime now = TimeCurrent();
   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol()!=_Symbol || pos.Magic()!=MagicNumber) continue;
      int age = (int)((now - pos.Time()) / 60);
      if(age >= MaxMinutes)
        {
         ENUM_POSITION_TYPE t = pos.PositionType();
         CloseDir(t, StringFormat("TIMEOUT %dmin", age));
         return;
        }
     }
  }

//══════════════════════════════════════════════════════════════════
//  BASKET CLOSE — ferme une direction si profit ou perte atteint
//══════════════════════════════════════════════════════════════════
void DoBasketClose()
  {
   if(NbOpen() == 0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // BUY basket
   if(g_hasBuy && NbDir(POSITION_TYPE_BUY) > 0)
     {
      double avg = AvgDir(POSITION_TYPE_BUY);
      double profit = ProfitDir(POSITION_TYPE_BUY);
      if(profit >= BasketTP_Dollar)
         CloseDir(POSITION_TYPE_BUY, StringFormat("BASKET TP BUY +$%.2f", profit));
      else if(profit <= -BasketSL_Dollar)
         CloseDir(POSITION_TYPE_BUY, StringFormat("BASKET SL BUY -$%.2f", MathAbs(profit)));
     }

   // SELL basket
   if(g_hasSell && NbDir(POSITION_TYPE_SELL) > 0)
     {
      double profit = ProfitDir(POSITION_TYPE_SELL);
      if(profit >= BasketTP_Dollar)
         CloseDir(POSITION_TYPE_SELL, StringFormat("BASKET TP SELL +$%.2f", profit));
      else if(profit <= -BasketSL_Dollar)
         CloseDir(POSITION_TYPE_SELL, StringFormat("BASKET SL SELL -$%.2f", MathAbs(profit)));
     }
  }

//══════════════════════════════════════════════════════════════════
//  OUVERTURE ORDRES
//══════════════════════════════════════════════════════════════════
bool DoBuy()
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double tp  = NormalizeDouble(ask + TP_Dollar, g_digits);
   double sl  = NormalizeDouble(ask - SL_Dollar, g_digits);
   if(trade.Buy(Lot, _Symbol, ask, sl, tp))
     { g_trades++; Log("✓ BUY @"+DoubleToString(ask,g_digits)+" TP:"+DoubleToString(tp,g_digits)); return true; }
   Log("✗ BUY echec: "+trade.ResultRetcodeDescription());
   return false;
  }

bool DoSell()
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double tp  = NormalizeDouble(bid - TP_Dollar, g_digits);
   double sl  = NormalizeDouble(bid + SL_Dollar, g_digits);
   if(trade.Sell(Lot, _Symbol, bid, sl, tp))
     { g_trades++; Log("✓ SELL @"+DoubleToString(bid,g_digits)+" TP:"+DoubleToString(tp,g_digits)); return true; }
   Log("✗ SELL echec: "+trade.ResultRetcodeDescription());
   return false;
  }

//══════════════════════════════════════════════════════════════════
//  UTILITAIRES
//══════════════════════════════════════════════════════════════════
void CloseAll(string why)
  {
   Print("[EA] CloseAll: ", why);
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(pos.SelectByIndex(i) && pos.Symbol()==_Symbol && pos.Magic()==MagicNumber)
         trade.PositionClose(pos.Ticket());
   g_hasBuy = false; g_hasSell = false;
  }

void CloseDir(ENUM_POSITION_TYPE t, string why)
  {
   Print("[EA] ", why);
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(pos.SelectByIndex(i) && pos.Symbol()==_Symbol &&
         pos.Magic()==MagicNumber && pos.PositionType()==t)
         trade.PositionClose(pos.Ticket());
   if(t == POSITION_TYPE_BUY)  g_hasBuy  = false;
   if(t == POSITION_TYPE_SELL) g_hasSell = false;
  }

int NbDir(ENUM_POSITION_TYPE t)
  {
   int c = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(pos.SelectByIndex(i) && pos.Symbol()==_Symbol &&
         pos.Magic()==MagicNumber && pos.PositionType()==t) c++;
   return c;
  }

int NbOpen()
  {
   int c = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(pos.SelectByIndex(i) && pos.Symbol()==_Symbol && pos.Magic()==MagicNumber) c++;
   return c;
  }

double AvgDir(ENUM_POSITION_TYPE t)
  {
   double w = 0, v = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(pos.SelectByIndex(i) && pos.Symbol()==_Symbol &&
         pos.Magic()==MagicNumber && pos.PositionType()==t)
        { w += pos.PriceOpen() * pos.Volume(); v += pos.Volume(); }
   return v > 0 ? w/v : 0;
  }

double ProfitDir(ENUM_POSITION_TYPE t)
  {
   double total = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(pos.SelectByIndex(i) && pos.Symbol()==_Symbol &&
         pos.Magic()==MagicNumber && pos.PositionType()==t)
         total += pos.Profit() + pos.Swap() + pos.Commission();
   return total;
  }

void Log(string msg)
  { if(ShowLogs) Print(msg); }

//══════════════════════════════════════════════════════════════════
//  PANNEAU
//══════════════════════════════════════════════════════════════════
void Afficher(double eq, double bal, double dd)
  {
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   double pnl = eq - bal;
   double sp  = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * g_pt;

   datetime now = TimeCurrent(); int oldest = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(pos.SelectByIndex(i) && pos.Symbol()==_Symbol && pos.Magic()==MagicNumber)
        { int a = (int)((now-pos.Time())/60); if(a>oldest) oldest=a; }

   double profBuy  = ProfitDir(POSITION_TYPE_BUY);
   double profSell = ProfitDir(POSITION_TYPE_SELL);

   string s = "";
   s += "════════════════════════════\n";
   s += "  GOLD MICRO SCALPER v6.0\n";
   s += "════════════════════════════\n";
   s += StringFormat(" Balance  : %.2f %s\n", bal, cur);
   s += StringFormat(" Equity   : %.2f %s\n", eq,  cur);
   s += StringFormat(" P&L open : %s%.2f %s\n", pnl>=0?"+":"", pnl, cur);
   s += StringFormat(" Drawdown : %.2f%% (max %.2f%%)\n", dd, g_maxDD);
   s += "────────────────────────────\n";
   s += StringFormat(" BUY  : x%d  P&L: %s%.2f$\n",
        NbDir(POSITION_TYPE_BUY),  profBuy>=0?"+":"",  profBuy);
   s += StringFormat(" SELL : x%d  P&L: %s%.2f$\n",
        NbDir(POSITION_TYPE_SELL), profSell>=0?"+":"", profSell);
   s += StringFormat(" Age pos  : %d / %d min\n", oldest, MaxMinutes);
   s += "────────────────────────────\n";
   s += StringFormat(" Trades   : %d  gains: %d\n", g_trades, g_wins);
   s += StringFormat(" Spread   : $%.2f / max $%.2f\n", sp, MaxSpread);
   s += "════════════════════════════";
   Comment(s);
  }

//──────────────────────────────────────────────────────────────────
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &req,
                        const MqlTradeResult  &res)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD && HistoryDealSelect(trans.deal))
     {
      double p = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
      if(p > 0) g_wins++;
     }
  }
//──────────────────────────────────────────────────────────────────
