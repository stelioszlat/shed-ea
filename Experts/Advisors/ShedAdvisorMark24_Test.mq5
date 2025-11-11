//+--------------------------------------------------------------------------------------------------+
//|                                                                                  ShedAdvisorMark24.mq5 |
//|                                                                                          Stelios Zlat |
//|                                                                                  https://www.mql5.com |
//+--------------------------------------------------------------------------------------------------+
#property copyright "Stelios Zlat"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

// Global trading object
CTrade trade;

enum ATRSelect {
      ATRAlwaysWider,
      ATRUse112,
      ATRUse20,
      ATROnCondition
};

enum OffSessionHandling {
      OffSessionBreakEven,
      OffSessionCloseOrder
};

//===================== Inlined ShedTradeHelper ======================//

input double RiskPercent = 0.1;                  // Risk per trade (not wired into triggers to preserve your behavior)
input int      MagicNumber = 12345;
input int      IndicatorPeriod = 112;          // ATR Indicator Period
input double ATRMultiplier = 1.0;              // ATR Multiplier
input ENUM_APPLIED_PRICE AppliedPrice = PRICE_CLOSE;  // Price type for indicator
input string TradingSessionJapanStart    = "01:30";
input string TradingSessionJapanEnd      = "06:00";
input string TradingSessionEuropeStart  = "06:00";
input string TradingSessionEuropeEnd    = "13:00";
input string TradingSessionUSAStart      = "13:00";
input string TradingSessionUSAEnd        = "23:00";

input int      lookback = 5;
input int      TimerIntervalSeconds = 180;
input double TakeProfit = 0.0;
input double StopLoss = 0.0;
input double TakeProfitMultiplier = 0.0;
input double BreakEvenPercent = 0.6;
input double BreakEvenMarginInPips = 1.0;
input double InitialStopLossMarginInPips = 0.0;
input double TrailingStopMarginInPips = 2.0;

input double TrailingStopEarlyStageMarginInPips = 5.0;
input double TrailingStopTightMarginInPips = 2.0;
input double ProfitThresholdForTightening = 1.0;
input double R1PartialPercent = 1.0;
input int      SpreadAddedToStop = 15;
input double BreakoutRetracementHigh = 70.0;
input double BreakoutRetracementLow = 10.0;
input double OrderCloseToRetracementPercent = 30.0;
input ATRSelect ATRUsedInStopLossCalculation = ATRAlwaysWider;
input string OutOfSessionCloseTime = "23:00";
input OffSessionHandling HandleOrdersOutOfSession = OffSessionBreakEven;
//input bool    UseADXFilter = true;                    // Enable ADX Trend Filter
//input int      ADXPeriod = 14;                        // ADX Period

// ===== Spread and Volatility Filtering =====
//input bool    UseSpreadFilter = true;                                        // Enable Spread Filter
//input double NormalSpreadPips = 0.8;                                          // Baseline Normal Spread (pips)
//input double MaxSpreadForEntry = 2.0;                                        // Max Spread to Allow Entry (pips)
//input bool    UseATRVolatilityAdjustment = true;                    // Adjust spread limits by ATR width
//input double SpreadToATRRatio = 0.15;                                        // Allow wider spread if ATR ratio exceeds this (15%)
//input double ExtremeSpreadMultiplier = 4.0;                            // Pause stop modifications at 4x normal spread

//input bool    UseMinimumVolatilityFilter = true;                    // Block trades in narrow markets
//input double MinimumATRChannelWidthPips = 15.0;                    // Minimum channel width in pips
//input double ATRRatioThresholdForWideSpread = 1.5;              // ATR112/ATR20 ratio to allow wider spreadsinput bool       
//input bool    UseDailyLimits = true;                                            // Enable daily profit/loss limits
// ===== Multi-Order Scaling System =====
input bool    EnableMultiOrderScaling = false;                    // Master switch for all scaling features

// --- Scaling into Losers (Averaging Down) ---
input bool    ScaleIntoLosers = false;                                    // Allow adding orders when price moves against us
input int      MaxScaleInLosers = 2;                                          // Max additional orders when averaging down (1-2, so total 3)
input double LoserScaleMinDistancePercent = 40.0;            // Min distance from previous order (% of its SL distance)
input double LoserOrder2LotMultiplier = 1.0;                      // Lot size multiplier for 2nd loser order (1.0 = same as first)
input double LoserOrder3LotMultiplier = 1.0;                      // Lot size multiplier for 3rd loser order
input int      MinBarsBetweenLoserOrders = 1;                        // Minimum bars between loser orders (0 = same bar allowed)

// --- Scaling into Winners (Pyramiding) ---
input bool    ScaleIntoWinners = true;                                    // Allow adding orders when price moves in our favor
input int      MaxScaleInWinners = 2;                                        // Max additional orders when pyramiding (1-2, so total 3)
input double WinnerScaleMinDistancePercent = 50.0;          // Min distance from previous order (% of its SL distance)
input double WinnerOrder2LotMultiplier = 0.8;                    // Lot size multiplier for 2nd winner order (0.8 = 80% of calculated size)
input double WinnerOrder3LotMultiplier = 0.6;                    // Lot size multiplier for 3rd winner order (0.6 = 60% of calculated size)
input int      MinBarsBetweenWinnerOrders = 1;                      // Minimum bars between winner orders

// --- Stop Loss Synchronization ---
input bool    SyncStopsAfterBreakEven = true;                      // Sync all orders' stops once each reaches break-even
input double MinStopProtectionPips = 2.0;                            // Minimum pips above entry when syncing stops

