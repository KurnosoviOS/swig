//
//  SWEndpoint.m
//  swig
//
//  Created by Pierre-Marc Airoldi on 2014-08-20.
//  Copyright (c) 2014 PeteAppDesigns. All rights reserved.
//

#import <UIKit/UIKit.h>

#import "SWEndpoint.h"
#import "SWTransportConfiguration.h"
#import "SWEndpointConfiguration.h"
#import "SWAccount.h"
#import "SWCall.h"
#import "pjsua.h"
#import "NSString+PJString.h"
#import <AFNetworkReachabilityManager.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

#import <libextobjc/extobjc.h>
#import "Logger.h"
#import "SWAccountConfiguration.h"
#import "SWUriFormatter.h"

#include <pjsua-lib/pjsua.h>
#include <pjsua-lib/pjsua_internal.h>

#import "UIDevice+FCUUID.h"

@import CoreTelephony;

#define KEEP_ALIVE_INTERVAL 600

typedef void (^SWAccountStateChangeBlock)(SWAccount *account);
typedef void (^SWIncomingCallBlock)(SWAccount *account, SWCall *call);
typedef void (^SWCallStateChangeBlock)(SWAccount *account, SWCall *call, pjsip_status_code statusCode);
typedef void (^SWCallMediaStateChangeBlock)(SWAccount *account, SWCall *call);


//thread statics
static pj_thread_t *thread;

//callback functions

static void SWOnIncomingCall(pjsua_acc_id acc_id, pjsua_call_id call_id, pjsip_rx_data *rdata);

static void SWOnCallMediaState(pjsua_call_id call_id);

static void SWOnCallMediaEvent(pjsua_call_id call_id, unsigned med_idx, pjmedia_event *event);

static void SWOnCallState(pjsua_call_id call_id, pjsip_event *e);

static void SWOnCallTransferStatus(pjsua_call_id call_id, int st_code, const pj_str_t *st_text, pj_bool_t final, pj_bool_t *p_cont);

static void SWOnCallReplaced(pjsua_call_id old_call_id, pjsua_call_id new_call_id);

static void SWOnRegState2(pjsua_acc_id acc_id, pjsua_reg_info *info);

static void SWOnRegStarted(pjsua_acc_id acc_id, pj_bool_t renew);

static void SWOnNatDetect(const pj_stun_nat_detect_result *res);

static void SWOnTransportState (pjsip_transport *tp, pjsip_transport_state state, const pjsip_transport_state_info *info);

static void SWOnDTMFDigit (pjsua_call_id call_id, int digit);

static pjsip_redirect_op SWOnCallRedirected(pjsua_call_id call_id, const pjsip_uri *target, const pjsip_event *e);

static void SWOnTyping (pjsua_call_id call_id, const pj_str_t *from, const pj_str_t *to, const pj_str_t *contact, pj_bool_t is_typing, pjsip_rx_data *rdata, pjsua_acc_id acc_id);


static pjsip_method pjsip_command_method;
static pjsip_method pjsip_syncdone_method;

static int rport;
static pj_str_t rhost;

static int resp_rport;
static pj_str_t resp_rhost;

static void fixContactHeader(pjsip_tx_data *tdata) {
    //На стороне B фиксим заголовок контакт в INVITE и UPDATE ибо по умолчанию там какая-то левота.
    pjsip_contact_hdr *contact = ((pjsip_contact_hdr*)pjsip_msg_find_hdr(tdata->msg, PJSIP_H_CONTACT, NULL));
    if (contact) {
        pjsip_sip_uri *contact_uri = (pjsip_sip_uri *)pjsip_uri_get_uri(contact->uri);
        
        pjsip_cseq_hdr *csec_hdr = PJSIP_MSG_CSEQ_HDR(tdata->msg);
        
        pj_bool_t need_fix_contact = PJ_FALSE;
        
        pj_str_t invite = pj_str((char *)"INVITE");
        pj_str_t update = pj_str((char *)"UPDATE");
        
        if (csec_hdr && (pj_strcmp(&csec_hdr->method.name, &invite) == 0 || pj_strcmp(&csec_hdr->method.name, &update) == 0)) {
            need_fix_contact = PJ_TRUE;
        }
        
        if (need_fix_contact && rport > 0 && tdata->tp_info.transport->remote_name.port == 5060) {
            NSLog(@"fixContactHeader");
            
            pjsip_msg_find_remove_hdr(tdata->msg, PJSIP_H_CONTACT, nil);
            contact_uri->port = rport;
            contact_uri->host = rhost;
            contact->uri = contact_uri;
            
            pjsip_msg_add_hdr(tdata->msg, (pjsip_hdr*)contact);
        }
    }
}

static pj_bool_t on_rx_request(pjsip_rx_data *rdata)
{
    //    fixContactHeaderRdata(rdata);
    //    fixContactHeader(rdata);
    return [[SWEndpoint sharedEndpoint] rxRequestPackageProcessing:rdata];
}


static pj_bool_t on_rx_response(pjsip_rx_data *rdata)
{
    return [[SWEndpoint sharedEndpoint] rxResponsePackageProcessing:rdata];
}

static pj_bool_t on_tx_response(pjsip_tx_data *tdata)
{
    fixContactHeader(tdata);
    return [[SWEndpoint sharedEndpoint] txResponsePackageProcessing:tdata];
}


static pj_bool_t on_tx_request(pjsip_tx_data *tdata)
{
    fixContactHeader(tdata);
    return [[SWEndpoint sharedEndpoint] txRequestPackageProcessing:tdata];
}


static pjsip_module sipgate_module =
{
    NULL, NULL,	             /* prev and next */
    { (char *)"sipmessenger-core", 17},   /* Name */
    //    { "mod-default-handler", 19 },
    -1,                      /* Id */
    //    PJSIP_MOD_PRIORITY_APPLICATION,/* Priority	 */
    PJSIP_MOD_PRIORITY_TRANSPORT_LAYER, /* Priority */
    NULL,                    /* load() */
    NULL,                    /* start() */
    NULL,                    /* stop() */
    NULL,                    /* unload() */
    &on_rx_request,          /* on_rx_request() */
    &on_rx_response,         /* on_rx_response() */
    &on_tx_request,        /* on_tx_request() */
    &on_tx_response,       /* on_tx_response() */
    NULL,                    /* on_tsx_state() */
};

static void refer_notify_callback(void *token, pjsip_event *e) {
    pjsip_via_hdr *via_hdr = (pjsip_via_hdr *)e->body.rx_msg.rdata->msg_info.via;
    if (via_hdr) {
        rport = via_hdr->rport_param;
        rhost = [[NSString stringWithPJString:via_hdr->recvd_param] pjString];
        NSLog(@"MyRealIP: %@:%d", [NSString stringWithPJString:via_hdr->recvd_param], via_hdr->rport_param);
    }
}


@interface SWEndpoint ()

@property (nonatomic, copy) SWIncomingCallBlock incomingCallBlock;
@property (nonatomic, copy) SWCallStateChangeBlock callStateChangeBlock;
@property (nonatomic, copy) SWCallMediaStateChangeBlock callMediaStateChangeBlock;
@property (nonatomic, copy) SWSyncDoneBlock syncDoneBlock;
@property (nonatomic, copy) SWGroupCreatedBlock groupCreatedBlock;

//@property (nonatomic, copy) SWMessageSentBlock messageSentBlock;
@property (nonatomic, copy) SWMessageReceivedBlock messageReceivedBlock;
@property (nonatomic, copy) SWMessageDeletedBlock messageDeletedBlock;
@property (nonatomic, copy) SWMessageStatusBlock messageStatusBlock;
@property (nonatomic, copy) SWAbonentStatusBlock abonentStatusBlock;
@property (nonatomic, copy) SWGroupMembersUpdatedBlock groupMembersUpdatedBlock;
@property (nonatomic, copy) SWTypingBlock typingBlock;

@property (nonatomic, copy) SWNeedConfirmBlock needConfirmBlock;
@property (nonatomic, copy) SWConfirmationBlock confirmationBlock;

//@property (nonatomic, copy) SWReadyToSendFileBlock readyToSendFileBlock;

@property (nonatomic, copy) SWGetCounterBlock getCountersBlock;
//@property (nonatomic, copy) SWContactServerUpdatedBlock contactsServerUpdatedBlock;
//@property (nonatomic, copy) SWPushServerUpdatedBlock pushServerUpdatedBlock;
//@property (nonatomic, copy) SWBalanceUpdatedBlock balanceUpdatedBlock;
@property (nonatomic, copy) SWSettingsUpdatedBlock settingsUpdatedBlock;

@property (nonatomic, strong) NSMutableDictionary *accountStateChangeBlockObservers;

@property (nonatomic) pj_thread_t *thread;

@property (nonatomic, strong) CTCallCenter *callCenter;

@end

@implementation SWEndpoint

static SWEndpoint *_sharedEndpoint = nil;



