//+------------------------------------------------------------------+
//|                                             ShedAdvisorMark24.mq5|
//|                                                     Stelios Zlat |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
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

//======================== Inlined ShedTradeHelper ========================//

input double RiskPercent = 0.1;         // Risk per trade (not wired into triggers to preserve your behavior)
input int    MagicNumber = 12345;
input int    IndicatorPeriod = 112;     // ATR Indicator Period
input double ATRMultiplier = 1.0;       // ATR Multiplier
input ENUM_APPLIED_PRICE AppliedPrice = PRICE_CLOSE; // Price type for indicator
input string TradingSessionJapanStart  = "01:30";
input string TradingSessionJapanEnd    = "06:00";
input string TradingSessionEuropeStart = "06:00";
input string TradingSessionEuropeEnd   = "13:00";
input string TradingSessionUSAStart    = "13:00";
input string TradingSessionUSAEnd      = "23:00";

input int    lookback = 5;
input int    TimerIntervalSeconds = 180;
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
input int    SpreadAddedToStop = 15;
input double BreakoutRetracementHigh = 70.0;
input double BreakoutRetracementLow = 10.0;
input double OrderCloseToRetracementPercent = 30.0;
input ATRSelect ATRUsedInStopLossCalculation = ATRAlwaysWider;
input string OutOfSessionCloseTime = "23:00";
input OffSessionHandling HandleOrdersOutOfSession = OffSessionCloseOrder;
input bool   UseADXFilter = true;          // Enable ADX Trend Filter
input int    ADXPeriod = 14;               // ADX Period

// ===== Spread and Volatility Filtering =====
input bool   UseSpreadFilter = true;                    // Enable Spread Filter
input double NormalSpreadPips = 0.8;                     // Baseline Normal Spread (pips)
input double MaxSpreadForEntry = 2.0;                    // Max Spread to Allow Entry (pips)
input bool   UseATRVolatilityAdjustment = true;          // Adjust spread limits by ATR width
input double SpreadToATRRatio = 0.15;                    // Allow wider spread if ATR ratio exceeds this (15%)
input double ExtremeSpreagMultiplier = 4.0;              // Pause stop modifications at 4x normal spread

input bool   UseMinimumVolatilityFilter = true;          // Block trades in narrow markets
input double MinimumATRChannelWidthPips = 15.0;          // Minimum channel width in pips
input double ATRRatioThresholdForWideSpread = 1.5;       // ATR112/ATR20 ratio to allow wider spreadsinput bool   
input bool   UseDailyLimits = true;                      // Enable daily profit/loss limits
// ===== Multi-Order Scaling System =====
input bool   EnableMultiOrderScaling = false;          // Master switch for all scaling features

// --- Scaling into Losers (Averaging Down) ---
input bool   ScaleIntoLosers = false;                  // Allow adding orders when price moves against us
input int    MaxScaleInLosers = 2;                     // Max additional orders when averaging down (1-2, so total 3)
input double LoserScaleMinDistancePercent = 40.0;      // Min distance from previous order (% of its SL distance)
input double LoserOrder2LotMultiplier = 1.0;           // Lot size multiplier for 2nd loser order (1.0 = same as first)
input double LoserOrder3LotMultiplier = 1.0;           // Lot size multiplier for 3rd loser order
input int    MinBarsBetweenLoserOrders = 1;            // Minimum bars between loser orders (0 = same bar allowed)

// --- Scaling into Winners (Pyramiding) ---
input bool   ScaleIntoWinners = true;                  // Allow adding orders when price moves in our favor
input int    MaxScaleInWinners = 2;                    // Max additional orders when pyramiding (1-2, so total 3)
input double WinnerScaleMinDistancePercent = 50.0;     // Min distance from previous order (% of its SL distance)
input double WinnerOrder2LotMultiplier = 0.8;          // Lot size multiplier for 2nd winner order (0.8 = 80% of calculated size)
input double WinnerOrder3LotMultiplier = 0.6;          // Lot size multiplier for 3rd winner order (0.6 = 60% of calculated size)
input int    MinBarsBetweenWinnerOrders = 1;           // Minimum bars between winner orders

// --- Stop Loss Synchronization ---
input bool   SyncStopsAfterBreakEven = true;           // Sync all orders' stops once each reaches break-even
input double MinStopProtectionPips = 2.0;              // Minimum pips above entry when syncing stops

// --- Safety Limits ---
input int    MaxTotalOpenOrders = 8;                   // Absolute max orders open at once (1-20)
input bool   AllowMixedScaling = false;                // Allow mixing loser + winner scaling in same sequence
input double MaxDailyProfitPercent = 5.0;
input double MaxDailyLossPercent = 2.0;

datetime g_lastResetDate = 0;
double g_dailyStartBalance = 0.0;
bool g_dailyLimitReached = false;
datetime g_lastBarTime = 0; // For new candle detection
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
bool g_extremeSpreadActive = false; // Tracks if extreme spread is active
// Multi-order tracking structures
struct OrderInfo {
   ulong ticket;
   double entryPrice;
   double initialSL;
   double currentSL;
   ENUM_POSITION_TYPE type;
   bool breakEvenReached;
   datetime openTime;
   int orderSequence;  // 1=first, 2=second, 3=third
   bool partialCloseDone;
};

OrderInfo g_orders[20];
int g_orderCount = 0;
datetime g_lastOrderTime = 0;
int g_scalingDirection = 0;  // 0=none, 1=winners, -1=losers

double CalculateLotSize(double stopLoss, double riskPercent=1.0) {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * (riskPercent / 100.0);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double volumeStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if (point <= 0 || tickValue <= 0 || volumeStep <= 0 || riskMoney <= 0) {
      Print("[ERROR]: CalculateLotSize Invalid inputs");
      return 0.0;
   }
   
   double stopLossPoints = MathRound(stopLoss / point);
   if (stopLossPoints <= 0) {
      Print("[ERROR]: CalculateLotSize Stop Loss less than 0");
      return 0.0;
   }

   double valuePerLot = stopLossPoints * tickValue;
   if (valuePerLot <= 0) {
      Print("[ERROR]: CalculateLotSize Invalid value per lot");
      return 0.0;
   }

   double lotSize = riskMoney / valuePerLot;
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lotSize = MathMax(minLot, lotSize);
   lotSize = MathMin(maxLot, lotSize);
   lotSize = MathFloor(lotSize / volumeStep + 0.000000001) * volumeStep;

   if (lotSize < minLot || lotSize > maxLot) {
      Print("[ERROR]: CalculateLotSize Lot Size out of bounds");
      return 0.0;
   }

   return lotSize;
}

double CalculateEfficiencyRatio(int period, int index, const double &closed[]) {
   if (index < period || period <= 0) return 0.0;

   double change = MathAbs(closed[index] - closed[index - period]);
   double volatility = 0.0;

   for (int k = 0; k < period ; k++) {
      volatility += MathAbs(closed[index - k] - closed[index - k - 1]);
   }

   if (volatility == 0.0) {
      return volatility;
   }

   return change / volatility;
}