// --- Safety Limits ---
input int      MaxTotalOpenOrders = 8;                                      // Absolute max orders open at once (1-20)
input bool    AllowMixedScaling = false;                                // Allow mixing loser + winner scaling in same sequence
//input double MaxDailyProfitPercent = 5.0;
//input double MaxDailyLossPercent = 2.0;

datetime g_lastResetDate = 0;
double g_dailyStartBalance = 0.0;
bool g_dailyLimitReached = false;
datetime g_lastBarTime = 0;  // For new candle detection
datetime g_lastTickTime = 0;
int g_tickCounter = 0;
const int SYNC_ORDER_INTERVAL = 10;
const int TRAILING_STOP_INTERVAL = 5;
double g_cachedUpper112 = 0.0;
double g_cachedLower112 = 0.0;
double g_cachedCentral112 = 0.0;
double g_cachedUpper20 = 0.0;
double g_cachedLower20 = 0.0;
double g_cachedCentral20 = 0.0;
datetime g_lastATRUpdate = 0;
datetime g_lastOffSessionProcessedDate = 0;

int adaptiveATRHandle112;
int adaptiveATRHandle20;
int adxHandle;
bool breakEvenRun = false;
bool partialCloseRun = false;
double g_lastTrailingStopBuy = 0.0;
double g_lastTrailingStopSell = 0.0;

double breakoutBuyLow = 0.0;
double breakoutBuyHigh = 0.0;
double breakoutSellLow = 0.0;
double breakoutSellHigh = 0.0;
double retracementBuyLow = 0.0;
double retracementBuyHigh = 0.0;
double retracementSellLow = 0.0;
double retracementSellHigh = 0.0;

enum TradeState {
      TRADE_IDLE,
      BREAKOUT_BUY,
      BREAKOUT_SELL,
      RETRACEMENT_BUY,
      RETRACEMENT_SELL
};

TradeState state;
ulong  gTicket = 0;   
double gInitialSL = 0.0;
bool g_extremeSpreadActive = false;  // Tracks if extreme spread is active
// Multi-order tracking structures
struct OrderInfo {
      ulong ticket;
      double entryPrice;
      double initialSL;
      double currentSL;
      ENUM_POSITION_TYPE type;
      bool breakEvenReached;
      datetime openTime;
      int orderSequence;    // 1=first, 2=second, 3=third
      bool partialCloseDone;
};

OrderInfo g_orders[20];
int g_orderCount = 0;
datetime g_lastOrderTime = 0;
int g_scalingDirection = 0;    // 0=none, 1=winners, -1=losers

double CalculateLotSize(double stopLoss, double riskPercent=1.0) {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double riskMoney = equity * (riskPercent / 100.0);
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double volumeStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

      if  (point <= 0 || tickValue <= 0 || volumeStep <= 0 || riskMoney <= 0)  {
            return 0.0;
      }
       
      double stopLossPoints = MathRound(stopLoss / point);
      if  (stopLossPoints <= 0)  {
            return 0.0;
      }

      double valuePerLot = stopLossPoints * tickValue;
      if  (valuePerLot <= 0)  {
            return 0.0;
      }

      double lotSize = riskMoney / valuePerLot;
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

      lotSize = MathMax(minLot, lotSize);
      lotSize = MathMin(maxLot, lotSize);
      lotSize = MathFloor(lotSize / volumeStep + 0.000000001) * volumeStep;

      if  (lotSize < minLot || lotSize > maxLot)  {
            return 0.0;
      }

      return lotSize;
}

double CalculateEfficiencyRatio(int period, int index, const double &closed[])  {
      if  (index < period || period <= 0) return 0.0;

      double change = MathAbs(closed[index] - closed[index - period]);
      double volatility = 0.0;

      for  (int k = 0; k < period ; k++)  {
            volatility += MathAbs(closed[index - k] - closed[index - k - 1]);
      }

      if  (volatility == 0.0)  {
            return volatility;
      }

      return change / volatility;
}

double CalculateInitialStopLossWidth(double channelWidth, double channel20Width)  {
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      long spread = SpreadAddedToStop;  // SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      double spreadInPrice = spread * point;
      double channel = channelWidth;
      switch  (ATRUsedInStopLossCalculation)  {
            case ATRAlwaysWider:
                  if  (channelWidth < channel20Width)  {
                        channel = channel20Width;
                  }
                  break;
            case ATRUse112:
                  break;
            case ATRUse20:
                  channel = channel20Width;
                  break;
            case ATROnCondition:
                  channel = (channelWidth + channel20Width) / 2;
      }
       
      return channel + spreadInPrice;
}