+(id)sharedEndpoint {
    
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        _sharedEndpoint = [self new];
    });
    
    return _sharedEndpoint;
}

-(instancetype)init {
    
    if (_sharedEndpoint) {
        return _sharedEndpoint;
    }
    
    self = [super init];
    
    if (!self) {
        return nil;
    }
    
    pj_str_t method_string_command = pj_str("COMMAND");
    pjsip_method_init_np(&pjsip_command_method, &method_string_command);
    
    pj_str_t method_string_syncdone = pj_str("SYNCDONE");
    pjsip_method_init_np(&pjsip_syncdone_method, &method_string_syncdone);
    
    
    self.accountStateChangeBlockObservers = [[NSMutableDictionary alloc] initWithCapacity:10];
    
    [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
    
    [DDLog addLogger:[DDASLLogger sharedInstance]];
    [DDLog addLogger:[DDTTYLogger sharedInstance]];
    
    DDFileLogger *fileLogger = [[DDFileLogger alloc] init];
    fileLogger.rollingFrequency = 0;
    fileLogger.maximumFileSize = 0;
    
    [DDLog addLogger:fileLogger];
    
    _accounts = [[NSMutableArray alloc] init];
    
    [self registerThread];
    
    NSURL *fileURL = [[NSBundle mainBundle] URLForResource:@"Ringtone" withExtension:@"aif"];
    
    _ringtone = [[SWRingtone alloc] initWithFileAtPath:fileURL];
    
    //TODO check if the reachability happens in background
    //FIX make sure connect doesnt get called too often
    //IP Change logic
    
    [[AFNetworkReachabilityManager sharedManager] setReachabilityStatusChangeBlock:^(AFNetworkReachabilityStatus status) {
        
        //        if ([AFNetworkReachabilityManager sharedManager].reachableViaWiFi) {
        //            [self performSelectorOnMainThread:@selector(keepAlive) withObject:nil waitUntilDone:YES];
        //        }
        //        else if ([AFNetworkReachabilityManager sharedManager].reachableViaWWAN) {
        //            [self performSelectorOnMainThread:@selector(keepAlive) withObject:nil waitUntilDone:YES];
        //        }
        //        else {
        //            //offline
        //        }
    }];
    
    
    [[AFNetworkReachabilityManager sharedManager] startMonitoring];
    
    self.callCenter = [[CTCallCenter alloc] init]; // get a CallCenter somehow; most likely as a global object or something similar?
    //
    [_callCenter setCallEventHandler:^(CTCall *call) {
        
        if ([[call callState] isEqual:CTCallStateConnected] || [[call callState] isEqual:CTCallStateIncoming]|| [[call callState] isEqual:CTCallStateDialing]) {
            SWAccount *account = [self firstAccount];
            SWCall *call = [account firstCall];
            if (call && call.mediaState == SWMediaStateActive) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [call setHold:^(NSError *error) {
                    }];
                });
            }
            
        } else if ([[call callState] isEqual:CTCallStateDisconnected]) {
            SWAccount *account = [self firstAccount];
            SWCall *call = [account firstCall];
            if (call && call.mediaState == SWMediaStateLocalHold) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [call reinvite:^(NSError *error) {
                    }];
                });
            }
            
        }
    }];
    
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector: @selector(handleEnteredForeground:) name: UIApplicationWillEnterForegroundNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector: @selector(handleEnteredBackground:) name: UIApplicationDidEnterBackgroundNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector: @selector(handleApplicationWillTeminate:) name:UIApplicationWillTerminateNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector: @selector(handleApplicationWillResignActiveNotification:) name:UIApplicationWillResignActiveNotification object:nil];
    
    return self;
}

-(void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillTerminateNotification object:nil];
    
    [self reset:^(NSError *error) {
        if (error) DDLogDebug(@"%@", [error description]);
    }];
}

#pragma Notification Methods

- (void) handleEnteredForeground: (NSNotification *)notification {
    NSLog(@"handleEnteredForeground %@", _callCenter.currentCalls);
    //    [self.firstAccount setPresenseStatusOnline:SWPresenseStateOnline completionHandler:^(NSError *error) {
    //    }];
    
}

- (void) handleApplicationWillResignActiveNotification: (NSNotification *)notification {
    NSLog(@"handleApplicationWillResignActiveNotification %@", _callCenter.currentCalls);
}

-(void)handleEnteredBackground:(NSNotification *)notification {
    NSLog(@"handleEnteredBackground %@", _callCenter.currentCalls);
    
    UIApplication *application = (UIApplication *)notification.object;
    
    [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:NULL];
    [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
    
    self.ringtone.volume = 0.0;
    
    //    [self performSelectorOnMainThread:@selector(keepAlive) withObject:nil waitUntilDone:YES];
    
    //    [self.firstAccount setPresenseStatusOnline:SWPresenseStateOffline completionHandler:^(NSError *error) {
    //    }];
    
    [application setKeepAliveTimeout:KEEP_ALIVE_INTERVAL handler: ^{
        [self performSelectorOnMainThread:@selector(keepAlive) withObject:nil waitUntilDone:YES];
    }];
}

-(void)handleApplicationWillTeminate:(NSNotification *)notification {
    
    UIApplication *application = (UIApplication *)notification.object;
    
    dispatch_sync(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        //TODO hangup all calls
        //TODO remove all accounts
        //TODO close all transports
        //TODO reset endpoint
        
        for (int i = 0; i < [self.accounts count]; ++i) {
            
            SWAccount *account = [self.accounts objectAtIndex:i];
            
            dispatch_semaphore_t semaphone = dispatch_semaphore_create(0);
            
            @weakify(account);
            [account disconnect:^(NSError *error) {
                
                @strongify(account);
                account = nil;
                
                dispatch_semaphore_signal(semaphone);
            }];
            
            dispatch_semaphore_wait(semaphone, DISPATCH_TIME_FOREVER);
        }
        
        NSMutableArray *mutableAccounts = [self.accounts mutableCopy];
        
        [mutableAccounts removeAllObjects];
        
        self.accounts = mutableAccounts;
        
        pj_status_t status = pjsua_destroy();
        
        [application setApplicationIconBadgeNumber:0];
    });
    
}

-(void)keepAlive {
    
    if (pjsua_get_state() != PJSUA_STATE_RUNNING) {
        return;
    }
    
    [self registerThread];
    
    for (SWAccount *account in self.accounts) {
        
        if (account.isValid) {
            
            dispatch_semaphore_t semaphone = dispatch_semaphore_create(0);
            
            [account connect:^(NSError *error) {
                
                dispatch_semaphore_signal(semaphone);
            }];
            
            dispatch_semaphore_wait(semaphone, DISPATCH_TIME_FOREVER);
        }
        
        else {
            
            dispatch_semaphore_t semaphone = dispatch_semaphore_create(0);
            
            [account disconnect:^(NSError *error) {
                
                dispatch_semaphore_signal(semaphone);
            }];
            
            dispatch_semaphore_wait(semaphone, DISPATCH_TIME_FOREVER);
        }
    }
}

#pragma Endpoint Methods

-(void)setEndpointConfiguration:(SWEndpointConfiguration *)endpointConfiguration {
    
    [self willChangeValueForKey:@"endpointConfiguration"];
    _endpointConfiguration = endpointConfiguration;
    [self didChangeValueForKey:@"endpointConfiguration"];
}

-(void)setRingtone:(SWRingtone *)ringtone {
    
    [self willChangeValueForKey:@"ringtone"];
    
    if (_ringtone.isPlaying) {
        [_ringtone stop];
        _ringtone = ringtone;
        [_ringtone start];
    }
    
    else {
        _ringtone = ringtone;
    }
    
    [self didChangeValueForKey:@"ringtone"];
}

