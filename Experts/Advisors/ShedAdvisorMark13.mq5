//+------------------------------------------------------------------+
//|                                             ShedAdvisorMark13.mq5|
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

//======================== Inlined ShedTradeHelper ========================//

input double RiskPercent = 0.1;         // Risk per trade (not wired into triggers to preserve your behavior)
input int    MagicNumber = 12345;
input int    IndicatorPeriod = 112;     // ATR Indicator Period
input double ATRMultiplier = 1.0;       // ATR Multiplier
input ENUM_APPLIED_PRICE AppliedPrice = PRICE_CLOSE; // Price type for indicator
input string TradingSessionJapanStart  = "01:30";
input string TradingSessionJapanEnd    = "06:00";
input string TradingSessionEuropeStart = "08:30";
input string TradingSessionEuropeEnd   = "13:00";
input string TradingSessionUSAStart    = "16:30";
input string TradingSessionUSAEnd      = "20:00";

input int    lookback = 5;
input int    TimerIntervalSeconds = 180;
input double TakeProfit = 0.0;
input double StopLoss = 0.0;
input double TakeProfitMultiplier = 0.0;
input double BreakEvenPercent = 0.6;
input double BreakEvenMarginInPips = 1.0;
input double InitialStopLossMarginInPips = 0.0;
input double R1PartialPercent = 1.0;
input int    SpreadAddedToStop = 15;
input double BreakoutRetracementHigh = 70.0;
input double BreakoutRetracementLow = 10.0;
input double OrderCloseToRetracementPercent = 30.0;
input ATRSelect ATRUsedInStopLossCalculation = ATRAlwaysWider;

datetime g_lastBarTime = 0; // For new candle detection