bool TriggerSellOrder(double channelWidth, double channel20Width, double riskPercent=0.1, int magicNumber=12345)  {
      if  (channelWidth <= 0)  {
            return false;
      }

      double entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double SL = NormalizeDouble(entryPrice + CalculateInitialStopLossWidth(channelWidth, channel20Width), _Digits) + InitialStopLossMarginInPips * GetPipSize();
      double takeProfitMultiplier = TakeProfitMultiplier != 0.0 ? TakeProfitMultiplier : 1.5;

      double baseVolume = CalculateLotSize(SL - entryPrice, 1.0);
      double volume = baseVolume;
       
      // Apply lot multiplier based on order sequence
      if  (g_orderCount > 0)  {
            if  (g_scalingDirection == 1)  {    // Scaling into winners
                  if  (g_orderCount == 1) volume = NormalizeVolume(_Symbol, baseVolume * WinnerOrder2LotMultiplier);
                  else if  (g_orderCount == 2) volume = NormalizeVolume(_Symbol, baseVolume * WinnerOrder3LotMultiplier);
            }  else if  (g_scalingDirection == -1)  {    // Scaling into losers
                  if  (g_orderCount == 1) volume = NormalizeVolume(_Symbol, baseVolume * LoserOrder2LotMultiplier);
                  else if  (g_orderCount == 2) volume = NormalizeVolume(_Symbol, baseVolume * LoserOrder3LotMultiplier);
            }
      }

      if  (volume <= 0)  {
            return false;
      }

      trade.SetExpertMagicNumber(magicNumber);
      trade.SetMarginMode();
      trade.SetTypeFillingBySymbol(_Symbol);

      if  (trade.Sell(volume, _Symbol, entryPrice, SL, 0.0, "Sell Order: ATR Channel Retracement"))  {
            ulong dealTicket = trade.ResultDeal();
            double tradeEntryPrice = trade.ResultPrice();
            double tradeInitialStopLoss = SL;
            double tradeChannelWidth = channelWidth;
             
            // Store order info
            if  (g_orderCount < MaxTotalOpenOrders)  {
                  g_orders[g_orderCount].ticket = dealTicket;
                  g_orders[g_orderCount].entryPrice = tradeEntryPrice;
                  g_orders[g_orderCount].initialSL = tradeInitialStopLoss;
                  g_orders[g_orderCount].currentSL = tradeInitialStopLoss;
                  g_orders[g_orderCount].type = POSITION_TYPE_SELL;
                  g_orders[g_orderCount].breakEvenReached = false;
                  g_orders[g_orderCount].openTime = TimeCurrent();
                  g_orders[g_orderCount].orderSequence = g_orderCount + 1;
                  g_orderCount++;
            }
             
            return true;
      }  else  {
            return false;
      }
}

bool TriggerBuyOrder(double channelWidth, double channel20Width, double riskPercent=0.1, int magicNumber=12345)  {
      if  (channelWidth <= 0)  {
            return false;
      }

      double entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double SL = NormalizeDouble(entryPrice - CalculateInitialStopLossWidth(channelWidth, channel20Width), _Digits) - InitialStopLossMarginInPips * GetPipSize();
      double takeProfitMultiplier = TakeProfitMultiplier != 0.0 ? TakeProfitMultiplier : 1.5;

      double baseVolume = CalculateLotSize(entryPrice - SL, 1.0);
      double volume = baseVolume;
       
      // Apply lot multiplier based on order sequence
      if  (g_orderCount > 0)  {
            if  (g_scalingDirection == 1)  {    // Scaling into winners
                  if  (g_orderCount == 1) volume = NormalizeVolume(_Symbol, baseVolume * WinnerOrder2LotMultiplier);
                  else if  (g_orderCount == 2) volume = NormalizeVolume(_Symbol, baseVolume * WinnerOrder3LotMultiplier);
            }  else if  (g_scalingDirection == -1)  {    // Scaling into losers
                  if  (g_orderCount == 1) volume = NormalizeVolume(_Symbol, baseVolume * LoserOrder2LotMultiplier);
                  else if  (g_orderCount == 2) volume = NormalizeVolume(_Symbol, baseVolume * LoserOrder3LotMultiplier);
            }
      }

      if  (volume <= 0)  {
            return false;
      }

      trade.SetExpertMagicNumber(magicNumber);
      trade.SetMarginMode();
      trade.SetTypeFillingBySymbol(_Symbol);

      if  (trade.Buy(volume, _Symbol, 0.0, SL, 0.0, "Buy Order: ATR Channel Retracement"))  {
            ulong dealTicket = trade.ResultDeal();
            double tradeEntryPrice = trade.ResultPrice();
            double tradeInitialStopLoss = SL;
            double tradeChannelWidth = channelWidth;
             
            // Store order info
            if  (g_orderCount < MaxTotalOpenOrders)  {
                  g_orders[g_orderCount].ticket = dealTicket;
                  g_orders[g_orderCount].entryPrice = tradeEntryPrice;
                  g_orders[g_orderCount].initialSL = tradeInitialStopLoss;
                  g_orders[g_orderCount].currentSL = tradeInitialStopLoss;
                  g_orders[g_orderCount].type = POSITION_TYPE_BUY;
                  g_orders[g_orderCount].breakEvenReached = false;
                  g_orders[g_orderCount].openTime = TimeCurrent();
                  g_orders[g_orderCount].orderSequence = g_orderCount + 1;
                  g_orderCount++;
            }
             
            return true;
      }  else  {
            return false;
      }
}

bool ModifyStopLoss(ulong ticket, double TS)  {
      /*if  (IsExtremeSpread())  {
            return false;
      }*/
      
      if  (!PositionSelectByTicket(ticket))  {
            return false;
      }

      double currentSL = PositionGetDouble(POSITION_SL);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if  (type == POSITION_TYPE_BUY && TS > currentSL)  {
            double TP = PositionGetDouble(POSITION_TP);
            trade.PositionModify(ticket, TS, TP);
            return true;
      }  else if  (type == POSITION_TYPE_SELL && TS < currentSL)  {
            double TP = PositionGetDouble(POSITION_TP);
            trade.PositionModify(ticket, TS, TP);
            return true;
      }
      return false;
}

bool PartialCloseByTicket(ulong ticket, double lot)  {
      if  (!PositionSelectByTicket(ticket))  return false;
       
      if  (trade.PositionClosePartial(ticket, lot))  {
            return true;
      }
      return false;
}