-(void)configure:(SWEndpointConfiguration *)configuration completionHandler:(void(^)(NSError *error))handler {
    
    //TODO add lock to this method
    
    self.endpointConfiguration = configuration;
    
    pj_status_t status;
    
    status = pjsua_create();
    
    if (status != PJ_SUCCESS) {
        
        NSError *error = [NSError errorWithDomain:@"Error creating pjsua" code:status userInfo:nil];
        
        if (handler) {
            handler(error);
        }
        
        return;
    }
    
    pjsua_config ua_cfg;
    pjsua_logging_config log_cfg;
    pjsua_media_config media_cfg;
    
    
    pjsua_config_default(&ua_cfg);
    pjsua_logging_config_default(&log_cfg);
    pjsua_media_config_default(&media_cfg);
    
    ua_cfg.cb.on_incoming_call = &SWOnIncomingCall;
    ua_cfg.cb.on_call_media_state = &SWOnCallMediaState;
    ua_cfg.cb.on_call_media_event = &SWOnCallMediaEvent;
    ua_cfg.cb.on_call_state = &SWOnCallState;
    ua_cfg.cb.on_call_transfer_status = &SWOnCallTransferStatus;
    ua_cfg.cb.on_call_replaced = &SWOnCallReplaced;
    ua_cfg.cb.on_reg_state2 = &SWOnRegState2;
    ua_cfg.cb.on_reg_state = &SWOnRegState;
    ua_cfg.cb.on_reg_started = &SWOnRegStarted;
    ua_cfg.cb.on_nat_detect = &SWOnNatDetect;
    ua_cfg.cb.on_call_redirected = &SWOnCallRedirected;
    ua_cfg.cb.on_transport_state = &SWOnTransportState;
    ua_cfg.cb.on_dtmf_digit = &SWOnDTMFDigit;
    ua_cfg.cb.on_typing2 = &SWOnTyping;
    
    
    //    ua_cfg.stun_host = [@"stun.sipgate.net" pjString];
    
    ua_cfg.user_agent = pj_str((char *)"Polyphone iOS 1.0");
    
    ua_cfg.use_srtp = PJMEDIA_SRTP_MANDATORY;
    ua_cfg.srtp_secure_signaling = 2;
    
    //
    ua_cfg.max_calls = (unsigned int)self.endpointConfiguration.maxCalls;
    
    log_cfg.level = (unsigned int)self.endpointConfiguration.logLevel;
    log_cfg.console_level = (unsigned int)self.endpointConfiguration.logConsoleLevel;
    log_cfg.log_filename = [self.endpointConfiguration.logFilename pjString];
    log_cfg.log_file_flags = (unsigned int)self.endpointConfiguration.logFileFlags;
//    log_cfg.decor = 2;
    log_cfg.msg_logging = PJ_TRUE;
    log_cfg.cb = &printLogs;
    
    media_cfg.clock_rate = (unsigned int)self.endpointConfiguration.clockRate;
    media_cfg.snd_clock_rate = (unsigned int)self.endpointConfiguration.sndClockRate;
    media_cfg.no_vad = 1;
    
    
    status = pjsua_init(&ua_cfg, &log_cfg, &media_cfg);
    
    if (status != PJ_SUCCESS) {
        
        NSError *error = [NSError errorWithDomain:@"Error initializing pjsua" code:status userInfo:nil];
        
        if (handler) {
            handler(error);
        }
        
        return;
    }
    
    status = pjsip_endpt_register_module(pjsua_get_pjsip_endpt(), &sipgate_module);
    if (status != PJ_SUCCESS) {
        return;
    }
    
    status = pjnath_init();
    if (status != PJ_SUCCESS) {
        return;
    }
    
    
    //    status = pjmedia_srtp_init_lib(pjsua_get_pjmedia_endpt());
    //    if (status != PJ_SUCCESS) {
    //        NSLog(@"Cannot start srtp");
    //        return;
    //    }
    
    //TODO autodetect port by checking transportId!!!!
    
//    for (SWTransportConfiguration *transport in self.endpointConfiguration.transportConfigurations) {
        NSLog(@"Create transport %@", self.endpointConfiguration.transportConfigurations);
        pjsua_transport_config transportConfig;
        pjsua_transport_id transportId;
        
        pjsip_tls_setting tls_setting;
        pjsip_tls_setting_default(&tls_setting);
        
        
        tls_setting.verify_server = PJ_FALSE;
        tls_setting.method = PJSIP_TLSV1_METHOD;
    pj_time_val timeout = {10,0};
//    timeout.sec = 10;
//    timeout.msec = 0;
    tls_setting.timeout = timeout;
        
        pjsua_transport_config_default(&transportConfig);
//        transportConfig.tls_setting = tls_setting;
        int port_range = 1024 + (rand() % (int)(65535 - 1024 + 1));

        transportConfig.port = port_range;
//        transportConfig.port_range = port_range;
//        transportConfig.public_addr = pj_str((char *)"127.0.0.1:31337");

        
//        pjsip_transport_type_e transportType = (pjsip_transport_type_e)transport.transportType;
    
        status = pjsua_transport_create(PJSIP_TRANSPORT_TLS6, &transportConfig, &transportId);
        if (status != PJ_SUCCESS) {
            
            NSError *error = [NSError errorWithDomain:@"Error creating pjsua transport" code:status userInfo:nil];
            
            if (handler) {
                handler(error);
            }
            
            return;
        }
//    }
    
    [self start:handler];
}


static void printLogs(int level, const char *data, int len) {
    NSString *theString =[NSString stringWithUTF8String:data];

    NSLog(@"PJSIP %d: %@", level, theString);
    
}

-(BOOL)hasTCPConfiguration {
    
    NSUInteger index = [self.endpointConfiguration.transportConfigurations indexOfObjectPassingTest:^BOOL(SWTransportConfiguration *obj, NSUInteger idx, BOOL *stop) {
        
        if (obj.transportType == SWTransportTypeTCP || obj.transportType == SWTransportTypeTCP6) {
            return YES;
            *stop = YES;
        }
        
        else {
            return NO;
        }
    }];
    
    if (index == NSNotFound) {
        return NO;
    }
    
    else {
        return YES;
    }
}

-(void)registerThread {
    
    if (pjsua_get_state() != PJSUA_STATE_RUNNING) {
        return;
    }
    
    if (!pj_thread_is_registered()) {
        pj_thread_register("swig", NULL, &thread);
    }
    
    else {
        thread = pj_thread_this();
    }
    
    //        if (!_pjPool) {
    //            dispatch_async(dispatch_get_main_queue(), ^{
    //                _pjPool = pjsua_pool_create("swig-pjsua", 512, 512);
    //            });
    //        }
}

- (pj_pool_t *) pjPool {
    static dispatch_once_t onceToken;
    static pj_pool_t *pool = nil;
    
    dispatch_once(&onceToken, ^{
        pool = pjsua_pool_create("swig-pjsua", 1024, 1024);
    });
    
    return pool;
}

-(void)start:(void(^)(NSError *error))handler {
    
    pj_status_t status = pjsua_start();
    
    if (status != PJ_SUCCESS) {
        
        NSError *error = [NSError errorWithDomain:@"Error starting pjsua" code:status userInfo:nil];
        
        if (handler) {
            handler(error);
        }
        
        return;
    }
    
    //    pjmedia_codec_info codecs[PJMEDIA_CODEC_MGR_MAX_CODECS];
    //    unsigned int prio[PJMEDIA_CODEC_MGR_MAX_CODECS];
    //    unsigned int count = PJ_ARRAY_SIZE(codecs);
    //
    //    pjmedia_codec_mgr *codec_mgr = pjmedia_endpt_get_codec_mgr(pjsua_get_pjmedia_endpt());
    //
    //    status = pjmedia_codec_mgr_enum_codecs(codec_mgr, &count, codecs, prio);
    //
    //    if (status==PJ_SUCCESS) {
    //        for (int i=0; i<count; i++) {
    //            NSLog(@"%@", [NSString stringWithFormat:@"%d %@/%u ", prio[i], [NSString stringWithPJString:codecs[i].encoding_name], codecs[i].clock_rate]);
    //
    //        }
    //    }
    //
    //
    if (handler) {
        handler(nil);
    }
}

-(void)reset:(void(^)(NSError *error))handler {
    //TODO shutdown agent correctly. stop all calls, destroy all accounts
    
    for (SWAccount *account in self.accounts) {
        
        [account endAllCalls];
        
        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        
        [account disconnect:^(NSError *error) {
            dispatch_semaphore_signal(sema);
            [self removeAccount:account];
        }];
        
        dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    }
    
    //    for (SWAccount *account in self.accounts) {
    //        [self removeAccount:account];
    //    }
    
    //    NSMutableArray *mutableArray = [self.accounts mutableCopy];
    //
    //    [mutableArray removeAllObjects];
    //
    //    self.accounts = mutableArray;
    
    //    pj_status_t status = pjsua_destroy();
    //
    //    if (status != PJ_SUCCESS) {
    //
    //        NSError *error = [NSError errorWithDomain:@"Error destroying pjsua" code:status userInfo:nil];
    //
    //        if (handler) {
    //            handler(error);
    //        }
    //
    //        return;
    //    }
    //
    //    if (handler) {
    //        handler(nil);
    //    }
}

-(void)restart:(void(^)(NSError *error))handler {
    
    pj_status_t status = pjsua_destroy2(PJSUA_DESTROY_NO_NETWORK);
    
    [[SWEndpoint sharedEndpoint] configure:self.endpointConfiguration completionHandler:^(NSError *error) {
        for (SWAccount *account in self.accounts) {
            [account configure:account.accountConfiguration completionHandler:^(NSError *error) {
            }];
        }
    }];
}

#pragma Account Management

-(void)addAccount:(SWAccount *)account {
    
    if (![self lookupAccount:account.accountId]) {
        
        NSMutableArray *mutableArray = [self.accounts mutableCopy];
        [mutableArray addObject:account];
        
        self.accounts = mutableArray;
    }
}

-(void)removeAccount:(SWAccount *)account {
    
    if ([self lookupAccount:account.accountId]) {
        
        NSMutableArray *mutableArray = [self.accounts mutableCopy];
        [mutableArray removeObject:account];
        
        self.accounts = mutableArray;
    }
}

