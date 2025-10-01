//+------------------------------------------------------------------+
//|                                              ShedTradeHelper.mq5 |
//|                                                     Stelios Zlat |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property library
#property copyright "Stelios Zlat"
#property link      "https://www.mql5.com"
#property version   "1.00"
#include <Trade\Trade.mqh>
CTrade trade;

enum WorkingStates {
   IDLE,
   CONSOLIDATION,
   BREAKOUT,
   RETRACEMENT,
   CONTINUATION
};
//+------------------------------------------------------------------+
//| My function                                                      |
//+------------------------------------------------------------------+

/*
   Calculates the lot size given the risk percentage and the current adaptive ART channel width
   
   Parameters:
      risk           [double]: double value of risk percentage
      channelWidth   [double]: width of the adaptive atr channel
      
   Return [double]:
      lot size

*/
double CalculateLotSize(double channelWidthPriceUnits, double riskPercent=0.1) {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * (riskPercent / 100.0);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double volumeStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   if (channelWidthPriceUnits <= point || point <= 0 || tickValue <= 0 || volumeStep <= 0 || riskMoney <= 0) {
      Print("[ERROR]: CalculateLotSize Invalid inputs");
      return 0.0;
   }
   
   double stopLossPoints = MathRound(channelWidthPriceUnits / point);
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

/*
   Calculates the efficiency ratio for a given period and index
   
   Parameters:
      period   [int]: the period for the calculation of the ratio
      index    [int]: the candlestick index for evaluation
      closed   [double[] &]: the values of the closed candlesticks, 0 is current
      
   Return [double]:
      the efficiency ratio value or zero if volatility is zero or the index is out of period
      
*/
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

/*
   Evaluates the current state of the trade and suggeests the next step
*/
bool EvaluateAdaptiveATRChannelTrade() {
   return true;
}

/*
   Triggers a Sell Order given a channel width
   
   Parameters:
      channelWidthPriceUnits  [double]: the adaptive ATR channel width 
      riskPercent             [double]: the risk percentage (default: 0.1 meaning 1%)
      magicNumber             [int]:    the number identifying the trade (default: 12345)
      
   Returns [bool]:
      true if the trade is successful, false otherwise

*/
bool TriggerSellOrder(double channelWidthPriceUnits, double riskPercent=0.1, int magicNumber=12345) {
   if (channelWidthPriceUnits <= 0) {
      Print("[ERROR] TriggerSellOrder invalid channel width: ", channelWidthPriceUnits);
      return false;
   }
   
   double entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double SL = entryPrice + channelWidthPriceUnits;
   SL = NormalizeDouble(SL, _Digits);
   
   double volume = CalculateLotSize(riskPercent, channelWidthPriceUnits);
   
   if (volume <= 0) {
      Print("[ERROR] TriggerSellOrder invalid volume ", volume);
      return false;
   }
   
   trade.SetExpertMagicNumber(magicNumber);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(_Symbol);
   
   PrintFormat("SELL: V=%.2f @ BID=%.*f, SL=%.*f", volume, _Digits, entryPrice, _Digits, SL);
   if (trade.Sell(volume, _Symbol, entryPrice, SL, 0, "Sell Order: ATR Channel Retracement")) {
      ulong dealTicket = trade.ResultDeal();
      bool tradeActive = true;
      bool breakEvenAdjusted = false;
      int tradeType = ORDER_TYPE_SELL;
      double tradeEntryPrice = trade.ResultPrice();
      double tradeInitialStopLoss = SL;
      double tradeChannelWidth = channelWidthPriceUnits;
      
      PrintFormat("[SELL] (#%d): V=%.2f @ %.5f, SL=%.5f (Channel Width=%.5f)", dealTicket, volume, tradeEntryPrice, tradeInitialStopLoss, tradeChannelWidth);
      return true;
   } else {
      Print("[FAIL] Sell Order Failed: ", trade.ResultRetcodeDescription(), "(Code: ", trade.ResultRetcode());
      return false;
   }
}

/*
   Triggers a trade without stop loss (HIGH RISK, USE WITH CAUTION)
   
   Parameters:
      channelWidthPriceUnits  [double]: the adaptive ATR channel width
      magicNumber             [int]:    the number identifying the trade (default: 12345)
      
   Returns [bool]:
      true if the trade is successful, false otherwise
*/
bool TriggerSellOrderWithoutSL(double channelWidthPriceUnits, int magicNumber=12345) {
   if (channelWidthPriceUnits <= 0) {
      Print("[ERROR] TriggerSellOrder invalid channel width: ", channelWidthPriceUnits);
      return false;
   }
   
   double volume = 0.1;
   
   trade.SetExpertMagicNumber(magicNumber);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(_Symbol);
   
   if (trade.Sell(volume, _Symbol)) {
      ulong dealTicket = trade.ResultDeal();
      bool tradeActive = true;
      bool breakEvenAdjusted = false;
      int tradeType = ORDER_TYPE_SELL;
      double tradeEntryPrice = trade.ResultPrice();
      double tradeChannelWidth = channelWidthPriceUnits;
      
      PrintFormat("[SELL] (#%d): V=%.2f @ %.5f (Channel Width=%.5f)", dealTicket, volume, tradeEntryPrice, tradeChannelWidth);
      return true;
   } else {
      Print("[FAIL] Sell Order Failed: ", trade.ResultRetcodeDescription(), "(Code: ", trade.ResultRetcode());
      return false;
   }
}

/*
   Triggers a buy order
   
   Parameters:
      channelWidthPriceUnits  [double]: the adaptive ATR channel width
      riskPercent             [double]: the risk percentage (default: 0.1 meaning 1%)
      magicNumber             [int]:    the number identifying the trade (default: 12345)
      
   Returns [bool]:
      true if the trade is successful, false otherwise
*/
bool TriggerBuyOrder(double channelWidthPriceUnits, double riskPercent=0.1, int magicNumber=12345) {
   if (channelWidthPriceUnits <= 0) {
      Print("[ERROR] TriggerBuyOrder invalid channel width: ", channelWidthPriceUnits);
      return false;
   }
   
   double entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double SL = entryPrice - channelWidthPriceUnits;
   SL = NormalizeDouble(SL, _Digits);
   
   double volume = CalculateLotSize(channelWidthPriceUnits, riskPercent);
   
   if (volume <= 0) {
      Print("[ERROR] TriggerBuyOrder invalid volume ", volume);
      return false;
   }
   
   trade.SetExpertMagicNumber(magicNumber);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(_Symbol);
   
   PrintFormat("BUY: V=%.2f @ ASK=%.*f, SL=%.*f", volume, _Digits, entryPrice, _Digits, SL);
   
   if (trade.Buy(volume, _Symbol, entryPrice, SL, 0, "Buy Order: ATR Channel Retracement")) {
      ulong dealTicket = trade.ResultDeal();
      bool tradeActive = true;
      bool breakEvenAdjusted = false;
      int tradeType = ORDER_TYPE_BUY;
      double tradeEntryPrice = trade.ResultPrice();
      double tradeInitialStopLoss = SL;
      double tradeChannelWidth = channelWidthPriceUnits;
      
      PrintFormat("[BUY] (#%d): V=%.2f @ %.5f, SL=%.5f (Channel Width=%.5f)", dealTicket, volume, tradeEntryPrice, tradeInitialStopLoss, tradeChannelWidth);
      return true;
   } else {
      Print("[FAIL] Buy Order Failed: ", trade.ResultRetcodeDescription(), "(Code: ", trade.ResultRetcode());
      return false;
   }
}

/*
   Triggers a buy without stop loss (HIGH RISK, USE WITH CAUTION)
   
   Parameters:
      channelWidthPriceUnits  [double]: the adaptive ATR channel width
      magicNumber             [int]:    the number identifying the trade (default: 12345)
      
   Returns [bool]:
      true if the trade is successful, false otherwise
*/
bool TriggerBuyOrderWithoutSL(double channelWidthPriceUnits, int magicNumber=12345) {
   if (channelWidthPriceUnits <= 0) {
      Print("[ERROR] TriggerBuyOrder invalid channel width: ", channelWidthPriceUnits);
      return false;
   }
   
   double entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   double volume = 0.1;
   
   trade.SetExpertMagicNumber(magicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   
   if (trade.Buy(volume, _Symbol)) {
      ulong dealTicket = trade.ResultDeal();
      bool tradeActive = true;
      bool breakEvenAdjusted = false;
      int tradeType = ORDER_TYPE_SELL;
      double tradeEntryPrice = trade.ResultPrice();
      double tradeChannelWidth = channelWidthPriceUnits;
      
      PrintFormat("[SELL] (#%d): V=%.2f @ %.5f (Channel Width=%.5f)", dealTicket, volume, tradeEntryPrice, tradeChannelWidth);
      return true;
   } else {
      Print("[FAIL] Sell Order Failed: ", trade.ResultRetcodeDescription(), "(Code: ", trade.ResultRetcode());
      return false;
   }
}

//+------------------------------------------------------------------+