void checkTradeConditions()  {
   ENUM_TIMEFRAMES timeframe = _Period;
   
   double channelWidth = g_cachedUpper112 - g_cachedLower112;
   double channel20Width = g_cachedUpper20 - g_cachedLower20;
   
   double currClose = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currOpen = iOpen(_Symbol, timeframe, 0);
   double prevClose = iClose(_Symbol, timeframe, 1);
   double prevOpen = iOpen(_Symbol, timeframe, 1);
   double lastPrevOpen = iOpen(_Symbol, timeframe, 2);
   double lastPrevClose = iClose(_Symbol, timeframe, 2);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   if(currClose > g_cachedUpper112 && g_cachedCentral20 > g_cachedUpper112 && 
      currOpen > prevOpen && prevOpen < prevClose && lastPrevOpen > lastPrevClose)  {
      
      findRetracementBuySwing();
      double retracementSwing = retracementBuyHigh - retracementBuyLow;
      double breakoutSwing = breakoutBuyHigh - breakoutBuyLow;
      
      double retracementPercent = 100 - retracementSwing / breakoutSwing * 100;
      double orderPlacementToRetracement = (retracementBuyHigh - currClose) / retracementSwing * 100;
      
      bool canTrade = false;
      if(EnableMultiOrderScaling)  {
         canTrade = GetOpenOrderCount() < MaxTotalOpenOrders && CanAddAnotherOrder(currClose, POSITION_TYPE_BUY);
      } else  {
         canTrade = !SelectPositionByMagic(_Symbol);
      }
      
      if(IsWithinSession() && canTrade && /*IsTrendingMarket() &&*/ 
         retracementPercent >= BreakoutRetracementLow && retracementPercent <= BreakoutRetracementHigh && 
         orderPlacementToRetracement >= OrderCloseToRetracementPercent)  {
         if(TriggerBuyOrder(channelWidth, channel20Width))  {
            g_lastOrderTime = TimeCurrent();
            partialCloseRun = false;
         }
      }
      
      breakoutBuyHigh = 0.0;
      breakoutBuyLow = 0.0;
      retracementBuyHigh = 0.0;
      retracementBuyLow = 0.0;
   }
   
   if(currClose < g_cachedLower112 && g_cachedCentral20 < g_cachedLower112 && 
      currOpen < prevOpen && prevOpen > prevClose && lastPrevOpen < lastPrevClose)  {
      
      findRetracementSellSwing();
      double retracementSwing = retracementSellHigh - retracementSellLow;
      double breakoutSwing = breakoutSellHigh - breakoutSellLow;
      
      double retracementPercent = 100 - retracementSwing / breakoutSwing * 100;
      double orderPlacementToRetracement = 100 - (currClose - retracementSellLow) / retracementSwing * 100;
      
      bool canTrade = false;
      if(EnableMultiOrderScaling)  {
         canTrade = GetOpenOrderCount() < MaxTotalOpenOrders && CanAddAnotherOrder(currClose, POSITION_TYPE_SELL);
      } else  {
         canTrade = !SelectPositionByMagic(_Symbol);
      }
      
      if(IsWithinSession() && canTrade && /*IsTrendingMarket() && */ 
         retracementPercent >= BreakoutRetracementLow && retracementPercent <= BreakoutRetracementHigh && 
         orderPlacementToRetracement >= OrderCloseToRetracementPercent)  {
         if(TriggerSellOrder(channelWidth, channel20Width))  {
            g_lastOrderTime = TimeCurrent();
            partialCloseRun = false;
         }
      }
      
      breakoutSellLow = 0.0;
      breakoutSellHigh = 0.0;
      retracementSellLow = 0.0;
      retracementSellHigh = 0.0;
   }
}

void findRetracementBuySwing()  {
      int index = 1;
      double previousOpen = iOpen(_Symbol, _Period, index + 1);
      double previousClose = iClose(_Symbol, _Period, index + 1);
      double currentLow = iLow(_Symbol, _Period, index);
      double previousLow = iLow(_Symbol, _Period, index + 1);
      double currentHigh = iHigh(_Symbol, _Period, index + 1);
      double previousHigh = iHigh(_Symbol, _Period, index + 1);
      retracementBuyLow = currentLow;
      retracementBuyHigh = currentHigh;
      while(previousOpen > previousClose)  {
            if  (previousHigh > retracementBuyHigh)  {
                  retracementBuyHigh = previousHigh;
            }
             
            if  (previousLow < retracementBuyLow)  {
                  retracementBuyLow = previousLow;
            }
            index++;
            previousOpen = iOpen(_Symbol, _Period, index + 1);
            previousClose = iClose(_Symbol, _Period, index + 1);
            previousLow = iLow(_Symbol, _Period, index + 1);
            previousHigh = iHigh(_Symbol, _Period, index + 1);
            currentLow = iLow(_Symbol, _Period, index);
      }
      breakoutBuyHigh = previousHigh;
      breakoutBuyLow = previousLow;
}

void findRetracementSellSwing()  {
      int index = 1;
      double previousOpen = iOpen(_Symbol, _Period, index + 1);
      double previousClose = iClose(_Symbol, _Period, index + 1);
      double currentLow = iLow(_Symbol, _Period, index);
      double previousLow = iLow(_Symbol, _Period, index + 1);
      double currentHigh = iHigh(_Symbol, _Period, index + 1);
      double previousHigh = iHigh(_Symbol, _Period, index + 1);
      retracementSellLow = currentLow;
      retracementSellHigh = currentHigh;
      while(previousOpen < previousClose)  {
            if  (previousHigh > retracementSellHigh)  {
                  retracementSellHigh = previousHigh;
            }
             
            if  (previousLow < retracementSellLow)  {
                  retracementSellLow = previousLow;
            }
            index++;
            previousOpen = iOpen(_Symbol, _Period, index + 1);
            previousClose = iClose(_Symbol, _Period, index + 1);
            previousLow = iLow(_Symbol, _Period, index + 1);
            previousHigh = iHigh(_Symbol, _Period, index + 1);
            currentLow = iLow(_Symbol, _Period, index);
      }
      breakoutSellHigh = previousHigh;
      breakoutSellLow = previousLow;
}