-(SWAccount *)lookupAccount:(NSInteger)accountId {
    
    NSUInteger accountIndex = [self.accounts indexOfObjectPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
        
        SWAccount *account = (SWAccount *)obj;
        
        if (account.accountId == accountId && account.accountId != PJSUA_INVALID_ID) {
            return YES;
        }
        
        return NO;
    }];
    
    if (accountIndex != NSNotFound) {
        return [self.accounts objectAtIndex:accountIndex]; //TODO add more management
    }
    
    else {
        return nil;
    }
}
-(SWAccount *)firstAccount {
    
    if (self.accounts.count > 0) {
        return self.accounts[0];
    }
    
    else {
        return nil;
    }
}


#pragma Block Parameters

-(void)setAccountStateChangeBlock:(void(^)(SWAccount *account))accountStateChangeBlock forObserver: (id) observer {
    NSString *key = [NSString stringWithFormat:@"%p", observer];
    [_accountStateChangeBlockObservers setObject:[accountStateChangeBlock copy] forKey:key];
}

-(void)removeAccountStateChangeBlockForObserver: (id) observer {
    NSString *key = [NSString stringWithFormat:@"%p", observer];
    [_accountStateChangeBlockObservers removeObjectForKey:key];
}


-(void)setIncomingCallBlock:(void(^)(SWAccount *account, SWCall *call))incomingCallBlock {
    
    _incomingCallBlock = incomingCallBlock;
}

-(void)setCallStateChangeBlock:(void(^)(SWAccount *account, SWCall *call, pjsip_status_code statusCode))callStateChangeBlock {
    
    _callStateChangeBlock = callStateChangeBlock;
}

-(void)setCallMediaStateChangeBlock:(void(^)(SWAccount *account, SWCall *call))callMediaStateChangeBlock {
    
    _callMediaStateChangeBlock = callMediaStateChangeBlock;
}

-(void)setSyncDoneBlock:(void(^)(SWAccount *account))syncDoneBlock {
    _syncDoneBlock = syncDoneBlock;
}

-(void)setGroupCreatedBlock:(void (^)(SWAccount *account, NSInteger groupID, NSString *groupName))groupCreatedBlock {
    _groupCreatedBlock = groupCreatedBlock;
}

//- (void) setMessageSentBlock: (SWMessageSentBlock) messageSentBlock {
//    _messageSentBlock = messageSentBlock;
//}

- (void) setNeedConfirmBlock: (SWNeedConfirmBlock) needConfirmBlock {
    _needConfirmBlock = needConfirmBlock;
}

- (void) setConfirmationBlock: (SWConfirmationBlock) confirmationBlock {
    _confirmationBlock = confirmationBlock;
}

- (void) setMessageStatusBlock: (SWMessageStatusBlock) messageStatusBlock {
    _messageStatusBlock = messageStatusBlock;
}

- (void) setMessageDeletedBlock: (SWMessageDeletedBlock) messageDeletedBlock {
    _messageDeletedBlock = messageDeletedBlock;
}

//- (void) setReadyToSendFileBlock:(SWReadyToSendFileBlock)readyToSendFileBlock {
//    _readyToSendFileBlock = readyToSendFileBlock;
//}

- (void) setGetCountersBlock: (SWGetCounterBlock) getCountersBlock {
    _getCountersBlock = getCountersBlock;
}

- (void) setSettingsUpdatedBlock: (SWSettingsUpdatedBlock) settingsUpdatedBlock {
    _settingsUpdatedBlock = settingsUpdatedBlock;
}

//- (void) setPushServerUpdatedBlock: (SWPushServerUpdatedBlock) pushServerUpdatedBlock {
//    _pushServerUpdatedBlock = pushServerUpdatedBlock;
//}
//
//- (void) setBalanceUpdatedBlock: (SWBalanceUpdatedBlock) balanceUpdatedBlock {
//    _balanceUpdatedBlock = balanceUpdatedBlock;
//}
//

- (void) setGroupMembersUpdatedBlock: (SWGroupMembersUpdatedBlock) groupMembersUpdatedBlock {
    _groupMembersUpdatedBlock = groupMembersUpdatedBlock;
}

- (void) setTypingBlock: (SWTypingBlock) typingBlock {
    _typingBlock = typingBlock;
}


#pragma PJSUA Callbacks

static pjsip_transport *the_transport;

static void SWOnRegState2(pjsua_acc_id acc_id, pjsua_reg_info *info) {
    
    
    struct pjsip_regc_cbparam *rp = info->cbparam;
    
    
    SWAccount *account = [[SWEndpoint sharedEndpoint] lookupAccount:(int)acc_id];
#warning ЧТО-ТО ПАДАЛО!!! протестить потом
//    if (info->cbparam->code == PJSIP_SC_REQUEST_TIMEOUT) {
//        
//        dispatch_async(dispatch_get_main_queue(), ^{
//            [[SWEndpoint sharedEndpoint] restart:^(NSError *error) {
//            }];
//        });
//    }
    
    
    if (account) {
        [account accountStateChanged];
        NSArray *observersKeys = [[SWEndpoint sharedEndpoint].accountStateChangeBlockObservers allKeys];
        for (NSString *key in observersKeys) {
            SWAccountStateChangeBlock observer = [[SWEndpoint sharedEndpoint].accountStateChangeBlockObservers objectForKey:key];
            dispatch_async(dispatch_get_main_queue(), ^{
                observer(account);
            });
            
        }
    }
}

static void SWOnRegState(pjsua_acc_id acc_id) {
    SWAccount *account = [[SWEndpoint sharedEndpoint] lookupAccount:(int)acc_id];
#warning ЧТО-ТО ПАДАЛО!!! протестить потом
    //    if (info->cbparam->code == PJSIP_SC_REQUEST_TIMEOUT) {
    //
    //        dispatch_async(dispatch_get_main_queue(), ^{
    //            [[SWEndpoint sharedEndpoint] restart:^(NSError *error) {
    //            }];
    //        });
    //    }
    
    
    if (account) {
        [account accountStateChanged];
        NSArray *observersKeys = [[SWEndpoint sharedEndpoint].accountStateChangeBlockObservers allKeys];
        for (NSString *key in observersKeys) {
            SWAccountStateChangeBlock observer = [[SWEndpoint sharedEndpoint].accountStateChangeBlockObservers objectForKey:key];
            dispatch_async(dispatch_get_main_queue(), ^{
                observer(account);
            });
            
        }
    }
}


static void SWOnRegStarted(pjsua_acc_id acc_id, pj_bool_t renew) {
    
    SWAccount *account = [[SWEndpoint sharedEndpoint] lookupAccount:(int)acc_id];
    
    if (account) {
        [account accountStateConnecting];
        NSArray *observersKeys = [[SWEndpoint sharedEndpoint].accountStateChangeBlockObservers allKeys];
        for (NSString *key in observersKeys) {
            SWAccountStateChangeBlock observer = [[SWEndpoint sharedEndpoint].accountStateChangeBlockObservers objectForKey:key];
            dispatch_async(dispatch_get_main_queue(), ^{
                observer(account);
            });
            
        }
    }
}

static void SWOnIncomingCall(pjsua_acc_id acc_id, pjsua_call_id call_id, pjsip_rx_data *rdata) {
    
    SWAccount *account = [[SWEndpoint sharedEndpoint] lookupAccount:acc_id];
    
    if (account) {
        
        SWCall *call = [SWCall callWithId:call_id accountId:acc_id inBound:YES];
        
        if (call) {
            
            [account addCall:call];
            
            [call callStateChanged];
            
            if ([SWEndpoint sharedEndpoint].incomingCallBlock) {
                [SWEndpoint sharedEndpoint].incomingCallBlock(account, call);
            }
        }
    }
}