double CalculateInitialStopLossWidth(double channelWidth, double channel20Width) {
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long spread = SpreadAddedToStop; // SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double spreadInPrice = spread * point;
   double channel = channelWidth;
   switch (ATRUsedInStopLossCalculation) {
      case ATRAlwaysWider:
         if (channelWidth < channel20Width) {
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

bool TriggerSellOrder(double channelWidth, double channel20Width, double riskPercent=0.1, int magicNumber=12345) {
   if (channelWidth <= 0) {
      Print("[ERROR] TriggerSellOrder invalid channel width: ", channelWidth);
      return false;
   }

   double entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double SL = NormalizeDouble(entryPrice + CalculateInitialStopLossWidth(channelWidth, channel20Width), _Digits) + InitialStopLossMarginInPips * GetPipSize();
   double takeProfitMultiplier = TakeProfitMultiplier != 0.0 ? TakeProfitMultiplier : 1.5;

   double baseVolume = CalculateLotSize(SL - entryPrice, 1.0);
   double volume = baseVolume;
   
   // Apply lot multiplier based on order sequence
   if (g_orderCount > 0) {
      if (g_scalingDirection == 1) {  // Scaling into winners
         if (g_orderCount == 1) volume = NormalizeVolume(_Symbol, baseVolume * WinnerOrder2LotMultiplier);
         else if (g_orderCount == 2) volume = NormalizeVolume(_Symbol, baseVolume * WinnerOrder3LotMultiplier);
      } else if (g_scalingDirection == -1) {  // Scaling into losers
         if (g_orderCount == 1) volume = NormalizeVolume(_Symbol, baseVolume * LoserOrder2LotMultiplier);
         else if (g_orderCount == 2) volume = NormalizeVolume(_Symbol, baseVolume * LoserOrder3LotMultiplier);
      }
   }

   if (volume <= 0) {
      Print("[ERROR] TriggerSellOrder invalid volume ", volume);
      return false;
   }

   trade.SetExpertMagicNumber(magicNumber);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(_Symbol);

   if (trade.Sell(volume, _Symbol, entryPrice, SL, 0.0, "Sell Order: ATR Channel Retracement")) {
      ulong dealTicket = trade.ResultDeal();
      double tradeEntryPrice = trade.ResultPrice();
      double tradeInitialStopLoss = SL;
      double tradeChannelWidth = channelWidth;
      
      // Store order info
      if (g_orderCount < MaxTotalOpenOrders) {
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
      
      PrintFormat("[SELL #%d] (#%d): V=%.2f @ %.5f, SL=%.5f (Channel Width=%.5f)", 
                  g_orderCount, dealTicket, volume, tradeEntryPrice, tradeInitialStopLoss, tradeChannelWidth);
      return true;
   } else {
      Print("[FAIL] Sell Order Failed: ", trade.ResultRetcodeDescription(), " (Code: ", trade.ResultRetcode(), ")");
      return false;
   }
}

bool TriggerBuyOrder(double channelWidth, double channel20Width, double riskPercent=0.1, int magicNumber=12345) {
   if (channelWidth <= 0) {
      Print("[ERROR] TriggerBuyOrder invalid channel width: ", channelWidth);
      return false;
   }

   double entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double SL = NormalizeDouble(entryPrice - CalculateInitialStopLossWidth(channelWidth, channel20Width), _Digits) - InitialStopLossMarginInPips * GetPipSize();
   double takeProfitMultiplier = TakeProfitMultiplier != 0.0 ? TakeProfitMultiplier : 1.5;

   double baseVolume = CalculateLotSize(entryPrice - SL, 1.0);
   double volume = baseVolume;
   
   // Apply lot multiplier based on order sequence
   if (g_orderCount > 0) {
      if (g_scalingDirection == 1) {  // Scaling into winners
         if (g_orderCount == 1) volume = NormalizeVolume(_Symbol, baseVolume * WinnerOrder2LotMultiplier);
         else if (g_orderCount == 2) volume = NormalizeVolume(_Symbol, baseVolume * WinnerOrder3LotMultiplier);
      } else if (g_scalingDirection == -1) {  // Scaling into losers
         if (g_orderCount == 1) volume = NormalizeVolume(_Symbol, baseVolume * LoserOrder2LotMultiplier);
         else if (g_orderCount == 2) volume = NormalizeVolume(_Symbol, baseVolume * LoserOrder3LotMultiplier);
      }
   }

   if (volume <= 0) {
      Print("[ERROR] TriggerBuyOrder invalid volume ", volume);
      return false;
   }

   trade.SetExpertMagicNumber(magicNumber);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(_Symbol);

   if (trade.Buy(volume, _Symbol, 0.0, SL, 0.0, "Buy Order: ATR Channel Retracement")) {
      ulong dealTicket = trade.ResultDeal();
      double tradeEntryPrice = trade.ResultPrice();
      double tradeInitialStopLoss = SL;
      double tradeChannelWidth = channelWidth;
      
      // Store order info
      if (g_orderCount < MaxTotalOpenOrders) {
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
      
      PrintFormat("[BUY #%d] (#%d): V=%.2f @ %.5f, SL=%.5f (Channel Width=%.5f)", 
                  g_orderCount, dealTicket, volume, tradeEntryPrice, tradeInitialStopLoss, tradeChannelWidth);
      return true;
   } else {
      Print("[FAIL] Buy Order Failed: ", trade.ResultRetcodeDescription(), " (Code: ", trade.ResultRetcode(), ")");
      return false;
   }
}

bool ModifyStopLoss(ulong ticket, double TS) {

   if(!PositionSelectByTicket(ticket)) {
      Print("Failed to select position with ticket: ", ticket);
      return false;
   }
   
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double current_price = PositionGetDouble(POSITION_PRICE_OPEN);
   double current_sl = PositionGetDouble(POSITION_SL);
   double current_tp = PositionGetDouble(POSITION_TP);
   string symbol = PositionGetString(POSITION_SYMBOL);
   
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   long stopsLevel = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance = stopsLevel * point;
   
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   
   TS = NormalizeDouble(TS, _Digits);
   
   if (posType == POSITION_TYPE_BUY) {
      if (TS >= bid) {
         Print("[ERROR] BUY Stop Loss ", TS, " must be below Bid ", bid);
         return false;
      }
      if (bid - TS < minDistance) {
         Print("[ERROR] BUY Stop Loss too close to market. Distance: ", (bid - TS)/point, " pts, Required: ", stopsLevel, " pts");
         return false;
      }
      if (current_sl > 0 && TS <= current_sl) {
         return false;
      }
   } else {
      if (TS <= ask) {
         Print("[ERROR] SELL Stop Loss ", TS, " must be above Ask ", ask);
         return false;
      }
      if (TS - ask < minDistance) {
         Print("[ERROR] SELL Stop Loss too close to market. Distance: ", (TS - ask)/point, " pts, Required: ", stopsLevel, " pts");
         return false;
      }
      if (current_sl > 0 && TS >= current_sl) {
         return false;
      }
   }
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol = symbol;
   request.sl = TS;
   request.tp = current_tp;
   
   if(OrderSend(request, result)) {
      Print("[MODIFY] Stop Loss modified successfully for ticket: ", ticket, " New SL: ", TS);
      return true;
   } else {
      Print("[ERROR] Failed to modify Stop Loss. Error: ", result.retcode, " - ", result.comment);
      return false;
   }
}

bool TriggerPartialCloseOrder(double lot) {
   // This function now works with PositionSelectByTicket already called
   ulong ticket = PositionGetInteger(POSITION_TICKET);
   
   double current_lot = PositionGetDouble(POSITION_VOLUME);
   
   if(lot >= current_lot) {
      Print("[ERROR] Cannot close ", lot, " >= ", current_lot);
      return false;
   }
   
   if (trade.PositionClosePartial(ticket, lot)) {
      Print("[PARTIAL_CLOSE] at ", lot, " for ticket ", ticket);
      return true;
   }
   
   Print("[ERROR] Partial close failed!");
   Print("  Error Code: ", GetLastError());
   Print("  RetCode: ", trade.ResultRetcode());
   Print("  Description: ", trade.ResultRetcodeDescription());
   
   return false;
}

void checkTradeConditions() {
   //Print("[DEBUG checkTradeConditions] Function called");
   ENUM_TIMEFRAMES timeframe = _Period;
   
   // if (!IsNewBar()) {
//    Print("[DEBUG checkTradeConditions] NOT a new bar - exiting");
//    return;
// }
   //Print("[DEBUG checkTradeConditions] Checking conditions (IsNewBar disabled for testing)");
   
   //Print("[DEBUG checkTradeConditions] NEW BAR detected - checking conditions");
   
   double central, upper, lower, central20, upper20, lower20;
   GetAdaptiveATRChannelByIndex(adaptiveATRHandle112, 112, 0, central, upper, lower);
   GetAdaptiveATRChannelByIndex(adaptiveATRHandle20, 20, 0,  central20, upper20, lower20);
   
   double channelWidth = upper - lower; // NOTE: This is in price units.
   double channel20Width = upper20 - lower20;

   double currClose = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currOpen  = iOpen(_Symbol, timeframe, 0);
   double prevClose = iClose(_Symbol, timeframe, 1);
   double prevOpen  = iOpen(_Symbol, timeframe, 1);
   double lastPrevOpen = iOpen(_Symbol, timeframe, 2);
   double lastPrevClose = iClose(_Symbol, timeframe,2);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   /*Print("[DEBUG SELL] currClose(" + DoubleToString(currClose, _Digits) + ") < lower(" + DoubleToString(lower, _Digits) + ") = " + (currClose < lower ? "true" : "false"));
   Print("[DEBUG SELL] central20(" + DoubleToString(central20, _Digits) + ") < lower(" + DoubleToString(lower, _Digits) + ") = " + (central20 < lower ? "true" : "false"));
   Print("[DEBUG SELL] currOpen(" + DoubleToString(currOpen, _Digits) + ") < prevOpen(" + DoubleToString(prevOpen, _Digits) + ") = " + (currOpen < prevOpen ? "true" : "false"));
   Print("[DEBUG SELL] prevOpen(" + DoubleToString(prevOpen, _Digits) + ") > prevClose(" + DoubleToString(prevClose, _Digits) + ") = " + (prevOpen > prevClose ? "true" : "false"));
   Print("[DEBUG SELL] lastPrevOpen(" + DoubleToString(lastPrevOpen, _Digits) + ") < lastPrevClose(" + DoubleToString(lastPrevClose, _Digits) + ") = " + (lastPrevOpen < lastPrevClose ? "true" : "false"));
   */
   /*if ((prevClose - prevOpen) < point * 10) {
      return;
   }*/
   //Print("Current Open: ", currOpen, ", current Close: ", currClose, " Previous Open: ", prevOpen, " Previous Close: ", prevClose);
   // keep this as the initial state and keep looking back for higher highs and lower lows to find the retracement swing.
   if (currClose > upper && central20 > upper && currOpen > prevOpen && prevOpen < prevClose && lastPrevOpen > lastPrevClose) {
      Print("BREAKOUT_BUY POSSIBLE ORDER");
      findRetracementBuySwing();
      double retracementSwing = retracementBuyHigh - retracementBuyLow;
      double breakoutSwing = breakoutBuyHigh - breakoutBuyLow;
      
      //Print("BREAKOUT SWING ", breakoutSwing);
      //Print("RETRACEMENT SWING", retracementSwing);
      
      double retracementPercent = 100 - retracementSwing / breakoutSwing * 100;        // this watches the retracement with 0% at the bottom of the breakout and the 100% at the top
      Print("RETRACEMENT PERCENT ", retracementPercent, " %");
      
      double orderPlacementToRetracement = (retracementBuyHigh - currClose) / retracementSwing * 100; // this watces the order close with 0% at the top and the 100% at the bottom (the retracement low)
      Print("ORDER PLACEMENT TO RETRACEMENT ", orderPlacementToRetracement, " %");
                     bool canTrade = false;
         if (EnableMultiOrderScaling) {
            canTrade = GetOpenOrderCount() < MaxTotalOpenOrders && CanAddAnotherOrder(currClose, POSITION_TYPE_BUY);
         } else {
            canTrade = !SelectPositionByMagic(_Symbol);
         }
         
         if (IsWithinSession() && canTrade && CheckDailyLimits() && IsTrendingMarket() &&
             !IsMarketTooNarrow(channelWidth, channel20Width) && 
             IsSpreadAcceptable(channelWidth, channel20Width) &&
             retracementPercent >= BreakoutRetracementLow && retracementPercent <= BreakoutRetracementHigh && orderPlacementToRetracement >= OrderCloseToRetracementPercent) {
            if (TriggerBuyOrder(channelWidth, channel20Width)) {
               g_lastOrderTime = TimeCurrent();
               partialCloseRun = false;
            }
         }
      
      breakoutBuyHigh = 0.0;
      breakoutBuyLow = 0.0;
      retracementBuyHigh = 0.0;
      retracementBuyLow = 0.0;
   }

   // This triggers a possible sell order and checks for retracement
   /*Print("[DEBUG SELL] currClose(" + DoubleToString(currClose, _Digits) + ") < lower(" + DoubleToString(lower, _Digits) + ") = " + (currClose < lower ? "true" : "false"));
   Print("[DEBUG SELL] central20(" + DoubleToString(central20, _Digits) + ") < lower(" + DoubleToString(lower, _Digits) + ") = " + (central20 < lower ? "true" : "false"));
   Print("[DEBUG SELL] currOpen(" + DoubleToString(currOpen, _Digits) + ") < prevOpen(" + DoubleToString(prevOpen, _Digits) + ") = " + (currOpen < prevOpen ? "true" : "false"));
   Print("[DEBUG SELL] prevOpen(" + DoubleToString(prevOpen, _Digits) + ") > prevClose(" + DoubleToString(prevClose, _Digits) + ") = " + (prevOpen > prevClose ? "true" : "false"));
   Print("[DEBUG SELL] lastPrevOpen(" + DoubleToString(lastPrevOpen, _Digits) + ") < lastPrevClose(" + DoubleToString(lastPrevClose, _Digits) + ") = " + (lastPrevOpen < lastPrevClose ? "true" : "false"));
   */
   if (currClose < lower && central20 < lower && currOpen < prevOpen && prevOpen > prevClose && lastPrevOpen < lastPrevClose)  {
      Print("BREAKOUT_SELL POSSIBLE ORDER");
      findRetracementSellSwing();
      double retracementSwing = retracementSellHigh - retracementSellLow;
      double breakoutSwing = breakoutSellHigh - breakoutSellLow;
      
      //Print("BREAKOUT SWING ", breakoutSwing);
      //Print("RETRACEMENT SWING", retracementSwing);
      
      double retracementPercent = 100 - retracementSwing / breakoutSwing * 100;  // this watches the retracement with 0% at the bottom of the breakout and the 100% at the top
      Print("RETRACEMENT PERCENT ", retracementPercent, " %");
      
      double orderPlacementToRetracement = 100 - (currClose - retracementSellLow) / retracementSwing * 100; // this watces the order close with 0% at the bottom and the 100% at the top (the retracement low)      
      Print("ORDER PLACEMENT TO RETRACEMENT ", orderPlacementToRetracement, " %");
                      bool canTrade = false;
         if (EnableMultiOrderScaling) {
            canTrade = GetOpenOrderCount() < MaxTotalOpenOrders && CanAddAnotherOrder(currClose, POSITION_TYPE_SELL);
         } else {
            canTrade = !SelectPositionByMagic(_Symbol);
         }
         
         if (IsWithinSession() && canTrade && CheckDailyLimits() && IsTrendingMarket() &&
             !IsMarketTooNarrow(channelWidth, channel20Width) && 
             IsSpreadAcceptable(channelWidth, channel20Width) &&
             retracementPercent >= BreakoutRetracementLow && retracementPercent <= BreakoutRetracementHigh && orderPlacementToRetracement >= OrderCloseToRetracementPercent) {
            if (TriggerSellOrder(channelWidth, channel20Width)) {
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

void findRetracementBuySwing() {
   int index = 1;
   double previousOpen = iOpen(_Symbol, _Period, index + 1);
   double previousClose = iClose(_Symbol, _Period, index + 1);
   double currentLow = iLow(_Symbol, _Period, index);
   double previousLow = iLow(_Symbol, _Period, index + 1);
   double currentHigh = iHigh(_Symbol, _Period, index + 1);
   double previousHigh = iHigh(_Symbol, _Period, index + 1);
   retracementBuyLow = currentLow;
   retracementBuyHigh = currentHigh;
   while(previousOpen > previousClose) {
      if (previousHigh > retracementBuyHigh) {
         //Print("HIGH ", previousHigh, " higher than ",  currentHigh);
         retracementBuyHigh = previousHigh;
      }
      
      if (previousLow < retracementBuyLow) {
         //Print("LOW ", previousLow, " lower than ",  currentLow);
         retracementBuyLow = previousLow;
      }
      
      currentHigh = previousHigh;
      //Print("Current High: ", currentHigh);
      currentLow = previousLow;
      //Print("Current Low: ", currentLow);
      index++;
      previousLow = iLow(_Symbol, _Period, index + 1);
      previousHigh = iHigh(_Symbol, _Period, index + 1);
      previousOpen = iOpen(_Symbol, _Period, index + 1);
      previousClose = iClose(_Symbol, _Period, index + 1);
   }
   if (previousHigh > retracementBuyHigh) {
      //Print("HIGH ", previousHigh, " higher than ",  currentHigh);
      retracementBuyHigh = previousHigh;
   }
   
   if (previousLow < retracementBuyLow) {
      //Print("LOW ", previousLow, " lower than ",  currentLow);
      retracementBuyLow = previousLow;
   }
   
   currentHigh = previousHigh;
   //Print("Current High: ", currentHigh);
   currentLow = previousLow;
   //Print("Current Low: ", currentLow);
   index++;
   previousLow = iLow(_Symbol, _Period, index + 1);
   previousHigh = iHigh(_Symbol, _Period, index + 1);
   previousOpen = iOpen(_Symbol, _Period, index + 1);
   previousClose = iClose(_Symbol, _Period, index + 1);
   
   breakoutBuyHigh = retracementBuyHigh;
   breakoutBuyLow = currentLow;
   while (previousOpen < previousClose) {
      if (previousLow < breakoutBuyLow) {
         //Print("LOW ", previousLow, " lower than ",  currentLow);
         breakoutBuyLow = previousLow;
      }
      
      if (previousHigh > breakoutBuyHigh) {
         //Print("HIGH ", previousHigh, " higher than ",  currentHigh);
         breakoutBuyHigh = previousHigh;
      }
      index++;
      currentLow = previousLow;
      previousLow = iLow(_Symbol, _Period, index + 1);
      currentHigh = previousHigh;
      previousHigh = iHigh(_Symbol, _Period, index + 1);
      previousOpen = iOpen(_Symbol, _Period, index + 1);
      previousClose = iClose(_Symbol, _Period, index + 1);
   }
   
   /*while(previousLow < breakoutBuyLow ) {
      breakoutBuyLow = previousLow;
      index++;
      previousLow = iLow(_Symbol, _Period, index + 1);
   }*/
   Print("BREAKOUT BUY:    LOW ", breakoutBuyLow, ", HIGH ", breakoutBuyHigh, ", DIFF ", breakoutBuyHigh - breakoutBuyLow);
   Print("RETRACEMENT BUY: LOW ", retracementBuyLow, ", HIGH ", retracementBuyHigh, ", DIFF ", retracementBuyHigh- retracementBuyLow);
}

// finds retracement swing for sell orders   
void findRetracementSellSwing() {
   int index = 1;
   double previousOpen = iOpen(_Symbol, _Period, index + 1);
   double previousClose = iClose(_Symbol, _Period, index + 1);
   double currentLow = iLow(_Symbol, _Period, index + 1);
   double previousLow = iLow(_Symbol, _Period, index + 1);
   double currentHigh = iHigh(_Symbol, _Period, index);
   double previousHigh = iHigh(_Symbol, _Period, index + 1);
   retracementSellLow = currentLow;
   retracementSellHigh = currentHigh;
   while(previousOpen < previousClose) {
      if (previousHigh > retracementSellHigh) {
         //Print("HIGH ", previousHigh, " higher than ",  currentHigh);
         retracementSellHigh = previousHigh;
      }
      
      if (previousLow < retracementSellLow) {
         //Print("LOW ", previousLow, " lower than ",  currentLow);
         retracementSellLow = previousLow;
      }
      
      currentHigh = previousHigh;
      //Print("Current High: ", currentHigh);
      currentLow = previousLow;
      //Print("Current Low: ", currentLow);
      index++;
      previousLow = iLow(_Symbol, _Period, index + 1);
      previousHigh = iHigh(_Symbol, _Period, index + 1);
      previousOpen = iOpen(_Symbol, _Period, index + 1);
      previousClose = iClose(_Symbol, _Period, index + 1);
   }
   if (previousHigh > retracementSellHigh) {
      //Print("HIGH ", previousHigh, " higher than ",  currentHigh);
      retracementSellHigh = previousHigh;
   }
   
   if (previousLow < retracementSellLow) {
      //Print("LOW ", previousLow, " lower than ",  currentLow);
      retracementSellLow = previousLow;
   }
   breakoutSellHigh = currentHigh;
   breakoutSellLow = currentLow;
   currentHigh = previousHigh;
   //Print("Current High: ", currentHigh);
   currentLow = previousLow;
   //Print("Current Low: ", currentLow);
   index++;
   previousLow = iLow(_Symbol, _Period, index + 1);
   previousHigh = iHigh(_Symbol, _Period, index + 1);
   previousOpen = iOpen(_Symbol, _Period, index + 1);
   previousClose = iClose(_Symbol, _Period, index + 1);
   while (previousOpen > previousClose) {
      if (previousLow < breakoutSellLow) {
         //Print("LOW ", previousLow, " lower than ",  currentLow);
         breakoutSellLow = previousLow;
      }
      
      if (previousHigh > breakoutSellHigh) {
         //Print("HIGH ", previousHigh, " higher than ",  currentHigh);
         breakoutSellHigh = previousHigh;
      }
      index++;
      currentLow = previousLow;
      previousLow = iLow(_Symbol, _Period, index + 1);
      currentHigh = previousHigh;
      previousHigh = iHigh(_Symbol, _Period, index + 1);
      previousOpen = iOpen(_Symbol, _Period, index + 1);
      previousClose = iClose(_Symbol, _Period, index + 1);
   }
   if (previousLow < breakoutSellLow) {
      //Print("LOW ", previousLow, " lower than ",  currentLow);
      breakoutSellLow = previousLow;
   }
      
   if (previousHigh > breakoutSellHigh) {
      //Print("HIGH ", previousHigh, " higher than ",  currentHigh);
      breakoutSellHigh = previousHigh;
   }

   /*while(previousLow < breakoutBuyLow ) {
      breakoutBuyLow = previousLow;
      index++;
      previousLow = iLow(_Symbol, _Period, index + 1);
   }*/
   Print("BREAKOUT SELL:    LOW ", breakoutSellLow, ", HIGH ", breakoutSellHigh, ", DIFF ", breakoutSellHigh - breakoutSellLow);
   Print("RETRACEMENT SELL: LOW ", retracementSellLow, ", HIGH ", retracementSellHigh, ", DIFF ", retracementSellHigh- retracementSellLow);
}

bool isATRWiderThan(int length, double value) {
   double central, upper, lower;
   int handleToUse = (length == 112) ? adaptiveATRHandle112 : adaptiveATRHandle20;
   GetAdaptiveATRChannelByIndex(handleToUse, length, 0, central, upper, lower);
   
   double channelWidth = upper - lower; // NOTE: This is in price units.

   return channelWidth > value;
}

// Use deepest order for ALL stop management decisions
void checkBreakEvenConditions() {
    int deepestIdx = GetDeepestOrderIndex();
    if (deepestIdx < 0) return;
    
    double deepestEntry = g_orders[deepestIdx].entryPrice;
    double deepestSL = g_orders[deepestIdx].initialSL;
    double stopDistance = MathAbs(deepestEntry - deepestSL);
    
    ENUM_POSITION_TYPE type = g_orders[deepestIdx].type;
    double currentPrice = type == POSITION_TYPE_BUY ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    
    // Check if DEEPEST order has reached break-even threshold
    bool deepestAtThreshold = false;
    if (type == POSITION_TYPE_BUY) {
        deepestAtThreshold = (currentPrice >= deepestEntry + (BreakEvenPercent * stopDistance));
    } else {
        deepestAtThreshold = (currentPrice <= deepestEntry - (BreakEvenPercent * stopDistance));
    }
    
    // If deepest reached threshold, move ALL orders to their own break-even
    if (deepestAtThreshold) {
        for(int i = 0; i < g_orderCount; i++) {
            if (g_orders[i].breakEvenReached) continue;
            
            double orderEntry = g_orders[i].entryPrice;
            double newSL = (type == POSITION_TYPE_BUY) ? 
                           orderEntry + BreakEvenMarginInPips * GetPipSize() :
                           orderEntry - BreakEvenMarginInPips * GetPipSize();
            
            if (ModifyStopLoss(g_orders[i].ticket, newSL)) {
                g_orders[i].breakEvenReached = true;
                g_orders[i].currentSL = newSL;
            }
        }
    }
}

void checkTrailingStopConditions() {
   if (g_extremeSpreadActive) {
      return;
   }
   
   ENUM_TIMEFRAMES timeframe = _Period;
   
   if (!IsNewBar()) {
      return;
   }
   
   SyncOrderTracking();
   
   if (g_orderCount == 0) {
      g_lastTrailingStopBuy = 0.0;
      g_lastTrailingStopSell = 0.0;
      return;
   }
   
   // Find the deepest order to use as reference
   int deepestIdx = GetDeepestOrderIndex();
   if (deepestIdx < 0) return;
   
   ulong deepestTicket = g_orders[deepestIdx].ticket;
   if (!PositionSelectByTicket(deepestTicket)) {
      g_lastTrailingStopBuy = 0.0;
      g_lastTrailingStopSell = 0.0;
      return;
   }
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double entryPrice = g_orders[deepestIdx].entryPrice;
   double currentSL = PositionGetDouble(POSITION_SL);
   double currClose = iClose(_Symbol, timeframe, 1);
   double currHigh = iHigh(_Symbol, timeframe, 1);
   double currLow = iLow(_Symbol, timeframe, 1);
   ENUM_POSITION_TYPE orderType = g_orders[deepestIdx].type;
   
   double stopLossDifference = 0.0;
   double currentProfit = 0.0;
   double profitInR = 0.0;
   double newTrailingStop = 0.0;
   
   // Calculate trailing stop for deepest order
   if (orderType == POSITION_TYPE_BUY) {
      stopLossDifference = entryPrice - g_orders[deepestIdx].initialSL;
      currentProfit = currClose - entryPrice;
      profitInR = (stopLossDifference > 0) ? (currentProfit / stopLossDifference) : 0.0;
      
      double pipDiff = (profitInR >= ProfitThresholdForTightening) ? 
                       TrailingStopTightMarginInPips * GetPipSize() : 
                       TrailingStopEarlyStageMarginInPips * GetPipSize();
      
      newTrailingStop = currLow - pipDiff;
      
      if(g_lastTrailingStopBuy == 0.0) {
         g_lastTrailingStopBuy = currentSL;
      }
      
      if(newTrailingStop > g_lastTrailingStopBuy && newTrailingStop > entryPrice) {
         Print("[TRAILING_STOP_BUY #", deepestIdx+1, " (Deepest)] Stop loss value:", newTrailingStop, " ProfitInR:", profitInR, " Margin:", pipDiff/GetPipSize(), " pips");
         
         // Apply to deepest order
         if(ModifyStopLoss(deepestTicket, newTrailingStop)) {
            g_lastTrailingStopBuy = newTrailingStop;
            g_orders[deepestIdx].currentSL = newTrailingStop;
         }
         
         // Apply to other orders if sync is enabled and they've reached break-even
         if (SyncStopsAfterBreakEven && g_orderCount > 1) {
            for(int i = 0; i < g_orderCount; i++) {
               if (i == deepestIdx) continue;  // Skip deepest, already done
               if (!g_orders[i].breakEvenReached) continue;  // Only sync if at break-even
               
               ulong ticket = g_orders[i].ticket;
               if (!PositionSelectByTicket(ticket)) continue;
               
               double orderEntry = g_orders[i].entryPrice;
               double minProtectedStop = orderEntry + MinStopProtectionPips * GetPipSize();
               double syncStop = MathMax(newTrailingStop, minProtectedStop);
               double orderCurrentSL = PositionGetDouble(POSITION_SL);
               
               if (syncStop > orderCurrentSL && syncStop > orderEntry) {
                  Print("[TRAILING_STOP_BUY #", i+1, " (Synced)] Stop loss value:", syncStop, " (Protected at entry+", MinStopProtectionPips, " pips)");
                  if(ModifyStopLoss(ticket, syncStop)) {
                     g_orders[i].currentSL = syncStop;
                  }
               }
            }
         }
      }   
   } 
   else if (orderType == POSITION_TYPE_SELL) {
      stopLossDifference = g_orders[deepestIdx].initialSL - entryPrice;
      currentProfit = entryPrice - currClose;
      profitInR = (stopLossDifference > 0) ? (currentProfit / stopLossDifference) : 0.0;
      
      double pipDiff = (profitInR >= ProfitThresholdForTightening) ? 
                       TrailingStopTightMarginInPips * GetPipSize() : 
                       TrailingStopEarlyStageMarginInPips * GetPipSize();
      
      newTrailingStop = currHigh + pipDiff;
      
      if(g_lastTrailingStopSell == 0.0) {
         g_lastTrailingStopSell = currentSL;
      }
      
      if(newTrailingStop < g_lastTrailingStopSell && newTrailingStop < entryPrice) {
         Print("[TRAILING_STOP_SELL #", deepestIdx+1, " (Deepest)] Stop loss value:", newTrailingStop, " ProfitInR:", profitInR, " Margin:", pipDiff/GetPipSize(), " pips");
         
         // Apply to deepest order
         if(ModifyStopLoss(deepestTicket, newTrailingStop)) {
            g_lastTrailingStopSell = newTrailingStop;
            g_orders[deepestIdx].currentSL = newTrailingStop;
         }
         
         // Apply to other orders if sync is enabled and they've reached break-even
         if (SyncStopsAfterBreakEven && g_orderCount > 1) {
            for(int i = 0; i < g_orderCount; i++) {
               if (i == deepestIdx) continue;  // Skip deepest, already done
               if (!g_orders[i].breakEvenReached) continue;  // Only sync if at break-even
               
               ulong ticket = g_orders[i].ticket;
               if (!PositionSelectByTicket(ticket)) continue;
               
               double orderEntry = g_orders[i].entryPrice;
               double minProtectedStop = orderEntry - MinStopProtectionPips * GetPipSize();
               double syncStop = MathMin(newTrailingStop, minProtectedStop);
               double orderCurrentSL = PositionGetDouble(POSITION_SL);
               
               if (syncStop < orderCurrentSL && syncStop < orderEntry) {
                  Print("[TRAILING_STOP_SELL #", i+1, " (Synced)] Stop loss value:", syncStop, " (Protected at entry-", MinStopProtectionPips, " pips)");
                  if(ModifyStopLoss(ticket, syncStop)) {
                     g_orders[i].currentSL = syncStop;
                  }
               }
            }
         }
      }
   }
}

// Use deepest order for partial close decisions - FIXED VERSION
void checkRConditions() {
    if (g_extremeSpreadActive) {
        return;
    }
    
    SyncOrderTracking();
    
    if (g_orderCount == 0) return;
    
    // Get deepest order as reference
    int deepestIdx = GetDeepestOrderIndex();
    if (deepestIdx < 0) return;
    
    double deepestEntry = g_orders[deepestIdx].entryPrice;
    double deepestSL = g_orders[deepestIdx].initialSL;
    double stopDistance = MathAbs(deepestEntry - deepestSL);
    ENUM_POSITION_TYPE type = g_orders[deepestIdx].type;
    
    if (stopDistance <= 0.0) return;
    
    // Calculate target price based on deepest order
    double targetPrice = 0.0;
    if (type == POSITION_TYPE_BUY) {
        targetPrice = deepestEntry + stopDistance * R1PartialPercent;
    } else {
        targetPrice = deepestEntry - stopDistance * R1PartialPercent;
    }
    
    double currentPrice = (type == POSITION_TYPE_BUY) ? 
                          SymbolInfoDouble(_Symbol, SYMBOL_ASK) : 
                          SymbolInfoDouble(_Symbol, SYMBOL_BID);
    
    // Check if deepest order reached target
    bool targetReached = false;
    if (type == POSITION_TYPE_BUY) {
        targetReached = (currentPrice >= targetPrice);
    } else {
        targetReached = (currentPrice <= targetPrice);
    }
    
    // If target reached, close partial on ALL orders
    if (targetReached) {
        for(int i = 0; i < g_orderCount; i++) {
            if (g_orders[i].partialCloseDone) continue;
            
            ulong ticket = g_orders[i].ticket;
            if (!PositionSelectByTicket(ticket)) continue;
            
            double currentVolume = PositionGetDouble(POSITION_VOLUME);
            double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
            
            if (currentVolume < minVolume * 2.0) continue;
            
            double lot = NormalizeVolume(_Symbol, currentVolume / 2.0);
            if (lot > 0.0 && TriggerPartialCloseOrder(lot)) {
                PrintFormat("[PARTIAL_CLOSE #%d] Closed %.2f lots at R=%.3f (Deepest: #%d @ %.5f, Target: %.5f, Current: %.5f)", 
                            i+1, lot, R1PartialPercent, deepestIdx+1, deepestEntry, targetPrice, currentPrice);
                g_orders[i].partialCloseDone = true;
            }
        }
    }
}

void checkTradesOffSession() {
   SyncOrderTracking();
   
   if (g_orderCount == 0) return;
   
   if (IsAfterOffSessionHour()) {
      // Process all open orders
      for(int i = 0; i < g_orderCount; i++) {
         ulong ticket = g_orders[i].ticket;
         if (!PositionSelectByTicket(ticket)) continue;
         
         double entryPrice = g_orders[i].entryPrice;
         ENUM_POSITION_TYPE orderType = g_orders[i].type;
         double TS = 0.0;
         
         Print("[OFF SESSION] Checking position #", i+1, " ticket " + string(ticket) + " with entry price: ", entryPrice);
         
         switch (HandleOrdersOutOfSession) {
            case OffSessionCloseOrder:
               if (trade.PositionClose(ticket)) {
                  Print("[CLOSE] Closing position #", i+1, " ticket " + string(ticket) + " off session");
               }
               break;
            case OffSessionBreakEven:
               if (orderType == POSITION_TYPE_BUY) {
                  TS = entryPrice + BreakEvenMarginInPips * GetPipSize();
                  if (ModifyStopLoss(ticket, TS)) {
                     g_orders[i].breakEvenReached = true;
                     g_orders[i].currentSL = TS;
                  }
               } else if (orderType == POSITION_TYPE_SELL) {
                  TS = entryPrice - BreakEvenMarginInPips * GetPipSize();
                  if (ModifyStopLoss(ticket, TS)) {
                     g_orders[i].breakEvenReached = true;
                     g_orders[i].currentSL = TS;
                  }
               }         
         }
      }
   }
}

//--------------------------- EA-specific code ----------------------------//
bool IsNewBar() {
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);

      if (currentBarTime != lastBarTime) {
      lastBarTime = currentBarTime;
      //Print("[DEBUG IsNewBar] ★★★ NEW BAR FORMED at ", TimeToString(currentBarTime), " ★★★");
      return true;
   }
   return false;
}

bool IsTrendingMarket() {
   if (!UseADXFilter) return true;
   
   double adxValue[];
   ArraySetAsSeries(adxValue, true);
   if(CopyBuffer(adxHandle, 0, 0, 1, adxValue) <= 0) return false;
   return adxValue[0] > 25.0;
}

int OnInit() {
   g_lastBarTime = iTime(_Symbol, _Period, 0);
   double pip = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;

   Print("[INIT] Adaptive ATR Channel Retracement EA Initialized");
   Print(_Symbol, ",", EnumToString(_Period), ", Magic#", MagicNumber);
   Print("Risk/Trade: ", DoubleToString(RiskPercent, 2), "%");
   Print("Indicator Period: ", IndicatorPeriod, ", Multiplier: ", ATRMultiplier);

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT); // check for reasonable Pip setting based on digits
   if (MathAbs(pip - GetPipSize()) > GetPipSize() && MathAbs(pip - GetPipSize()) > GetPipSize()) {
      Print("[WARN] Pip ", pip, " might not match standard symbol pip definition for ", _Symbol);
   }
   adaptiveATRHandle112 = iCustom(_Symbol, _Period, "AdaptiveATRChannel", 112, AppliedPrice, ATRMultiplier);
   adaptiveATRHandle20 = iCustom(_Symbol, _Period, "AdaptiveATRChannel", 20, AppliedPrice, ATRMultiplier);
   adxHandle = iADX(_Symbol, _Period, ADXPeriod);
   
      if(adaptiveATRHandle112 == INVALID_HANDLE || adaptiveATRHandle20 == INVALID_HANDLE || adxHandle == INVALID_HANDLE) {
      Print("[ERROR] Failed to initialize AdaptiveATRChannel indicators");
      return(INIT_FAILED);
   }
   
   Print("[INIT] ATR Handles created - 112: ", adaptiveATRHandle112, " 20: ", adaptiveATRHandle20);
      datetime currentTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);
   g_lastResetDate = StringToTime(IntegerToString(dt.year) + "." + 
                                   IntegerToString(dt.mon) + "." + 
                                   IntegerToString(dt.day));
   g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dailyLimitReached = false;
      // Initialize multi-order tracking
   g_orderCount = 0;
   g_scalingDirection = 0;
   g_lastOrderTime = 0;
   for(int i = 0; i < 3; i++) {
      g_orders[i].ticket = 0;
   }
   Print("[INIT] Multi-order scaling: ", EnableMultiOrderScaling ? "ENABLED" : "DISABLED");
   if (EnableMultiOrderScaling) {
      Print("  - Scale into winners: ", ScaleIntoWinners ? "YES" : "NO", " (Max: ", MaxScaleInWinners, ")");
      Print("  - Scale into losers: ", ScaleIntoLosers ? "YES" : "NO", " (Max: ", MaxScaleInLosers, ")");
      Print("  - Max total orders: ", MaxTotalOpenOrders);
   }
   
   Print("[INIT] Daily limits initialized - Start balance: ", g_dailyStartBalance);

    if (MaxTotalOpenOrders < 1 || MaxTotalOpenOrders > 20) {
        Print("[ERROR] MaxTotalOpenOrders must be between 1 and 20. Got: ", MaxTotalOpenOrders);
        return(INIT_PARAMETERS_INCORRECT);
    }
   
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   Print("Adaptive ATR Channel Retracement EA Deinitialized. Reason ", reason);
   IndicatorRelease(adaptiveATRHandle112);
   IndicatorRelease(adaptiveATRHandle20);
   IndicatorRelease(adxHandle);
}

void OnTick() {
   //Print("[DEBUG OnTick] Called - g_orderCount=", g_orderCount);
   checkTradesOffSession();
   
   // Sync order tracking with actual positions
   SyncOrderTracking();
   
   if (g_orderCount > 0) {
      // Update global ticket for backwards compatibility
      if (g_orderCount == 1) {
         gTicket = g_orders[0].ticket;
         gInitialSL = g_orders[0].initialSL;
      }
      
      if (!partialCloseRun) {
         checkRConditions();
      }
      checkBreakEvenConditions();
      checkTrailingStopConditions();
      
      // Still check for new entries if multi-scaling is enabled
      if (EnableMultiOrderScaling && g_orderCount < MaxTotalOpenOrders) {
         checkTradeConditions();
      }
   } else {
      gTicket = 0;
      gInitialSL = 0.0;
      breakEvenRun = false;
      partialCloseRun = false;
      g_lastTrailingStopBuy = 0.0;
      g_lastTrailingStopSell = 0.0;
      
      checkTradeConditions();
   }
   
}

//--------------------- Extra Helpers (optional) ---------------------//
bool SelectPositionByMagic(string symbol) {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0) {
         if(PositionGetString(POSITION_SYMBOL) == symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            return PositionSelectByTicket(ticket);
         }
      }
   }
   return false;
}

double NormalizeVolume(string symbol, double lots) {
   double step=0.0, vmin=0.0, vmax=0.0;
   SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP, step);
   SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN,  vmin);
   SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX,  vmax);

   if(step <= 0.0) step = 0.01;
   if(vmin <= 0.0) vmin = step;
   if(vmax <= 0.0) vmax = 100.0;

   double v = MathMax(vmin, MathMin(lots, vmax));
   v = MathRound(v/step) * step;

   int volDigits = (int)MathMax(0, -MathFloor(MathLog10(step)));
   return NormalizeDouble(v, volDigits);
   }
   // Check if we can add another order based on multi-scaling rules
bool CanAddAnotherOrder(double currentPrice, ENUM_POSITION_TYPE orderType) {
   if (!EnableMultiOrderScaling) return false;
   if (g_orderCount == 0) return true;  // First order always allowed
   if (g_orderCount >= MaxTotalOpenOrders) return false;
   
   // Get last order info
   OrderInfo lastOrder = g_orders[g_orderCount - 1];
   double lastEntry = lastOrder.entryPrice;
   double lastSL = lastOrder.initialSL;
   double stopDistance = MathAbs(lastEntry - lastSL);
   double pipSize = GetPipSize();
      // Determine if scaling into winner or loser
   bool isWinner = false;
   bool isLoser = false;
   
   if (orderType == POSITION_TYPE_BUY) {
      isWinner = (currentPrice >= lastEntry);
      isLoser = (currentPrice < lastEntry);
   } else {
      isWinner = (currentPrice <= lastEntry);
      isLoser = (currentPrice > lastEntry);
   }
   
   // Check minimum bars between orders
      int minBars = isLoser ? MinBarsBetweenLoserOrders : MinBarsBetweenWinnerOrders;
   int barsSinceLastOrder = iBarShift(_Symbol, _Period, g_lastOrderTime);
   if (barsSinceLastOrder < minBars) {
      Print("[SCALE_BLOCK] Only ", barsSinceLastOrder, " bars since last order. Need ", minBars);
      return false;
   }
       
   // Check scaling direction rules
   if (isWinner) {
      if (!ScaleIntoWinners) return false;
      if (g_orderCount > MaxScaleInWinners) return false;
      
      // Check if mixing is allowed
      if (g_scalingDirection == -1 && !AllowMixedScaling) {
         Print("[SCALE_BLOCK] Already scaling into losers, cannot switch to winners");
         return false;
      }
      
      // Check minimum distance
      double minDistance = stopDistance * (WinnerScaleMinDistancePercent / 100.0);
      double actualDistance = MathAbs(currentPrice - lastEntry);
      
      if (actualDistance < minDistance) {
         Print("[SCALE_BLOCK] Winner distance too small: ", actualDistance/pipSize, " pips < ", minDistance/pipSize, " pips required");
         return false;
      }
      
      g_scalingDirection = 1;  // Scaling into winners
      return true;
      
   } else if (isLoser) {
      if (!ScaleIntoLosers) return false;
      if (g_orderCount > MaxScaleInLosers) return false;
      
      // Check if mixing is allowed
      if (g_scalingDirection == 1 && !AllowMixedScaling) {
         Print("[SCALE_BLOCK] Already scaling into winners, cannot switch to losers");
         return false;
      }
      
      // Check minimum distance
      double minDistance = stopDistance * (LoserScaleMinDistancePercent / 100.0);
      double actualDistance = MathAbs(currentPrice - lastEntry);
      
      if (actualDistance < minDistance) {
         Print("[SCALE_BLOCK] Loser distance too small: ", actualDistance/pipSize, " pips < ", minDistance/pipSize, " pips required");
         return false;
      }
      
      g_scalingDirection = -1;  // Scaling into losers
      return true;
   }
   
   return false;
}

// Get count of open positions with our magic number
int GetOpenOrderCount() {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0) {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            count++;
         }
      }
   }
   return count;
}