double GetPipSize()  {
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      if  (digits == 3 || digits == 5) return SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
      return SymbolInfoDouble(_Symbol, SYMBOL_POINT);
}

bool GetAdaptiveATRChannelByIndex(int handle, int period, int index, double &central, double &upper, double &lower)  {
      double buffer0[];
      double buffer2[];
      double buffer3[];
      ArraySetAsSeries(buffer0, true);
      ArraySetAsSeries(buffer2, true);
      ArraySetAsSeries(buffer3, true);

      if  (CopyBuffer(handle, 0, index, 1, buffer0) <= 0 ||
           CopyBuffer(handle, 2, index, 1, buffer2) <= 0 ||
           CopyBuffer(handle, 3, index, 1, buffer3) <= 0)  {
            return false;
      }

      central = buffer0[0];
      upper   = buffer2[0];
      lower   = buffer3[0];
      return true;
}

bool SelectPositionByMagic(string symbol)  {
      for  (int i = PositionsTotal() - 1; i >= 0; i--)  {
            ulong ticket = PositionGetTicket(i);
            if  (ticket > 0)  {
                  if  (PositionSelectByTicket(ticket))  {
                        string posSymbol = PositionGetString(POSITION_SYMBOL);
                        long posMagic = PositionGetInteger(POSITION_MAGIC);
                        if  (posSymbol == symbol && posMagic == MagicNumber)  {
                              return true;
                        }
                  }
            }
      }
      return false;
}

void CloseAllOrders()  {
      for  (int i = PositionsTotal() - 1; i >= 0; i--)  {
            ulong ticket = PositionGetTicket(i);
            if  (PositionSelectByTicket(ticket))  {
                  string posSymbol = PositionGetString(POSITION_SYMBOL);
                  long posMagic = PositionGetInteger(POSITION_MAGIC);
                  if  (posSymbol == _Symbol && posMagic == MagicNumber)  {
                        trade.PositionClose(ticket);
                  }
            }
      }
      
      g_orderCount = 0;
      gTicket = 0;
      gInitialSL = 0.0;
      g_scalingDirection = 0;
}

datetime TimeStringToSeconds(string timeStr)  {
      string parts[];
      int count = StringSplit(timeStr, ':', parts);
      if  (count != 2) return 0;
      
      int hours = (int)StringToInteger(parts[0]);
      int minutes = (int)StringToInteger(parts[1]);
      
      return hours * 3600 + minutes * 60;
}

bool IsWithinSessionTime(string startStr, string endStr)  {
      MqlDateTime dtStruct;
      TimeCurrent(dtStruct);
      
      int currentSeconds = dtStruct.hour * 3600 + dtStruct.min * 60 + dtStruct.sec;
      int startSeconds = (int)TimeStringToSeconds(startStr);
      int endSeconds   = (int)TimeStringToSeconds(endStr);
      
      if  (startSeconds < endSeconds)  {
            return (currentSeconds >= startSeconds && currentSeconds < endSeconds);
      }  else  {
            return (currentSeconds >= startSeconds || currentSeconds < endSeconds);
      }
}

bool IsWithinSession()  {
      return IsWithinSessionTime(TradingSessionJapanStart, TradingSessionJapanEnd) ||
             IsWithinSessionTime(TradingSessionEuropeStart, TradingSessionEuropeEnd) ||
             IsWithinSessionTime(TradingSessionUSAStart, TradingSessionUSAEnd);
}

bool IsTrendingMarket()  {
      //if  (!UseADXFilter) return true;
      
      double adxBuffer[];
      ArraySetAsSeries(adxBuffer, true);
      
      if  (CopyBuffer(adxHandle, 0, 0, 1, adxBuffer) <= 0)  {
            return false;
      }
      
      double adxValue = adxBuffer[0];
      
      if  (adxValue >= 25.0)  {
            return true;
      }
      
      return false;
}

/*bool IsSpreadAcceptable()  {
      //if  (!UseSpreadFilter) return true;
      
      long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double currentSpreadPips = spreadPoints * point / GetPipSize();
      
      if  (currentSpreadPips <= MaxSpreadForEntry)  {
            return true;
      }
      
      if  (UseATRVolatilityAdjustment)  {
            double channelWidth = g_cachedUpper112 - g_cachedLower112;
            double spreadToATR = currentSpreadPips / (channelWidth / GetPipSize());
            
            if  (spreadToATR <= SpreadToATRRatio)  {
                  return true;
            }
      }
      
      return false;
}*/

/*bool IsExtremeSpread()  {
      long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double currentSpreadPips = spreadPoints * point / GetPipSize();
      double extremeThreshold = NormalSpreadPips * ExtremeSpreadMultiplier;
      
      bool isExtreme = (currentSpreadPips >= extremeThreshold);
      
      if  (isExtreme && !g_extremeSpreadActive)  {
            g_extremeSpreadActive = true;
      }  else if  (!isExtreme && g_extremeSpreadActive)  {
            g_extremeSpreadActive = false;
      }
      
      return isExtreme;
}*/

/*bool IsChannelWidthSufficient()  {
      if  (!UseMinimumVolatilityFilter) return true;
      
      double channelWidth = g_cachedUpper112 - g_cachedLower112;
      double channelWidthPips = channelWidth / GetPipSize();
      
      return (channelWidthPips >= MinimumATRChannelWidthPips);
}*/

