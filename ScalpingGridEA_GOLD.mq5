//+------------------------------------------------------------------+
//|  GoldGridScalper.mq5  — XAUUSD M5  v5.0                         |
//|  Logique simple : EMA + RSI → Grid → sortie rapide              |
//+------------------------------------------------------------------+
#property copyright "GoldGridScalper v5"
#property version   "5.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
CTrade trade; CPositionInfo pos;

//──────────────────────────────────────────────────────────────────
input group "=== SIGNAL ==="
input int    EMA_Fast     = 9;     // EMA rapide
input int    EMA_Slow     = 21;    // EMA lente
input int    RSI_Period   = 14;    // RSI
input double RSI_Buy      = 55.0;  // RSI > seuil = BUY
input double RSI_Sell     = 45.0;  // RSI < seuil = SELL

input group "=== GRID ==="
input int    TradesParSignal = 3;   // Nb trades ouverts d'un coup au signal
input double GridStep     = 2.0;   // Ecart entre niveaux ($)
input int    MaxLevels    = 4;     // Max niveaux grille
input double Lot          = 0.01;  // Lot de base
input double LotMult      = 1.3;   // Multiplicateur par niveau

input group "=== SORTIES ==="
input double TP           = 2.0;   // TP par position ($)
input double SL           = 8.0;   // SL urgence ($)
input double BasketTP     = 5.0;   // Ferme tout quand profit total ($)
input int    MaxMinutes   = 25;    // Timeout (ferme si > X min)
input double BETrigger    = 1.0;   // Breakeven après ($) profit

input group "=== FILTRE ==="
input double MaxSpread    = 1.50;  // Spread max ($)
input double MaxDD        = 15.0;  // Drawdown max (%)
input int    EOD_Hour     = 21;    // Fermeture journalière (UTC)
input int    MagicNumber  = 55501;

//──────────────────────────────────────────────────────────────────
double   g_pt; int g_digits;
bool     g_buy=false, g_sell=false;
int      h_fast, h_slow, h_rsi;
double   g_peak=0; double g_maxDD=0;
int      g_trades=0, g_wins=0;
datetime g_lastBar=0;

//──────────────────────────────────────────────────────────────────
int OnInit()
  {
   if(StringFind(_Symbol,"XAU")<0 && StringFind(_Symbol,"GOLD")<0)
     { Alert("EA réservé XAUUSD !"); return INIT_FAILED; }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   g_pt=_Point; g_digits=_Digits;

   h_fast = iMA(_Symbol,PERIOD_M5,EMA_Fast,0,MODE_EMA,PRICE_CLOSE);
   h_slow = iMA(_Symbol,PERIOD_M5,EMA_Slow,0,MODE_EMA,PRICE_CLOSE);
   h_rsi  = iRSI(_Symbol,PERIOD_M5,RSI_Period,PRICE_CLOSE);

   if(h_fast==INVALID_HANDLE||h_slow==INVALID_HANDLE||h_rsi==INVALID_HANDLE)
     { Print("Erreur indicateurs"); return INIT_FAILED; }

   g_peak = AccountInfoDouble(ACCOUNT_BALANCE);
   Print("GoldGridScalper v5 démarré");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int r)
  { IndicatorRelease(h_fast); IndicatorRelease(h_slow); IndicatorRelease(h_rsi); Comment(""); }

