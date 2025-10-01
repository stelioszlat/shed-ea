//+------------------------------------------------------------------+
//|                                            AdaptiveATRHelper.mq5 |
//|                                                     Stelios Zlat |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property library
#property copyright "Stelios Zlat"
#property link      "https://www.mql5.com"
#property version   "1.00"
//+------------------------------------------------------------------+
//| My function                                                      |
//+------------------------------------------------------------------+
int TimeStringToMinutes(string timeStr) {
   int hr = (int)StringToInteger(StringSubstr(timeStr, 0, 2));
   int mn = (int)StringToInteger(StringSubstr(timeStr, 3, 2));
   return hr * 60 + mn;
}

 bool IsWithinTradingSession(string TradingSessionStart, string TradingSessionEnd) {
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   int currentMinutes = dt.hour * 60 + dt.min;
   int sessionStart = TimeStringToMinutes(TradingSessionStart);
   int sessionEnd = TimeStringToMinutes(TradingSessionEnd);
   
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
 bool GetAdaptiveATRChannelByIndex(int period, int index, double &central, double &upper, double &lower) {
   double atrValues[], upperBand[], lowerBand[], trendColor[], centralLine[] ;
   adaptiveATRHandle = iCustom(_Symbol, _Period, "AdaptiveATRChannel", period, PRICE_CLOSE, 1.0);
   if (adaptiveATRHandle == INVALID_HANDLE) {
      Print("[ERROR] GetAdaptiveATRChannel invalid indicator handle ", GetLastError());
      return false;
   }
   
   int bars = iBars(_Symbol, _Period);
   if (bars <= period + 2) {
      Print("Not enough bars for Adaptive ATR Channel");
      return false;
   }
   
   ArraySetAsSeries(atrValues, true);
   if (CopyBuffer(adaptiveATRHandle, 5, 0, 2, atrValues) < 2 ||
       CopyBuffer(adaptiveATRHandle, 2, 0, 2, upperBand) < 2 ||
       CopyBuffer(adaptiveATRHandle, 3, 0, 2, lowerBand) < 2 ||
       CopyBuffer(adaptiveATRHandle, 1, 0, 2, trendColor) < 2 ||
       CopyBuffer(adaptiveATRHandle, 0, 0, 2, centralLine) < 2) {
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
 bool GetAdaptiveATRChannel(int period, double[] &central, double[] &upper, double[] &lower) {
   double atrValues[], upperBand[], lowerBand[], trendColor[], centralLine[] ;
   adaptiveATRHandle = iCustom(_Symbol, _Period, "AdaptiveATRChannel", period, PRICE_CLOSE, 1.0);
   if (adaptiveATRHandle == INVALID_HANDLE) {
      Print("[ERROR] GetAdaptiveATRChannel invalid indicator handle ", GetLastError());
      return false;
   }
   
   int bars = iBars(_Symbol, _Period);
   if (bars <= period + 2) {
      Print("Not enough bars for Adaptive ATR Channel");
      return false;
   }
   
   ArraySetAsSeries(atrValues, true);
   if (CopyBuffer(adaptiveATRHandle, 5, 0, 2, atrValues) < 2 ||
       CopyBuffer(adaptiveATRHandle, 2, 0, 2, upperBand) < 2 ||
       CopyBuffer(adaptiveATRHandle, 3, 0, 2, lowerBand) < 2 ||
       CopyBuffer(adaptiveATRHandle, 1, 0, 2, trendColor) < 2 ||
       CopyBuffer(adaptiveATRHandle, 0, 0, 2, centralLine) < 2) {
      Print("[ERROR] OnTick copying indicator buffer: ", GetLastError());
      return false;
   }
   
   ArrayResize(centralLine, period);
   ArrayResize(upperBand, period);
   ArrayResize(lowerBand, period);
   
   central = centralLine;
   upper = upperBand;
   lower = lowerBand;
   
   return true;
}

/*
   Calculates the lot size given the risk percentage and the current adaptive ART channel width
   
   Parameters:
      risk           [double]: double value of risk percentage
      channelWidth   [double]: width of the adaptive atr channel
      
   Return [double]:
      lot size

*/
double CalculateLotSize(double channelWidthPriceUnits) {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * (RiskPercent / 100.0);
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

//+------------------------------------------------------------------+