/*void CheckDailyLimits()  {
      if  (!UseDailyLimits) return;
      
      MqlDateTime dtStruct;
      datetime currentTime = TimeCurrent(dtStruct);
      
      if  (dtStruct.day_of_year != g_lastResetDate)  {
            g_lastResetDate = dtStruct.day_of_year;
            g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
            g_dailyLimitReached = false;
      }
      
      if  (g_dailyLimitReached) return;
      
      double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      double profitLoss = currentBalance - g_dailyStartBalance;
      double profitLossPercent = (profitLoss / g_dailyStartBalance) * 100.0;
      
      if  (profitLossPercent >= MaxDailyProfitPercent)  {
            g_dailyLimitReached = true;
            CloseAllOrders();
      }
      
      if  (profitLossPercent <= -MaxDailyLossPercent)  {
            g_dailyLimitReached = true;
            CloseAllOrders();
      }
}*/

double NormalizeVolume(string symbol, double volume)  {
      double minVol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      double maxVol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
      double stepVol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
      
      volume = MathMax(volume, minVol);
      volume = MathMin(volume, maxVol);
      volume = MathFloor(volume / stepVol) * stepVol;
      
      return volume;
}

int GetOpenOrderCount()  {
      int count = 0;
      for  (int i = PositionsTotal() - 1; i >= 0; i--)  {
            ulong ticket = PositionGetTicket(i);
            if  (PositionSelectByTicket(ticket))  {
                  string posSymbol = PositionGetString(POSITION_SYMBOL);
                  long posMagic = PositionGetInteger(POSITION_MAGIC);
                  if  (posSymbol == _Symbol && posMagic == MagicNumber)  {
                        count++;
                  }
            }
      }
      return count;
}

bool CanAddAnotherOrder(double currentPrice, ENUM_POSITION_TYPE newOrderType)  {
      if  (!EnableMultiOrderScaling) return false;
      
      if  (g_orderCount >= MaxTotalOpenOrders) return false;
      
      int barsSinceLastOrder = (int)((TimeCurrent() - g_lastOrderTime) / PeriodSeconds(_Period));
      
      if  (g_orderCount == 0)  {
            g_scalingDirection = 0;
            return true;
      }
      
      OrderInfo lastOrder = g_orders[g_orderCount - 1];
      
      if  (lastOrder.type != newOrderType) return false;
      
      double priceDistance = MathAbs(currentPrice - lastOrder.entryPrice);
      double slDistance = MathAbs(lastOrder.initialSL - lastOrder.entryPrice);
      double distancePercent = (priceDistance / slDistance) * 100.0;
      
      bool isWinner = (newOrderType == POSITION_TYPE_BUY && currentPrice > lastOrder.entryPrice) ||
                     (newOrderType == POSITION_TYPE_SELL && currentPrice < lastOrder.entryPrice);
      
      bool isLoser = (newOrderType == POSITION_TYPE_BUY && currentPrice < lastOrder.entryPrice) ||
                    (newOrderType == POSITION_TYPE_SELL && currentPrice > lastOrder.entryPrice);
      
      int proposedDirection = 0;
      if  (isWinner) proposedDirection = 1;
      else if  (isLoser) proposedDirection = -1;
      
      if  (g_scalingDirection == 0)  {
            g_scalingDirection = proposedDirection;
      }  else if  (!AllowMixedScaling && g_scalingDirection != proposedDirection)  {
            return false;
      }
      
      if  (isWinner && ScaleIntoWinners)  {
            int winnersCount = 0;
            for  (int i = 0; i < g_orderCount; i++)  {
                  bool orderIsWinner = (g_orders[i].type == POSITION_TYPE_BUY && g_orders[i].entryPrice > g_orders[0].entryPrice) ||
                                      (g_orders[i].type == POSITION_TYPE_SELL && g_orders[i].entryPrice < g_orders[0].entryPrice);
                  if  (orderIsWinner) winnersCount++;
            }
            
            if  (winnersCount >= MaxScaleInWinners) return false;
            
            if  (distancePercent < WinnerScaleMinDistancePercent) return false;
            
            if  (barsSinceLastOrder < MinBarsBetweenWinnerOrders) return false;
            
            return true;
      }
      
      if  (isLoser && ScaleIntoLosers)  {
            int losersCount = 0;
            for  (int i = 0; i < g_orderCount; i++)  {
                  bool orderIsLoser = (g_orders[i].type == POSITION_TYPE_BUY && g_orders[i].entryPrice < g_orders[0].entryPrice) ||
                                     (g_orders[i].type == POSITION_TYPE_SELL && g_orders[i].entryPrice > g_orders[0].entryPrice);
                  if  (orderIsLoser) losersCount++;
            }
            
            if  (losersCount >= MaxScaleInLosers) return false;
            
            if  (distancePercent < LoserScaleMinDistancePercent) return false;
            
            if  (barsSinceLastOrder < MinBarsBetweenLoserOrders) return false;
            
            return true;
      }
      
      return false;
}

void SyncOrderTracking()  {
      int activeOrders = 0;
      
      for  (int i = 0; i < g_orderCount; i++)  {
            if  (PositionSelectByTicket(g_orders[i].ticket))  {
                  g_orders[i].currentSL = PositionGetDouble(POSITION_SL);
                  activeOrders++;
            }  else  {
                  for  (int j = i; j < g_orderCount - 1; j++)  {
                        g_orders[j] = g_orders[j + 1];
                  }
                  g_orderCount--;
                  i--;
            }
      }
      
      if  (activeOrders == 0)  {
            g_orderCount = 0;
            g_scalingDirection = 0;
      }
}

