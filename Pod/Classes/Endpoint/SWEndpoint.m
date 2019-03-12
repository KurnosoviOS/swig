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
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <SystemConfiguration/SystemConfiguration.h>

#import <libextobjc/extobjc.h>
#import "Logger.h"
#import "SWAccountConfiguration.h"
#import "SWUriFormatter.h"

#include <pjsua-lib/pjsua.h>
#include <pjsua-lib/pjsua_internal.h>

#import "UIDevice+FCUUID.h"

#import "EWFileLogger.h"

#import "transport_adapter_fec.h"
#import "transport_adapter_nack.h"

#import "SWThreadManager.h"
#import "SWAudioSessionObserver.h"
#import "SWRingtoneDescription.h"
#import "SWMessageSender.h"
#import "SWIntentManager.h"

#import "SWThreadManager.h"

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

//TODO: проверить, нужна ли вообще эта хрень
static void fixContactHeader(pjsip_tx_data *tdata) {
    
    //На стороне B фиксим заголовок контакт в INVITE и UPDATE ибо по умолчанию там какая-то левота.
    //rightFindHeader(tdata->msg, PJSIP_H_CONTACT, NULL);
    
    //Старый вариант (сиповский). При копировании/изменении tdata уходил в бесконечный цикл.
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
    if (e->body.tsx_state.type != PJSIP_EVENT_RX_MSG) {
        return;
    }
    pjsip_via_hdr *via_hdr = (pjsip_via_hdr *)e->body.rx_msg.rdata->msg_info.via;
    if (via_hdr) {
        rport = via_hdr->rport_param;
        rhost = [[NSString stringWithPJString:via_hdr->recvd_param] pjString];
        NSLog(@"MyRealIP: %@:%d", [NSString stringWithPJString:via_hdr->recvd_param], via_hdr->rport_param);
    }
}

@interface SWEndpoint () {
    BOOL _areOtherCalls;
}

@property (atomic, assign) pj_pool_t *pool;

@property (nonatomic, copy) SWShouldResumeBlock shouldResumeBlock;
@property (nonatomic, copy) SWIncomingCallBlock incomingCallBlock;
@property (nonatomic, copy) SWCallStateChangeBlock callStateChangeBlock;
@property (nonatomic, copy) SWCallMediaStateChangeBlock callMediaStateChangeBlock;
@property (nonatomic, copy) SWSyncDoneBlock syncDoneBlock;
@property (nonatomic, copy) SWGroupCreatedBlock groupCreatedBlock;

//@property (nonatomic, copy) SWMessageSentBlock messageSentBlock;
@property (nonatomic, copy) SWMessageReceivedBlock messageReceivedBlock;
@property (nonatomic, copy) SWMessageDeletedBlock messageDeletedBlock;
@property (nonatomic, copy) SWMessageStatusBlock messageStatusBlock;
@property (nonatomic, copy) SWMessageStatusBlockForAbonent messageStatusBlockForAbonent;
@property (nonatomic, copy) SWAbonentStatusBlock abonentStatusBlock;
@property (nonatomic, copy) SWGroupMembersUpdatedBlock groupMembersUpdatedBlock;
@property (nonatomic, copy) SWTypingBlock typingBlock;

@property (nonatomic, copy) SWConfirmationBlock confirmationBlock;

@property (nonatomic, copy) SWUnauthorizedBlock unauthorizedBlock;

@property (nonatomic, copy) SWErrorBlock otherErrorBlock;

//@property (nonatomic, copy) SWReadyToSendFileBlock readyToSendFileBlock;

@property (nonatomic, copy) SWGetCounterBlock getCountersBlock;
//@property (nonatomic, copy) SWContactServerUpdatedBlock contactsServerUpdatedBlock;
//@property (nonatomic, copy) SWPushServerUpdatedBlock pushServerUpdatedBlock;
//@property (nonatomic, copy) SWBalanceUpdatedBlock balanceUpdatedBlock;
@property (nonatomic, copy) SWSettingsUpdatedBlock settingsUpdatedBlock;
@property (nonatomic, copy) SWChatDeletedBlock chatDeletedBlock;

@property (nonatomic, strong) NSMutableDictionary *accountStateChangeBlockObservers;

@property (nonatomic) pj_thread_t *thread;
@property (nonatomic, strong) NSMutableSet<NSString *> *sipThreadNames;

@property (nonatomic, strong) CTCallCenter *callCenter;

@property (nonatomic, strong) SWAudioSessionObserver *audioSessionObserver;
@property (atomic, assign) BOOL needResetPjPool;

@property (nonatomic, strong) SWRingtone *standartRingtone;
@property (nonatomic, readonly) NSMutableDictionary<NSURL *, SWRingtone *>  *ringtones;
@property (atomic, assign) pjsua_transport_id pjsuaTransportId;
@property (atomic, assign) BOOL regRequestWasSent;

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
    
    self.replacedCallIds = [NSMutableDictionary new];
    self.reverseCallIds = [NSMutableDictionary new];
    
    self->_messageSender = [SWMessageSender new];
    self->_intentManager = [SWIntentManager new];
    
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
    
    //Здесь pjsua ещё не запущен, регистрировать нет смысла!
    //[self registerThread];
    
    [self setStandartRingtone];
    _ringtones = [NSMutableDictionary new];
    
    //TODO check if the reachability happens in background
    //FIX make sure connect doesnt get called too often
    //IP Change logic
    
    self.audioSessionObserver = [SWAudioSessionObserver new];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector: @selector(handleEnteredForeground:) name: @"SWEndPointWakeUp" object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector: @selector(handleEnteredForeground:) name: UIApplicationWillEnterForegroundNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector: @selector(handleEnteredBackground:) name: UIApplicationDidEnterBackgroundNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector: @selector(handleApplicationWillTeminate:) name:UIApplicationWillTerminateNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector: @selector(handleApplicationWillResignActiveNotification:) name:UIApplicationWillResignActiveNotification object:nil];
    
    return self;
}

-(void) configureCallCenterMonitoring {
    //Если есть внешняя функция определения звонков, здесь следить не нужно
    if (self.endpointConfiguration.areOtherCallsBlock) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    
    //пишут, что инициализированный не в главном потоке криво возвращает список звонков
    dispatch_async(dispatch_get_main_queue(), ^{
        //Если не первый вызов
        if (weakSelf.callCenter) {
            return;
        }
        weakSelf.callCenter = [[CTCallCenter alloc] init];
        
        [_callCenter setCallEventHandler:^(CTCall *call) {
            
            __strong typeof(weakSelf) slf = weakSelf;
            if(!slf) return;
            
            SWAccount *account = [slf firstAccount];
            
            SWCall *swcall = [account firstCall];
            
            //Может ли звонок в коллцентре появиться до СИПа?
            if (!swcall) {
                
                NSUInteger callCount = [[self.callCenter currentCalls] count];
                if((call.callState == CTCallStateDisconnected) && (callCount > 0)) {
                    callCount--;
                }
                
                slf->_areOtherCalls = (callCount > 0);
                NSLog(@"<--check other calls--> setting areOtherCalls: %@", slf->_areOtherCalls ? @"true" : @"false");
                return;
            }
            else {
                //TODO: areOtherCalls wrong! Зафиксирован случай, когда прошли по этой ветке при активном GSM-звонке. (Эвент был вызван самим СИП-звонком)
                NSLog(@"<--check other calls--> setting areOtherCalls: false");
                slf->_areOtherCalls = NO;
            }
            
            //Если звонок не привязан к звонку коллцентра, привяжем
            if (swcall.ctcallId == nil) {
                swcall.ctcallId = call.callID;
            }
            
            //Если это событие по тому же звонку, ничего больше делать не нужно
            if ([call.callID isEqualToString: swcall.ctcallId]) {
                return;
            }
            
            /*
             if ([[call callState] isEqual:CTCallStateConnected] || [[call callState] isEqual:CTCallStateIncoming]|| [[call callState] isEqual:CTCallStateDialing]) {
             
             if (swcall && swcall.mediaState == SWMediaStateActive) {
             dispatch_async(dispatch_get_main_queue(), ^{
             [swcall setHold:^(NSError *error) {
             }];
             });
             }
             } else if ([[call callState] isEqual:CTCallStateDisconnected]) {
             
             if (swcall && swcall.mediaState == SWMediaStateLocalHold) {
             dispatch_async(dispatch_get_main_queue(), ^{
             
             [swcall reinvite:^(NSError *error) {
             }];
             });
             }
             
             }
             */
        }];
        
        __strong typeof(weakSelf) slf2 = weakSelf;
        
        slf2->_areOtherCalls = ([[slf2.callCenter currentCalls] count] > 0);
        NSLog(@"<--check other calls--> setting areOtherCalls: %@", slf2->_areOtherCalls ? @"true" : @"false");
    });
}

-(void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillTerminateNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"SWEndPointWakeUp" object:nil];
    
    
    [self reset:^(NSError *error) {
        if (error) DDLogDebug(@"%@", [error description]);
    }];
}

#pragma Notification Methods