static void SWOnCallState(pjsua_call_id call_id, pjsip_event *e) {
    
    pjsua_call_info callInfo;
    pjsua_call_get_info(call_id, &callInfo);
    
    SWAccount *account = [[SWEndpoint sharedEndpoint] lookupAccount:callInfo.acc_id];
    
    if (account) {
        
        SWCall *call = [account lookupCall:call_id];
        
        if (call) {
            
            if (callInfo.state == PJSIP_INV_STATE_CONNECTING && callInfo.role == PJSIP_ROLE_UAC) {
                pjsip_via_hdr *via_hdr = e->body.rx_msg.rdata->msg_info.via;
                resp_rport = via_hdr->rport_param;
                
                resp_rhost = pj_str(via_hdr->recvd_param.ptr);
                resp_rhost.slen = via_hdr->recvd_param.slen;
                
                NSLog(@"MyRealIP: %@:%d", [NSString stringWithPJString:resp_rhost], resp_rport);
            }
            
            
            if (callInfo.state == PJSIP_INV_STATE_CONFIRMED && callInfo.role == PJSIP_ROLE_UAC) {
                
                pjsip_uri* local_contact_uri = pjsip_parse_uri([SWEndpoint sharedEndpoint].pjPool, callInfo.local_contact.ptr, callInfo.local_contact.slen, NULL);
                pjsip_sip_uri *local_contact_sip_uri = (pjsip_sip_uri *)pjsip_uri_get_uri(local_contact_uri);
                
                local_contact_sip_uri->port = resp_rport;
                local_contact_sip_uri->host = resp_rhost;
                
                char contact_buf[512];
                pj_str_t new_contact;
                new_contact.ptr = contact_buf;
                
                new_contact.slen = pjsip_uri_print(PJSIP_URI_IN_CONTACT_HDR, local_contact_sip_uri, contact_buf, 512);
                
                pjsip_tx_data *tdata;
                pjsua_call *call;
                pjsip_dialog *dlg = NULL;
                pj_status_t status;
                
                status = acquire_call("pjsua_call_update_contact()", call_id, &call, &dlg);
                if (status != PJ_SUCCESS) {
                    NSLog(@"cannot aquire call");
                }
                
                
                //                / Create UPDATE with new offer /
                status = pjsip_inv_update(call->inv, &new_contact, NULL, &tdata);
                if (status != PJ_SUCCESS) {
                    NSLog(@"Unable to create UPDATE request");
                }
                
                //                / Add additional headers etc /
                //                pjsua_process_msg_data(tdata, e->body.tx_msg);
                
                //                / Send the request /
                status = pjsip_inv_send_msg(call->inv, tdata);
                if (status != PJ_SUCCESS) {
                    NSLog(@"Unable to send UPDATE");
                }
                
                if (dlg) pjsip_dlg_dec_lock(dlg);
            }
            
            
            
            [call callStateChanged];
            
            if ([SWEndpoint sharedEndpoint].callStateChangeBlock) {
                [SWEndpoint sharedEndpoint].callStateChangeBlock(account, call, callInfo.last_status);
            }
            
            if (call.callState == SWCallStateDisconnected) {
                [account removeCall:call.callId];
                rport = 0;
                resp_rport = 0;
                rhost = pj_str("");
                resp_rhost = pj_str("");
            }
        }
    }
}

static void SWOnCallMediaState(pjsua_call_id call_id) {
    
    pjsua_call_info callInfo;
    pjsua_call_get_info(call_id, &callInfo);
    
    
    SWAccount *account = [[SWEndpoint sharedEndpoint] lookupAccount:callInfo.acc_id];
    
    if (account) {
        
        SWCall *call = [account lookupCall:call_id];
        
        if (call) {
            
            [call mediaStateChanged];
            
            if ([SWEndpoint sharedEndpoint].callMediaStateChangeBlock) {
                [SWEndpoint sharedEndpoint].callMediaStateChangeBlock(account, call);
            }
        }
    }
}

static void SWOnCallMediaEvent(pjsua_call_id call_id, unsigned med_idx, pjmedia_event *event) {
    NSLog(@"MediaEvent");
}

//TODO: implement these
static void SWOnCallTransferStatus(pjsua_call_id call_id, int st_code, const pj_str_t *st_text, pj_bool_t final, pj_bool_t *p_cont) {
    NSLog(@"%d", call_id);
}

static void SWOnCallReplaced(pjsua_call_id old_call_id, pjsua_call_id new_call_id) {
    
}

static void SWOnNatDetect(const pj_stun_nat_detect_result *res){
    
//    NSLog(@"Nat detect: %s", res->nat_type_name);
}

static void SWOnTransportState (pjsip_transport *tp, pjsip_transport_state state, const pjsip_transport_state_info *info) {
    if (state == PJSIP_TP_STATE_DISCONNECTED && the_transport == tp) {
        NSLog(@"xxx: Releasing transport..");
        pjsip_transport_dec_ref(the_transport);
        the_transport = NULL;
    }
    
    //    NSLog(@"%@ %@", tp, info);
}

static void SWOnDTMFDigit (pjsua_call_id call_id, int digit) {
    NSLog(@"SWOnDTMFDigit: %@", [NSString stringWithFormat:@"%c", digit]);
}


static pjsip_redirect_op SWOnCallRedirected(pjsua_call_id call_id, const pjsip_uri *target, const pjsip_event *e){
    return PJSIP_REDIRECT_ACCEPT;
}

static void SWOnTyping (pjsua_call_id call_id, const pj_str_t *from, const pj_str_t *to, const pj_str_t *contact, pj_bool_t is_typing, pjsip_rx_data *rdata, pjsua_acc_id acc_id) {
    SWAccount *account = [[SWEndpoint sharedEndpoint] lookupAccount:acc_id];
    
    if (account && [SWEndpoint sharedEndpoint].typingBlock) {
        pjsip_sip_uri *fromUri = (pjsip_sip_uri*)pjsip_uri_get_uri(rdata->msg_info.from->uri);
        NSString *fromUser = [NSString stringWithPJString:fromUri->user];
        [SWEndpoint sharedEndpoint].typingBlock(account, fromUser, (BOOL)is_typing);
    }

}

#pragma Setters/Getters

-(void)setAccounts:(NSArray *)accounts {
    
    [self willChangeValueForKey:@"accounts"];
    _accounts = accounts;
    [self didChangeValueForKey:@"accounts"];
}

- (pj_bool_t) rxRequestPackageProcessing: (pjsip_rx_data *)data {
    
    if (data == nil) {
        return PJ_FALSE;
    }
    
    if (pjsip_method_cmp(&data->msg_info.msg->line.req.method, &pjsip_message_method) == 0) {
        pjsip_ctype_hdr* content_type_hdr = (pjsip_ctype_hdr *)pjsip_msg_find_hdr(&data->msg_info.msg, PJSIP_H_CONTENT_TYPE, nil);
        pj_str_t subtype = pj_str((char *)"im-iscomposing+xml");
        int result = pj_strcmp(&content_type_hdr->media.subtype, &subtype);
        if (content_type_hdr != nil &&  result == 0) {
            return PJ_FALSE;
        }
        [self incomingMessage:data];
        return PJ_TRUE;
        //    } else if(pjsip_method_cmp(&data->msg_info.msg->line.req.method, &pjsip_subscribe_method) == 0) {
        //        puts("subs");
    } else if(pjsip_method_cmp(&data->msg_info.msg->line.req.method, &pjsip_options_method) == 0) {
        pjsip_endpt_respond_stateless(pjsua_get_pjsip_endpt(), data, PJSIP_SC_OK, NULL, NULL, NULL);
        return PJ_TRUE;
    } else if (pjsip_method_cmp(&data->msg_info.msg->line.req.method, &pjsip_notify_method) == 0) {
        [self incomingNotify:data];
        return PJ_TRUE;
        //    } else if (pjsip_method_cmp(&data->msg_info.msg->line.req.method, &pjsip_invite_method) == 0) {
        //        [self incomingInvite:data];
    } else if (pjsip_method_cmp(&data->msg_info.msg->line.req.method, &pjsip_refer_method) == 0) {
        [self incomingRefer:data];
        pjsip_endpt_respond_stateless(pjsua_get_pjsip_endpt(), data, PJSIP_SC_OK, NULL, NULL, NULL);
        return PJ_TRUE;
    } else if (pjsip_method_cmp(&data->msg_info.msg->line.req.method, &pjsip_command_method) == 0) {
        return [self incomingCommand:data];
    } else if (pjsip_method_cmp(&data->msg_info.msg->line.req.method, &pjsip_syncdone_method) == 0) {
        return [self incomingSyncDone:data];
    }
    
    return PJ_FALSE;
}

- (pj_bool_t) txRequestPackageProcessing:(pjsip_tx_data *) tdata {
    pjsip_from_hdr *from_hdr = PJSIP_MSG_FROM_HDR(tdata->msg);
    
    //    int status = tdata->msg_info.msg->line.status.code;
    
    pjsip_sip_uri *uri = (pjsip_sip_uri *)pjsip_uri_get_uri(from_hdr->uri);
    
    pjsua_acc_id acc_id = pjsua_acc_find_for_outgoing(&uri->user);
    
    SWAccount *account = [[SWEndpoint sharedEndpoint] lookupAccount:acc_id];
    
    if (pjsip_method_cmp(&tdata->msg->line.req.method, &pjsip_register_method) == 0 && [account.accountConfiguration.code length] == 4) {
        pj_str_t hname = pj_str((char *)"Auth");
        
        //        NSString *devID = [[UIDevice currentDevice] identifierForVendor].UUIDString;
        
        NSString *devID = [[UIDevice currentDevice] uuid];
        
        pj_str_t hvalue = [[NSString stringWithFormat:@"code=%@ UID=%@ DevID=%@", account.accountConfiguration.code, account.accountConfiguration.password, devID] pjString];
        [account.accountConfiguration setCode:@""];
        
        pjsip_generic_string_hdr* event_hdr = pjsip_generic_string_hdr_create(self.pjPool, &hname, &hvalue);
        
        pjsip_msg_add_hdr(tdata->msg, (pjsip_hdr*)event_hdr);
    }
    
    pjsip_authorization_hdr *auth_header = (pjsip_authorization_hdr *)pjsip_msg_find_hdr(tdata->msg, PJSIP_H_AUTHORIZATION, 0);
    if (_getCountersBlock && pjsip_method_cmp(&tdata->msg->line.req.method, &pjsip_register_method) == 0 && auth_header) {
        pj_str_t hname = pj_str((char *)"SYNC");
        
        __block struct Sync counters;
        //        dispatch_queue_t q = dispatch_queue_create("com.foo.samplequeue", NULL);
        //        dispatch_sync(q, ^{
        counters = _getCountersBlock(account);
        //        });
        
        pj_str_t hvalue = [[NSString stringWithFormat:@"last_smid_rx=%tu, last_smid_tx=%tu, last_report=%tu, last_view=%tu", counters.lastSmidRX, counters.lastSmidTX, counters.lastReport, counters.lastViev] pjString];
        
        pjsip_generic_string_hdr* sync_hdr = pjsip_generic_string_hdr_create(self.pjPool, &hname, &hvalue);
        
        pjsip_msg_add_hdr(tdata->msg, (pjsip_hdr*)sync_hdr);
    }
    
    return PJ_FALSE;
}

