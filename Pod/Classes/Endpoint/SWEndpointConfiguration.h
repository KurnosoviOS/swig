//
//  SWEndpointConfiguration.h
//  swig
//
//  Created by Pierre-Marc Airoldi on 2014-08-20.
//  Copyright (c) 2014 PeteAppDesigns. All rights reserved.
//

#import <Foundation/Foundation.h>

@class SWRingtoneDescription, SWCall;

@interface SWEndpointConfiguration : NSObject

//ua config
@property (nonatomic) NSUInteger maxCalls; //4 is default

//log config
@property (nonatomic) NSUInteger logLevel; //5 is default
@property (nonatomic) NSUInteger logConsoleLevel; //4 is default
@property (nonatomic, strong) NSString *logFilename; //nil by default
@property (nonatomic) NSUInteger logFileFlags; //append by default

//media config
@property (nonatomic) NSUInteger clockRate; //16kHZ is default
@property (nonatomic) NSUInteger sndClockRate; //0 is default

//transport configurations
@property (nonatomic, strong) NSArray *transportConfigurations; //empty by default must specify

@property (nonatomic, readonly) NSMutableDictionary <NSNumber *, SWRingtoneDescription *> *ringtones;
@property (nonatomic, copy, nullable) SWRingtoneDescription* (^getRingtoneBlock)(NSInteger reason, SWCall *call);
@property (nonatomic, assign) BOOL callKitCanHandleAudioSession;
@property (nonatomic, copy, nullable) BOOL (^areOtherCallsBlock)();
@property (nonatomic, copy, nullable) void (^logBlock)(NSString *prefix, const char *file, int lineNumber, const char *funcName, NSString *msg);

+(instancetype)configurationWithTransportConfigurations:(NSArray *)transportConfigurations;

@end
