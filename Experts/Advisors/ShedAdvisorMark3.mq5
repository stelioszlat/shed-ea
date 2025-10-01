//+------------------------------------------------------------------+
//|                                             ShedAdvisorMark3.mq5 |
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

//======================== Inlined ShedTradeHelper ========================//

input double RiskPercent = 0.1;         // Risk per trade (not wired into triggers to preserve your behavior)
input int    MagicNumber = 12345;
input int    IndicatorPeriod = 112;     // ATR Indicator Period
input double ATRMultiplier = 1.0;       // ATR Multiplier
input ENUM_APPLIED_PRICE AppliedPrice = PRICE_CLOSE; // Price type for indicator
input double pip = 0.01;                // pip size
input string TradingSessionStart = "08:30";
input string TradingSessionEnd   = "13:00";
input int    lookback = 5;
input int    TimerIntervalSeconds = 180;
input double Margin = 0.0;
input double Difference = 0.0;
input double TakeProfit = 0.0;
input double StopLoss = 0.0;
input double TakeProfitMultiplier = 0.0;
input double BreakEven = 0.0;

datetime g_lastBarTime = 0; // For new candle detection

int adaptiveATRHandle;
bool breakEvenRun = false;

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

double CalculateLotSize(double channelWidthPriceUnits, double riskPercent=1.0) {
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

bool TriggerSellOrder(double channelWidth, double riskPercent=0.1, int magicNumber=12345) {
   if (channelWidth <= 0) {
      Print("[ERROR] TriggerSellOrder invalid channel width: ", channelWidth);
      return false;
   }

   double entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double SL = NormalizeDouble(entryPrice + channelWidth, _Digits);
   double takeProfitMultiplier = TakeProfitMultiplier != 0.0 ? TakeProfitMultiplier : 1.5;
   double TP = TakeProfit != 0.0 ? NormalizeDouble(TakeProfit * 1000, _Digits) : NormalizeDouble(entryPrice - channelWidth * takeProfitMultiplier, _Digits);

   double volume = CalculateLotSize(channelWidth, 1.0);

   if (volume <= 0) {
      Print("[ERROR] TriggerSellOrder invalid volume ", volume);
      return false;
   }

   trade.SetExpertMagicNumber(magicNumber);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(_Symbol);

   PrintFormat("SELL: V=%.2f @ BID=%.*f, SL=%.*f", volume, _Digits, entryPrice, _Digits, SL);
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

bool TriggerBuyOrder(double channelWidth, double riskPercent=0.1, int magicNumber=12345) {
   if (channelWidth <= 0) {
      Print("[ERROR] TriggerBuyOrder invalid channel width: ", channelWidth);
      return false;
   }

   double entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double SL = NormalizeDouble(entryPrice - channelWidth, _Digits);
   double takeProfitMultiplier = TakeProfitMultiplier != 0.0 ? TakeProfitMultiplier : 1.5;
   double TP = TakeProfit != 0.0 ? NormalizeDouble(TakeProfit * 1000, _Digits) : NormalizeDouble(entryPrice + channelWidth * takeProfitMultiplier, _Digits);

   double volume = CalculateLotSize(channelWidth, 1.0); // keeps original 1% risk behavior from your helper

   if (volume <= 0) {
      Print("[ERROR] TriggerBuyOrder invalid volume ", volume);
      return false;
   }

   trade.SetExpertMagicNumber(magicNumber);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(_Symbol);

   PrintFormat("BUY: V=%.2f @ ASK=%.*f, SL=%.*f, TP=%.*f", volume, _Digits, entryPrice, _Digits, SL, _Digits, TP);

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

void checkTradeConditions() {
   ENUM_TIMEFRAMES timeframe = _Period;
   
   double central, upper, lower, central20, upper20, lower20;
   GetAdaptiveATRChannelByIndex(adaptiveATRHandle, 112, 0, central, upper, lower);
   GetAdaptiveATRChannelByIndex(adaptiveATRHandle, 20, 0,  central20, upper20, lower20);
   
   double channelWidth = upper - lower; // NOTE: This is in price units.
   margin = Margin;
   diff   = Difference;

   double currClose = iClose(_Symbol, timeframe, 0);
   double currOpen  = iOpen(_Symbol, timeframe, 0);
   double prevClose = iClose(_Symbol, timeframe, 1);
   double prevOpen  = iOpen(_Symbol, timeframe, 1);
   

   if (currClose > upper && central20 > upper && currOpen > prevOpen && prevOpen < prevClose && state == RETRACEMENT_BUY) {
      TriggerBuyOrder(channelWidth);
   }

   if (currClose < lower && central20 < lower && currOpen < prevOpen && prevOpen > prevClose && state == RETRACEMENT_SELL) {
      TriggerSellOrder(channelWidth);
   }

   if (currClose > upper && currOpen > prevOpen && prevOpen < prevClose) {
      Print("[BREAKOUT_BUY]");
      state = BREAKOUT_BUY;
   }

   if (currClose < lower && currOpen < prevOpen && prevOpen > prevClose) {
      Print("[BREAKOUT_SELL]");
      state = BREAKOUT_SELL;
   }

   if (currClose > upper && currOpen < prevOpen && prevOpen > prevClose && state == BREAKOUT_BUY) {
      Print("[RETRACEMENT_BUY]");
      state = RETRACEMENT_BUY;
   }

   if (currClose < lower && currOpen > prevOpen && prevOpen < prevClose && state == BREAKOUT_SELL) {
      Print("[RETRACEMENT_SELL]");
      state = RETRACEMENT_SELL;
   }
}

void checkBreakEvenConditions() {
   ulong ticket = PositionGetTicket(0);
   if (ticket != gTicket) {
      gTicket = ticket;
      gInitialSL = PositionGetDouble(POSITION_SL);
   }
   
   double entryPrice = PositionSelectByTicket(ticket) ? PositionGetDouble(POSITION_PRICE_OPEN) : 0.0;
   double breakEven = BreakEven != 0.0 ? BreakEven : 0.6;
   
   double stopLoss = gInitialSL;
   ENUM_POSITION_TYPE orderType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double currentPrice = orderType == POSITION_TYPE_BUY ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double stopLossDifference = 0.0;
   if (orderType == POSITION_TYPE_BUY) {
      stopLossDifference = entryPrice - stopLoss;
      if (entryPrice + (breakEven * stopLossDifference) <= currentPrice && breakEvenRun) {
         double TS = entryPrice + 0.01;                              // add one pip to the price
         Print("[BREAK_EVEN_BUY] Stop loss value:", TS);
         if (ModifyStopLoss(ticket, TS)) {
            breakEvenRun = true;
         }
      }
   } else if (orderType == POSITION_TYPE_SELL) {
      stopLossDifference = stopLoss - entryPrice;
      if (entryPrice - (breakEven * stopLossDifference) >= currentPrice && breakEvenRun) {
         double TS = entryPrice - 0.01;                              // add one pip to the price
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
   
   ulong ticket = PositionGetTicket(0);
   double stopLoss = gInitialSL;
   double entryPrice = PositionSelectByTicket(ticket) ? PositionGetDouble(POSITION_PRICE_OPEN) : 0.0;
   double currClose = iClose(_Symbol, timeframe, 1);
   double currHigh = iHigh(_Symbol, timeframe, 1);
   double currLow = iLow(_Symbol, timeframe, 1);
   ENUM_POSITION_TYPE orderType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   
   double stopLossDifference = 0.0;
   if (orderType == POSITION_TYPE_BUY) {
      stopLossDifference = entryPrice - stopLoss;
      if ((entryPrice <= currClose + (0.6 * stopLossDifference)) && (entryPrice <= currLow + (0.3 * stopLossDifference))) {
         Print("[TRAILING_STOP_BUY] Stop loss value:", currLow - 0.02);
         ModifyStopLoss(ticket, currLow - 0.02);
      }   
   } else if (orderType == POSITION_TYPE_SELL) {
      stopLossDifference = stopLoss - entryPrice;
      if ((entryPrice >= currClose - (0.6 * stopLossDifference)) && (entryPrice >= currHigh - (0.3 * stopLossDifference))) {
         Print("[TRAILING_STOP_SELL] Stop loss value:", currHigh + 0.02);
         ModifyStopLoss(ticket, currHigh + 0.02);
      }
   }
}

//--------------------------- EA-specific code ----------------------------//

double closedPrices[];
double margin = 0.0; // margin in pips
double diff   = 0.0; // candlestick difference in pips

bool IsNewBar() {
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(Symbol(), PERIOD_CURRENT, 0);

   if (currentBarTime != lastBarTime) {
      lastBarTime = currentBarTime;
      return true;
   }
   return false;
}

int OnInit() {
   ENUM_TIMEFRAMES timeframe = _Period;
   g_lastBarTime = iTime(_Symbol, timeframe, 0);

   Print("[INIT] Adaptive ATR Channel Retracement EA Initialized");
   Print(_Symbol, ",", EnumToString(timeframe), ", Magic#", MagicNumber);
   Print("Trading Session: ", TradingSessionStart, "-", TradingSessionEnd);
   Print("Risk/Trade: ", DoubleToString(RiskPercent, 2), "%");
   Print("Indicator Period: ", IndicatorPeriod, ", Multiplier: ", ATRMultiplier);

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT); // check for reasonable Pip setting based on digits
   if (MathAbs(pip - point * 10) > point * 0.1 && MathAbs(pip - point * 100) > point * 0.1) {
      Print("[WARN] Pip ", pip, " might not match standard symbol pip definition for ", _Symbol);
   }

   state = TRADE_IDLE;

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   Print("Adaptive ATR Channel Retracement EA Deinitialized. Reason ", reason);
   IndicatorRelease(adaptiveATRHandle);
}

void OnTick() {
   ENUM_TIMEFRAMES timeframe = _Period;
   
   if (!IsWithinTradingSession(TradingSessionStart, TradingSessionEnd)) {
      return;
   }
    
   if (PositionSelect(_Symbol)) {
      checkBreakEvenConditions();
      checkTrailingStopConditions();
      return;
   } else {
      gTicket = 0;
      gInitialSL = 0.0;
      breakEvenRun = false;
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