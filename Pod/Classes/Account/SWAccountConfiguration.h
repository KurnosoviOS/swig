//
//  SWAccountConfiguration.h
//  swig
//
//  Created by Pierre-Marc Airoldi on 2014-08-20.
//  Copyright (c) 2014 PeteAppDesigns. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

@interface SWAccountConfiguration : NSObject

@property (nonatomic, strong) NSString *displayName;
@property (nonatomic, strong) NSString *address;
@property (nonatomic, strong) NSString *domain;
@property (nonatomic, strong) NSString *proxy;
@property (nonatomic, strong) NSString *authScheme;
@property (nonatomic, strong) NSString *authRealm;
@property (nonatomic, strong) NSString *username;
@property (nonatomic, strong) NSString *password;
@property (nonatomic, strong) NSString *code;
@property (nonatomic) BOOL registerOnAdd;
@property (nonatomic) BOOL noRegister;
@property (nonatomic) BOOL publishEnabled;
@property (nonatomic, assign) CGSize outputVideoSize;
@property (nonatomic, assign) NSInteger registrationTimeout;

+(NSString *)addressFromUsername:(NSString *)username domain:(NSString *)domain;

@end