void checkRConditions()  {
      if  (!IsWithinSession()) return;
      if  (partialCloseRun) return;
      
      for  (int i = 0; i < g_orderCount; i++)  {
            if  (g_orders[i].partialCloseDone) continue;
            
            if  (!PositionSelectByTicket(g_orders[i].ticket)) continue;
            
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            double currentPrice = (posType == POSITION_TYPE_BUY) ? 
                                 SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                                 SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double entryPrice = g_orders[i].entryPrice;
            double initialSL = g_orders[i].initialSL;
            
            double riskDistance = MathAbs(entryPrice - initialSL);
            double currentProfit = (posType == POSITION_TYPE_BUY) ? 
                                  (currentPrice - entryPrice) : 
                                  (entryPrice - currentPrice);
            
            double rMultiple = currentProfit / riskDistance;
            
            if  (rMultiple >= R1PartialPercent)  {
                  double posVolume = PositionGetDouble(POSITION_VOLUME);
                  double closeVolume = NormalizeVolume(_Symbol, posVolume * 0.5);
                  
                  if  (closeVolume >= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))  {
                        if  (PartialCloseByTicket(g_orders[i].ticket, closeVolume))  {
                              g_orders[i].partialCloseDone = true;
                        }
                  }
            }
      }
}

void checkBreakEvenConditions()  {
      for  (int i = 0; i < g_orderCount; i++)  {
            if  (g_orders[i].breakEvenReached) continue;
            
            if  (!PositionSelectByTicket(g_orders[i].ticket)) continue;
            
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            double currentPrice = (posType == POSITION_TYPE_BUY) ? 
                                 SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                                 SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double entryPrice = g_orders[i].entryPrice;
            double initialSL = g_orders[i].initialSL;
            double currentSL = PositionGetDouble(POSITION_SL);
            
            double riskDistance = MathAbs(entryPrice - initialSL);
            double targetDistance = riskDistance * BreakEvenPercent;
            
            bool shouldMoveToBreakEven = false;
            
            if  (posType == POSITION_TYPE_BUY)  {
                  if  (currentPrice >= entryPrice + targetDistance)  {
                        shouldMoveToBreakEven = true;
                  }
            }  else  {
                  if  (currentPrice <= entryPrice - targetDistance)  {
                        shouldMoveToBreakEven = true;
                  }
            }
            
            if  (shouldMoveToBreakEven)  {
                  double newSL = entryPrice + (BreakEvenMarginInPips * GetPipSize() * ((posType == POSITION_TYPE_BUY) ? 1 : -1));
                  
                  bool shouldUpdate = (posType == POSITION_TYPE_BUY && newSL > currentSL) ||
                                    (posType == POSITION_TYPE_SELL && newSL < currentSL);
                  
                  if  (shouldUpdate && ModifyStopLoss(g_orders[i].ticket, newSL))  {
                        g_orders[i].currentSL = newSL;
                        g_orders[i].breakEvenReached = true;
                        
                        if  (SyncStopsAfterBreakEven)  {
                              SyncAllStopsToBreakEven(posType, newSL);
                        }
                  }
            }
      }
}

void SyncAllStopsToBreakEven(ENUM_POSITION_TYPE posType, double referenceSL)  {
      for  (int i = 0; i < g_orderCount; i++)  {
            if  (!PositionSelectByTicket(g_orders[i].ticket)) continue;
            
            if  (g_orders[i].type != posType) continue;
            
            double entryPrice = g_orders[i].entryPrice;
            double minProtection = MinStopProtectionPips * GetPipSize();
            double targetSL = entryPrice + (minProtection * ((posType == POSITION_TYPE_BUY) ? 1 : -1));
            
            double currentSL = PositionGetDouble(POSITION_SL);
            
            bool shouldUpdate = (posType == POSITION_TYPE_BUY && targetSL > currentSL) ||
                              (posType == POSITION_TYPE_SELL && targetSL < currentSL);
            
            if  (shouldUpdate && ModifyStopLoss(g_orders[i].ticket, targetSL))  {
                  g_orders[i].currentSL = targetSL;
                  g_orders[i].breakEvenReached = true;
            }
      }
}

void checkTrailingStopConditions()  {
      double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      
      for  (int i = 0; i < g_orderCount; i++)  {
            if  (!PositionSelectByTicket(g_orders[i].ticket)) continue;
            
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            double entryPrice = g_orders[i].entryPrice;
            double initialSL = g_orders[i].initialSL;
            double currentSL = PositionGetDouble(POSITION_SL);
            
            double riskDistance = MathAbs(entryPrice - initialSL);
            
            if  (posType == POSITION_TYPE_BUY)  {
                  double currentProfit = currentBid - entryPrice;
                  double rMultiple = currentProfit / riskDistance;
                  
                  double marginPips = (rMultiple >= ProfitThresholdForTightening) ? 
                                     TrailingStopTightMarginInPips : 
                                     TrailingStopEarlyStageMarginInPips;
                  
                  double newTS = currentBid - (marginPips * GetPipSize());
                  
                  if  (newTS > currentSL)  {
                        if  (ModifyStopLoss(g_orders[i].ticket, newTS))  {
                              g_orders[i].currentSL = newTS;
                        }
                  }
            }  else if  (posType == POSITION_TYPE_SELL)  {
                  double currentProfit = entryPrice - currentAsk;
                  double rMultiple = currentProfit / riskDistance;
                  
                  double marginPips = (rMultiple >= ProfitThresholdForTightening) ? 
                                     TrailingStopTightMarginInPips : 
                                     TrailingStopEarlyStageMarginInPips;
                  
                  double newTS = currentAsk + (marginPips * GetPipSize());
                  
                  if  (newTS < currentSL)  {
                        if  (ModifyStopLoss(g_orders[i].ticket, newTS))  {
                              g_orders[i].currentSL = newTS;
                        }
                  }
            }
      }
}