- (void) handleEnteredForeground: (NSNotification *)notification {
    NSLog(@"<--starting--> handleEnteredForeground %@", _callCenter.currentCalls);
    
    //Этим свойством отсекаем лишнюю реакцию на подвисший ответ REGISTER, обработанный после перезапуска приложения
    self.regRequestWasSent = NO;
    //    [self.firstAccount setPresenseStatusOnline:SWPresenseStateOnline completionHandler:^(NSError *error) {
    //    }];
    
#warning experiment 2018-03-12
    /*
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (int i = 0; i < [self.accounts count]; ++i) {
            
            SWAccount *account = [self.accounts objectAtIndex:i];
            BOOL shouldResume = YES;
            
            if (_shouldResumeBlock) {
                shouldResume = _shouldResumeBlock(account);
            }
            if (!shouldResume) continue;
            
            dispatch_semaphore_t semaphone = dispatch_semaphore_create(0);
            
            //            @weakify(account);
            [account resume:^(NSError *error) {
                
                //                @strongify(account);
                //                account = nil;
                
                dispatch_semaphore_signal(semaphone);
            }];
            
            dispatch_semaphore_wait(semaphone, DISPATCH_TIME_FOREVER);
        }
    });
     */
    
    if (![SWEndpoint sharedEndpoint].firstAccount.firstCall) {
        
        dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), queue, ^{
            NSInteger accountState = [SWEndpoint sharedEndpoint].firstAccount.accountState;
            
            if (! [SWEndpoint sharedEndpoint].firstAccount.isAuthorized) {
                NSLog(@"<--swaccount--> handleEnteredForeground firstAccount isAuthorized false");
                return;
            }
            
            if(self.isWakingUp) {
                NSLog(@"<--swaccount--> handleEnteredForeground isWakingUp already");
                return;
            }
            self.isWakingUp = YES;
            
            NSLog(@"<--swaccount--> handleEnteredForeground code=%d", accountState);
            if (accountState == SWAccountStateDisconnected) {
                [[SWEndpoint sharedEndpoint] restart:^(NSError *error) {
                    SWAccount *account = [[SWEndpoint sharedEndpoint] firstAccount];
                    
                    SWAccountConfiguration *configuration = account.accountConfiguration;
                    
                    [account resume:^(NSError *error) {
                        self.isWakingUp = NO;
                    }];
                }];
            } else {
                SWAccount *account = [[SWEndpoint sharedEndpoint] firstAccount];
                [account resume:^(NSError *error) {
                    self.isWakingUp = NO;
                }];
            }
        });
    }
}

- (void) handleApplicationWillResignActiveNotification: (NSNotification *)notification {
    NSLog(@"handleApplicationWillResignActiveNotification %@", _callCenter.currentCalls);
}

-(void)handleEnteredBackground:(NSNotification *)notification {
    NSLog(@"handleEnteredBackground %@", _callCenter.currentCalls);
    
    UIApplication *application = (UIApplication *)notification.object;
    
    UIBackgroundTaskIdentifier taskId = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:NULL];
    //    [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
    
    self.ringtone.volume = 0.0;
    //    [self performSelectorOnMainThread:@selector(keepAlive) withObject:nil waitUntilDone:YES];
    
    //    [self.firstAccount setPresenseStatusOnline:SWPresenseStateOffline completionHandler:^(NSError *error) {
    //    }];
    
    //    [application setKeepAliveTimeout:KEEP_ALIVE_INTERVAL handler: ^{
    //        [self performSelectorOnMainThread:@selector(keepAlive) withObject:nil waitUntilDone:YES];
    //    }];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (int i = 0; i < [self.accounts count]; ++i) {
            
            SWAccount *account = [self.accounts objectAtIndex:i];
            if (account.firstCall) continue;
            
            dispatch_semaphore_t semaphone = dispatch_semaphore_create(0);
            
            //            @weakify(account);
            [account pause:^(NSError *error) {
                
                //                @strongify(account);
                //                account = nil;
                
                dispatch_semaphore_signal(semaphone);
            }];
            
            dispatch_semaphore_wait(semaphone, DISPATCH_TIME_FOREVER);
        }
        
        [application endBackgroundTask:taskId];
    });
    
}

-(void)handleApplicationWillTeminate:(NSNotification *)notification {
    
    UIApplication *application = (UIApplication *)notification.object;
    
    [self.threadFactory runBlockOnRegThread:^{
        //[application setApplicationIconBadgeNumber:0];
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
        
    } wait:NO];
    
}

//-(void)keepAlive {
//
//    if (pjsua_get_state() != PJSUA_STATE_RUNNING) {
//        return;
//    }
//
//    [self registerThread];
//
//    for (SWAccount *account in self.accounts) {
//
//        if (account.isValid) {
//
//            dispatch_semaphore_t semaphone = dispatch_semaphore_create(0);
//
//            [account connect:^(NSError *error) {
//
//                dispatch_semaphore_signal(semaphone);
//            }];
//
//            dispatch_semaphore_wait(semaphone, DISPATCH_TIME_FOREVER);
//        }
//
//        else {
//
//            dispatch_semaphore_t semaphone = dispatch_semaphore_create(0);
//
//            [account disconnect:^(NSError *error) {
//
//                dispatch_semaphore_signal(semaphone);
//            }];
//
//            dispatch_semaphore_wait(semaphone, DISPATCH_TIME_FOREVER);
//        }
//    }
//}

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
        //После смены рингтона он может быть для другой цели, поэтому его надо запускать заново.
        //[_ringtone start];
    }
    
    else {
        _ringtone = ringtone;
    }
    
    [self didChangeValueForKey:@"ringtone"];
}