int adaptiveATRHandle;
bool breakEvenRun = false;
bool partialCloseRun = false;

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
   //double TP = TakeProfit != 0.0 ? NormalizeDouble(TakeProfit * 1000, _Digits) : NormalizeDouble(entryPrice - channelWidth * takeProfitMultiplier, _Digits);

   double volume = CalculateLotSize(SL - entryPrice, 1.0);

   if (volume <= 0) {
      Print("[ERROR] TriggerSellOrder invalid volume ", volume);
      return false;
   }

   trade.SetExpertMagicNumber(magicNumber);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(_Symbol);

   // PrintFormat("SELL: V=%.2f @ BID=%.*f, SL=%.*f", volume, _Digits, entryPrice, _Digits, SL);
   if (trade.Sell(volume, _Symbol, entryPrice, SL, 0.0, "Sell Order: ATR Channel Retracement")) {
      ulong dealTicket = trade.ResultDeal();
      double tradeEntryPrice = trade.ResultPrice();
      double tradeInitialStopLoss = SL;
      double tradeChannelWidth = channelWidth;
      PrintFormat("[SELL] (#%d): V=%.2f @ %.5f, SL=%.5f (Channel Width=%.5f)", dealTicket, volume, tradeEntryPrice, tradeInitialStopLoss, tradeChannelWidth);
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
   //double TP = TakeProfit != 0.0 ? NormalizeDouble(TakeProfit * 1000, _Digits) : NormalizeDouble(entryPrice + channelWidth * takeProfitMultiplier, _Digits);

   double volume = CalculateLotSize(entryPrice - SL, 1.0); // keeps original 1% risk behavior from your helper

   if (volume <= 0) {
      Print("[ERROR] TriggerBuyOrder invalid volume ", volume);
      return false;
   }

   trade.SetExpertMagicNumber(magicNumber);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(_Symbol);

   //---PrintFormat("BUY: V=%.2f @ ASK=%.*f, SL=%.*f, TP=%.*f", volume, _Digits, entryPrice, _Digits, SL, _Digits, TP);

   if (trade.Buy(volume, _Symbol, 0.0, SL, 0.0, "Buy Order: ATR Channel Retracement")) {
      ulong dealTicket = trade.ResultDeal();
      double tradeEntryPrice = trade.ResultPrice();
      double tradeInitialStopLoss = SL;
      double tradeChannelWidth = channelWidth;
      PrintFormat("[BUY] (#%d): V=%.2f @ %.5f, SL=%.5f (Channel Width=%.5f)",
                  dealTicket, volume, tradeEntryPrice, tradeInitialStopLoss, tradeChannelWidth);
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
   
   double current_price = PositionGetDouble(POSITION_PRICE_OPEN);
   double current_tp = PositionGetDouble(POSITION_TP);
   string symbol = PositionGetString(POSITION_SYMBOL);
   
   TS = NormalizeDouble(TS, _Digits);
   
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
   if(!PositionSelect(_Symbol)) {
      Print("[PARTIAL_CLOSE_ERROR] No position for ", _Symbol);
      return false;
   }
   
   double current_lot = PositionGetDouble(POSITION_VOLUME);
   
   if(lot >= current_lot) {
      Print("[ERROR] Cannot close ", lot, " >= ", current_lot);
      return false;
   }
   
   ulong ticket = PositionGetInteger(POSITION_TICKET);
   
   if (trade.PositionClosePartial(ticket, lot)) {
      Print("[PARTIAL_CLOSE] at ", lot);
      partialCloseRun = true;
      return true;
   }
   
   Print("[ERROR] Partial close failed!");
   Print("  Error Code: ", GetLastError());
   Print("  RetCode: ", trade.ResultRetcode());
   Print("  Description: ", trade.ResultRetcodeDescription());
   
   return false;
}

void checkTradeConditions() {
   ENUM_TIMEFRAMES timeframe = _Period;
   
   if (!IsNewBar()) {
      return;
   }
   
   double central, upper, lower, central20, upper20, lower20;
   GetAdaptiveATRChannelByIndex(adaptiveATRHandle, 112, 0, central, upper, lower);
   GetAdaptiveATRChannelByIndex(adaptiveATRHandle, 20, 0,  central20, upper20, lower20);
   
   double channelWidth = upper - lower; // NOTE: This is in price units.
   double channel20Width = upper20 - lower20;

   double currClose = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currOpen  = iOpen(_Symbol, timeframe, 0);
   double prevClose = iClose(_Symbol, timeframe, 1);
   double prevOpen  = iOpen(_Symbol, timeframe, 1);
   double lastPrevOpen = iOpen(_Symbol, timeframe, 2);
   double lastPrevClose = iClose(_Symbol, timeframe,2);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
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
      if (!PositionSelect(_Symbol) && retracementPercent >= BreakoutRetracementLow && retracementPercent <= BreakoutRetracementHigh && orderPlacementToRetracement > OrderCloseToRetracementPercent) {
         TriggerBuyOrder(channelWidth, channel20Width);
         partialCloseRun = false;
      }
      
      breakoutBuyHigh = 0.0;
      breakoutBuyLow = 0.0;
      retracementBuyHigh = 0.0;
      retracementBuyLow = 0.0;
   }

   // This triggers a possible sell order and checks for retracement
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
      if (!PositionSelect(_Symbol) && retracementPercent >= BreakoutRetracementLow && retracementPercent <= BreakoutRetracementHigh && orderPlacementToRetracement > OrderCloseToRetracementPercent) {
         TriggerSellOrder(channelWidth, channel20Width);
         partialCloseRun = false;
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
   GetAdaptiveATRChannelByIndex(adaptiveATRHandle, length, 0, central, upper, lower);
   
   double channelWidth = upper - lower; // NOTE: This is in price units.

   return channelWidth > value;
}

void checkBreakEvenConditions() {
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   ulong ticket = PositionGetTicket(0);
   if (ticket != gTicket) {
      gTicket = ticket;
      gInitialSL = PositionGetDouble(POSITION_SL);
   }
   
   double entryPrice = PositionSelectByTicket(ticket) ? PositionGetDouble(POSITION_PRICE_OPEN) : 0.0;
   double breakEven = BreakEvenPercent;
   
   double stopLoss = gInitialSL;
   ENUM_POSITION_TYPE orderType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double currentPrice = orderType == POSITION_TYPE_BUY ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double stopLossDifference = 0.0;
   if (orderType == POSITION_TYPE_BUY) {
      stopLossDifference = entryPrice - stopLoss;
      if (entryPrice + (breakEven * stopLossDifference) <= currentPrice && !breakEvenRun) {
         double TS = entryPrice + BreakEvenMarginInPips * GetPipSize();
         Print("[BREAK_EVEN_BUY] Stop loss value:", TS);
         if (ModifyStopLoss(ticket, TS)) {
            breakEvenRun = true;
         }
      }
   } else if (orderType == POSITION_TYPE_SELL) {
      stopLossDifference = stopLoss - entryPrice;
      if (entryPrice - (breakEven * stopLossDifference) >= currentPrice && !breakEvenRun) {
         double TS = entryPrice - BreakEvenMarginInPips * GetPipSize();
         Print("[BREAK_EVEN_BUY] Stop loss value:", TS);
         if (ModifyStopLoss(ticket, TS)) {
            breakEvenRun = true;
         }
      }
   }
}

void checkTrailingStopConditions() {
   ENUM_TIMEFRAMES timeframe = _Period;
   
   // New Candle Detection
   if (!IsNewBar()) {
      return;
   }
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   ulong ticket = PositionGetTicket(0);
   double entryPrice = PositionSelectByTicket(ticket) ? PositionGetDouble(POSITION_PRICE_OPEN) : 0.0;
   double currClose = iClose(_Symbol, timeframe, 1);
   double currHigh = iHigh(_Symbol, timeframe, 1);
   double currLow = iLow(_Symbol, timeframe, 1);
   ENUM_POSITION_TYPE orderType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   
   if (orderType == POSITION_TYPE_BUY) {
      double pipDiff = 2 * GetPipSize();
      double TS = currLow - pipDiff;
      if (TS > entryPrice && entryPrice - pipDiff <= currLow) {
         Print("[TRAILING_STOP_BUY] Stop loss value:", TS);
         ModifyStopLoss(ticket, TS);
      }   
   } else if (orderType == POSITION_TYPE_SELL) {
      double pipDiff = 2 * GetPipSize();
      double TS = currHigh + pipDiff;
      if (TS < entryPrice && entryPrice + pipDiff >= currHigh) {
         Print("[TRAILING_STOP_SELL] Stop loss value:", TS);
         ModifyStopLoss(ticket, TS);
      }
   }
}

void checkRConditions() {
   double stopLoss = gInitialSL == 0.0 ? PositionGetDouble(POSITION_SL) : gInitialSL;
   ulong ticket = PositionGetTicket(0);
   double entryPrice = PositionSelectByTicket(ticket) ? PositionGetDouble(POSITION_PRICE_OPEN) : 0.0;
   ENUM_POSITION_TYPE orderType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   
   if (orderType == POSITION_TYPE_BUY) {
      double stopLossDifference = entryPrice - stopLoss;
      double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if (stopLossDifference > 0 && currentPrice >= (stopLossDifference + entryPrice) * R1PartialPercent) {
         double lot = NormalizeVolume(_Symbol, PositionGetDouble(POSITION_VOLUME) / 2.0);
         TriggerPartialCloseOrder(lot);
      }
   } else if (orderType == POSITION_TYPE_SELL) {
      double stopLossDifference = stopLoss - entryPrice;
      double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if (stopLossDifference > 0 && currentPrice <= (entryPrice - stopLossDifference) * R1PartialPercent) {
         double lot = NormalizeVolume(_Symbol, PositionGetDouble(POSITION_VOLUME) / 2.0);
         TriggerPartialCloseOrder(lot);
      }
   }
} 

//--------------------------- EA-specific code ----------------------------//
bool IsNewBar() {
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);

   if (currentBarTime != lastBarTime) {
      lastBarTime = currentBarTime;
      return true;
   }
   return false;
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

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   Print("Adaptive ATR Channel Retracement EA Deinitialized. Reason ", reason);
   IndicatorRelease(adaptiveATRHandle);
}

