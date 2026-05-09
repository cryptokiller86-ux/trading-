//+------------------------------------------------------------------+
//|  BTCMicroScalper.mq5  — BTCUSD M1  v1.0                         |
//|  Scalping agressif micro-profits en rafale sur Bitcoin           |
//|  Timeframe : M1                                                  |
//+------------------------------------------------------------------+
#property copyright "BTCMicroScalper v1"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
CTrade trade;
CPositionInfo pos;

//──────────────────────────────────────────────────────────────────
input group "=== SIGNAL ==="
input int    EMA_Fast        = 5;      // EMA rapide M1
input int    EMA_Slow        = 13;     // EMA lente  M1
input int    RSI_Period      = 7;      // RSI court = réactif
input double RSI_Buy         = 48.0;   // RSI > X → BUY
input double RSI_Sell        = 52.0;   // RSI < X → SELL

input group "=== TRADES ==="
input int    TradesParSignal = 2;      // Trades simultanés au signal
input double Lot             = 0.01;   // Lot (0.01 BTC standard mini)

input group "=== SORTIES (en $) ==="
input double TP_Dollar       = 15.0;   // TP par trade ($)
input double SL_Dollar       = 45.0;   // SL par trade ($) — ratio 1:3
input double BasketTP_Dollar = 35.0;   // Ferme tout si profit dir ($)
input double BasketSL_Dollar = 80.0;   // Ferme tout si perte dir ($)
input int    MaxMinutes      = 20;     // Timeout max (min)
input double BETrigger       = 8.0;    // Breakeven dès ($) profit

input group "=== FILTRE ==="
input double MaxSpread       = 25.0;   // Spread max autorisé ($)
input double MaxDD           = 20.0;   // Drawdown max (%)
input int    EOD_Hour        = 23;     // BTC 24/7 — ferme le dimanche soir
input int    MagicNumber     = 77701;

input group "=== AFFICHAGE ==="
input bool   ShowLogs        = true;

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
   string s = _Symbol;
   if(StringFind(s,"BTC")<0 && StringFind(s,"XBT")<0 && StringFind(s,"Bitcoin")<0)
     { Alert("Attacher sur BTCUSD uniquement ! Symbole: "+s); return INIT_FAILED; }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(100); // BTC slippage plus large
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   g_pt     = _Point;
   g_digits = _Digits;

   h_fast = iMA(_Symbol, PERIOD_M1, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   h_slow = iMA(_Symbol, PERIOD_M1, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   h_rsi  = iRSI(_Symbol, PERIOD_M1, RSI_Period, PRICE_CLOSE);

   if(h_fast==INVALID_HANDLE || h_slow==INVALID_HANDLE || h_rsi==INVALID_HANDLE)
     { Print("ERREUR handles indicateurs"); return INIT_FAILED; }

   g_peak = AccountInfoDouble(ACCOUNT_BALANCE);
   Print("=== BTCMicroScalper v1 | ",_Symbol," | Balance: ",g_peak," ===");
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

   if(dd >= MaxDD) { CloseAll("DRAWDOWN MAX"); return; }

   // BTC 24/7 — on ferme seulement le dimanche 22h UTC (faible liquidité)
   MqlDateTime dt; TimeToStruct(TimeGMT(), dt);
   if(dt.day_of_week == 0 && dt.hour >= EOD_Hour)
     { if(NbOpen()>0) CloseAll("DIMANCHE SOIR"); return; }

   DoBreakeven();
   DoTimeout();
   DoBasketClose();

   datetime bar = iTime(_Symbol, PERIOD_M1, 0);
   if(bar == g_lastBar) { Afficher(eq, bal, dd); return; }
   g_lastBar = bar;

   // Spread BTC en dollars
   double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * g_pt;
   if(spread > MaxSpread)
     { Log("Spread bloquant: $"+DoubleToString(spread,2)); return; }

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

   Log(StringFormat("BTC M1 | EMA:%s RSI:%.1f | BUY:%d SELL:%d | Spread:$%.1f",
       emaBull?"↑":"↓", rsi[0], nBuy, nSell, spread));

   if(emaBull && rsiBull && nBuy == 0)
     {
      int ok = 0;
      for(int k=0; k<TradesParSignal; k++) if(DoBuy()) ok++;
      if(ok > 0) { g_hasBuy = true; Log(">> "+IntegerToString(ok)+" BUY ouverts"); }
     }

   if(emaBear && rsiBear && nSell == 0)
     {
      int ok = 0;
      for(int k=0; k<TradesParSignal; k++) if(DoSell()) ok++;
      if(ok > 0) { g_hasSell = true; Log(">> "+IntegerToString(ok)+" SELL ouverts"); }
     }

   Afficher(eq, bal, dd);
  }

//──────────────────────────────────────────────────────────────────
void DoBreakeven()
  {
   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol()!=_Symbol || pos.Magic()!=MagicNumber) continue;
      if(pos.Profit() < BETrigger) continue;
      double open = pos.PriceOpen(), sl = pos.StopLoss();
      if(pos.PositionType()==POSITION_TYPE_BUY)
        { double beSL=NormalizeDouble(open+g_pt,g_digits);
          if(sl<beSL) trade.PositionModify(pos.Ticket(),beSL,pos.TakeProfit()); }
      else
        { double beSL=NormalizeDouble(open-g_pt,g_digits);
          if(sl==0||sl>beSL) trade.PositionModify(pos.Ticket(),beSL,pos.TakeProfit()); }
     }
  }

