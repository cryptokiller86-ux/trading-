# ScalpingGridEA v2.0 — Guide de Configuration

## Paires recommandées
- EURUSD, GBPUSD, USDJPY (spread faible, liquidité max)
- Timeframe : M1 ou M5

## Paramètres optimaux par profil

### Profil SAFE (débutant / compte réel <1000$)
| Paramètre | Valeur |
|---|---|
| GridStep | 25 |
| MaxGridLevels | 5 |
| LotStart | 0.01 |
| LotMultiplier | 1.3 |
| TakeProfit_Points | 30 |
| GridTP_Points | 70 |
| StopLoss_Points | 200 |
| MaxDrawdownPct | 10 |
| UseAutoLot | false |

### Profil BALANCED (compte 2000$+)
| Paramètre | Valeur |
|---|---|
| GridStep | 20 |
| MaxGridLevels | 8 |
| LotStart | 0.02 |
| LotMultiplier | 1.5 |
| TakeProfit_Points | 30 |
| GridTP_Points | 80 |
| StopLoss_Points | 150 |
| MaxDrawdownPct | 15 |
| UseAutoLot | true |
| RiskPerTrade | 1.0 |

### Profil AGGRESSIVE (compte 5000$+, expérimenté)
| Paramètre | Valeur |
|---|---|
| GridStep | 15 |
| MaxGridLevels | 10 |
| LotStart | 0.05 |
| LotMultiplier | 1.8 |
| TakeProfit_Points | 25 |
| GridTP_Points | 60 |
| StopLoss_Points | 120 |
| MaxDrawdownPct | 20 |
| UseAutoLot | true |
| RiskPerTrade | 2.0 |

## Installation MT5
1. Copier `ScalpingGridEA.mq5` dans: `MQL5/Experts/`
2. Compiler avec MetaEditor (F7)
3. Attacher sur le graphique (M1 ou M5)
4. Activer **AutoTrading**
5. Cocher **"Allow live trading"** dans les propriétés

## Logique de l'EA

### Entrée en position
- EMA rapide (8) > EMA lente (21) → BUY quand RSI < 30
- EMA rapide (8) < EMA lente (21) → SELL quand RSI > 70

### Grid
- Si le prix évolue contre la position de `GridStep` points → ouvre un niveau supplémentaire
- Lot multiplié par `LotMultiplier` à chaque niveau (Martingale)
- Option Anti-Martingale disponible (lot divisé au lieu de multiplié)

### Sortie
- Chaque position a son propre TP individuel
- TP panier global: ferme tout quand le profit total atteint `GridTP_Points` points sur le prix moyen
- Stop Loss d'urgence sur chaque position
- Trailing stop activable

### Protection
- Max Drawdown: ferme tout si le drawdown dépasse le seuil %
- Filtre spread: n'ouvre pas si spread > MaxSpread
- Filtre sessions: Londres (8h-17h UTC) et New York (13h-22h UTC)

## Risques importants
> **Le grid trading avec martingale peut générer des drawdowns importants.**
> Toujours tester en compte démo avant le compte réel.
> Ne jamais risquer plus que ce que vous pouvez vous permettre de perdre.