//──────────────────────────────────────────────────────────────────
void OnTick()
  {
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(eq > g_peak) g_peak = eq;
   double dd = (g_peak>0) ? (g_peak-eq)/g_peak*100.0 : 0;
   if(dd > g_maxDD) g_maxDD = dd;

   //--- Protections (chaque tick)
   if(dd >= MaxDD) { CloseAll("DRAWDOWN MAX"); return; }

   MqlDateTime dt; TimeToStruct(TimeGMT(),dt);
   if(dt.hour >= EOD_Hour) { if(Open()>0) CloseAll("FIN JOURNEE"); return; }

   //--- Gestion positions ouvertes (chaque tick)
   DoBreakeven();
   DoTimeout();
   DoBasketTP();

   //--- Signaux : 1x par barre M5
   datetime bar = iTime(_Symbol,PERIOD_M5,0);
   if(bar == g_lastBar) { Panel(eq,bal,dd); return; }
   g_lastBar = bar;

   //--- Spread
   double sp = (double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)*g_pt;
   if(sp > MaxSpread) { Print("Spread trop large: $",DoubleToString(sp,2)); return; }

   //--- Lecture indicateurs
   double f[2], s[2], r[2];
   if(CopyBuffer(h_fast,0,1,2,f)<2) return;
   if(CopyBuffer(h_slow,0,1,2,s)<2) return;
   if(CopyBuffer(h_rsi, 0,1,2,r)<2) return;

   double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);

   bool emaBull = f[0] > s[0];   // EMA rapide au-dessus = haussier
   bool emaBear = f[0] < s[0];
   bool rsiBull = r[0] > RSI_Buy;
   bool rsiBear = r[0] < RSI_Sell;

   int nBuy  = Dir(POSITION_TYPE_BUY);
   int nSell = Dir(POSITION_TYPE_SELL);

   Print(StringFormat("Bar | EMA:%s RSI:%.1f | BUY:%d SELL:%d | Spread:$%.2f",
         emaBull?"UP":"DOWN", r[0], nBuy, nSell, sp));

   //--- Entrée : ouvre TradesParSignal trades d'un coup
   if(emaBull && rsiBull && nBuy==0)
     { for(int k=0;k<TradesParSignal;k++) if(Buy(CalcLot(0))) g_buy=true; }
   if(emaBear && rsiBear && nSell==0)
     { for(int k=0;k<TradesParSignal;k++) if(Sell(CalcLot(0))) g_sell=true; }

   //--- Niveaux grille
   if(g_buy && nBuy>0 && nBuy<MaxLevels)
     { double lp=LastPrice(POSITION_TYPE_BUY);
       if(lp>0 && (lp-ask)>=GridStep) Buy(CalcLot(nBuy)); }

   if(g_sell && nSell>0 && nSell<MaxLevels)
     { double lp=LastPrice(POSITION_TYPE_SELL);
       if(lp>0 && (bid-lp)>=GridStep) Sell(CalcLot(nSell)); }

   Panel(eq,bal,dd);
  }

//──────────────────────────────────────────────────────────────────
void DoTimeout()
  {
   datetime now=TimeCurrent();
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      if(!pos.SelectByIndex(i)||pos.Symbol()!=_Symbol||pos.Magic()!=MagicNumber) continue;
      int age=(int)((now-pos.Time())/60);
      if(age >= MaxMinutes)
        {
         ENUM_POSITION_TYPE t=pos.PositionType();
         CloseDir(t,StringFormat("TIMEOUT %dmin dir=%s",age,t==POSITION_TYPE_BUY?"BUY":"SELL"));
         return;
        }
     }
  }

void DoBreakeven()
  {
   double bufPts = 10;  // 10 pts = $0.10 au-dessus du prix d'entrée
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      if(!pos.SelectByIndex(i)||pos.Symbol()!=_Symbol||pos.Magic()!=MagicNumber) continue;
      if(pos.Profit() < BETrigger) continue;
      double open=pos.PriceOpen(), sl=pos.StopLoss();
      if(pos.PositionType()==POSITION_TYPE_BUY)
        { double beSL=NormalizeDouble(open+bufPts*g_pt,g_digits);
          if(sl<beSL) trade.PositionModify(pos.Ticket(),beSL,pos.TakeProfit()); }
      else
        { double beSL=NormalizeDouble(open-bufPts*g_pt,g_digits);
          if(sl==0||sl>beSL) trade.PositionModify(pos.Ticket(),beSL,pos.TakeProfit()); }
     }
  }

void DoBasketTP()
  {
   if(Open()==0) return;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   // Ferme chaque direction indépendamment
   if(g_buy)
     { double avg=AvgDir(POSITION_TYPE_BUY);
       if(avg>0 && (bid-avg)>=BasketTP) CloseDir(POSITION_TYPE_BUY,"BASKET TP BUY"); }
   if(g_sell)
     { double avg=AvgDir(POSITION_TYPE_SELL);
       if(avg>0 && (avg-ask)>=BasketTP) CloseDir(POSITION_TYPE_SELL,"BASKET TP SELL"); }
  }

//──────────────────────────────────────────────────────────────────
bool Buy(double lot)
  {
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double tp=NormalizeDouble(ask+TP/g_pt*g_pt,g_digits);
   double sl=NormalizeDouble(ask-SL/g_pt*g_pt,g_digits);
   if(trade.Buy(lot,_Symbol,ask,sl,tp)){ g_trades++; Print("✓ BUY @",ask," lot=",lot); return true; }
   Print("✗ BUY echec: ",trade.ResultRetcodeDescription());
   return false;
  }

bool Sell(double lot)
  {
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double tp=NormalizeDouble(bid-TP/g_pt*g_pt,g_digits);
   double sl=NormalizeDouble(bid+SL/g_pt*g_pt,g_digits);
   if(trade.Sell(lot,_Symbol,bid,sl,tp)){ g_trades++; Print("✓ SELL @",bid," lot=",lot); return true; }
   Print("✗ SELL echec: ",trade.ResultRetcodeDescription());
   return false;
  }