void DoTimeout()
  {
   datetime now = TimeCurrent();
   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol()!=_Symbol || pos.Magic()!=MagicNumber) continue;
      int age = (int)((now - pos.Time()) / 60);
      if(age >= MaxMinutes)
        { ENUM_POSITION_TYPE t = pos.PositionType();
          CloseDir(t, StringFormat("TIMEOUT %dmin", age)); return; }
     }
  }

void DoBasketClose()
  {
   if(NbOpen()==0) return;
   if(g_hasBuy && NbDir(POSITION_TYPE_BUY)>0)
     {
      double p = ProfitDir(POSITION_TYPE_BUY);
      if(p >= BasketTP_Dollar)       CloseDir(POSITION_TYPE_BUY,  StringFormat("BASKET TP BUY +$%.2f",p));
      else if(p <= -BasketSL_Dollar) CloseDir(POSITION_TYPE_BUY,  StringFormat("BASKET SL BUY -$%.2f",MathAbs(p)));
     }
   if(g_hasSell && NbDir(POSITION_TYPE_SELL)>0)
     {
      double p = ProfitDir(POSITION_TYPE_SELL);
      if(p >= BasketTP_Dollar)       CloseDir(POSITION_TYPE_SELL, StringFormat("BASKET TP SELL +$%.2f",p));
      else if(p <= -BasketSL_Dollar) CloseDir(POSITION_TYPE_SELL, StringFormat("BASKET SL SELL -$%.2f",MathAbs(p)));
     }
  }

//──────────────────────────────────────────────────────────────────
bool DoBuy()
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double tp  = NormalizeDouble(ask + TP_Dollar, g_digits);
   double sl  = NormalizeDouble(ask - SL_Dollar, g_digits);
   if(trade.Buy(Lot, _Symbol, ask, sl, tp))
     { g_trades++; Log("✓ BUY @"+DoubleToString(ask,g_digits)); return true; }
   Log("✗ BUY echec: "+trade.ResultRetcodeDescription());
   return false;
  }

bool DoSell()
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double tp  = NormalizeDouble(bid - TP_Dollar, g_digits);
   double sl  = NormalizeDouble(bid + SL_Dollar, g_digits);
   if(trade.Sell(Lot, _Symbol, bid, sl, tp))
     { g_trades++; Log("✓ SELL @"+DoubleToString(bid,g_digits)); return true; }
   Log("✗ SELL echec: "+trade.ResultRetcodeDescription());
   return false;
  }