// Update order tracking array from actual positions
void SyncOrderTracking() {
    int actualCount = GetOpenOrderCount();
    
    if (actualCount == 0) {
        g_orderCount = 0;
        g_scalingDirection = 0;
        g_lastOrderTime = 0;
        for(int i = 0; i < MaxTotalOpenOrders; i++) {
            g_orders[i].ticket = 0;
            g_orders[i].entryPrice = 0.0;
            g_orders[i].initialSL = 0.0;
            g_orders[i].currentSL = 0.0;
            g_orders[i].breakEvenReached = false;
            g_orders[i].partialCloseDone = false;
        }
        return;
    }
    
    OrderInfo tempOrders[20];  // Match the array size
    int tempCount = 0;
    
    for(int i = PositionsTotal() - 1; i >= 0 && tempCount < MaxTotalOpenOrders; i--) {
        ulong ticket = PositionGetTicket(i);
        if(ticket > 0) {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
               PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
                
                bool found = false;
                for(int j = 0; j < g_orderCount; j++) {
                    if(g_orders[j].ticket == ticket) {
                        tempOrders[tempCount] = g_orders[j];
                        tempOrders[tempCount].currentSL = PositionGetDouble(POSITION_SL);
                        found = true;
                        break;
                    }
                }
                
                if(!found) {
                    tempOrders[tempCount].ticket = ticket;
                    tempOrders[tempCount].entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
                    tempOrders[tempCount].initialSL = PositionGetDouble(POSITION_SL);
                    tempOrders[tempCount].currentSL = PositionGetDouble(POSITION_SL);
                    tempOrders[tempCount].type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
                    tempOrders[tempCount].breakEvenReached = false;
                    tempOrders[tempCount].partialCloseDone = false;
                    tempOrders[tempCount].openTime = (datetime)PositionGetInteger(POSITION_TIME);
                    tempOrders[tempCount].orderSequence = tempCount + 1;
                }
                tempCount++;
            }
        }
    }
    
    for(int i = 0; i < MaxTotalOpenOrders; i++) {
        if(i < tempCount) {
            g_orders[i] = tempOrders[i];
        } else {
            g_orders[i].ticket = 0;
            g_orders[i].entryPrice = 0.0;
            g_orders[i].initialSL = 0.0;
            g_orders[i].currentSL = 0.0;
            g_orders[i].breakEvenReached = false;
            g_orders[i].partialCloseDone = false;
        }
    }
    
    g_orderCount = tempCount;
    
    if(g_orderCount == 0) {
        g_scalingDirection = 0;
    }
}