double CalcLot(int lvl)
  {
   double lot=Lot; for(int i=0;i<lvl;i++) lot*=LotMult;
   double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double st=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   lot=MathMax(MathMin(lot,mx),mn);
   return NormalizeDouble(MathFloor(lot/st)*st,2);
  }

void CloseAll(string why)
  {
   Print("[EA] CloseAll: ",why);
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(pos.SelectByIndex(i)&&pos.Symbol()==_Symbol&&pos.Magic()==MagicNumber)
         trade.PositionClose(pos.Ticket());
   g_buy=false; g_sell=false;
  }

void CloseDir(ENUM_POSITION_TYPE t, string why)
  {
   Print("[EA] ",why);
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(pos.SelectByIndex(i)&&pos.Symbol()==_Symbol&&pos.Magic()==MagicNumber&&pos.PositionType()==t)
         trade.PositionClose(pos.Ticket());
   if(t==POSITION_TYPE_BUY)  g_buy=false;
   if(t==POSITION_TYPE_SELL) g_sell=false;
  }

double AvgDir(ENUM_POSITION_TYPE t)
  { double w=0,v=0;
    for(int i=PositionsTotal()-1;i>=0;i--)
      if(pos.SelectByIndex(i)&&pos.Symbol()==_Symbol&&pos.Magic()==MagicNumber&&pos.PositionType()==t)
        { w+=pos.PriceOpen()*pos.Volume(); v+=pos.Volume(); }
    return v>0?w/v:0; }

int Dir(ENUM_POSITION_TYPE t)
  { int c=0; for(int i=PositionsTotal()-1;i>=0;i--)
      if(pos.SelectByIndex(i)&&pos.Symbol()==_Symbol&&pos.Magic()==MagicNumber&&pos.PositionType()==t) c++;
    return c; }

int Open()
  { int c=0; for(int i=PositionsTotal()-1;i>=0;i--)
      if(pos.SelectByIndex(i)&&pos.Symbol()==_Symbol&&pos.Magic()==MagicNumber) c++;
    return c; }

double LastPrice(ENUM_POSITION_TYPE t)
  { double p=0; datetime ts=0;
    for(int i=PositionsTotal()-1;i>=0;i--)
      if(pos.SelectByIndex(i)&&pos.Symbol()==_Symbol&&pos.Magic()==MagicNumber&&pos.PositionType()==t&&pos.Time()>=ts){ts=pos.Time();p=pos.PriceOpen();}
    return p; }

double AvgPrice()
  { double w=0,v=0;
    for(int i=PositionsTotal()-1;i>=0;i--)
      if(pos.SelectByIndex(i)&&pos.Symbol()==_Symbol&&pos.Magic()==MagicNumber){w+=pos.PriceOpen()*pos.Volume();v+=pos.Volume();}
    return v>0?w/v:0; }

//──────────────────────────────────────────────────────────────────
void Panel(double eq,double bal,double dd)
  {
   string cur=AccountInfoString(ACCOUNT_CURRENCY);
   double pnl=eq-bal, sp=(double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)*g_pt;
   datetime now=TimeCurrent(); int old=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(pos.SelectByIndex(i)&&pos.Symbol()==_Symbol&&pos.Magic()==MagicNumber)
        { int a=(int)((now-pos.Time())/60); if(a>old)old=a; }
   string s="";
   s+="═══════════════════════════\n";
   s+=" GOLD GRID SCALPER  v5.0\n";
   s+="═══════════════════════════\n";
   s+=StringFormat(" Balance : %.2f %s\n",bal,cur);
   s+=StringFormat(" Equity  : %.2f %s\n",eq,cur);
   s+=StringFormat(" P&L     : %s%.2f %s\n",pnl>=0?"+":"",pnl,cur);
   s+=StringFormat(" Drawdown: %.2f%% (max %.2f%%)\n",dd,g_maxDD);
   s+="───────────────────────────\n";
   s+=StringFormat(" BUY  x%d / SELL x%d\n",Dir(POSITION_TYPE_BUY),Dir(POSITION_TYPE_SELL));
   s+=StringFormat(" Age pos : %d / %d min\n",old,MaxMinutes);
   s+=StringFormat(" Trades  : %d  gains:%d\n",g_trades,g_wins);
   s+=StringFormat(" Spread  : $%.2f\n",sp);
   s+="═══════════════════════════";
   Comment(s);
  }

void OnTradeTransaction(const MqlTradeTransaction &t,const MqlTradeRequest &r,const MqlTradeResult &res)
  { if(t.type==TRADE_TRANSACTION_DEAL_ADD&&HistoryDealSelect(t.deal))
      { double p=HistoryDealGetDouble(t.deal,DEAL_PROFIT); if(p!=0){if(p>0)g_wins++;} } }