void OnTick() {
   
   if (/*!IsWithinTradingSession(TradingSessionJapanStart, TradingSessionJapanEnd) 
      && */!IsWithinTradingSession(TradingSessionEuropeStart, TradingSessionEuropeEnd) 
      && !IsWithinTradingSession(TradingSessionUSAStart, TradingSessionUSAEnd)) {
      return;
   }
   
   /*if (isATRWiderThan(112, 0.005) && isATRWiderThan(20, 0.005)) {
      return;
   }*/
   
   // TODO: Stop adjusting the trailing stop backwards
   // TODO: Make the EA stop when achieving a specific daily profit
   // TODO: COnsider Spread during anouncement hours and during the SL calculation
   // TODO: Make the EA symbol and point proof
   // TODO: find any pip specific calculation and make them dynamic
   // TODO: Fix sell retracement swing calculation
   // TODO: HAVE FUN WHILE CODING!!
    
   if (PositionSelect(_Symbol)) {
      if (!partialCloseRun) {
         checkRConditions();
      }
      checkBreakEvenConditions();
      checkTrailingStopConditions();
      return;
   } else {
      gTicket = 0;
      gInitialSL = 0.0;
      breakEvenRun = false;
      partialCloseRun = false;
   }
   
   checkTradeConditions();
}

//--------------------- Extra Helpers (optional) ---------------------//

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
   handle = iCustom(_Symbol, _Period, "AdaptiveATRChannel", period, PRICE_CLOSE, 1.0);
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
   handle = iCustom(_Symbol, _Period, "AdaptiveATRChannel", period, PRICE_CLOSE, 1.0);
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
   handle = iCustom(_Symbol, _Period, "AdaptiveATRChannel", period, PRICE_CLOSE, 1.0);
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

double GetPipSize() {
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // For most pairs: 5 digits = point * 10, 3 digits = point * 1
   // For JPY pairs: 3 digits = point * 1, 2 digits = point * 10
   if(digits == 5 || digits == 3) {
      return point * 10;  // 5-digit broker (0.00001) or 3-digit JPY (0.001)
   }
   else if(digits == 4 || digits == 2) {
      return point * 100; // 4-digit broker (0.0001) or 2-digit JPY (0.01)
   }
   else {
      return point; // Fallback for unusual cases
   }
}