//──────────────────────────────────────────────────────────────────
void CloseAll(string why)
  {
   Print("[EA] CloseAll: ",why);
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(pos.SelectByIndex(i)&&pos.Symbol()==_Symbol&&pos.Magic()==MagicNumber)
         trade.PositionClose(pos.Ticket());
   g_hasBuy=false; g_hasSell=false;
  }

void CloseDir(ENUM_POSITION_TYPE t, string why)
  {
   Print("[EA] ",why);
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(pos.SelectByIndex(i)&&pos.Symbol()==_Symbol&&pos.Magic()==MagicNumber&&pos.PositionType()==t)
         trade.PositionClose(pos.Ticket());
   if(t==POSITION_TYPE_BUY) g_hasBuy=false; else g_hasSell=false;
  }

int NbDir(ENUM_POSITION_TYPE t)
  { int c=0; for(int i=PositionsTotal()-1;i>=0;i--)
      if(pos.SelectByIndex(i)&&pos.Symbol()==_Symbol&&pos.Magic()==MagicNumber&&pos.PositionType()==t) c++;
    return c; }

int NbOpen()
  { int c=0; for(int i=PositionsTotal()-1;i>=0;i--)
      if(pos.SelectByIndex(i)&&pos.Symbol()==_Symbol&&pos.Magic()==MagicNumber) c++;
    return c; }

double ProfitDir(ENUM_POSITION_TYPE t)
  { double p=0;
    for(int i=PositionsTotal()-1;i>=0;i--)
      if(pos.SelectByIndex(i)&&pos.Symbol()==_Symbol&&pos.Magic()==MagicNumber&&pos.PositionType()==t)
         p+=pos.Profit()+pos.Swap()+pos.Commission();
    return p; }

void Log(string msg) { if(ShowLogs) Print(msg); }

//──────────────────────────────────────────────────────────────────
void Afficher(double eq, double bal, double dd)
  {
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   double pnl = eq - bal;
   double sp  = (double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)*g_pt;
   datetime now=TimeCurrent(); int oldest=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(pos.SelectByIndex(i)&&pos.Symbol()==_Symbol&&pos.Magic()==MagicNumber)
        { int a=(int)((now-pos.Time())/60); if(a>oldest)oldest=a; }

   string s="";
   s+="══════════════════════════════\n";
   s+="   BTC MICRO SCALPER  v1.0\n";
   s+="══════════════════════════════\n";
   s+=StringFormat(" Balance  : %.2f %s\n",bal,cur);
   s+=StringFormat(" Equity   : %.2f %s\n",eq,cur);
   s+=StringFormat(" P&L open : %s%.2f %s\n",pnl>=0?"+":"",pnl,cur);
   s+=StringFormat(" Drawdown : %.2f%% (max %.2f%%)\n",dd,g_maxDD);
   s+="──────────────────────────────\n";
   s+=StringFormat(" BUY  : x%d  P&L: %s%.2f$\n",
      NbDir(POSITION_TYPE_BUY),ProfitDir(POSITION_TYPE_BUY)>=0?"+":"",ProfitDir(POSITION_TYPE_BUY));
   s+=StringFormat(" SELL : x%d  P&L: %s%.2f$\n",
      NbDir(POSITION_TYPE_SELL),ProfitDir(POSITION_TYPE_SELL)>=0?"+":"",ProfitDir(POSITION_TYPE_SELL));
   s+=StringFormat(" Age pos  : %d / %d min\n",oldest,MaxMinutes);
   s+="──────────────────────────────\n";
   s+=StringFormat(" Trades   : %d  gains: %d\n",g_trades,g_wins);
   s+=StringFormat(" Spread   : $%.1f / max $%.1f\n",sp,MaxSpread);
   s+="══════════════════════════════";
   Comment(s);
  }

void OnTradeTransaction(const MqlTradeTransaction &t,
                        const MqlTradeRequest &r, const MqlTradeResult &res)
  { if(t.type==TRADE_TRANSACTION_DEAL_ADD&&HistoryDealSelect(t.deal))
      { double p=HistoryDealGetDouble(t.deal,DEAL_PROFIT); if(p>0) g_wins++; } }
//──────────────────────────────────────────────────────────────────