- (pj_bool_t) txResponsePackageProcessing:(pjsip_tx_data *) tdata {
    
    //    if (pjsip_method_cmp(&tdata->msg->type, &pjsip_register_method) == 0) {
    //
    //    pjsip_via_hdr *via_hdr = (pjsip_via_hdr *)pjsip_msg_find_hdr(tdata->msg, PJSIP_H_VIA, nil);
    //    if (via_hdr) {
    //        NSLog(@"MyRealIP: %@:%d", via_hdr->rport_param, via_hdr->recvd_param);
    //    }
    //
    //    }
    
    return PJ_FALSE;
}


- (pj_bool_t) rxResponsePackageProcessing:(pjsip_rx_data *)data {
    /* Разбираем - на какой запрос пришел ответ */
    NSString *call_id = [NSString stringWithPJString:data->msg_info.cid->id];
    int status = data->msg_info.msg->line.status.code;
    
    //    NSUInteger cseq = data->msg_info.cseq->cseq;
    pjsua_acc_id acc_id = 0;
    
    if (pjsua_acc_get_count() == 0) return PJ_FALSE;
//    acc_id = pjsua_acc_find_for_incoming(&data);
    SWAccount *account = [[SWEndpoint sharedEndpoint] lookupAccount:(int)acc_id];
    
    if (pjsip_method_cmp(&data->msg_info.cseq->method, &pjsip_register_method) == 0) {
        
        struct Settings settings;
        settings.fileServer = nil;
        settings.contactServer = nil;
        settings.pushServer = nil;
        
        pj_str_t contact_server_hdr_str = pj_str((char *)"Contact-Server");
        pjsip_generic_string_hdr* contact_server_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &contact_server_hdr_str, nil);
        if (contact_server_hdr != nil) {
            settings.contactServer = [[NSString stringWithPJString:contact_server_hdr->hvalue] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"<>"]];
        }
        
        pj_str_t push_server_hdr_str = pj_str((char *)"Push-Server");
        pjsip_generic_string_hdr* push_server_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &push_server_hdr_str, nil);
        if (push_server_hdr != nil) {
            settings.pushServer = [[NSString stringWithPJString:push_server_hdr->hvalue] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"<>"]];
        }
        
        pj_str_t file_server_hdr_str = pj_str((char *)"File-Server");
        pjsip_generic_string_hdr* file_server_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &file_server_hdr_str, nil);
        if (push_server_hdr != nil) {
            settings.fileServer = [[NSString stringWithPJString:file_server_hdr->hvalue] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"<>"]];
        }
        
        pj_str_t home_abonent_hdr_str = pj_str((char *)"Home-Abonent");
        pjsip_generic_string_hdr* home_abonent_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &home_abonent_hdr_str, nil);
        if (home_abonent_hdr != nil) {
            settings.homeAbonent = (BOOL)atoi(home_abonent_hdr->hvalue.ptr);
        }
        
        if (_settingsUpdatedBlock && settings.contactServer && settings.pushServer && settings.fileServer) {
            //            dispatch_async(dispatch_get_main_queue(), ^{
            _settingsUpdatedBlock(settings);
            //            });
            
        }
        
        if (status == PJSIP_SC_NOT_FOUND || status == PJSIP_SC_MOVED_TEMPORARILY){
            if (_needConfirmBlock && account.accountState == SWAccountStateConnecting) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSMutableDictionary *dict = [NSMutableDictionary new];
                    
                    pj_str_t register_server_hdr_str = pj_str((char *)"Register-Server");
                    pjsip_generic_string_hdr* register_server_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &register_server_hdr_str, nil);
                    if (register_server_hdr != nil) {
                        
                        NSString *registerServer = [[NSString stringWithPJString:register_server_hdr->hvalue] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"<>"]];
                        [dict setValue:registerServer forKey:@"Register-Server"];
                    }

                    _needConfirmBlock(account, status, dict);
                });
            }
            return PJ_FALSE;
        }
        
        if (status == PJSIP_SC_OK) {
            if (_confirmationBlock && (account.accountState == SWAccountStateConnected || account.accountState == SWAccountStateConnecting)) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    _confirmationBlock(nil);
                });
            }
            return PJ_FALSE;
        }
        
    }
    
    
    
    return PJ_FALSE;
}

#pragma mark Входящее уведомление
- (void) incomingNotify:(pjsip_rx_data *)data {
    /* Смотрим о каком абоненте речь в сообщении */
    
    pjsua_acc_id acc_id;
    if (pjsua_acc_get_count() == 0) return;
    
    acc_id = pjsua_acc_find_for_incoming(data);
    SWAccount *account = [[SWEndpoint sharedEndpoint] lookupAccount:(int)acc_id];
    
    
    pjsip_sip_uri *uri = (pjsip_sip_uri*)pjsip_uri_get_uri(data->msg_info.from->uri);
    NSString *abonent = [NSString stringWithPJString:uri->user];
    
    pj_str_t status_str    = pj_str((char *)"Status");
    pj_str_t delivered_str = pj_str((char *)"Event");
    
    /* Нужно разобраться что за уведомление пришло */
    /* заголовок Status: status_type      - статус абонента */
    /* заголовок Event: status            - статус сообщения SmID */
    
    /* Status? */
    pjsip_generic_string_hdr *status_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &status_str, nil);
    if (status_hdr != nil) {
        //        if (!InDestrxoy) {
        int  status;
        char   buf[32] = {0};
        memcpy(buf, status_hdr->hvalue.ptr, status_hdr->hvalue.slen);
        status = atoi(buf);
        
        
        NSDate *lastOnline = [NSDate date];
        pj_str_t last_online_hdr_str = pj_str((char *)"LastOnline");
        pjsip_generic_string_hdr* last_online_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &last_online_hdr_str, nil);
        if (last_online_hdr != nil) {
            NSString *dateString = [NSString stringWithPJString:last_online_hdr->hvalue];
            
            NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
            [dateFormatter setDateFormat:@"YYYY-MM-dd HH:mm:ss Z"];
            
            lastOnline = [dateFormatter dateFromString:dateString];
        }
        
        
        if (_abonentStatusBlock) {
            //            dispatch_async(dispatch_get_main_queue(), ^{
            _abonentStatusBlock(account, abonent, (SWPresenseState)status, lastOnline);
            //            });
        }
        
        [self sendSubmit:data withCode:PJSIP_SC_OK];
        return;
    }
    
    
    
    /* Event? */
    pjsip_generic_string_hdr *event_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &delivered_str, nil);
    if (event_hdr != nil) {
        
        pj_str_t  sync_hdr_str = pj_str((char *)"SYNC");
        pjsip_generic_string_hdr *sync_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &sync_hdr_str, nil);
        BOOL lastMessageInPack = NO;
        if (sync_hdr) {
            int num = 0;
            int total = 0;
            int seq = 0;
            int type = 0;
            
            sscanf(sync_hdr->hvalue.ptr, "num=%i, total=%i, seq=%i, type=%i", &num, &total, &seq, &type);
            
            
            if (total == seq) {
                lastMessageInPack = YES;
            }
        }
        
        
        /* Получаем SmID */
        NSUInteger sm_id = 0;
        pj_str_t  smid_hdr_str = pj_str((char *)"SMID");
        pjsip_generic_string_hdr* smid_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &smid_hdr_str, nil);
        if (smid_hdr != nil) {
            sm_id = atoi(smid_hdr->hvalue.ptr);
            NSUInteger event_value = atoi(event_hdr->hvalue.ptr);
            
            /* Передаем идентификатор и статус сообщения в GUI */
            if (_messageStatusBlock) {
                //                dispatch_async(dispatch_get_main_queue(), ^{
                _messageStatusBlock(account, sm_id, (SWMessageStatus) event_value, (sync_hdr?YES:NO), lastMessageInPack);
                //                });
            }
            
            [self sendSubmit:data withCode:PJSIP_SC_OK];
        }
        return;
    }
}

