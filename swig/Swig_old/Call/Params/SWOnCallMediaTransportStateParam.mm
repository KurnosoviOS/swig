//
//  SWOnCallMediaTransportStateParam.m
//  swig
//
//  Created by Pierre-Marc Airoldi on 2014-08-19.
//  Copyright (c) 2014 PeteAppDesigns. All rights reserved.
//

#import "SWOnCallMediaTransportStateParam.h"

@implementation SWOnCallMediaTransportStateParam

+(instancetype)onParamFromParam:(pj::OnCallMediaTransportStateParam)param {

    return [SWOnCallMediaTransportStateParam new];
}

@end