// Find the deepest order (last one) for trailing stop reference
int GetDeepestOrderIndex() {
   if (g_orderCount == 0) return -1;
   
   int deepestIdx = 0;
   ENUM_POSITION_TYPE type = g_orders[0].type;
   
   for(int i = 1; i < g_orderCount; i++) {
      if (type == POSITION_TYPE_BUY) {
         if (g_orders[i].entryPrice < g_orders[deepestIdx].entryPrice) {
            deepestIdx = i;
         }
      } else {
         if (g_orders[i].entryPrice > g_orders[deepestIdx].entryPrice) {
            deepestIdx = i;
         }
      }
   }
   
   return deepestIdx;
}

bool CheckDailyLimits() {
   if (!UseDailyLimits) return true;
   
   datetime currentTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);
   datetime todayDate = StringToTime(IntegerToString(dt.year) + "." + 
                                     IntegerToString(dt.mon) + "." + 
                                     IntegerToString(dt.day));
   
   if (todayDate != g_lastResetDate) {
      g_lastResetDate = todayDate;
      g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_dailyLimitReached = false;
      Print("[DAILY_LIMIT] Reset - Start Balance: ", g_dailyStartBalance);
   }
   
   if (g_dailyLimitReached) {
      return false;
   }
   
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyPnL = currentBalance - g_dailyStartBalance;
   double dailyPnLPercent = (dailyPnL / g_dailyStartBalance) * 100.0;
   
   if (dailyPnLPercent >= MaxDailyProfitPercent) {
      if (!g_dailyLimitReached) {
         Print("[DAILY_LIMIT] Max profit reached: ", DoubleToString(dailyPnLPercent, 2), 
               "% (Target: ", MaxDailyProfitPercent, "%) - No more trades today");
         g_dailyLimitReached = true;
      }
      return false;
   }
   
   if (dailyPnLPercent <= -MaxDailyLossPercent) {
      if (!g_dailyLimitReached) {
         Print("[DAILY_LIMIT] Max loss reached: ", DoubleToString(dailyPnLPercent, 2), 
               "% (Limit: -", MaxDailyLossPercent, "%) - No more trades today");
         g_dailyLimitReached = true;
      }
      return false;
   }
   
   return true;
}