//- (void) incomingInvite:(pjsip_rx_data *)data {
//    /* Смотрим о каком абоненте речь в сообщении */
//
//}


- (void) incomingMessage:(pjsip_rx_data *)data {
    if (data == nil) {
        return;
    }
    
    pjsip_sip_uri *toUri = (pjsip_sip_uri*)pjsip_uri_get_uri(data->msg_info.to->uri);
    if (toUri == nil) {
        [self sendSubmit:data withCode:PJSIP_SC_BAD_REQUEST];
        return;
    }
    
    pjsua_acc_id acc_id;
    if (pjsua_acc_get_count() == 0) return;
    
    acc_id = pjsua_acc_find_for_incoming(data);
    SWAccount *account = [[SWEndpoint sharedEndpoint] lookupAccount:(int)acc_id];
    
    
    //    NSString *to = [NSString stringWithPJString:uri->user];
    //    if (![account.accountConfiguration.username isEqualToString:to]) {
    //        [self sendSubmit:data withCode:PJSIP_SC_NOT_FOUND];
    //        return;
    //    }
    
    
    pjsip_sip_uri *fromUri = (pjsip_sip_uri*)pjsip_uri_get_uri(data->msg_info.from->uri);
    
    NSString *fromUser = [NSString stringWithPJString:fromUri->user];
    NSString *toUser = [NSString stringWithPJString:toUri->user];
    
    NSString *message_txt = @"";
    
    if (data->msg_info.msg->body != nil) {
        message_txt = [[NSString alloc] initWithBytes:data->msg_info.msg->body->data length:(NSUInteger)data->msg_info.msg->body->len encoding:NSUTF8StringEncoding];
    }
    /* Выдираем Sm_ID */
    NSUInteger sm_id = 0;
    NSInteger group_id = 0;
    
    /* Смотрим есть ли в сообщении заголовок SmID */
    pj_str_t  smid_hdr_str = pj_str((char *)"SMID");
    pjsip_generic_string_hdr* smid_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &smid_hdr_str, nil);
    if (smid_hdr != nil) {
        sm_id = atoi(smid_hdr->hvalue.ptr);
    }
    
    pj_str_t  groupid_hdr_str = pj_str((char *)"GroupID");
    pjsip_generic_string_hdr* groupid_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &groupid_hdr_str, nil);
    if (groupid_hdr != nil) {
        group_id = atoi(groupid_hdr->hvalue.ptr);
    }
    
    
    SWFileType fileType = SWFileTypeNo;
    NSString *fileHash = @"";
    NSString *fileServer = @"";
    /* Смотрим есть ли в сообщении заголовок FileType */
    pj_str_t  file_type_hdr_str = pj_str((char *)"FileType");
    pjsip_generic_string_hdr* file_type_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &file_type_hdr_str, nil);
    if (file_type_hdr != nil) {
        fileType = (SWFileType)atoi(file_type_hdr->hvalue.ptr);
        
        pj_str_t  file_hash_hdr_str = pj_str((char *)"FileHash");
        pjsip_generic_string_hdr* file_hash_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &file_hash_hdr_str, nil);
        if (file_hash_hdr != nil) {
            NSInteger hashInt = atoi(file_hash_hdr->hvalue.ptr);
            fileHash = [NSString stringWithFormat:@"%x", hashInt];
        }
        pj_str_t  file_server_hdr_str = pj_str((char *)"File-Server");
        pjsip_generic_string_hdr* file_server_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &file_server_hdr_str, nil);
        if (file_server_hdr != nil) {
            fileServer = [[NSString stringWithPJString:file_server_hdr->hvalue] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"<>"]];
        }
    }
    
    NSDate *submitTime = [NSDate date];
    pj_str_t submit_time_hdr_str = pj_str((char *)"SubmitTime");
    pjsip_generic_string_hdr* submit_time_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &submit_time_hdr_str, nil);
    if (submit_time_hdr != nil) {
        NSString *dateString = [NSString stringWithPJString:submit_time_hdr->hvalue];
        
        NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
        [dateFormatter setDateFormat:@"YYYY-MM-dd HH:mm:ss Z"];
        
        submitTime = [dateFormatter dateFromString:dateString];
    }
    
    pj_str_t  sync_hdr_str = pj_str((char *)"SYNC");
    pjsip_generic_string_hdr *sync_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &sync_hdr_str, nil);
    BOOL lastMessageInPack = NO;
    if (sync_hdr) {
        int num = 0;
        int total = 0;
        int seq = 0;
        int type = 0;
        
        sscanf(sync_hdr->hvalue.ptr, "num=%i, total=%i, seq=%i, type=%i", &num, &total, &seq, &type);
        
        
        if (total == seq) {
            lastMessageInPack = YES;
        }
    }
    
    if (_messageReceivedBlock) {
        _messageReceivedBlock(account, fromUser, toUser, message_txt, (NSUInteger) sm_id, group_id, submitTime, fileType, fileHash, fileServer, (sync_hdr?YES:NO), lastMessageInPack);
    }
    
    [self sendSubmit:data withCode:PJSIP_SC_OK];
}
- (void) incomingRefer:(pjsip_rx_data *)data {
    /* Смотрим о каком абоненте речь в сообщении */
    
    pjsua_acc_id acc_id;
    if (pjsua_acc_get_count() == 0) return;
    
    acc_id = pjsua_acc_find_for_incoming(data);
    
    pj_str_t  smid_hdr_str = pj_str((char *)"Refer-To");
    pjsip_generic_string_hdr* refer_to = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &smid_hdr_str, nil);
    if (refer_to == nil) {
        return;
    }
    
    
    pj_status_t    status;
    pjsip_tx_data *tx_msg;
    
    pj_str_t hname = pj_str((char *)"Event");
    pj_str_t hvalue = pj_str((char *)"Ready");
    
    pjsip_generic_string_hdr* event_hdr = pjsip_generic_string_hdr_create(self.pjPool, &hname, &hvalue);
    
    
    pjsua_transport_info transport_info;
    pjsua_transport_get_info(0, &transport_info);
    
    
    pjsua_acc_info info;
    
    pjsua_acc_get_info(acc_id, &info);
    
    
    pjsip_sip_uri *to = (pjsip_sip_uri *)pjsip_uri_get_uri(data->msg_info.to->uri);
    pjsip_sip_uri *from = (pjsip_sip_uri *)pjsip_uri_get_uri(data->msg_info.from->uri);
    
    char to_string[256];
    char from_string[256];
    
    pj_str_t source;
    source.ptr = to_string;
    source.slen = snprintf(to_string, 256, "sips:%.*s@%.*s", (int)to->user.slen, to->user.ptr, (int)to->host.slen,to->host.ptr);
    
    pj_str_t target;
    target.ptr = from_string;
    target.slen = snprintf(from_string, 256, "sips:%.*s@%.*s", (int)from->user.slen, from->user.ptr, (int)from->host.slen,from->host.ptr);
    /* Создаем непосредственно запрос */
    status = pjsip_endpt_create_request(pjsua_get_pjsip_endpt(),
                                        &pjsip_notify_method,
                                        &refer_to->hvalue, //proxy
                                        &source, //from
                                        &target, //to
                                        &info.acc_uri, //contact
                                        &data->msg_info.cid->id,
                                        data->msg_info.cseq->cseq,
                                        nil,
                                        &tx_msg);
    
    
    if (status != PJ_SUCCESS) {
        return;
    }
    
    
    pjsip_msg_add_hdr(tx_msg->msg, (pjsip_hdr*)event_hdr);
    
    if (status != PJ_SUCCESS) {
        return;
    }
    
    pjsip_endpt_send_request(pjsua_get_pjsip_endpt(), tx_msg, 1000, nil, &refer_notify_callback);
    
    //    status = pjsip_endpt_send_request_stateless(pjsua_get_pjsip_endpt(), tx_msg, nil, nil);
    
    if (status != PJ_SUCCESS) {
        return;
    }
}