-(void) configureWithCompletion: (void(^)(NSError *error))handler {
    self.endpointIteration++;
    
    [self configureCallCenterMonitoring];
    
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
    ua_cfg.cb.on_reg_started = &SWOnRegStarted;
    ua_cfg.cb.on_nat_detect = &SWOnNatDetect;
    ua_cfg.cb.on_call_redirected = &SWOnCallRedirected;
    ua_cfg.cb.on_transport_state = &SWOnTransportState;
    ua_cfg.cb.on_create_media_transport = &SWOnMediaTransportCreate;
    //ua_cfg.cb.on_create_media_transport_srtp = &SWOnSrtpTransportCreate;
    ua_cfg.cb.on_dtmf_digit = &SWOnDTMFDigit;
    ua_cfg.cb.on_typing2 = &SWOnTyping;
    //ua_cfg.cb.on_call_sdp_created = &SWOnCallSdpCreated; //Пока SDP не пригодились
    
    
    //    ua_cfg.stun_host = [@"stun.sipgate.net" pjString];
    
    NSString *userAgent = [NSString stringWithFormat:@"%@/%@ (%@; iOS %@; Scale/%0.2f)", [[NSBundle mainBundle] infoDictionary][(__bridge NSString *)kCFBundleExecutableKey] ?: [[NSBundle mainBundle] infoDictionary][(__bridge NSString *)kCFBundleIdentifierKey], [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"] ?: [[NSBundle mainBundle] infoDictionary][(__bridge NSString *)kCFBundleVersionKey], [[UIDevice currentDevice] model], [[UIDevice currentDevice] systemVersion], [[UIScreen mainScreen] scale]];
    ua_cfg.user_agent = [userAgent pjString];
    
    ua_cfg.use_srtp = PJMEDIA_SRTP_MANDATORY;
    ua_cfg.srtp_secure_signaling = 2;
    
    //
    ua_cfg.max_calls = (unsigned int)self.endpointConfiguration.maxCalls;
    
    log_cfg.level = (unsigned int)self.endpointConfiguration.logLevel;
    log_cfg.console_level = (unsigned int)self.endpointConfiguration.logConsoleLevel;
    log_cfg.log_filename = [self.endpointConfiguration.logFilename pjString];
    log_cfg.log_file_flags = (unsigned int)self.endpointConfiguration.logFileFlags;
    
#warning test
    log_cfg.console_level = 4;
    log_cfg.cb = &logCallback;
    log_cfg.decor = PJ_FALSE;
    
    
    
    media_cfg.clock_rate = (unsigned int)self.endpointConfiguration.clockRate;
    media_cfg.snd_clock_rate = (unsigned int)self.endpointConfiguration.sndClockRate;
    media_cfg.no_vad = 1;
    //media_cfg.has_ioqueue = YES;
    
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
    
    
    status = pjmedia_srtp_init_lib(pjsua_get_pjmedia_endpt());
    if (status != PJ_SUCCESS) {
        NSLog(@"Cannot start srtp");
        return;
    }
    
    //TODO autodetect port by checking transportId!!!!
    
    for (SWTransportConfiguration *transport in self.endpointConfiguration.transportConfigurations) {
        
        pjsua_transport_config transportConfig;
        pjsua_transport_id transportId;
        
        pjsip_tls_setting tls_setting;
        pjsip_tls_setting_default(&tls_setting);
        
        tls_setting.method = PJSIP_TLSV1_METHOD;
        tls_setting.verify_client = PJ_FALSE;
        tls_setting.verify_server = PJ_FALSE;
        tls_setting.require_client_cert = PJ_FALSE;
        
        transportConfig.tls_setting = tls_setting;
        pjsua_transport_config_default(&transportConfig);
        int random_port = 1024 + (rand() % (int)(65535 - 1024 + 1));
        
        transportConfig.port = random_port;
        
        pjsip_transport_type_e transportType = (pjsip_transport_type_e)transport.transportType;
        
        status = pjsua_transport_create(transportType, &transportConfig, &transportId);
        if (status != PJ_SUCCESS) {
            
            NSError *error = [NSError errorWithDomain:@"Error creating pjsua transport" code:status userInfo:nil];
            
            if (handler) {
                handler(error);
            }
            
            return;
        }
        
        self.pjsuaTransportId = transportId;
    }
    
    [self start:handler];
}

-(void)configure:(SWEndpointConfiguration *)configuration completionHandler:(void(^)(NSError *error))handler {
    
    //TODO add lock to this method
    
    self.endpointConfiguration = configuration;
    
    [self registerSipThreads];
    
    NSThread *regThread = [self.threadFactory getRegistrationThread];
    
    [self performSelector:@selector(configureWithCompletion:) onThread:regThread withObject:handler waitUntilDone:NO];
}

void logCallback (int level, const char *data, int len) {
    NSString *logMessage = [NSString stringWithUTF8String:data];
    
    NSLog(@"SIP: %@", [logMessage stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]);
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

- (void) registerSipThreads {
    
    self.sipThreadNames = [[NSMutableSet alloc] initWithCapacity:2];
    
    self.threadFactory = [SWThreadManager sharedInstance];
    
    //[self registerThread];
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

-(pj_thread_t *) registerThreadWithName: (NSString *) name {
    
    if (pjsua_get_state() != PJSUA_STATE_RUNNING) {
        return nil;
    }
    
    const char *chName = name.UTF8String;
    pj_thread_t * thrd;
    
    pj_thread_desc desc;
    if (!pj_thread_is_registered()) {
        pj_thread_register(chName, desc, &thrd);
    }
    
    else {
        thrd = pj_thread_this();
    }
    
    //        if (!_pjPool) {
    //            dispatch_async(dispatch_get_main_queue(), ^{
    //                _pjPool = pjsua_pool_create("swig-pjsua", 512, 512);
    //            });
    //        }
    
    return thrd;
}

- (void) registerSipThread: (NSThread *) thread {
    if (NO == [[NSThread currentThread] isEqual:thread]) {
        [self performSelector:@selector(registerSipThread:) onThread:thread withObject:thread waitUntilDone:NO];
        return;
    }
    
    if ([self.sipThreadNames containsObject:thread.name]) {
        return;
    }
    
    pj_thread_t *pjthread = [self registerThreadWithName:thread.name];
    
    if (pjthread) {
        [self.sipThreadNames addObject:thread.name];
    }
}

/*
- (pj_pool_t *) pjPool {
    NSLog(@"<--pjPool--> pool accessed");
    static dispatch_once_t onceToken;
    //static pj_pool_t *pool = nil;
    static pj_pool_t *pool;
    dispatch_once(&onceToken, ^{
        pool = pjsua_pool_create("swig-pjsua", 512, 512);
    });
    
    return pool;
}
*/

- (pj_pool_t *) pjPool {
    NSLog(@"<--pjPool--> pool accessed");
    //static pj_pool_t *pool = nil;
    static pj_pool_t *pool;
    
    @synchronized (self) {
        if(self.needResetPjPool) {
            pool = nil;
        }
        
        if (pool == nil) {
            pool = pjsua_pool_create("swig-pjsua", 512, 512);
            self.needResetPjPool = NO;
        }
    }
    
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
    
    pjmedia_codec_info codecs[PJMEDIA_CODEC_MGR_MAX_CODECS];
    unsigned int prio[PJMEDIA_CODEC_MGR_MAX_CODECS];
    unsigned int count = PJ_ARRAY_SIZE(codecs);
    
    pjmedia_codec_mgr *codec_mgr = pjmedia_endpt_get_codec_mgr(pjsua_get_pjmedia_endpt());
    
    status = pjmedia_codec_mgr_enum_codecs(codec_mgr, &count, codecs, prio);
    
    if (status==PJ_SUCCESS) {
        for (int i=0; i<count; i++) {
            NSLog(@"%@", [NSString stringWithFormat:@"%d %@/%u ", prio[i], [NSString stringWithPJString:codecs[i].encoding_name], codecs[i].clock_rate]);
            
        }
    }
    
#warning experiment
    [self registerSipThread:[NSThread mainThread]];
    
    [SWCall closeSoundTrack:nil];
    
    if (handler) {
        handler(nil);
    }
}

-(void)reset:(void(^)(NSError *error))handler {
    NSThread *regThread = [[SWEndpoint sharedEndpoint].threadFactory getRegistrationThread];
    
    if([NSThread currentThread] != regThread) {
        [self performSelector:@selector(reset:) onThread:regThread withObject:handler waitUntilDone:NO];
        return;
    }
    
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
    
#warning надо формировать ошибку
    if (handler) {
        handler(nil);
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
    
    NSThread *regThread = [[SWEndpoint sharedEndpoint].threadFactory getRegistrationThread];
    
    if([NSThread currentThread] != regThread) {
        [self performSelector:@selector(restart:) onThread:regThread withObject:handler waitUntilDone:NO];
        return;
    }
    
    NSString *loguid = [[NSUUID UUID] UUIDString];
    
    NSLog(@"<--pjsip freeze--> before pjsua_destroy2. UID=%@", loguid);
    while(pjsua_get_state() != PJSUA_STATE_NULL) {
        NSLog(@"<--pjsip freeze--> before pjsua_destroy2 attempt. UID=%@", loguid);
        pj_status_t status = pjsua_destroy2(PJSUA_DESTROY_NO_NETWORK);
        NSLog(@"<--pjsip freeze--> after pjsua_destroy2 attempt. UID=%@", loguid);
    }
    NSLog(@"<--pjsip freeze--> after pjsua_destroy2. UID=%@", loguid);
    
    self.needResetPjPool = YES;
        
    [[SWEndpoint sharedEndpoint] configure:self.endpointConfiguration completionHandler:^(NSError *error) {
        
        if(self.accounts.count == 0) {
            handler(nil);
            return;
        }
        
        for (int i = 0; i < self.accounts.count; i++) {
            SWAccount *account = self.accounts[i];
            [account configure:account.accountConfiguration completionHandler:^(NSError *error) {
                if ((i == self.accounts.count - 1) && (handler != nil)) {
                    handler(nil);
                }
            }];
        }
    }];
}

-(void)setShouldResumeBlock:(SWShouldResumeBlock)handler {
    _shouldResumeBlock = handler;
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

-(void)setCallVideoFormatChangeBlock:(void(^)(SWAccount *account, SWCall *call))callVideoFormatChangeBlock {
    
    _callVideoFormatChangeBlock = callVideoFormatChangeBlock;
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

- (void) setChatDeletedBlock: (SWChatDeletedBlock) chatDeletedBlock {
    _chatDeletedBlock = chatDeletedBlock;
}

- (void) setConfirmationBlock: (SWConfirmationBlock) confirmationBlock {
    _confirmationBlock = confirmationBlock;
}

- (void)setOtherErrorBlock:(SWErrorBlock)otherErrorBlock {
    _otherErrorBlock = otherErrorBlock;
}

- (void) setMessageStatusBlock: (SWMessageStatusBlock) messageStatusBlock {
    _messageStatusBlock = messageStatusBlock;
}

- (void) setMessageStatusBlockForAbonent: (SWMessageStatusBlockForAbonent) messageStatusBlockForAbonent {
    _messageStatusBlockForAbonent = messageStatusBlockForAbonent;
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
    
    NSLog(@"<--swaccount--> SWOnRegState2 code=%d", info->cbparam->code);
    
    BOOL regRequestWasSent = [SWEndpoint sharedEndpoint].regRequestWasSent;
    
    if ((info != NULL) && (info->cbparam != NULL) && (info->cbparam->code == PJSIP_SC_REQUEST_TIMEOUT)) {
        
        [[SWEndpoint sharedEndpoint] restart:^(NSError *error) {
            SWThreadManager *thrManager = [SWEndpoint sharedEndpoint].threadFactory;
            
            NSThread *regThread = [thrManager getRegistrationThread];
            [thrManager runBlock:^{
                SWAccount *account = [[SWEndpoint sharedEndpoint] lookupAccount:acc_id];
                if ((account != nil) && regRequestWasSent) {
                    [account accountStateChanged];
                    NSArray *observersKeys = [[SWEndpoint sharedEndpoint].accountStateChangeBlockObservers allKeys];
                    for (NSString *key in observersKeys) {
                        SWAccountStateChangeBlock observer = [[SWEndpoint sharedEndpoint].accountStateChangeBlockObservers objectForKey:key];
#warning mainthread
                        dispatch_async(dispatch_get_main_queue(), ^{
                            observer(account);
                        });
                    }
                }
            } onThread:regThread wait:NO];
        }];
    }
    else {
        SWThreadManager *thrManager = [SWEndpoint sharedEndpoint].threadFactory;
        
        NSThread *regThread = [thrManager getRegistrationThread];
        [thrManager runBlock:^{
            SWAccount *account = [[SWEndpoint sharedEndpoint] lookupAccount:acc_id];
            if ((account != nil) && regRequestWasSent) {
                [account accountStateChanged];
                
                NSArray *observersKeys = [[SWEndpoint sharedEndpoint].accountStateChangeBlockObservers allKeys];
                for (NSString *key in observersKeys) {
                    SWAccountStateChangeBlock observer = [[SWEndpoint sharedEndpoint].accountStateChangeBlockObservers objectForKey:key];
#warning mainthread
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                        if (observer) {
                            observer(account);
                        }
                    });
                }
            }
        } onThread:regThread wait:NO];
    }
    
}

static void SWOnRegStarted(pjsua_acc_id acc_id, pj_bool_t renew) {
    
    SWAccount *account = [[SWEndpoint sharedEndpoint] lookupAccount:acc_id];
    
    if (account) {
        [account accountStateConnecting];
        NSArray *observersKeys = [[SWEndpoint sharedEndpoint].accountStateChangeBlockObservers allKeys];
        for (NSString *key in observersKeys) {
            SWAccountStateChangeBlock observer = [[SWEndpoint sharedEndpoint].accountStateChangeBlockObservers objectForKey:key];
#warning mainthread
            dispatch_async(dispatch_get_main_queue(), ^{
                observer(account);
            });
            
        }
    }
}

static void SWOnIncomingCall(pjsua_acc_id acc_id, pjsua_call_id call_id, pjsip_rx_data *rdata) {
    SWEndpoint *endpoint = [SWEndpoint sharedEndpoint];
    dispatch_async(dispatch_get_main_queue(), ^{
        if([endpoint areOtherCalls]) {
            [[[endpoint firstAccount] lookupCall:call_id] hangupOnReason:SWCallReasonLocalBusy withCompletion:nil];
        }
    });
    
    SWAccount *account = [[SWEndpoint sharedEndpoint] lookupAccount:acc_id];
    
    if (account) {
        
        SWCall *call = [SWCall callWithId:call_id accountId:acc_id inBound:YES isGsm:NO];
        
        if (call) {
            
            [account addCall:call];
            NSLog(@"<--callStateChanged--> SWOnIncomingCall");
            
            [call callStateChanged];
            
            if ([SWEndpoint sharedEndpoint].incomingCallBlock) {
                [SWEndpoint sharedEndpoint].incomingCallBlock(account, call);
            }
        }
    }
    
    
}

static void SWOnCallState(pjsua_call_id call_id, pjsip_event *e) {
    
    pjsip_msg *msg = [SWEndpoint getMessageFromEvent:e];
    
    NSString *hangupReasonStr = [SWEndpoint getHeaderByName:@"X-Reason" forMessage:msg];
    
    NSLog(@"<--hangupReason--> reason header: %@", hangupReasonStr);
    
    pjsua_call_info callInfo;
    pjsua_call_get_info(call_id, &callInfo);
    
    pjsip_uri* local_contact_uri = pjsip_parse_uri([SWEndpoint sharedEndpoint].pjPool, callInfo.local_contact.ptr, callInfo.local_contact.slen, NULL);
    pjsip_sip_uri *local_contact_sip_uri = (pjsip_sip_uri *)pjsip_uri_get_uri(local_contact_uri);
    
    SWEndpoint *endpoint = [SWEndpoint sharedEndpoint];
    SWAccount *account;
    SWCall *call;
    //Найдем аккаунт, в котором есть звонок с нужным идентификатором
    /*
    NSArray *acs = [endpoint.accounts copy];
    
    if (acs) {
        for (SWAccount *acc in acs) {
            call = [acc lookupCall:call_id];
            if (call != nil) {
                account = acc;
                break;
            }
        }
    }
     */
    
    account = [endpoint firstAccount];
    call = [account lookupCall:call_id];
    
    if (account) {
        if (call) {
            
            if (callInfo.state == PJSIP_INV_STATE_CONNECTING && callInfo.role == PJSIP_ROLE_UAC) {
                pjsip_via_hdr *via_hdr = e->body.rx_msg.rdata->msg_info.via;
                resp_rport = via_hdr->rport_param;
                
                resp_rhost = pj_str(via_hdr->recvd_param.ptr);
                resp_rhost.slen = via_hdr->recvd_param.slen;
                
                NSLog(@"MyRealIP: %@:%d", [NSString stringWithPJString:resp_rhost], resp_rport);
            }
            
            
            if (callInfo.state == PJSIP_INV_STATE_CONFIRMED && callInfo.role == PJSIP_ROLE_UAC) {
#warning experiment вынесено из блока
                /*
                 pjsip_uri* local_contact_uri = pjsip_parse_uri([SWEndpoint sharedEndpoint].pjPool, callInfo.local_contact.ptr, callInfo.local_contact.slen, NULL);
                 pjsip_sip_uri *local_contact_sip_uri = (pjsip_sip_uri *)pjsip_uri_get_uri(local_contact_uri);
                 */
                
                local_contact_sip_uri->port = resp_rport;
                local_contact_sip_uri->host = resp_rhost;
                
                char contact_buf[512];
                pj_str_t new_contact;
                new_contact.ptr = contact_buf;
                
                new_contact.slen = pjsip_uri_print(PJSIP_URI_IN_CONTACT_HDR, local_contact_sip_uri, contact_buf, 512);
                
                pjsip_tx_data *tdata;
                pjsua_call *pjcall;
                pjsip_dialog *dlg = NULL;
                pj_status_t status;
                
                status = acquire_call("pjsua_call_update_contact()", call_id, &pjcall, &dlg);
                if (status != PJ_SUCCESS) {
                    NSLog(@"cannot aquire call");
                }
                
                
                //                / Create UPDATE with new offer /
                status = pjsip_inv_update(pjcall->inv, &new_contact, NULL, &tdata);
                if (status != PJ_SUCCESS) {
                    NSLog(@"Unable to create UPDATE request");
                }
                
                //                / Add additional headers etc /
                //                pjsua_process_msg_data(tdata, e->body.tx_msg);
                
                //                / Send the request /
                status = pjsip_inv_send_msg(pjcall->inv, tdata);
                if (status != PJ_SUCCESS) {
                    NSLog(@"Unable to send UPDATE");
                }
                
                if (dlg) pjsip_dlg_dec_lock(dlg);
            }
            
            NSLog(@"<--callStateChanged--> SWOnCallState: %d callInfo.last_status: %d", callInfo.state, callInfo.last_status);
            
            NSInteger hangupReason = 0;
            
            if (hangupReasonStr) {
                NSRegularExpression* regex = [NSRegularExpression regularExpressionWithPattern:@".*cause=(\\d*);.*" options:NSRegularExpressionCaseInsensitive error:nil];
                
                hangupReason = [[hangupReasonStr substringWithRange:[[regex firstMatchInString:hangupReasonStr options:0 range:NSMakeRange(0, hangupReasonStr.length)] rangeAtIndex:1]] integerValue];
            }
            else {
                switch (callInfo.last_status) {
                    case PJSIP_SC_NOT_ACCEPTABLE:
                        hangupReason = SWCallReasonUnavailiable;
                        break;
                        
                    case PJSIP_SC_TEMPORARILY_UNAVAILABLE:
                        hangupReason = SWCallReasonNotAnswered;
                        break;
                        
                    case PJSIP_SC_BUSY_HERE:
                        hangupReason = SWCallReasonRemoteBusy;
                        break;
                        
                    case PJSIP_SC_PAYMENT_REQUIRED:
                        hangupReason = SWCallReasonNoMoney;
                        break;
                        
                    case PJSIP_SC_METHOD_NOT_ALLOWED:
                        hangupReason = SWCallReasonRestricted;
                        break;
                        
                    case 499:
                        hangupReason = SWCallReasonNotExists;
                        break;
                        
                    default:
                        break;
                }
            }
            
#warning experiment callInfo получаем вне блока
            //[call callStateChangedWithReason:hangupReason];
            [call callStateChanged:callInfo withReason:hangupReason];
            
            [endpoint runCallStateChangeBlockForCall:call setCode:callInfo.last_status];
            
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
    
    NSLog(@"---SWOnCallMediaState invoked");
    
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
    NSLog(@"MediaEvent. Type=%d", event->type);

    if (event->type == PJMEDIA_EVENT_FMT_CHANGED){
        SWAccount *account = [[SWEndpoint sharedEndpoint] firstAccount];
        
        SWCall *call = [account lookupCall:call_id];
        
        if (call) {
            CGFloat scale = [[UIScreen mainScreen] scale];
            
            CGSize videoSize = CGSizeMake(event->data.fmt_changed.new_fmt.det.vid.size.w, event->data.fmt_changed.new_fmt.det.vid.size.h);
            
            videoSize = CGSizeMake(videoSize.width*1.0/scale, videoSize.height*1.0/scale);
            
            const pj_str_t codec_id = {"H264", 4};
            pjmedia_vid_codec_param param;
            
            pjsua_vid_codec_get_param(&codec_id, &param);
            
            CGSize codecSize = CGSizeMake(param.dec_fmt.det.vid.size.w, param.dec_fmt.det.vid.size.h);
            
            NSLog(@"MediaEvent. Videosize:%@; codecSize:%@", NSStringFromCGSize(videoSize), NSStringFromCGSize(codecSize));
            
            NSLog(@"MediaEvent. Videosize changed to:%@", NSStringFromCGSize(videoSize));
            
            [call changeVideoWindowWithSize: videoSize];
            
        }
    }
}

//TODO: implement these
static void SWOnCallTransferStatus(pjsua_call_id call_id, int st_code, const pj_str_t *st_text, pj_bool_t final, pj_bool_t *p_cont) {
    NSLog(@"%d", call_id);
}

static void SWOnCallReplaced(pjsua_call_id old_call_id, pjsua_call_id new_call_id) {
    
}

static void SWOnNatDetect(const pj_stun_nat_detect_result *res){
    
    NSLog(@"Nat detect: %s", res->nat_type_name);
}

static void SWOnCallSdpCreated (pjsua_call_id call_id,
                                        pjmedia_sdp_session *sdp,
                                        pj_pool_t *pool,
             const pjmedia_sdp_session *rem_sdp) {
    //TODO: перенести эти свойства в звонок
    if (sdp != NULL) {
        [SWEndpoint sharedEndpoint]->_localSdp = sdp;
    }
    
    if (rem_sdp != NULL) {
        [SWEndpoint sharedEndpoint]->_remoteSdp = rem_sdp;
    }
}

static void SWOnTransportState (pjsip_transport *tp, pjsip_transport_state state, const pjsip_transport_state_info *info) {
    NSLog(@"<--SWOnTransportState--> state=%d", state);
#warning experiment
    if (state != PJSIP_TP_STATE_CONNECTED) {
        //TODO: транспорт все равно не пересоздается? Разобраться.
        return;
        
        //TODO: убрать дублирование кода
        SWEndpoint *endpoint = [SWEndpoint sharedEndpoint];
        SWThreadManager *threadManager = endpoint.threadFactory;
        
        NSThread *regThread = [threadManager getRegistrationThread];
        
        [threadManager runBlock:^{
            for (SWTransportConfiguration *transport in endpoint.endpointConfiguration.transportConfigurations) {
                
                pjsua_transport_config transportConfig;
                pjsua_transport_id transportId;
                
                pjsip_tls_setting tls_setting;
                pjsip_tls_setting_default(&tls_setting);
                
                tls_setting.method = PJSIP_TLSV1_METHOD;
                tls_setting.verify_client = PJ_FALSE;
                tls_setting.verify_server = PJ_FALSE;
                tls_setting.require_client_cert = PJ_FALSE;
                
                transportConfig.tls_setting = tls_setting;
                pjsua_transport_config_default(&transportConfig);
                int random_port = 1024 + (rand() % (int)(65535 - 1024 + 1));
                
                transportConfig.port = random_port;
                
                pjsip_transport_type_e transportType = (pjsip_transport_type_e)transport.transportType;
                pj_status_t status;
                
                status = pjsua_transport_create(transportType, &transportConfig, &transportId);
                if (status != PJ_SUCCESS) {
                    
                    NSError *error = [NSError errorWithDomain:@"Error creating pjsua transport" code:status userInfo:nil];
                    
                    return;
                }
                endpoint.pjsuaTransportId = transportId;
            }
        } onThread:regThread wait:NO];
        
        
    }
    
    //    NSLog(@"%@ %@", tp, info);
}

static void SWOnSrtpTransportCreate (pjsua_call_id call_id,
                                                   unsigned media_idx,
                                                   pjmedia_srtp_setting *srtp_opt) {
#warning отличать видеопоток от аудио-
    //if (media_idx == 0) return;
    
    pjmedia_transport *adapter;
    pj_status_t status;
    
    pjmedia_transport *base_tp;
    
    pjsua_call call = pjsua_var.calls[call_id];
    
    pjsua_call_media *call_med;
    call_med = &call.media_prov[media_idx];
    
    base_tp = call_med->tp;
    
    /* Create the adapter */
    status = pjmedia_fec_adapter_create(pjsua_get_pjmedia_endpt(),
                                        NULL, base_tp,
                                        PJSUA_MED_TP_CLOSE_MEMBER,
                                        &adapter);
    
    
    
    call_med->tp_orig = base_tp;
    
    call_med->tp = adapter;
    
    
    if (status != PJ_SUCCESS) {
        NSLog(@"<--swig-->Error creating fec adapter");
        return;
    }
    
    NSLog(@"<--swig-->Fec adapter is created for call %d media %d",
          call_id, media_idx);
    
}

static pjmedia_transport* SWOnMediaTransportCreate (pjsua_call_id call_id,
                                     unsigned media_idx,
                                     pjmedia_transport *base_tp,
                                     unsigned flags) {
    
    NSLog(@"<--SWOnMediaTransportCreate-->");
    
    if (media_idx == 0) {
        pjmedia_transport *adapter;
        pj_status_t status;
        
        /* Create the adapter */
        status = pjmedia_nack_adapter_create(pjsua_get_pjsip_endpt(), pjsua_get_pjmedia_endpt(),
                                            NULL, base_tp,
                                            (flags & PJSUA_MED_TP_CLOSE_MEMBER),
                                            &adapter);
        if (status != PJ_SUCCESS) {
            NSLog(@"<--swig-->Error creating nack adapter");
            return NULL;
        }
        
        NSLog(@"<--swig-->Nack adapter is created for call %d media %d",
              call_id, media_idx);
        
        return adapter;
    }
    else {
        pjmedia_transport *adapter;
        pj_status_t status;
        
        /* Create the adapter */
        status = pjmedia_fec_adapter_create(pjsua_get_pjmedia_endpt(),
                                            NULL, base_tp,
                                            (flags & PJSUA_MED_TP_CLOSE_MEMBER),
                                            &adapter);
        if (status != PJ_SUCCESS) {
            NSLog(@"<--swig-->Error creating fec adapter");
            return NULL;
        }
        
        NSLog(@"<--swig-->Fec adapter is created for call %d media %d",
              call_id, media_idx);
        
        return adapter;
    }
    
}

static void SWOnDTMFDigit (pjsua_call_id call_id, int digit) {
    NSLog(@"SWOnDTMFDigit: %@", [NSString stringWithFormat:@"%c", digit]);
}


static pjsip_redirect_op SWOnCallRedirected(pjsua_call_id call_id, const pjsip_uri *target, const pjsip_event *e){
    return PJSIP_REDIRECT_ACCEPT;
}

static void SWOnTyping (pjsua_call_id call_id, const pj_str_t *from, const pj_str_t *to, const pj_str_t *contact, pj_bool_t is_typing, pjsip_rx_data *rdata, pjsua_acc_id acc_id) {
    SWAccount *account = [[SWEndpoint sharedEndpoint] lookupAccount:acc_id];
    
    NSInteger group_id = 0;
    
    pj_str_t  groupid_hdr_str = pj_str((char *)"GroupID");
    
    
    pjsip_generic_string_hdr* groupid_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(rdata->msg_info.msg, &groupid_hdr_str, nil);
    if (groupid_hdr != nil) {
        group_id = atoi(groupid_hdr->hvalue.ptr);
    }
    
    if (account && [SWEndpoint sharedEndpoint].typingBlock) {
        pjsip_sip_uri *fromUri = (pjsip_sip_uri*)pjsip_uri_get_uri(rdata->msg_info.from->uri);
        NSString *fromUser = [NSString stringWithPJString:fromUri->user];
        [SWEndpoint sharedEndpoint].typingBlock(account, fromUser, group_id, (BOOL)is_typing);
    }
    
}

#pragma Setters/Getters

-(void)setAccounts:(NSArray *)accounts {
    
    [self willChangeValueForKey:@"accounts"];
    _accounts = accounts;
    [self didChangeValueForKey:@"accounts"];
}

- (void) replaceTxCallIdForData: (pjsip_tx_data *)tdata {
    pjsip_cid_hdr *callIdHeader = ((pjsip_cid_hdr*)pjsip_msg_find_hdr(tdata->msg, PJSIP_H_CALL_ID, NULL));
    
    if (callIdHeader) {
        pjsip_to_hdr *to_hdr = PJSIP_MSG_TO_HDR(tdata->msg);
        
        pjsip_sip_uri *uri = (pjsip_sip_uri *)pjsip_uri_get_uri(to_hdr->uri);
        
        NSString *phone = [NSString stringWithPJString:uri->user];
        
        NSString *replacedCallId = self.replacedCallIds[phone];
        NSString *originalCallId = [NSString stringWithPJString:callIdHeader->id];
        
        if (replacedCallId == nil) { return; }
        
        [self.reverseCallIds setObject: originalCallId forKey:replacedCallId];
        NSLog(@"<--call--><--swig--> callId replaced from %@ to %@", originalCallId, replacedCallId);
        
        pjsip_msg_find_remove_hdr(tdata->msg, PJSIP_H_CALL_ID, nil);
        callIdHeader->id = [replacedCallId pjString];
        pjsip_msg_add_hdr(tdata->msg, callIdHeader);
    }
}

- (void) replaceRxCallIdForData: (pjsip_rx_data *)data {
    pjsip_cid_hdr *callIdHeader = ((pjsip_cid_hdr*)pjsip_msg_find_hdr(data->msg_info.msg, PJSIP_H_CALL_ID, NULL));
    
    if (callIdHeader) {
        NSString *replacedCallId = [NSString stringWithPJString:callIdHeader->id];
        NSString *originalCallId = self.reverseCallIds[replacedCallId];
        
        if (originalCallId == nil) { return; }
        
        NSLog(@"<--call--><--swig--> callId resolved from %@ to %@", replacedCallId, originalCallId);
        
        pjsip_msg_find_remove_hdr(data->msg_info.msg, PJSIP_H_CALL_ID, nil);
        callIdHeader->id = [originalCallId pjString];
        pjsip_msg_add_hdr(data->msg_info.msg, callIdHeader);
    }
}

- (pj_bool_t) rxRequestPackageProcessing: (pjsip_rx_data *)data {
    
    if (data == nil) {
        return PJ_FALSE;
    }
    
    [self replaceRxCallIdForData:data];
    
    NSString *messageStr = [NSString stringWithCharacters:data->msg_info.msg_buf length:data->msg_info.len];
    
    NSString *methodName = [NSString stringWithPJString:data->msg_info.msg->line.req.method.name];
    
    if (pjsip_method_cmp(&data->msg_info.msg->line.req.method, &pjsip_message_method) == 0) {

        pjsip_ctype_hdr* content_type_hdr = (pjsip_ctype_hdr *)pjsip_msg_find_hdr(data->msg_info.msg, PJSIP_H_CONTENT_TYPE, nil);
        pj_str_t subtype = pj_str((char *)"im-iscomposing+xml");
        if ((content_type_hdr != nil) && (pj_strcmp(&content_type_hdr->media.subtype, &subtype) == 0)) {
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
        pjsip_endpt_respond_stateless(pjsua_get_pjsip_endpt(), data, PJSIP_SC_OK, NULL, NULL, NULL);
        [self incomingRefer:data];
        return PJ_TRUE;
    } else if (pjsip_method_cmp(&data->msg_info.msg->line.req.method, &pjsip_command_method) == 0) {
        return [self incomingCommand:data];
    } else if (pjsip_method_cmp(&data->msg_info.msg->line.req.method, &pjsip_syncdone_method) == 0) {
        return [self incomingSyncDone:data];
    }
    
    return PJ_FALSE;
}

- (pj_bool_t) txRequestPackageProcessing:(pjsip_tx_data *) tdata {
    
    [self replaceTxCallIdForData:tdata];
    
    pjsip_from_hdr *from_hdr = PJSIP_MSG_FROM_HDR(tdata->msg);
    
    pjsip_sip_uri *uri = (pjsip_sip_uri *)pjsip_uri_get_uri(from_hdr->uri);
    
    pjsua_acc_id acc_id = pjsua_acc_find_for_outgoing(&uri->user);
    
    SWAccount *account = [[SWEndpoint sharedEndpoint] lookupAccount:acc_id];
    
    if (pjsip_method_cmp(&tdata->msg->line.req.method, &pjsip_register_method) == 0) {
        
        self.regRequestWasSent = YES;
        
        if ([account.accountConfiguration.code length] == 4) {
            pj_str_t hname = pj_str((char *)"Auth");
            
            NSString *devID = [[UIDevice currentDevice] uuid];
            
            pj_str_t hvalue = [[NSString stringWithFormat:@"code=%@ UID=%@ DevID=%@", account.accountConfiguration.code, account.accountConfiguration.password, devID] pjString];
            [account.accountConfiguration setCode:@""];
            
            pjsip_generic_string_hdr* event_hdr = pjsip_generic_string_hdr_create(tdata->pool, &hname, &hvalue);
            
            pjsip_msg_add_hdr(tdata->msg, (pjsip_hdr*)event_hdr);
        }
    }
    
    BOOL authExists = NO;
    
    pjsip_authorization_hdr *auth_header = (pjsip_authorization_hdr *)pjsip_msg_find_hdr(tdata->msg, PJSIP_H_AUTHORIZATION, 0);
    
    pj_str_t  auth_header_name = pj_str((char *)"Auth");
    pjsip_generic_string_hdr* auth_header_custom = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(tdata->msg, &auth_header_name, nil);
    
    authExists = (auth_header != nil) || (auth_header_custom != nil);
    
    int expiresval = 0;
    
    pjsip_generic_string_hdr *exp_header = (pjsip_generic_string_hdr *)pjsip_msg_find_hdr(tdata->msg, PJSIP_H_EXPIRES, 0);
    
    if ((exp_header != NULL) && (exp_header->hvalue.slen < 10)) {
        expiresval = [[NSString stringWithPJString:exp_header->hvalue] intValue];
    }
    
    if (_getCountersBlock && pjsip_method_cmp(&tdata->msg->line.req.method, &pjsip_register_method) == 0 && authExists /* && (expiresval > 0) */ ) {
        pj_str_t hname = pj_str((char *)"SYNC");
        
        __block struct Sync counters;
        //        dispatch_queue_t q = dispatch_queue_create("com.foo.samplequeue", NULL);
        //        dispatch_sync(q, ^{
        counters = _getCountersBlock(account);
        //        });
        
        pj_str_t hvalue = [[NSString stringWithFormat:@"last_smid_rx=%llu, last_smid_tx=%llu, last_report=%llu, last_view=%llu", counters.lastSmidRX, counters.lastSmidTX, counters.lastReport, counters.lastViev] pjString];
        
        pjsip_generic_string_hdr* sync_hdr = pjsip_generic_string_hdr_create(tdata->pool, &hname, &hvalue);
        
        pjsip_msg_add_hdr(tdata->msg, (pjsip_hdr*)sync_hdr);
    }
    
    return PJ_FALSE;
}

- (pj_bool_t) txResponsePackageProcessing:(pjsip_tx_data *) tdata {
    
    [self replaceTxCallIdForData:tdata];
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
    
    [self replaceRxCallIdForData:data];
    /* Разбираем - на какой запрос пришел ответ */
    NSString *call_id = [NSString stringWithPJString:data->msg_info.cid->id];
    int status = data->msg_info.msg->line.status.code;
    
    //    NSUInteger cseq = data->msg_info.cseq->cseq;
    pjsua_acc_id acc_id;
    
    if (pjsua_acc_get_count() == 0) return PJ_FALSE;
    acc_id = pjsua_acc_find_for_incoming(data);
    SWAccount *account = [[SWEndpoint sharedEndpoint] lookupAccount:(int)acc_id];
    
    [self setMediaIpv6Enabled:(data->pkt_info.src_addr.addr.sa_family == AF_INET6) forAccId:acc_id];
    
    BOOL isRegMethod = (pjsip_method_cmp(&data->msg_info.cseq->method, &pjsip_register_method) == 0);
    
    if ((_unauthorizedBlock != nil) && (status == PJSIP_SC_NOT_FOUND || status == PJSIP_SC_UNAUTHORIZED || status == 467 || status == PJSIP_SC_FORBIDDEN)) {
        if (status == PJSIP_SC_NOT_FOUND || status == 467 || status == PJSIP_SC_FORBIDDEN) {
            NSLog(@"<--logout--> SIP unauthorizedBlock. Code=%d", status);
            _unauthorizedBlock(account);
            return PJ_FALSE;
        }
         
        if ((account.accountState == SWAccountStateConnected) && (!isRegMethod)) {
            NSLog(@"<--logout--> SIP unauthorizedBlock. Code=%d; AccState=SWAccountStateConnected", status);
            _unauthorizedBlock(account);
            return PJ_FALSE;
        }
    }
    
    if (isRegMethod) {
        
        struct Settings settings;
        settings.fileServer = nil;
        settings.contactServer = nil;
        settings.pushServer = nil;
        
        pj_str_t contact_server_hdr_str = pj_str((char *)"Contact-Server");
        pjsip_generic_string_hdr* contact_server_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &contact_server_hdr_str, nil);
        if (contact_server_hdr != nil) {
            settings.contactServer = [[NSString stringWithPJString:contact_server_hdr->hvalue] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"<>"]];
        }
        
        settings.syncServer = @"";
        
        pj_str_t sync_server_hdr_str = pj_str((char *)"Sync-Server");
        pjsip_generic_string_hdr* sync_server_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &sync_server_hdr_str, nil);
        if (sync_server_hdr != nil) {
            settings.syncServer = [[NSString stringWithPJString:sync_server_hdr->hvalue] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"<>"]];
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
                
                account.isAuthorized = NO;
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    _confirmationBlock(account, nil);
                });
            }
            return PJ_FALSE;
        }
        
        if (_registerErrorBlock) {
            _registerErrorBlock(status);
            return PJ_FALSE;
        }
        
    }
    
    if(_otherErrorBlock) {
        _otherErrorBlock(status);
    }
    
    return PJ_FALSE;
}

#pragma mark Входящее уведомление
- (void) incomingNotify:(pjsip_rx_data *)data {
    NSLog(@"<--sendSubmit--> incomingNotify");
    
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
        
#warning experiment Если генерируем ответ на сообщение до того, как отправился предыдущий, ловим bad_access. А статус "печатает" отправляется параллельно с сообщениями. Поэтому пробуем не отправлять на него ответ.
        //[self sendSubmit:data withCode:PJSIP_SC_OK];
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
        
        
        NSDate *submitTime = [NSDate date];
        pj_str_t submit_time_hdr_str = pj_str((char *)"DateTime");
        pjsip_generic_string_hdr* submit_time_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &submit_time_hdr_str, nil);
        if (submit_time_hdr != nil) {
            NSString *dateString = [NSString stringWithPJString:submit_time_hdr->hvalue];
            
            NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
            [dateFormatter setDateFormat:@"YYYY-MM-dd HH:mm:ss Z"];
            
            submitTime = [dateFormatter dateFromString:dateString];
        }
        
        pjsip_sip_uri *fromUri = (pjsip_sip_uri*)pjsip_uri_get_uri(data->msg_info.from->uri);
        NSString *fromUser = [NSString stringWithPJString:fromUri->user];
        
        /* Получаем SmID */
        NSUInteger sm_id = 0;
        pj_str_t  smid_hdr_str = pj_str((char *)"SMID");
        pjsip_generic_string_hdr* smid_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &smid_hdr_str, nil);
        
        if (smid_hdr != nil) {
            sm_id = atoi(smid_hdr->hvalue.ptr);
            NSUInteger event_value = atoi(event_hdr->hvalue.ptr);
            
            /* Передаем идентификатор и статус сообщения в GUI */
            if (_messageStatusBlockForAbonent) {
                //                dispatch_async(dispatch_get_main_queue(), ^{
                _messageStatusBlockForAbonent(account, sm_id, (SWMessageStatus) event_value, submitTime, (sync_hdr?YES:NO), lastMessageInPack, fromUser);
                //                });
            }
            
            /* Передаем идентификатор и статус сообщения в GUI */
            else if (_messageStatusBlock) {
                //                dispatch_async(dispatch_get_main_queue(), ^{
                _messageStatusBlock(account, sm_id, (SWMessageStatus) event_value, submitTime, (sync_hdr?YES:NO), lastMessageInPack);
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
    
    NSLog(@"<--sendSubmit--> incomingMessage");
    if (data == nil) {
        return;
    }
    
    pjsip_sip_uri *toUri = (pjsip_sip_uri*)pjsip_uri_get_uri(data->msg_info.to->uri);
    if (toUri == nil) {
        [self sendSubmit:data withCode:PJSIP_SC_BAD_REQUEST];
        return;
    }
    
    pjsua_acc_id acc_id;
    if (pjsua_acc_get_count() == 0) {
        NSLog(@"<--sendSubmit--> no account");
        return;
    }
    
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
    else {
#warning experiment не отправляем ответ на "печатает"
        NSLog(@"<--sendSubmit--> typing event. No submit.");
        return;
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
    // * STATUS *
    pj_str_t status_str = pj_str((char *) "Status");
    pjsip_generic_string_hdr *status_hdr =
    (pjsip_generic_string_hdr*) pjsip_msg_find_hdr_by_name(
                                                           data->msg_info.msg, &status_str, NULL);
    int event_value;
    if (status_hdr!=NULL){
        event_value = (int)pj_strtol(&status_hdr->hvalue);
    }
    
    if (_messageReceivedBlock) {
        _messageReceivedBlock(account, fromUser, toUser, message_txt, (NSUInteger) sm_id, group_id, submitTime, fileType, fileHash, fileServer, (sync_hdr?YES:NO), lastMessageInPack, event_value);
    }
    
    [self sendSubmit:data withCode:PJSIP_SC_OK];
}
- (void) incomingRefer:(pjsip_rx_data *)data {
    
    BOOL ipv6Enabled = (data->pkt_info.src_addr.addr.sa_family == AF_INET6);
    
    /* Смотрим о каком абоненте речь в сообщении */
    
    pjsua_acc_id acc_id;
    if (pjsua_acc_get_count() == 0) return;
    
    acc_id = pjsua_acc_find_for_incoming(data);
    
    pj_str_t  smid_hdr_str = pj_str((char *)"Refer-To");
    pjsip_generic_string_hdr* refer_to = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &smid_hdr_str, nil);
    if (refer_to == nil) {
        return;
    }
    
    pjsip_uri* refer_uri = pjsip_parse_uri(data->tp_info.pool, refer_to->hvalue.ptr, refer_to->hvalue.slen, NULL);
    pjsip_sip_uri *refer_sip_uri = (pjsip_sip_uri *)pjsip_uri_get_uri(refer_uri);
    
    pj_status_t    status;
    pjsip_tx_data *tx_msg;
    
    SWAccount *account = [self lookupAccount:acc_id];
    
    pjsua_acc_info accountInfo = [account getInfo];
    
    pjsip_sip_uri *to = (pjsip_sip_uri *)pjsip_uri_get_uri(data->msg_info.to->uri);
    pjsip_sip_uri *from = (pjsip_sip_uri *)pjsip_uri_get_uri(data->msg_info.from->uri);
    
    NSString *serverAddress = [NSString stringWithFormat:@"%@:%d", [NSString stringWithPJString:refer_sip_uri->host], refer_sip_uri->port];
    
    [self innerOnReferFrom:[NSString stringWithPJString:from->user] server:serverAddress forAccount:acc_id ipV6:ipv6Enabled callId:[NSString stringWithPJString:data->msg_info.cid->id] cSeq:0];
}



- (void) onReferFrom: (NSString *) abonent server: (NSString *)voiceUrl forAccount: (int)acc_id ipV6: (BOOL) ipv6Enabled callId: (NSString *)callId cSeq: (int)cSeq {
    
    SWThreadManager *thrManager = [SWEndpoint sharedEndpoint].threadFactory;
    NSThread *regThread = [thrManager getRegistrationThread];
    
    if([NSThread currentThread] != regThread) {
        [thrManager runBlock:^{
            [self innerOnReferFrom:abonent server:voiceUrl forAccount:acc_id ipV6:ipv6Enabled callId:callId cSeq:cSeq];
        } onThread:regThread wait:NO];
        return;
    }
    else {
        [self innerOnReferFrom:abonent server:voiceUrl forAccount:acc_id ipV6:ipv6Enabled callId:callId cSeq:cSeq];
    }
}

- (void) innerOnReferFrom: (NSString *) abonent server: (NSString *)voiceUrl forAccount: (int)acc_id ipV6: (BOOL) ipv6Enabled callId: (NSString *)callId cSeq: (int)cSeq {
    
    pj_status_t    status;
    
    NSString *targetUrl = [NSString stringWithFormat:@"<sips:%@@%@>", abonent, voiceUrl];
    
    pj_str_t target = [targetUrl pjString];
    
    pjsip_tx_data *pjsua_data;
    
    pjsua_acc_create_request(acc_id, &pjsip_notify_method, &target, &pjsua_data);
    
    [self setMediaIpv6Enabled:ipv6Enabled forAccId:acc_id];
    
    pj_str_t hname = pj_str((char *)"Event");
    pj_str_t hvalue = pj_str((char *)"Ready");
    pjsip_generic_string_hdr* event_hdr = pjsip_generic_string_hdr_create(pjsua_data->pool, &hname, &hvalue);
    
    pjsip_msg_add_hdr(pjsua_data->msg, (pjsip_hdr*)event_hdr);
    
    pjsip_msg_find_remove_hdr(pjsua_data->msg, PJSIP_H_CSEQ, NULL);
    pjsip_msg_find_remove_hdr(pjsua_data->msg, PJSIP_H_CALL_ID, NULL);
    
    pjsip_cseq_hdr *cseq_hdr = pjsip_cseq_hdr_create(pjsua_data->pool);
    cseq_hdr->cseq = cSeq;
    cseq_hdr->method = pjsip_notify_method;
    pjsip_msg_add_hdr(pjsua_data->msg, cseq_hdr);
    
    pjsip_cid_hdr* cid_hdr = pjsip_cid_hdr_create(pjsua_data->pool);
    cid_hdr->id = [callId pjString];
    pjsip_msg_add_hdr(pjsua_data->msg, cid_hdr);
    
    
    //
    status = pjsip_endpt_send_request(pjsua_get_pjsip_endpt(), pjsua_data, 1000, nil, &refer_notify_callback);
    
    if (status != PJ_SUCCESS) {
        return;
    }
}

- (void) setMediaIpv6Enabled: (BOOL) enabled forAccId: (int) accId {
    /*
#ifndef DEBUG
#error TODO
    //TODO: разделить этот признак по аккаунтам?
#endif
     */
    if(self.isMediaIpv6Enabled == enabled) {
        return;
    }
    
    pjsua_acc_config acc_cfg;
    pjsua_acc_get_config(accId, self.pjPool, &acc_cfg);
    
    self.isMediaIpv6Enabled = enabled;
    
    if (enabled) {
        acc_cfg.ipv6_media_use = PJSUA_IPV6_ENABLED;
        NSLog(@"<--ipv6-->WIll USE IPv6 For Media");
    } else {
        acc_cfg.ipv6_media_use = PJSUA_IPV6_DISABLED;
        NSLog(@"<--ipv6-->WIll USE IPv4 For Media");
        
    }
    
    pj_status_t status_acc = pjsua_acc_modify(accId, &acc_cfg);
    if (status_acc != PJ_SUCCESS) {
        NSLog(@"<--ipv6-->Failed To modify acc");
        self.isMediaIpv6Enabled = !enabled;
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
    pj_str_t command_delete_chat = pj_str((char *)"DeleteChat");
    pj_str_t command_create_chat = pj_str((char *)"CreateChat");
    
    pj_str_t command_add_abonent = pj_str((char *)"AddAbonent");
    pj_str_t command_delete_abonent = pj_str((char *)"DeleteAbonent");
    
    
    pjsip_generic_string_hdr* new_name_hdr = pjsip_generic_string_hdr_create(data->tp_info.pool, &command_name_hdr->name, &command_name_hdr->hvalue);
    
    struct pjsip_hdr hdr_list;
    
    pj_list_init(&hdr_list);
    
    pj_list_push_back(&hdr_list, new_name_hdr);
    
    if (command_name_hdr != nil && pj_strcmp(&command_name_hdr->hvalue, &command_sync) == 0) {
        pj_status_t status = pjsip_endpt_respond_stateless(pjsua_get_pjsip_endpt(), data, PJSIP_SC_OK, NULL, &hdr_list, NULL);
        NSLog(@"RespondToCommand %d", status);
        
        NSLog(@"<--pjsua_acc_set_registration--> incomingCommand");
        //status = pjsua_acc_set_registration(acc_id, PJ_TRUE);
        status = [account requestRegisterState:PJ_TRUE];
        if (status != PJ_SUCCESS) {
            NSLog(@"Failed to reregister");
        }
        return PJ_TRUE;
    }
    
    if (command_name_hdr != nil && pj_strcmp(&command_name_hdr->hvalue, &command_delete_chat) == 0) {
        pj_str_t  name_hdr_str = pj_str((char *)"Command-Value");
        pjsip_generic_string_hdr* value_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &name_hdr_str, nil);
        int smid = 0;
        int chat_id = 0;
        
        pjsip_sip_uri *fromUri = (pjsip_sip_uri*)pjsip_uri_get_uri(data->msg_info.from->uri);
        NSString *abonent = [NSString stringWithPJString:fromUri->user];
        
        
        if (value_hdr != nil) {
            sscanf(value_hdr->hvalue.ptr, "SMID=%i ChatID=%i", &smid, &chat_id);
        }
        
        if (value_hdr != nil) {
            if (_chatDeletedBlock) {
                _chatDeletedBlock(account, abonent, (NSUInteger) chat_id);
            }
        }
        
        pj_status_t status = pjsip_endpt_respond_stateless(pjsua_get_pjsip_endpt(), data, PJSIP_SC_OK, NULL, NULL, NULL);
        
        
        if (status != PJ_SUCCESS) {
            NSLog(@"Failed to respond");
        }
        
        return PJ_TRUE;
    }
    
    
    if (command_name_hdr != nil && pj_strcmp(&command_name_hdr->hvalue, &command_delete_message) == 0) {
        
        
        pj_str_t smid_hdr_str = pj_str((char *)"SMID");
        pjsip_generic_string_hdr *smid_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(data->msg_info.msg, &smid_hdr_str, nil);
        
        pjsip_generic_string_hdr* new_smid_hdr = pjsip_generic_string_hdr_create(data->tp_info.pool, &smid_hdr->name, &smid_hdr->hvalue);
        
        
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
    pjsua_acc_id acc_id;
    if (pjsua_acc_get_count() == 0) return PJ_FALSE;
    acc_id = pjsua_acc_find_for_incoming(data);
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

- (void) runCallStateChangeBlockForCall: (SWCall *)call setCode: (pjsip_status_code) statusCode {
    SWAccount *account = [self lookupAccount:call.accountId];
    
    if (self.callStateChangeBlock) {
        self.callStateChangeBlock(account, call, PJSIP_SC_OK);
    }
}

#pragma mark - Отправляем абоненту результат обработки его сообщения

- (BOOL) sendSubmit:(pjsip_rx_data *) message withCode:(int32_t) answer_code {
    return [self sendSubmitToValue:*message withCode:answer_code];
}

- (BOOL) sendSubmitToValue:(pjsip_rx_data) messageValue withCode:(int32_t) answer_code {
    NSLog(@"<--sendSubmit--> invoked");
    
    SWThreadManager *thrManager = self.threadFactory;
    NSThread *mesThread = [thrManager getMessageThread];
    
    NSInteger endpointIteration = self.endpointIteration;
    
    __weak typeof(self) weakSelf = self;
    
    #warning experiment выполняем в текущем потоке
    //[thrManager runBlock:^{
        
        pjsip_rx_data *message = &messageValue;
        //Если либа перезагружается или перезагрузилась, ничего не делаем. Сообщение придет еще раз.
        
        if ((pjsua_get_state() != PJSUA_STATE_RUNNING) || (endpointIteration != weakSelf.endpointIteration) || (message->msg_info.msg->type != PJSIP_REQUEST_MSG)) {
            NSLog(@"<--sendSubmit--> runblock stopped");
            
            NSString *messageStr = [NSString stringWithCharacters:message->msg_info.msg_buf length:message->msg_info.len];
            
            return YES;
        }
        
        SWAccount *account;
        pjsip_tx_data *response;
        pj_status_t status;
        int sm_id;
        
        /* Готовим ответ абоненту о результате регистрации */
        status = pjsip_endpt_create_response(pjsua_get_pjsip_endpt(), message, answer_code, nil, &response);
        if (status == PJ_SUCCESS) {
            NSLog(@"<--sendSubmit--> response created. bufLen = %d; bufOffset = %d", &response->buf.end - &response->buf.start, &response->buf.cur - &response->buf.start);
            
            pj_str_t smid_hdr_str = pj_str((char *)"SMID");
            pjsip_hdr *smid_hdr = (pjsip_hdr*)pjsip_msg_find_hdr_by_name(message->msg_info.msg, &smid_hdr_str, nil);
            
            pj_str_t  sync_hdr_str = pj_str((char *)"SYNC");
            pjsip_generic_string_hdr *sync_hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(message->msg_info.msg, &sync_hdr_str, nil);
            
            if (smid_hdr != nil) {
                pjsip_msg_add_hdr(response->msg, smid_hdr);
                sm_id = atoi(((pjsip_generic_string_hdr *)smid_hdr)->hvalue.ptr);
            }
            
            
            pjsua_acc_id acc_id;
            if (pjsua_acc_get_count() == 0) {
                //ret_value = PJ_FALSE;
                //TODO: Нужно ли обрабатывать ответ?
                return YES;
            }
            
            /*
             //Работаем с одним аккаунтом
            acc_id = pjsua_acc_find_for_incoming(message);
            account = [self lookupAccount:acc_id];
             */
            
            account = [self firstAccount];
            
            if (sync_hdr != nil) {
                
                NSLog(@"<--sendSubmit--> sync header exists");
                
                int num = 0;
                int total = 0;
                int seq = 0;
                int type = 0;
                
                sscanf(sync_hdr->hvalue.ptr, "num=%i, total=%i, seq=%i, type=%i", &num, &total, &seq, &type);
                
                
                if (total == seq) {
                    
                    NSLog(@"<--sendSubmit--> last sync message");
                    
                    char sync_buf[256];
                    
                    pj_str_t hname = pj_str((char *)"SYNC");
                    pj_str_t hvalue;
                    hvalue.ptr = sync_buf;
                    hvalue.slen = snprintf(sync_buf, 256, "num=%i, smid=%i, type=%i", num, sm_id, type);
                    
                    pjsip_generic_string_hdr* submit_sync_hdr = pjsip_generic_string_hdr_create(response->pool, &hname, &hvalue);
                    if (submit_sync_hdr != nil) {
                        pjsip_msg_add_hdr(response->msg, submit_sync_hdr);
                    }
                    
                } else {
                    NSLog(@"<--sendSubmit--> not last sync message");
                    //ret_value = YES;
                    //TODO: Нужно ли обрабатывать ответ?
                    return YES;
                }
            }
            
            if (account != nil) {
                
                /* Получаем адрес, куда мы должны отправить ответ */
                pjsip_response_addr  response_addr;
                status = pjsip_get_response_addr(response->pool, message, &response_addr);
                
                NSLog(@"<--sendSubmit--> runblock proceeded. bufLen = %d; bufOffset = %d, bufcur=%d; bufstart=%d", &response->buf.end - &response->buf.start, &response->buf.cur - &response->buf.start, &response->buf.cur, &response->buf.start);
                
                //pjsua_acc_info info = [account getInfo];
                
#warning experiment можно ли делать это в текущем потоке? Это и так поток сипа
                pjsua_acc_info info;
                pjsua_acc_get_info(account.accountId, &info);
                
                
                pjsip_uri *uri = (pjsip_name_addr*)pjsip_parse_uri(response->pool, info.acc_uri.ptr, info.acc_uri.slen, PJSIP_PARSE_URI_AS_NAMEADDR);
                
                pjsip_to_hdr *to_hdr = pjsip_to_hdr_create(response->pool);
                
                to_hdr->uri = uri;
                pjsip_msg_find_remove_hdr(response->msg, PJSIP_H_TO, NULL);
                //
                pjsip_msg_add_hdr(response->msg, to_hdr);
                
                /* Отправляем ответ на регистрацию */
                pjsip_endpoint *innerEndpoint = pjsua_get_pjsip_endpt();
                status = pjsip_endpt_send_response(innerEndpoint, &response_addr, response, nil, nil);
                if (status == PJ_SUCCESS) {
                    
                    NSLog(@"<--sendSubmit--> submit sent");
                    //ret_value = true;
                    //TODO: Нужно ли обрабатывать ответ?
                }
                else {
                    NSLog(@"<--sendSubmit--> submit sending error");
                }
            }
            else {
                NSLog(@"<--sendSubmit--> account is nil");
            }
        }
        
#warning experiment выполняем в текущем потоке
    //} onThread:mesThread wait:NO];
    
    return YES;
}


#pragma mark Ringtone management

- (void) setStandartRingtone {
    if (!_standartRingtone) {
        
        NSURL *fileURL = [[NSBundle mainBundle] URLForResource:@"Ringtone" withExtension:@"caf"];
        
        _standartRingtone = [[SWRingtone alloc] initWithFileAtPath:fileURL];
    }
    
    self.ringtone = _standartRingtone;
}

- (SWRingtone *) getRingtoneForReason: (NSInteger) reason andCall: (SWCall *) call {
    SWRingtone *ringtone;
    SWRingtoneDescription *description;
    
    if (self.endpointConfiguration.getRingtoneBlock != nil) {
        //Может быть, в конфигурации задан блок поиска рингтона
        description = self.endpointConfiguration.getRingtoneBlock(reason, call);
    }
    else {
        //Поищем в конфиге
        description = [self.endpointConfiguration.ringtones objectForKey:[NSNumber numberWithInteger:reason]];
        
        //Если причина не нашлась, проиграем общий рингтон (короткие гудки)
        if (description == nil) {
            description = [self.endpointConfiguration.ringtones objectForKey:[NSNumber numberWithInteger:0]];
        }
    }
    
    if (description) {
        
        //Возможно, такой рингтон уже есть в кэше
        ringtone = [self.ringtones objectForKey:description.url];
        
        //...или создадим по конфигу
        if ((ringtone == nil) && (description.url != nil)) {
            //создадим ринтон и поместим его в кэш
            ringtone = [[SWRingtone alloc] initWithFileAtPath:description.url];
            ringtone.noVibrations = !description.hasVibrations;
            ringtone.isFinite = description.isFinite;
            
            [self.ringtones setObject:ringtone forKey:description.url];
        }
    }
    
    return ringtone;
}

- (SWRingtone *) getRingtoneForReason: (NSInteger) reason {
    return [self getRingtoneForReason:reason andCall:nil];
}

- (void) startStandartRingtone {
    [self setStandartRingtone];
    
    [self.ringtone start];
}

+ (NSString *) getHeaderByName: (NSString *) hname forMessage: (pjsip_msg *) msg {
    NSString *result = nil;
    
    if (msg == nil) {
        return nil;
    }
    
    pj_str_t  hdr_name = pj_str((char *)[hname UTF8String]);
    
    pjsip_generic_string_hdr* hdr;
    
    /*
    //Процедура pjsip_msg_find_hdr_by_name подвисает, если не находит нужного хедера. Проверим вручную.
    pjsip_hdr *currenthdr = msg->hdr.next;
    pjsip_hdr *lasthdr = &msg->hdr;
    BOOL found = NO;
    
    while (currenthdr != lasthdr) {
        if (pj_strcmp(&currenthdr->name, &hdr_name) == 0) {
            found = YES;
            break;
        }
        currenthdr = currenthdr->next;
    }
    
    //не нашли
    if(!found) {
        return nil;
    }
    */
     
    hdr = (pjsip_generic_string_hdr*)pjsip_msg_find_hdr_by_name(msg, &hdr_name, nil);
    
    if (hdr != nil) {
        result = [NSString stringWithPJString:hdr->hvalue];
    }
    
    return result;
}

+ (pjsip_msg *) getMessageFromEvent: (pjsip_event *) e {
    pjsip_rx_data     *rdata = nil;
    pjsip_tx_data     *tdata = nil;
    pjsip_msg         *msg   = nil;
    switch (e->type)
    {
        case PJSIP_EVENT_TIMER :
            break;
            
        case PJSIP_EVENT_RX_MSG :
            rdata = e->body.rx_msg.rdata;
            break;
            
        case PJSIP_EVENT_TX_MSG :
            tdata = e->body.tx_msg.tdata;
            break;
            
        case PJSIP_EVENT_TRANSPORT_ERROR :
            tdata = e->body.tx_error.tdata;
            //tsx   = e->body.tx_error.tsx;
            break;
            
        case PJSIP_EVENT_TSX_STATE :
            switch (e->body.tsx_state.type)
        {
            case PJSIP_EVENT_TIMER :
                break;
                
            case PJSIP_EVENT_RX_MSG :
                rdata = e->body.tsx_state.src.rdata;
                break;
                
            case PJSIP_EVENT_TX_MSG :
                tdata = e->body.tsx_state.src.tdata;
                break;
                
            case PJSIP_EVENT_TRANSPORT_ERROR :
                break;
        }
            break;
    }
    if (rdata)
        msg = rdata->msg_info.msg;
    else if (tdata)
        msg = tdata->msg;
    
    return msg;
}

- (BOOL)areOtherCalls {
    if (self.endpointConfiguration.areOtherCallsBlock) {
        return self.endpointConfiguration.areOtherCallsBlock();
    }
    NSLog(@"<--check other calls--> areOtherCalls: %@", _areOtherCalls ? @"true" : @"false");
    return _areOtherCalls;
}

- (BOOL)hasActiveAccount {
    __block BOOL result = NO;
    
    SWThreadManager *threadManager = self.threadFactory;
    
    NSThread *regThread = [threadManager getRegistrationThread];
    
    __weak typeof(self) weakSelf = self;
    
    [threadManager runBlock:^{
        if (pjsua_get_state() != PJSUA_STATE_RUNNING) {
            result = NO;
            return;
        }
        
        SWAccount *account = [weakSelf firstAccount];
        
        if (account == nil) {
            result = NO;
            return;
        }
        
        pjsua_acc_info accinfo = [account getInfo];
        
        result = ((account.accountState == SWAccountStateConnected) && (accinfo.expires > 3));
        
        return;
        
    } onThread:regThread wait:YES];
    
    return result;
}

+ (pjsip_contact_hdr *) rightFindHeaderInMessage: (pjsip_msg) msg
                                         forType: (pjsip_hdr_e) type {
    
    pjsip_contact_hdr *result = nil;
    
    pjsip_hdr *firstHeader = msg.hdr.next->next;
    pjsip_hdr *lastHeader = firstHeader->prev;
    
    pjsip_hdr *hdr = firstHeader;
    
    int i = 0;
    i++;
    
    //Проверяем, пока не дошли до последнего хедера
    while(hdr != lastHeader) {
        if (hdr->type == type) {
            result = hdr;
            return result;
        }
        
        //ограничим глубину поиска?
        if (i>100) return result;
        i++;
        
        hdr = hdr->next;
    }
    
    //проверим еще раз для последнего
    if (hdr->type == type) {
        result = hdr;
        return result;
    }
    
    return nil;
}

+ (pjsip_contact_hdr *) rightFindHeaderInMessage: (pjsip_msg)msg
                                         forName: (const pj_str_t *) name {
    pjsip_contact_hdr *result = nil;
    
    NSString *findingName = [[NSString stringWithPJString:*name] lowercaseString];
    pjsip_hdr *msgHdr = &msg.hdr;
    pjsip_hdr *firstHeader = msg.hdr.next->next;
    pjsip_hdr *lastHeader = firstHeader->prev;
    
    pjsip_hdr *hdr = firstHeader;
    
    int i = 0;
    
    //Проверяем, пока не дошли до последнего хедера
    while(hdr != lastHeader) {
        NSString *hdrname;
        
        if ((hdr != msgHdr) && (hdr->type <= PJSIP_H_OTHER) && (hdr->name.ptr != nil) && (hdr->name.ptr != "")) {
            hdrname = [[NSString stringWithPJString:hdr->name] lowercaseString];
        }
        if ([findingName isEqualToString:hdrname]) {
            result = hdr;
            return result;
        }
        
        
        //ограничим глубину поиска?
        if (i>100) return result;
        i++;
        
        hdr = hdr->next;
    }
    
    //проверим еще раз для последнего
    NSString *hdrname = [NSString stringWithPJString:hdr->name];
    if ([findingName isEqualToString:hdrname]) {
        result = hdr;
        return result;
    }
    
    return nil;
}

@end