double NormalizePrice(string symbol, double price) {
   double tick = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0) tick = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(tick <= 0.0) return price;
   return MathRound(price / tick) * tick;
}

int MinStopDistancePoints(string symbol) {
   long stops = 0;
   if(!SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL, stops)) return 0;
   return (int)stops; // already in points
}

int TimeStringToMinutes(string timeStr) {
   int hr = (int)StringToInteger(StringSubstr(timeStr, 0, 2));
   int mn = (int)StringToInteger(StringSubstr(timeStr, 3, 2));
   return hr * 60 + mn;
}

bool IsWithinSession() {
   return IsWithinTradingSession(TradingSessionJapanStart, TradingSessionJapanEnd) 
      || IsWithinTradingSession(TradingSessionEuropeStart, TradingSessionEuropeEnd) 
      || IsWithinTradingSession(TradingSessionUSAStart, TradingSessionUSAEnd);
}

bool IsAfterOffSessionHour() {
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   int currentMinutes = dt.hour * 60 + dt.min;
   int endOfDayMinutes = TimeStringToMinutes(OutOfSessionCloseTime);
   
   return currentMinutes > endOfDayMinutes;
}

bool IsWithinTradingSession(string tradingSessionStart, string tradingSessionEnd) {
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   int currentMinutes = dt.hour * 60 + dt.min;
   int sessionStart = TimeStringToMinutes(tradingSessionStart);
   int sessionEnd = TimeStringToMinutes(tradingSessionEnd);
   
   if (sessionEnd >= sessionStart) {
      return (currentMinutes >= sessionStart && currentMinutes <= sessionEnd);
   } else {
      return (currentMinutes >= sessionStart || currentMinutes <= sessionEnd);
   }
 }
 
 /*
   This function returns false if the Adaptive ATR Channel can't be calculated or there is an error when copying the values to the argument arrays
   Given a specified period and index it retrieves the AdaptiveATRChannel Values and saves them in the array arguments for the canldestick the index implies
 
   Parameters:
      period   [int]: The period to fetch data to use for the calculation
      index    [int]: The index of the candlestick to return the values for, 0 for current
      central  [double &]: The pointer that holds the central line value of the candlestick selected by index
      upper    [double &]: The pointer that holds the upper line value of the candlestick selected by index
      lower    [double &]: The pointer that holds the lower line value of the candlestick selected by index
      
   Return [bool]:
      A flag that determines if the central upper and lower pointers have been populated properly
 */