void checkTradesOffSession()  {
      if  (IsWithinSession()) return;
      
      MqlDateTime dtStruct;
      datetime currentTime = TimeCurrent(dtStruct);
      
      int currentDayOfYear = dtStruct.day_of_year;
      int lastProcessedDay = 0;
      
      if  (g_lastOffSessionProcessedDate > 0)  {
            MqlDateTime lastDtStruct;
            TimeToStruct(g_lastOffSessionProcessedDate, lastDtStruct);
            lastProcessedDay = lastDtStruct.day_of_year;
      }
      
      if  (currentDayOfYear == lastProcessedDay) return;
      
      if  (!IsWithinSessionTime(OutOfSessionCloseTime, "23:59")) return;
      
      if  (HandleOrdersOutOfSession == OffSessionBreakEven)  {
            for  (int i = 0; i < g_orderCount; i++)  {
                  if  (!PositionSelectByTicket(g_orders[i].ticket)) continue;
                  
                  ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
                  double entryPrice = g_orders[i].entryPrice;
                  double currentSL = PositionGetDouble(POSITION_SL);
                  
                  double newSL = entryPrice + (BreakEvenMarginInPips * GetPipSize() * ((posType == POSITION_TYPE_BUY) ? 1 : -1));
                  
                  bool shouldUpdate = (posType == POSITION_TYPE_BUY && newSL > currentSL) ||
                                    (posType == POSITION_TYPE_SELL && newSL < currentSL);
                  
                  if  (shouldUpdate)  {
                        ModifyStopLoss(g_orders[i].ticket, newSL);
                  }
            }
      }  else if  (HandleOrdersOutOfSession == OffSessionCloseOrder)  {
            CloseAllOrders();
      }
      
      g_lastOffSessionProcessedDate = currentTime;
}

bool IsNewBar()  {
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime != g_lastBarTime)  {
      g_lastBarTime = currentBarTime;
      return true;
   }
   return false;
}

void UpdateATRCache()  {
   GetAdaptiveATRChannelByIndex(adaptiveATRHandle112, 112, 0, g_cachedCentral112, g_cachedUpper112, g_cachedLower112);
   GetAdaptiveATRChannelByIndex(adaptiveATRHandle20, 20, 0, g_cachedCentral20, g_cachedUpper20, g_cachedLower20);
   g_lastATRUpdate = iTime(_Symbol, _Period, 0);
}

void OnTick()  {
   g_tickCounter++;
   
   if(g_tickCounter % SYNC_ORDER_INTERVAL == 0)  {
      SyncOrderTracking();
   }
   
   if(g_tickCounter % SYNC_ORDER_INTERVAL == 0)  {
      checkTradesOffSession();
   }
   
   if(g_orderCount > 0)  {
      if(g_orderCount == 1)  {
         gTicket = g_orders[0].ticket;
         gInitialSL = g_orders[0].initialSL;
      }
      
      bool isNewBar = IsNewBar();
      if(isNewBar && !partialCloseRun)  {
         checkRConditions();
      }
      
      if(isNewBar)  {
         checkBreakEvenConditions();
      }
      
      if(g_tickCounter % TRAILING_STOP_INTERVAL == 0)  {
         checkTrailingStopConditions();
      }
      
      if(EnableMultiOrderScaling && g_orderCount < MaxTotalOpenOrders && isNewBar)  {
         UpdateATRCache();
         checkTradeConditions();
      }
   } else  {
      gTicket = 0;
      gInitialSL = 0.0;
      breakEvenRun = false;
      partialCloseRun = false;
      g_lastTrailingStopBuy = 0.0;
      g_lastTrailingStopSell = 0.0;
      
      if(IsNewBar())  {
         UpdateATRCache();
         checkTradeConditions();
      }
   }
}

int OnInit()  {
      trade.SetExpertMagicNumber(MagicNumber);
      trade.SetMarginMode();
      trade.SetTypeFillingBySymbol(_Symbol);
      
      adaptiveATRHandle112 = iCustom(_Symbol, _Period, "Indicators\\AdaptiveATRChannel", 
                                    IndicatorPeriod, ATRMultiplier, AppliedPrice);
      adaptiveATRHandle20 = iCustom(_Symbol, _Period, "Indicators\\AdaptiveATRChannel", 
                                    20, ATRMultiplier, AppliedPrice);
      
      if  (adaptiveATRHandle112 == INVALID_HANDLE || adaptiveATRHandle20 == INVALID_HANDLE)  {
            return INIT_FAILED;
      }
      
      /*if  (UseADXFilter)  {
            adxHandle = iADX(_Symbol, _Period, ADXPeriod);
            if  (adxHandle == INVALID_HANDLE)  {
                  return INIT_FAILED;
            }
      }*/
      
      EventSetMillisecondTimer(100);
      
      g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_dailyLimitReached = false;
      
      return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)  {
      if  (adaptiveATRHandle112 != INVALID_HANDLE) IndicatorRelease(adaptiveATRHandle112);
      if  (adaptiveATRHandle20 != INVALID_HANDLE) IndicatorRelease(adaptiveATRHandle20);
      if  (adxHandle != INVALID_HANDLE) IndicatorRelease(adxHandle);
      EventKillTimer();
}

/*void OnTimer()  {
      CheckDailyLimits();
}*/