- (pj_status_t) incomingCommand:(pjsip_rx_data *)data {
    
    pjsua_acc_id acc_id;
    if (pjsua_acc_get_count() == 0) return PJ_FALSE;
    acc_id = pjsua_acc_find_for_incoming(data);
    SWAccount *account = [[SWEndpoint sharedEndpoint] lookupAccount:(int)acc_id];
    pj_str_t command_name_hdr_str = pj_str((char *)"Command-Name");
    pjsip_generic_string_hdr *command_name_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &command_name_hdr_str, NULL);
    
    pj_str_t command_sync = pj_str((char *)"Sync");
    pj_str_t command_delete_message = pj_str((char *)"DeleteMessage");
    pj_str_t command_create_chat = pj_str((char *)"CreateChat");

    pj_str_t command_add_abonent = pj_str((char *)"AddAbonent");
    pj_str_t command_delete_abonent = pj_str((char *)"DeleteAbonent");

    
    pjsip_generic_string_hdr* new_name_hdr = pjsip_generic_string_hdr_create(self.pjPool, &command_name_hdr->name, &command_name_hdr->hvalue);
    
    struct pjsip_hdr hdr_list;
    
    pj_list_init(&hdr_list);
    
    pj_list_push_back(&hdr_list, new_name_hdr);
    
    if (command_name_hdr != nil && pj_strcmp(&command_name_hdr->hvalue, &command_sync) == 0) {
        pj_status_t status = pjsip_endpt_respond_stateless(pjsua_get_pjsip_endpt(), data, PJSIP_SC_OK, NULL, &hdr_list, NULL);
        NSLog(@"RespondToCommand %d", status);
        
        status = pjsua_acc_set_registration(acc_id, PJ_TRUE);
        if (status != PJ_SUCCESS) {
            NSLog(@"Failed to reregister");
        }
        return PJ_TRUE;
    }
    
    if (command_name_hdr != nil && pj_strcmp(&command_name_hdr->hvalue, &command_delete_message) == 0) {
        
        
        pj_str_t smid_hdr_str = pj_str((char *)"SMID");
        pjsip_generic_string_hdr *smid_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &smid_hdr_str, nil);
        
        pjsip_generic_string_hdr* new_smid_hdr = pjsip_generic_string_hdr_create(self.pjPool, &smid_hdr->name, &smid_hdr->hvalue);
        
        
        pj_list_push_back(&hdr_list, new_smid_hdr);
        
        if (smid_hdr != nil) {
            NSInteger messageID = atoi(((pjsip_generic_string_hdr *)smid_hdr)->hvalue.ptr);
            
            if (_messageDeletedBlock) {
                _messageDeletedBlock(account, messageID);
            }
        }
        
        pj_status_t status = pjsip_endpt_respond_stateless(pjsua_get_pjsip_endpt(), data, PJSIP_SC_OK, NULL, &hdr_list, NULL);
        
        
        if (status != PJ_SUCCESS) {
            NSLog(@"Failed to respond");
        }
        
        return PJ_TRUE;
    }

    if (command_name_hdr != nil && pj_strcmp(&command_name_hdr->hvalue, &command_create_chat) == 0) {
        NSString *groupName;
        
        pj_str_t  name_hdr_str = pj_str((char *)"Command-Value");
        pjsip_generic_string_hdr* name_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &name_hdr_str, nil);
        if (name_hdr != nil) {
            groupName = [NSString stringWithPJString:name_hdr->hvalue];
        }
        
        
        NSInteger group_id = 0;
        pj_str_t  groupid_hdr_str = pj_str((char *)"GroupID");
        pjsip_generic_string_hdr* groupid_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &groupid_hdr_str, nil);
        if (groupid_hdr != nil) {
            group_id = atoi(groupid_hdr->hvalue.ptr);
        }

        
        
        if (group_id > 0) {
            if (_groupCreatedBlock) {
                _groupCreatedBlock(account, group_id, groupName);
            }
        }
        return PJ_TRUE;
    }
    
    if (command_name_hdr != nil && (pj_strcmp(&command_name_hdr->hvalue, &command_add_abonent) == 0 || pj_strcmp(&command_name_hdr->hvalue, &command_delete_abonent) == 0)) {
        
        NSInteger groupID = 0;
        pj_str_t  groupid_hdr_str = pj_str((char *)"Command-Value");
        pjsip_generic_string_hdr* groupid_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &groupid_hdr_str, nil);
        if (groupid_hdr != nil) {
            groupID = atoi(groupid_hdr->hvalue.ptr);
        }

        BOOL abonentAdded = NO;
        if (pj_strcmp(&command_name_hdr->hvalue, &command_add_abonent) == 0) {
            abonentAdded = YES;
        }
        
        NSString *abonent = @"";
        
        if (data->msg_info.msg->body != nil) {
            abonent = [[NSString alloc] initWithBytes:data->msg_info.msg->body->data length:(NSUInteger)data->msg_info.msg->body->len encoding:NSUTF8StringEncoding];
        }
        
        pjsip_sip_uri *fromUri = (pjsip_sip_uri*)pjsip_uri_get_uri(data->msg_info.from->uri);
        
        NSString *admin = [NSString stringWithPJString:fromUri->user];
        
        
        _groupMembersUpdatedBlock(account, abonent, admin, groupID, abonentAdded);
        return PJ_TRUE;
    }

    
    return PJ_FALSE;
}

- (pj_status_t) incomingSyncDone:(pjsip_rx_data *)data {
    pjsua_acc_id acc_id = 0;
    if (pjsua_acc_get_count() == 0) return PJ_FALSE;
//    acc_id = pjsua_acc_find_for_incoming(data);
    SWAccount *account = [[SWEndpoint sharedEndpoint] lookupAccount:(int)acc_id];
    
    if (_syncDoneBlock) {
        _syncDoneBlock(account);
    }
    pj_status_t status = pjsip_endpt_respond_stateless(pjsua_get_pjsip_endpt(), data, PJSIP_SC_OK, NULL, NULL, NULL);
    
    if (status == PJ_SUCCESS) {
        return PJ_TRUE;
    }
    return PJ_FALSE;
}


#pragma mark - Отправляем абоненту результат обработки его сообщения
- (BOOL) sendSubmit:(pjsip_rx_data *) message withCode:(int32_t) answer_code {
    pjsip_tx_data *response;
    pj_status_t status;
    bool ret_value = false;
    int sm_id;
    
    /* Готовим ответ абоненту о результате регистрации */
    status = pjsip_endpt_create_response(pjsua_get_pjsip_endpt(), message, answer_code, nil, &response);
    if (status == PJ_SUCCESS) {
        
        pj_str_t smid_hdr_str = pj_str((char *)"SMID");
        pjsip_hdr *smid_hdr = (pjsip_hdr*)pjsip_msg_find_hdr_by_name(message->msg_info.msg, &smid_hdr_str, nil);
        
        pj_str_t  sync_hdr_str = pj_str((char *)"SYNC");
        pjsip_generic_string_hdr *sync_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(message->msg_info.msg, &sync_hdr_str, nil);
        
        if (smid_hdr != nil) {
            pjsip_msg_add_hdr(response->msg, smid_hdr);
            sm_id = atoi(((pjsip_generic_string_hdr *)smid_hdr)->hvalue.ptr);
        }
        
        if (sync_hdr != nil) {
            int num = 0;
            int total = 0;
            int seq = 0;
            int type = 0;
            
            sscanf(sync_hdr->hvalue.ptr, "num=%i, total=%i, seq=%i, type=%i", &num, &total, &seq, &type);
            
            
            if (total == seq) {
                char sync_buf[256];
                
                pj_str_t hname = pj_str((char *)"SYNC");
                pj_str_t hvalue;
                hvalue.ptr = sync_buf;
                hvalue.slen = snprintf(sync_buf, 256, "num=%i, smid=%i, type=%i", num, sm_id, type);
                
                pjsip_generic_string_hdr* submit_sync_hdr = pjsip_generic_string_hdr_create(response->pool, &hname, &hvalue);
                if (submit_sync_hdr != nil) {
                    pjsip_msg_add_hdr(response->msg, submit_sync_hdr);
                }
                
                //В поле TO всегда отвечаем, что это мы. иначе - пизда.
                
                pjsip_to_hdr *to_hdr = pjsip_to_hdr_create(self.pjPool);
                
                pjsua_acc_id acc_id;
                if (pjsua_acc_get_count() == 0) return PJ_FALSE;
                
                acc_id = pjsua_acc_find_for_incoming(message);
                
                pjsua_acc_info info;
                
                status = pjsua_acc_get_info(acc_id, &info);
                
                pjsip_uri *uri = (pjsip_name_addr*)pjsip_parse_uri(self.pjPool, info.acc_uri.ptr, info.acc_uri.slen, PJSIP_PARSE_URI_AS_NAMEADDR);
                
                to_hdr->uri = uri;
                pjsip_msg_find_remove_hdr(response->msg, PJSIP_H_TO, NULL);
                //
                pjsip_msg_add_hdr(response->msg, to_hdr);
                
            } else {
                return YES;
            }
        }
        
        
        /* Получаем адрес, куда мы должны отправить ответ */
        pjsip_response_addr  response_addr;
        status = pjsip_get_response_addr(response->pool, message, &response_addr);
        if (status == PJ_SUCCESS) {
            /* Отправляем ответ на регистрацию */
            status = pjsip_endpt_send_response(pjsua_get_pjsip_endpt(), &response_addr, response, nil, nil);
            if (status == PJ_SUCCESS) {
                ret_value = true;
            }
        }
    }
    if (status != PJ_SUCCESS) {
        NSLog(@"Error");
        //        [self parseError:status];
    }
    return ret_value;
}

@end