bool GetAdaptiveATRChannelByIndex(int handle, int period, int index, double &central, double &upper, double &lower) {
   double atrValues[], upperBand[], lowerBand[], trendColor[], centralLine[] ;
   if (handle == INVALID_HANDLE) {
      Print("[ERROR] GetAdaptiveATRChannel invalid indicator handle ", GetLastError());
      return false;
   }
   
   int bars = iBars(_Symbol, _Period);
   if (bars <= period + 2) {
      Print("Not enough bars for Adaptive ATR Channel");
      return false;
   }
   
   ArraySetAsSeries(atrValues, true);
   if (CopyBuffer(handle, 5, 0, 2, atrValues) < 2 ||
       CopyBuffer(handle, 2, 0, 2, upperBand) < 2 ||
       CopyBuffer(handle, 3, 0, 2, lowerBand) < 2 ||
       CopyBuffer(handle, 1, 0, 2, trendColor) < 2 ||
       CopyBuffer(handle, 0, 0, 2, centralLine) < 2) {
      Print("[ERROR] OnTick copying indicator buffer: ", GetLastError());
      return false;
   }
   
   ArrayResize(centralLine, bars);
   ArrayResize(upperBand, bars);
   ArrayResize(lowerBand, bars);
   
   central = centralLine[index];
   upper = upperBand[index];
   lower = lowerBand[index];
   
   return true;
}

/*
   Given a specified period it retrieves the AdaptiveATRChannel Values and saves them in the array arguments
   Returns false if the Adaptive ATR Channel can't be calculated or there is an error when copying the values to the argument arrays
   
   Parameters:
      period   [int]: The period to fetch data to use for the calculation
      central  [double[] &]: The pointer that holds the central line values back to the given period
      upper    [double[] &]: The pointer that holds the upper line values back to the given period
      lower    [double[] &]: The pointer that holds the lower line values back to the given period
      
   Return [bool]:
      A flag that determines if the central upper and lower pointers have been populated properly
 */
bool GetAdaptiveATRChannel(int handle, int period, double &central[], double &upper[], double &lower[]) {
   double atrValues[], upperBand[], lowerBand[], trendColor[], centralLine[] ;
   if (handle == INVALID_HANDLE) {
      Print("[ERROR] GetAdaptiveATRChannel invalid indicator handle ", GetLastError());
      return false;
   }
   
   int bars = iBars(_Symbol, _Period);
   if (bars <= period + 2) {
      //Print("Not enough bars for Adaptive ATR Channel");
      return false;
   }
   
   ArraySetAsSeries(atrValues, true);
   if (CopyBuffer(handle, 5, 0, 2, atrValues) < 2 ||
       CopyBuffer(handle, 2, 0, 2, upperBand) < 2 ||
       CopyBuffer(handle, 3, 0, 2, lowerBand) < 2 ||
       CopyBuffer(handle, 1, 0, 2, trendColor) < 2 ||
       CopyBuffer(handle, 0, 0, 2, centralLine) < 2) {
      //Print("[ERROR] OnTick copying indicator buffer: ", GetLastError());
      return false;
   }
   
   ArrayResize(centralLine, period);
   ArrayResize(upperBand, period);
   ArrayResize(lowerBand, period);
   ArrayResize(central, period);
   ArrayResize(upper, period);
   ArrayResize(lower, period);
   
   ArrayCopy(central, centralLine);
   ArrayCopy(upper, upperBand);
   ArrayCopy(lower, lowerBand);
   
   return true;
}

/*
   Draws the Adaptive ATR Channel Indicator given a specified period in candlesticks
   
   Parameters:
      period   [int]:   the period in candlesticks
      
   Returns [int]:
      an INVALID_HANDLE flag or 0 for success
*/
int AddAdaptiveATRChannelIndicator(int handle, int period) {
   if (handle == INVALID_HANDLE) {
      Print("[ERROR] AddAdaptiveATRChannelIndicator invalid indicator handle");
      return INVALID_HANDLE;
   }
   
   long chartId = ChartID();
   if (!ChartIndicatorAdd(chartId, 0, handle)) {
      Print("[ERROR] AddAdaptiveATRChannelIndicator adding indicator to chart ", GetLastError());
      return INVALID_HANDLE;
   }
   
   return 0;
}

double GetCurrentSpreadInPips() {
   long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pipSize = GetPipSize();
   
   if (pipSize == 0) return 0.0;
   
   double spreadInPrice = spreadPoints * point;
   double spreadInPips = spreadInPrice / pipSize;
   
   return spreadInPips;
}
bool IsSpreadAcceptable(double channelWidth112, double channelWidth20) {
   if (!UseSpreadFilter) return true;
   
   double currentSpread = GetCurrentSpreadInPips();
   double pipSize = GetPipSize();
   
   double channelWidthPips112 = channelWidth112 / pipSize;
   double channelWidthPips20 = channelWidth20 / pipSize;
   double maxChannelWidthPips = MathMax(channelWidthPips112, channelWidthPips20);
   
   double allowedSpread = MaxSpreadForEntry;
   
   if (UseATRVolatilityAdjustment) {
      double atrRatio = channelWidthPips112 / MathMax(channelWidthPips20, 0.0001);
      
      if (atrRatio > ATRRatioThresholdForWideSpread) {
         allowedSpread = MaxSpreadForEntry * 1.5;
         Print("[SPREAD_FILTER] High volatility detected (ATR112/ATR20=", DoubleToString(atrRatio, 2), 
               ") - Allowing wider spread: ", DoubleToString(allowedSpread, 2), " pips");
      }
      
      if (maxChannelWidthPips > 0 && (currentSpread / maxChannelWidthPips) < SpreadToATRRatio) {
         Print("[SPREAD_FILTER] Spread/ATR ratio acceptable: Spread=", DoubleToString(currentSpread, 2), 
               " pips, ATR=", DoubleToString(maxChannelWidthPips, 2), " pips");
         return true;
      }
   }
   
      if (currentSpread > allowedSpread) {
      Print("[SPREAD_FILTER] BLOCKED - Spread too wide: ", DoubleToString(currentSpread, 2), 
            " pips > ", DoubleToString(allowedSpread, 2), " pips (Normal: ", DoubleToString(NormalSpreadPips, 2), " pips)");
      return false;
   }
   
   double spreadMultiplier = currentSpread / MathMax(NormalSpreadPips, 0.01);
   if (spreadMultiplier >= ExtremeSpreagMultiplier) {
      if (!g_extremeSpreadActive) {
         Print("[SPREAD_FILTER] **EXTREME SPREAD DETECTED** - ", DoubleToString(currentSpread, 2), 
               " pips (", DoubleToString(spreadMultiplier, 1), "x normal) - Pausing stop modifications");
         g_extremeSpreadActive = true;
      }
      return false;
   } else {
      if (g_extremeSpreadActive) {
         Print("[SPREAD_FILTER] Spread normalized - ", DoubleToString(currentSpread, 2), 
               " pips - Resuming normal operations");
         g_extremeSpreadActive = false;
      }
   }
   
   return true;
}
bool IsMarketTooNarrow(double channelWidth112, double channelWidth20) {
   if (!UseMinimumVolatilityFilter) return false;
   
   double pipSize = GetPipSize();
   double channelWidthPips112 = channelWidth112 / pipSize;
   double channelWidthPips20 = channelWidth20 / pipSize;
   double maxChannelWidthPips = MathMax(channelWidthPips112, channelWidthPips20);
   
   if (maxChannelWidthPips < MinimumATRChannelWidthPips) {
      Print("[VOLATILITY_FILTER] BLOCKED - Market too narrow: ATR Channel=", DoubleToString(maxChannelWidthPips, 2), 
            " pips < Minimum ", DoubleToString(MinimumATRChannelWidthPips, 2), " pips");
      return true;
   }
   
   return false;
}

double GetPipSize() {
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   if(digits == 5 || digits == 3) {
      return point * 10;
   }
   else if(digits == 4 || digits == 2) {
      return point * 10;
   }
   else {
      return point;
   }
}