//
//  SWCall.m
//  swig
//
//  Created by Pierre-Marc Airoldi on 2014-08-21.
//  Copyright (c) 2014 PeteAppDesigns. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "SWCall.h"
#import "SWAccount.h"
#import "SWEndpoint.h"
#import "SWUriFormatter.h"
#import "NSString+PJString.h"
#import "pjsua.h"
#import <AVFoundation/AVFoundation.h>
#import "SWMutableCall.h"
#import "SWAccountConfiguration.h"
#import "SWThreadManager.h"
#import "EWFileLogger.h"
#import <pjsua-lib/pjsua_internal.h>

@import CoreTelephony;

@interface SWCall ()

@property (nonatomic, strong) UILocalNotification *notification;
@property (nonatomic, strong) SWRingback *ringback;
@property (nonatomic, copy, nullable) void (^answerHandler)(NSError *error);
/*
#ifndef DEBUG
#error TODO
//TODO: вместо хэндлера надо использовать признак, который не может быть nil
#endif
 */

#define PJMEDIA_NO_VID_DEVICE -100

@property (nonatomic, assign) pjmedia_vid_dev_index currentVideoCaptureDevice;

@property (nonatomic, assign) BOOL isHangupSent;
@property (nonatomic, assign) BOOL wasConnected;


@end

@implementation SWCall {
    NSTimeInterval _spendTime;
    BOOL _isGsm;
    BOOL _callkitAreHandlingAudioSession;
}

-(instancetype)init {
    
    NSAssert(NO, @"never call init directly use init with call id");
    
    return nil;
}

-(instancetype)initWithCallId:(NSUInteger)callId accountId:(NSInteger)accountId inBound:(BOOL)inbound isGsm: (BOOL) isGsm {
    
    self = [self initBeforeSipWithAccountId:accountId inBound:inbound withVideo:NO forUri:nil isGsm:isGsm withGeneratedId: nil];
    
    if (!self) {
        return nil;
    }
    
    [self initSipDataForCallId:callId];
    
    return self;
}


-(instancetype)initWithCallId:(NSUInteger)callId accountId:(NSInteger)accountId inBound:(BOOL)inbound {
    return [self initWithCallId:callId accountId:accountId inBound:inbound isGsm:NO];
}

- (instancetype)initBeforeSipWithAccountId:(NSInteger)accountId inBound:(BOOL)inbound withVideo: (BOOL) withVideo forUri: (NSString *) uri isGsm: (BOOL) isGsm withGeneratedId: (NSString *) generatedCallId {
    
    self = [super init];
    
    _sipCallId = generatedCallId;
    if (generatedCallId != nil) {
        _isCallIdReplaced = YES;
    }
    
    //TODO: проверить закомментированный вариант
    //[SWCall closeSoundTrack:nil];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:AVAudioSessionInterruptionNotification object:[AVAudioSession sharedInstance] userInfo:@{AVAudioSessionInterruptionTypeKey: [NSNumber numberWithUnsignedInteger:AVAudioSessionInterruptionTypeBegan]}];
    
    _callId = -2;
    _accountId = accountId;
    _inbound = inbound;
    _spendTime = -1;
    _isGsm = isGsm;
    
    self.currentVideoCaptureDevice = PJMEDIA_NO_VID_DEVICE;
    
    if (!self) {
        return nil;
    }
    
    if (_inbound) {
        _missed = YES;
    }
    
    _withVideo = withVideo;
    
    _mute = NO;
    _speaker = _withVideo && [SWCall isOnlySpeakerOutput];
    
    _callState = SWCallStateReady;
    
    if (uri) {
        [self contactSetForUri:uri];
    }
    
    //TODO: move to account to fix multiple call problem
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(returnToBackground:) name:UIApplicationWillResignActiveNotification object:nil];
    
    return self;
}

-(instancetype)initBeforeSipWithAccountId:(NSInteger)accountId inBound:(BOOL)inbound withVideo: (BOOL) withVideo forUri: (NSString *) uri {
    
    return [self initBeforeSipWithAccountId:accountId inBound:inbound withVideo:withVideo forUri:uri isGsm:NO withGeneratedId: nil];
}

-(void)initSipDataForCallId: (NSUInteger)callId {
    
    _callId = callId;
    
    pjsua_call_info info;
    
    pj_status_t status = pjsua_call_get_info(_callId, &info);
    if (_isCallIdReplaced) {
        _localCallId = [NSString stringWithPJString:info.call_id];
    }
    else {
        _sipCallId = [NSString stringWithPJString:info.call_id];
    }
    //configure ringback
    
    _ringback = [SWRingback new];
    
    [self contactChanged];
    
    if ((status == PJ_SUCCESS) && (info.rem_vid_cnt > 0 || (!_inbound && (info.setting.vid_cnt > 0)))) {
        _withVideo = YES;
    }
    
    NSLog(@"<--swcall--> initSipDataForCallId withVideo:%@", _withVideo ? @"true" : @"false");
    
    _mute = NO;
    _speaker = _withVideo && [SWCall isOnlySpeakerOutput];
}

-(instancetype)copyWithZone:(NSZone *)zone {
    
    SWCall *call = [[SWCall allocWithZone:zone] init];
    call.contact = [self.contact copyWithZone:zone];
    call.callId = self.callId;
    call.accountId = self.accountId;
    call.callState = self.callState;
    call.mediaState = self.mediaState;
    call.inbound = self.inbound;
    call.missed = self.missed;
    call.date = [self.date copyWithZone:zone];
    call.duration = self.duration;
    
    return call;
}

-(instancetype)mutableCopyWithZone:(NSZone *)zone {
    
    SWMutableCall *call = [[SWMutableCall  allocWithZone:zone] init];
    call.contact = [self.contact copyWithZone:zone];
    call.callId = self.callId;
    call.accountId = self.accountId;
    call.callState = self.callState;
    call.mediaState = self.mediaState;
    call.inbound = self.inbound;
    call.missed = self.missed;
    call.date = [self.date copyWithZone:zone];
    call.duration = self.duration;
    
    return call;
}

+(instancetype)callWithId:(NSInteger)callId accountId:(NSInteger)accountId inBound:(BOOL)inbound {
    
    return [self callWithId:callId accountId:accountId inBound:inbound isGsm:NO];
}

+(instancetype)callWithId:(NSInteger)callId accountId:(NSInteger)accountId inBound:(BOOL)inbound isGsm: (BOOL) isGsm {
    
    SWCall *call = [[SWCall alloc] initWithCallId:callId accountId:accountId inBound:inbound isGsm:isGsm];
    
    return call;
}

+(instancetype)callBeforeSipForAccountId:(NSInteger)accountId inBound:(BOOL)inbound withVideo: (BOOL) withVideo forUri: (NSString *) uri isGsm: (BOOL) isGsm withCallId: (NSString *)callId {
    SWCall *call = [[SWCall alloc] initBeforeSipWithAccountId:accountId inBound:inbound withVideo:withVideo forUri:uri isGsm:isGsm withGeneratedId: callId];
    
    return call;
}

+(instancetype)callBeforeSipForAccountId:(NSInteger)accountId inBound:(BOOL)inbound withVideo: (BOOL) withVideo forUri: (NSString *) uri isGsm: (BOOL) isGsm {
    
    return [self callBeforeSipForAccountId:accountId inBound:inbound withVideo:withVideo forUri:uri isGsm:isGsm withCallId:nil];
}

+(instancetype)callBeforeSipForAccountId:(NSInteger)accountId inBound:(BOOL)inbound withVideo: (BOOL) withVideo forUri: (NSString *) uri {
    return [self callBeforeSipForAccountId:accountId inBound:inbound withVideo:withVideo forUri:uri isGsm:NO withCallId:nil];
}

-(void)createLocalNotification {
    
    if ([[[UIDevice currentDevice] systemVersion] floatValue] < 10.0) {
        _notification = [[UILocalNotification alloc] init];
        _notification.repeatInterval = 0;
        _notification.soundName = [[[SWEndpoint sharedEndpoint].ringtone.fileURL path] lastPathComponent];
        
        pj_status_t status;
        
        pjsua_call_info info;
        
        status = pjsua_call_get_info((int)self.callId, &info);
        
        
        
        if (status == PJ_TRUE) {
            _notification.alertBody = [NSString stringWithFormat:@"Incoming call from %@", self.contact.name];
        }
        
        else {
            _notification.alertBody = @"Incoming call";
        }
        
        _notification.alertAction = @"Activate app";
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [[UIApplication sharedApplication] presentLocalNotificationNow:_notification];
        });
    }
}

-(void)dealloc {
    
    if (_notification) {
        [[UIApplication sharedApplication] cancelLocalNotification:_notification];
    }
    
    if (_callState != SWCallStateDisconnected && _callState != SWCallStateDisconnectRingtone && _callId != PJSUA_INVALID_ID) {
#warning main thread!
        dispatch_async(dispatch_get_main_queue(), ^{
            pjsua_call_hangup((int)_callId, 0, NULL, NULL);
        });
        
    }
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillResignActiveNotification object:nil];
}

-(void)setCallId:(NSInteger)callId {
    
    [self willChangeValueForKey:@"callId"];
    _callId = callId;
    [self didChangeValueForKey:@"callId"];
}

-(void)setAccountId:(NSInteger)accountId {
    
    [self willChangeValueForKey:@"callId"];
    _accountId = accountId;
    [self didChangeValueForKey:@"callId"];
}

-(void)setCallState:(SWCallState)callState {
    
    [self willChangeValueForKey:@"callState"];
    _callState = callState;
    [self didChangeValueForKey:@"callState"];
}

-(void)setMediaState:(SWMediaState)mediaState {
    
    [self willChangeValueForKey:@"mediaState"];
    _mediaState = mediaState;
    [self didChangeValueForKey:@"mediaState"];
}

-(void)setRingback:(SWRingback *)ringback {
    
    [self willChangeValueForKey:@"ringback"];
    _ringback = ringback;
    [self didChangeValueForKey:@"ringback"];
}

-(void)setContact:(SWContact *)contact {
    
    [self willChangeValueForKey:@"contact"];
    _contact = contact;
    [self didChangeValueForKey:@"contact"];
}

-(void)setMissed:(BOOL)missed {
    
    [self willChangeValueForKey:@"missed"];
    _missed = missed;
    [self didChangeValueForKey:@"missed"];
}

-(void)setInbound:(BOOL)inbound {
    
    [self willChangeValueForKey:@"inbound"];
    _inbound = inbound;
    [self didChangeValueForKey:@"inbound"];
}

-(void)setDate:(NSDate *)date {
    
    [self willChangeValueForKey:@"date"];
    _date = date;
    [self didChangeValueForKey:@"date"];
}

-(void)setDuration:(NSTimeInterval)duration {
    
    [self willChangeValueForKey:@"duration"];
    _duration = duration;
    [self didChangeValueForKey:@"duration"];
}

-(void)callStateChanged {
    [self callStateChangedWithReason:-1];
}

-(void)callStateChangedWithReason: (NSInteger) reason {
    
    pjsua_call_info callInfo;
    pjsua_call_get_info((int)self.callId, &callInfo);
    
    [self callStateChanged:callInfo withReason:reason];
}

-(void)callStateChanged: (pjsua_call_info) callInfo withReason: (NSInteger) reason {
    
    SWEndpoint *endpoint = [SWEndpoint sharedEndpoint];
    
    NSLog(@"<--SWCall callStateChangedWithReason--> callInfo.state: %d reason: %d", callInfo.state, reason);
    
    switch (callInfo.state) {
        case PJSIP_INV_STATE_NULL: {
            [SWCall closeSoundTrack:nil];
            [self.ringback stop];
            [endpoint.ringtone stop];
            if (self.callState == SWCallStateDisconnectRingtone) {
                self.callState = SWCallStateDisconnected;
            }
            else {
                self.callState = SWCallStateReady;
            }
            [self updateOverrideSpeaker];
        } break;
            
        case PJSIP_INV_STATE_INCOMING: {
            if([endpoint areOtherCalls]) {
                [self hangupOnReason:SWCallReasonLocalBusy withCompletion:nil];
                return;
            }
            
            [SWCall closeSoundTrack:nil];
            [endpoint startStandartRingtone];
            [self sendRinging];
            self.callState = SWCallStateIncoming;
            [self updateOverrideSpeaker];
        } break;
            
        case PJSIP_INV_STATE_CALLING: {
            
            [SWCall closeSoundTrack:nil];
            SWRingtone *ringtone = nil;
            
            if([endpoint areOtherCalls]) {
                [self hangupOnReason:SWCallReasonLocalBusy withCompletion:nil];
                return;
            }
            
            NSInteger localReason = reason;
            
            if ((localReason == 0) || (localReason == -1)) {
                localReason = SWCallReasonConnecting;
            }
            
            //Рингтон на стадии звонка решено не использовать - только гудки с Б-стороны
            /*
            ringtone = [endpoint getRingtoneForReason: localReason andCall:self];
            
            //Если мы звоним, до прихода гудков с сервера играем свои
            if ((!self.inbound) && (ringtone != nil)) {
                [ringtone setAudioPlayerDelegate:self];
                [endpoint setRingtone:ringtone];
                [ringtone startRingtone];
            }
             */
            
            self.callState = SWCallStateCalling;
            [self updateOverrideSpeaker];
        } break;
            
        case PJSIP_INV_STATE_EARLY: {
            self.callState = SWCallStateCalling;
#warning experiment лишний раз?
            //[self updateOverrideSpeaker];
            if (!self.inbound) {
                [SWCall openSoundTrack:^(NSError *error) {
                    if (callInfo.last_status == PJSIP_SC_RINGING) {
                        [self.ringback start];
                    } else if (callInfo.last_status == PJSIP_SC_PROGRESS) {
                        [self.ringback stop];
                    }
                }];
            }
            
        } break;
            
        case PJSIP_INV_STATE_CONNECTING: {
            if (self.ctcallId == nil) {
                self.ctcallId = self.inbound ? @"incoming polyphone" : @"outgoing polyphone";
            }
            
            [SWCall closeSoundTrack:nil];
            [self.ringback stop];
            [endpoint.ringtone stop];
            
            self.callState = SWCallStateConnecting;
            [self updateOverrideSpeaker];
        } break;
            
        case PJSIP_INV_STATE_CONFIRMED: {
            
            self.wasConnected = YES;
            NSLog(@"<--starting--> SWCallStateConnected");
            //[self reRunVideo];
            
            [SWCall openSoundTrack:nil];
            
            self.callState = SWCallStateConnected;
            self->_dateStartSpeaking = [NSDate date];
            [self updateMuteStatus];
            [self updateOverrideSpeaker];
        } break;
            
        case PJSIP_INV_STATE_DISCONNECTED: {
            [SWCall closeSoundTrack:nil];
            [self.ringback stop];
            [endpoint.ringtone stop];
            
            [self disableVideoCaptureDevice];
            
            _spendTime = [[NSDate date] timeIntervalSinceDate:self.dateStartSpeaking];
            
            SWRingtone *ringtone = nil;
            
            //Если отбой инициирован не нами, по причине отбоя найдём рингтон
            //Если звонок не соединился и при этом не наш, гудки играть не нужно
            if (!self.isHangupSent && (self.wasConnected || (!self.inbound))) {
                ringtone = [endpoint getRingtoneForReason:reason andCall:self];
                [ringtone setAudioPlayerDelegate:self];
            }
            
            //и есть ли соответствующий гудок
            if (ringtone) {
                self.callState = SWCallStateDisconnectRingtone;
                
                [endpoint setRingtone:ringtone];
                
                //Если используется коллкит, рингтон стратует, когда он закроет сессию. Звонок отслеживает, контролирует ли коллкит сессию
                if (!self.callkitAreHandlingAudioSession) {
                    [ringtone startRingtone];
                }
            }
            else {
                self.callState = SWCallStateDisconnected;
                [self updateOverrideSpeaker];
            }
        } break;
    }
    
    [self contactChanged];
}

- (void) reRunVideo {
    if (!self.withVideo) {
        return;
    }
    
    __weak typeof(self) weakSelf = self;
    
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), queue, ^{
        
        SWThreadManager *thrManager = [SWEndpoint sharedEndpoint].threadFactory;
        
        NSThread *callThread = [thrManager getCallManagementThread];
        
        [thrManager runBlock:^{
            pj_status_t status;
            
            pjsua_call_setting call_setting;
            pjsua_call_setting_default(&call_setting);
            call_setting.vid_cnt=1;
            
            status = pjsua_call_reinvite2((int)self.callId, &call_setting, NULL);
            //status = pjsua_call_reinvite((int)weakSelf.callId, PJ_TRUE, NULL);
        } onThread:callThread wait:NO];
        
    });
}

-(void)mediaStateChanged {
    pjsua_call_info callInfo;
    pjsua_call_get_info((int)self.callId, &callInfo);
    
    if (callInfo.media_status == PJSUA_CALL_MEDIA_ACTIVE || callInfo.media_status == PJSUA_CALL_MEDIA_REMOTE_HOLD) {
        pjsua_conf_connect(callInfo.conf_slot, 0);
        pjsua_conf_connect(0, callInfo.conf_slot);
        unsigned medCnt = callInfo.media_cnt;
        if(self.withVideo && (callInfo.media_status == PJSUA_CALL_MEDIA_ACTIVE)) {
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([[UIApplication sharedApplication] applicationState] == UIApplicationStateActive) {
                    [self sendVideoKeyframe];
                }
            });
            
        }
    }
    
    pjsua_call_media_status mediaStatus = callInfo.media_status;
    
    self.mediaState = (SWMediaState)mediaStatus;
    
    [self updateMuteStatus];
}

- (void) runVideoStream {
    pjsua_call *call;
    
    pjsua_call_media *call_med;
    
    call = &pjsua_var.calls[self.callId];
    
    int med_idx = pjsua_call_get_vid_stream_idx(self.callId);
    pj_status_t status;
    
    call_med = &call->media[med_idx];
    pjmedia_vid_stream *stream = call_med->strm.v.stream;
    char errmsg[PJ_ERR_MSG_SIZE];
    
    if (!stream) {
        pjmedia_endpt *endpt = pjsua_var.med_endpt;
        pjmedia_vid_stream_info *info;
        
        status = pjmedia_vid_stream_create(endpt, NULL, &info, call_med->tp, NULL, &stream);
        
        
        if (status != PJ_SUCCESS) {
            pj_strerror(status, errmsg, sizeof(errmsg));
        }
    }
    
    if (!stream) {
        return;
    }
    
    BOOL isRunning = pjmedia_vid_stream_is_running(stream, PJMEDIA_DIR_ENCODING);
    
    if(!isRunning) {
        status = pjmedia_vid_stream_start(stream);
    }
}

- (void) changeVideoWindowWithSize: (CGSize) size {
    self.videoSize = size;
    
    [self enableVideoWindow];
}

- (void) enableVideoWindow {
#warning experiment Похоже,требует главного потока (работа с окнами итп)
    dispatch_async(dispatch_get_main_queue(), ^{
    //[[SWEndpoint sharedEndpoint].threadFactory runBlockOnRegThread:^{
        int vid_idx = pjsua_call_get_vid_stream_idx((int)self.callId);
        pjsua_vid_win_id wid;
        
        if (vid_idx >= 0) {
            pjsua_call_info ci;
            
            pjsua_call_get_info((int)self.callId, &ci);
            wid = ci.media[vid_idx].stream.vid.win_in;
            
            //Если окно не инициализировано, wid = -1
            if (wid == PJSUA_INVALID_ID) {
                return;
            }
            
            pjsua_vid_win_info windowInfo;
            pj_status_t status;
            
            status = pjsua_vid_win_get_info(wid, &windowInfo);
            
            if(status == PJ_SUCCESS) {
                
                UIView *videoView = (__bridge UIView *)windowInfo.hwnd.info.ios.window;
                
                self.videoView = videoView;
                
                pjsua_vid_win_set_show(wid, PJ_TRUE);
            }
        }
        
        if (self.currentVideoCaptureDevice == PJMEDIA_NO_VID_DEVICE) {
            self.currentVideoCaptureDevice = PJMEDIA_VID_DEFAULT_CAPTURE_DEV;
        }
        
        [self setVideoCaptureDevice:self.currentVideoCaptureDevice];
        
        SWAccount *account = [[SWEndpoint sharedEndpoint] lookupAccount:self.accountId];
        
        if ([SWEndpoint sharedEndpoint].callVideoFormatChangeBlock) {
            [SWEndpoint sharedEndpoint].callVideoFormatChangeBlock(account, self);
        }
    //} wait:NO];
    });
}

-(SWAccount *)getAccount {
    
    pjsua_call_info info;
    pjsua_call_get_info((int)self.callId, &info);
    
    return [[SWEndpoint sharedEndpoint] lookupAccount:info.acc_id];
}

-(void)contactChanged {
    
    pjsua_call_info info;
    pjsua_call_get_info((int)self.callId, &info);
    
    NSString *remoteURI = [NSString stringWithPJString:info.remote_info];
    
    [self contactSetForUri:remoteURI];
}

-(void)contactSetForUri: (NSString *) remoteURI {
    
    SWContact *contect = [SWUriFormatter contactFromURI:remoteURI];
    
    self.contact = contect;
}

- (void) sendRinging {
    
#warning experiment гудки должен слать сервер
    //return;
    
    SWEndpoint *endpoint = [SWEndpoint sharedEndpoint];
    
    NSThread *callThread = [endpoint.threadFactory getCallManagementThread];
    
    if([NSThread currentThread] != callThread) {
        [self performSelector:@selector(sendRinging) onThread:callThread withObject:nil waitUntilDone:NO];
        return;
    }
    
    pj_status_t status;
    NSError *error;
    
    status = pjsua_call_answer((int)self.callId, PJSIP_SC_RINGING, NULL, NULL);
    
    if (status != PJ_SUCCESS) {
        
        error = [NSError errorWithDomain:@"Error send ringing" code:0 userInfo:nil];
    }
    
}

#pragma Call Management

-(void)answer:(void(^)(NSError *error))handler {
    
    if ((!self.callkitAreHandlingAudioSession) && (@available(iOS 10.0, *))) {
        self.answerHandler = handler;
        return;
    }
    
    
    self.answerHandler = nil;
    
    SWEndpoint *endpoint = [SWEndpoint sharedEndpoint];
    
    NSThread *callThread = [endpoint.threadFactory getCallManagementThread];
    
    if([NSThread currentThread] != callThread) {
        [self performSelector:@selector(answer:) onThread:callThread withObject:handler waitUntilDone:NO];
        return;
    }
    
    pj_status_t status;
    NSError *error;
    
    
    unsigned vid_cnt = 0;
    
    if (self.withVideo && (!self.videoIsInactive)) {
        vid_cnt = 1;
    }
    
#warning отвечать без видео, если звонок с коллкита с заблокированного экрана?
    pjsua_call_setting call_setting;
    pjsua_call_setting_default(&call_setting);
    call_setting.vid_cnt=vid_cnt;
    
    pjsua_call_answer2((int)self.callId, &call_setting, PJSIP_SC_OK, NULL, NULL);
    
    //status = pjsua_call_answer((int)self.callId, PJSIP_SC_OK, NULL, NULL);
    
    if (status != PJ_SUCCESS) {
        
        error = [NSError errorWithDomain:@"Error answering up call" code:0 userInfo:nil];
    }
    
    else {
        self.missed = NO;
    }
    
    //[self updateOverrideSpeaker];
    
    if (handler) {
        handler(error);
    }
    
}

-(void)terminateWithCompletion:(void(^)(NSError *error))handler {
    if (self.callState == SWCallStateReady) {
        _callState = SWCallStateDisconnected;
        [[SWEndpoint sharedEndpoint] runCallStateChangeBlockForCall:self setCode:PJSIP_SC_TSX_TRANSPORT_ERROR];
        if (handler) {
            handler(nil);
        }
    }
    else {
        [self hangup:handler];
    }
}

-(void)hangup:(void(^)(NSError *error))handler {
    
    SWThreadManager *thrManager = [SWEndpoint sharedEndpoint].threadFactory;
    NSThread *callThread = [thrManager getCallManagementThread];
    
    if ([NSThread currentThread] != callThread) {
        [self performSelector:@selector(hangup:) onThread:callThread withObject:handler waitUntilDone:NO];
        return;
    }
    
    typeof (self) slf = self;
    
    slf.isHangupSent = YES;
    
    pj_status_t status;
    NSError *error;
    
    //Если звонок уже сброшен, но ещё идёт рингтон, просто обновим статус (перейдёт в состояние disconnected)
    if (slf.callState == SWCallStateDisconnectRingtone) {
        [slf callStateChanged];
        [[SWEndpoint sharedEndpoint] runCallStateChangeBlockForCall:slf setCode:SWCallStateDisconnected];
        
        SWAccount *account = [self getAccount];
        
        [account removeCall:self.callId];
        
        return;
    }
    
    
    //Если попали сюда из hangupOnReason, сгенерируем структуру, добавим в хедер и очистим свойство
    
    pjsua_msg_data *msg_data = NULL;
    
    NSString *reason;
    unsigned hangupCode = 0;
    
    //исторически сложилось, что этот код отправляется другим способом
    if (slf.hangupReason == SWCallReasonTerminatedRemote) {
        reason = [NSString stringWithFormat:@"SIP;cause=%d;text=””", slf.hangupReason];
        NSLog(@"<--hangup--> reason sent: %@", reason);
    }
    else if (slf.hangupReason > 0) {
        hangupCode = slf.hangupReason;
    }
    else if (slf.hangupReason == SWCallReasonLocalBusy) {
        hangupCode = PJSIP_SC_BUSY_HERE;
    }
    
    if (reason != nil) {
        msg_data = malloc(sizeof(pjsua_msg_data));
        
        slf.hangupReason = -1;
        pjsua_msg_data_init(msg_data);
        
        pj_str_t hname = pj_str((char *)[@"X-Reason" UTF8String]);
        char * headerValue=(char *)[reason UTF8String];
        pj_str_t hvalue = pj_str(headerValue);
        
        pj_pool_t *pool;
        pool = pjsua_pool_create("reasonheader", 512, 512);
        
        pjsip_generic_string_hdr* add_hdr = pjsip_generic_string_hdr_create(pool, &hname, &hvalue);
        pj_list_push_back(&(*msg_data).hdr_list, add_hdr);
    }
    else {
        msg_data = NULL;
    }
    
    if (slf.callId != PJSUA_INVALID_ID && slf.callState != SWCallStateDisconnected) {
        
        status = pjsua_call_hangup((int)slf.callId, hangupCode, NULL, msg_data);
        //status = pjsua_call_hangup((int)self.callId, 0, NULL, NULL);
        
        if (status != PJ_SUCCESS) {
            
            error = [NSError errorWithDomain:@"Error hanging up call" code:0 userInfo:nil];
        }
        else {
            slf.missed = NO;
        }
    }
    
    if (handler) {
        handler(error);
    }
    
    slf.ringback = nil;
}

-(void)hangupOnReason: (NSInteger) reason withCompletion:(void(^)(NSError *error))handler {
    self.hangupReason = reason;
    
    SWThreadManager *thrManager = [SWEndpoint sharedEndpoint].threadFactory;
    NSThread *callThread = [thrManager getCallManagementThread];
    
    [self performSelector:@selector(hangup:) onThread:callThread withObject:handler waitUntilDone:NO];
}

-(void)openSoundTrack:(void(^)(NSError *error))handler {
    
    [SWCall openSoundTrack:handler];
}

-(void)closeSoundTrack:(void(^)(NSError *error))handler {
    [SWCall closeSoundTrack:handler];
}

+(void)openSoundTrack:(void(^)(NSError *error))handler {
    
    SWThreadManager *thrManager = [SWEndpoint sharedEndpoint].threadFactory;
    NSThread *callThread = [thrManager getCallManagementThread];
    
    if ([NSThread currentThread] != callThread) {
        [self performSelector:@selector(openSoundTrack:) onThread:callThread withObject:handler waitUntilDone:NO];
        return;
    }
    
    NSLog(@"<--starting call--> openSoundTrack");
    
    pj_status_t status;
    NSError *error;
    
    status = pjsua_set_snd_dev(PJMEDIA_AUD_DEFAULT_CAPTURE_DEV, PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV);
    
    if (status != PJ_SUCCESS) {
        error = [NSError errorWithDomain:@"Error open sound track" code:0 userInfo:nil];
    }
    
    
    if (handler) {
        handler(error);
    }
}

+(void)closeSoundTrack:(void(^)(NSError *error))handler {
    NSLog(@"<--starting call--> closeSoundTrack");
    SWThreadManager *thrManager = [SWEndpoint sharedEndpoint].threadFactory;
    NSThread *callThread = [thrManager getCallManagementThread];
    
    if ([NSThread currentThread] != callThread) {
        [self performSelector:@selector(closeSoundTrack:) onThread:callThread withObject:handler waitUntilDone:NO];
        return;
    }
    
    NSError *error;
    
    pjsua_set_no_snd_dev();
    
    //pjsua_set_no_snd_dev возвращает не статус!
    /*
     pj_status_t status;
     NSError *error;
     
     status = pjsua_set_no_snd_dev();
     
     if (status != PJ_SUCCESS) {
     error = [NSError errorWithDomain:@"Error close sound track" code:0 userInfo:nil];
     }
     */
    
    if (handler) {
        handler(error);
    }
}

-(void)setHold:(void(^)(NSError *error))handler {
    pj_status_t status;
    NSError *error;
    
    if (self.callId != PJSUA_INVALID_ID && self.callState != SWCallStateDisconnected && self.callState != SWCallStateDisconnectRingtone) {
        
        pjsua_set_no_snd_dev();
        
        status = pjsua_call_set_hold((int)self.callId, NULL);
        
        if (status != PJ_SUCCESS) {
            
            error = [NSError errorWithDomain:@"Error holding call" code:0 userInfo:nil];
            
        }
        
    }
    
    if (handler) {
        handler(error);
    }
    
}

#pragma mark video

- (void) setVideoEnabled: (BOOL) enabled {
    if (enabled) {
        pjsua_call_set_vid_strm(self.callId, PJSUA_CALL_VID_STRM_ADD, NULL);
    }
    else {
        pjsua_call_set_vid_strm(self.callId, PJSUA_CALL_VID_STRM_REMOVE, NULL);
    }
}

- (void) changeVideoCaptureDevice {
    unsigned count = pjsua_vid_dev_count();
    
    if ((count == 0) || (self.callState != SWCallStateConnected)) {
        return;
    }
    
    pjmedia_vid_dev_info vdi;
    pj_status_t status;
    
    pjmedia_vid_dev_index currentDev = PJMEDIA_NO_VID_DEVICE;
    pjmedia_vid_dev_index nextDev = PJMEDIA_VID_DEFAULT_CAPTURE_DEV;
    
    for (pjmedia_vid_dev_index i=0; i<count; ++i) {
        status = pjsua_vid_dev_get_info(i, &vdi);
        
        if ((status == PJ_SUCCESS) && (vdi.dir == PJMEDIA_DIR_CAPTURE)) {
            //Если дошли до колорбаров, настоящие камеры кончились
            if([[[NSString stringWithCString:vdi.name encoding:NSASCIIStringEncoding] lowercaseString] containsString:@"colorbar"]) {
                break;
            }
            
            //pjsua_vid_dev_is_active (vdi.id) лучше не использовать
            //активными могут остаться несколько окон
            if(vdi.id == self.currentVideoCaptureDevice) {
                currentDev = vdi.id;
            }
            else {
                nextDev = vdi.id;
                
                //Если перед этим нашли текущее устройство видеозахвата, надо перейти на это.
                if(currentDev != PJMEDIA_NO_VID_DEVICE) {
                    
                    break;
                }
            }
        }
    }
    
    //Почему-то после этого pjsua_vid_dev_is_active всё равно тру, зато окно превью пропадает насовсем
    /*
     if(currentDev != PJMEDIA_NO_VID_DEVICE) {
     //Отключаем захват превью
     
     pjsua_vid_preview_stop(currentDev);
     }
     */
    
    [self setVideoCaptureDevice:nextDev];
}

- (void) disableVideoCaptureDevice {
    unsigned count = pjsua_vid_dev_count();
    
    if (count == 0) {
        return;
    }
    
    pjmedia_vid_dev_info vdi;
    pj_status_t status;
    
    pjmedia_vid_dev_index currentDev = PJMEDIA_NO_VID_DEVICE;
    
    //Найдём все активные видеоустройства
    for (pjmedia_vid_dev_index i=0; i<count; ++i) {
        status = pjsua_vid_dev_get_info(i, &vdi);
        
        if ((status == PJ_SUCCESS) && (vdi.dir == PJMEDIA_DIR_CAPTURE)) {
            //Если дошли до колорбаров, настоящие камеры кончились
            if([[[NSString stringWithCString:vdi.name encoding:NSASCIIStringEncoding] lowercaseString] containsString:@"colorbar"]) {
                break;
            }
            
            if(pjsua_vid_dev_is_active (vdi.id)) {
                currentDev = vdi.id;
                
                //Отключаем захват превью и его окно
                pjsua_vid_win_id wid;
                wid = pjsua_vid_preview_get_win(currentDev);
                if (wid != PJSUA_INVALID_ID) {
                    pjsua_vid_win_set_show(wid, PJ_FALSE);
                }
                
                pjsua_vid_preview_stop(currentDev);
            }
        }
    }
    
    self.currentVideoCaptureDevice = PJMEDIA_NO_VID_DEVICE;
    self.videoPreviewView = nil;
}

- (void) setVideoCaptureDevice: (int) devId {
    SWAccount *account = [self getAccount];
    __weak typeof(self) weakSelf = self;
    
#warning experiment Похоже, код ниже требует главного потока. Иначе потом будет bad_access
    dispatch_async(dispatch_get_main_queue(), ^{
        [account configureVideoCodecForDevice: devId];
        
        pjsua_call_vid_strm_op_param param;
        
        pjsua_call_vid_strm_op_param_default(&param);
        
        param.cap_dev = devId;
        
        pjsua_call_set_vid_strm(weakSelf.callId,
                                PJSUA_CALL_VID_STRM_CHANGE_CAP_DEV,
                                &param);
        
        pjsua_vid_preview_param prvParam;
        
        pjsua_vid_preview_param_default(&prvParam);
        prvParam.wnd_flags = PJMEDIA_VID_DEV_WND_BORDER |
        PJMEDIA_VID_DEV_WND_RESIZABLE;
        
        pjsua_vid_preview_start(devId,&prvParam);
        
        pjsua_vid_win_id wnd = pjsua_vid_preview_get_win(devId);
        
        weakSelf.currentVideoCaptureDevice = devId;
        
        pjsua_vid_win_info windowInfo;
        
        pj_status_t status = pjsua_vid_win_get_info(wnd, &windowInfo);
        
        if(status != PJ_SUCCESS) return;
        
        if ((weakSelf.videoPreviewSize.width > 0) && (weakSelf.videoPreviewSize.height > 0)) {
            pjmedia_rect_size size;
            
            CGSize outputVideoSize = account.currentOutputVideoSize;
            
            CGFloat aspect = outputVideoSize.width / outputVideoSize.height;
            
            size.w = (int)weakSelf.videoPreviewSize.width;
#warning игнорируется переданная высота. Может быть, использовать как ограничения?
            size.h = (int)weakSelf.videoPreviewSize.width / aspect;
            
            pjsua_vid_win_set_size(wnd, &size);
        }
        else {
            pjsua_vid_win_set_show(wnd, PJ_FALSE);
        }
        
        weakSelf.videoPreviewView = (__bridge UIView *)windowInfo.hwnd.info.ios.window;
    });
    
}

- (void) sendVideoKeyframe {
    NSInteger callId = self.callId;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        for(int i = 0; i < 5; i++) {
            
            [NSThread sleepForTimeInterval:1];
            
#warning UI thread
            dispatch_async(dispatch_get_main_queue(), ^{
                pj_status_t status;
                status = pjsua_call_set_vid_strm(callId, PJSUA_CALL_VID_STRM_SEND_KEYFRAME, NULL);
            });
        }
    });
}

-(void)reinvite:(void(^)(NSError *error))handler {
    pj_status_t status;
    NSError *error;
    
    if (self.callId != PJSUA_INVALID_ID && self.callState != SWCallStateDisconnected && self.callState != SWCallStateDisconnectRingtone) {
        
#warning experiment
        /*
         int capture_dev = 0;
         int playback_dev = 0;
         
         status = pjsua_get_snd_dev(&capture_dev, &playback_dev);
         status = pjsua_set_snd_dev(capture_dev, playback_dev);
         */
        
        status = pjsua_set_snd_dev(PJMEDIA_AUD_DEFAULT_CAPTURE_DEV, PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV);
        
        pjsua_call_setting call_setting;
        pjsua_call_setting_default(&call_setting);
        call_setting.vid_cnt=1;
        
        status = pjsua_call_reinvite2((int)self.callId, &call_setting, NULL);
        
        if (status != PJ_SUCCESS) {
            error = [NSError errorWithDomain:@"Error reinvite call" code:0 userInfo:nil];
        }
    }
    
    if (handler) {
        handler(error);
    }
}

//-(void)transferCall:(NSString *)destination completionHandler:(void(^)(NSError *error))handler;
//-(void)replaceCall:(SWCall *)call completionHandler:(void (^)(NSError *))handler;

- (void)setMute:(BOOL)mute {
    NSLog(@"<--mute--> setMute: %@", mute ? @"true" : @"false");
    if (mute == _mute) {
        return;
    }
    
    _mute = mute;
    
    if(self.callState == SWCallStateConnected) {
        [self updateMuteStatus];
    }
}

- (void) updateMuteStatus {
    
    NSLog(@"<--mute--> value:%@", _mute ? @"true" : @"false");
    [[SWEndpoint sharedEndpoint].threadFactory runBlockOnRegThread:^{
        pjsua_call_info callInfo;
        pjsua_call_get_info((int)self.callId, &callInfo);
        
        pj_status_t status;
        NSError *error = nil;
        if (_mute) {
            status = pjsua_conf_disconnect(0, callInfo.conf_slot);
            if (status != PJ_SUCCESS) {
                error = [NSError errorWithDomain:@"Error mute" code:0 userInfo:nil];
                _mute = NO;
            }
        }
        
        else {
            status = pjsua_conf_connect(0, callInfo.conf_slot);
            if (status != PJ_SUCCESS) {
                error = [NSError errorWithDomain:@"Error unmute" code:0 userInfo:nil];
                _mute = YES;
            }
            
        }
    } wait:NO];
    
    
}

-(void)toggleMute:(void(^)(NSError *error))handler {
    
    pjsua_call_info callInfo;
    pjsua_call_get_info((int)self.callId, &callInfo);
    
    pj_status_t status;
    NSError *error = nil;
    if (!_mute) {
        status = pjsua_conf_disconnect(0, callInfo.conf_slot);
        _mute = YES;
        if (status != PJ_SUCCESS) {
            error = [NSError errorWithDomain:@"Error mute" code:0 userInfo:nil];
        }
        
    }
    
    else {
        status = pjsua_conf_connect(0, callInfo.conf_slot);
        _mute = NO;
        if (status != PJ_SUCCESS) {
            error = [NSError errorWithDomain:@"Error unmute" code:0 userInfo:nil];
        }
        
    }
    handler(error);
}

- (void)setSpeaker:(BOOL)speaker {
    if (_speaker == speaker) return;
    
    _speaker = speaker;
    
    [self updateOverrideSpeaker];
}

- (void) updateOverrideSpeaker {
    BOOL inbound = self.inbound;
    SWCallState callState = self.callState;
    BOOL currentspeaker = _speaker;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        
        BOOL isOnlyBuiltinInput = [SWCall isOnlyBuiltinInput];
        
        /*
#ifdef DEBUG
#warning test
        pjsua_conf_adjust_rx_level(0, 1.0);
#else
#error test
#endif
        */
        //усиление микрофона - при громкой связи, если не подключена гарнитура
        if (!isOnlyBuiltinInput) {
            pjsua_conf_adjust_rx_level(0, 2.0);
            NSLog(@"<--headset settings-->");
        }
        else if(currentspeaker) {
            pjsua_conf_adjust_rx_level(0, 1.5);
            pj_status_t stts = pjsua_set_ec(1000,0);
            //pjsua_conf_adjust_rx_level(0, 1.5);
        }
        else {
            pjsua_conf_adjust_rx_level(0, 1.0);
        }
        
        /*
         #ifndef DEBUG
         #error TODO
         //TODO: сделать что-то вроде этого?
         #endif
         pj_status_t stts = pjsua_set_ec(5000,0);
        */
        
        AVAudioSession *audioSession = [AVAudioSession sharedInstance];
        NSString *sessionMode = AVAudioSessionModeDefault;
        NSString *sessionCategory = AVAudioSessionCategoryPlayAndRecord;
        
        if ([[UIApplication sharedApplication] applicationState] != UIApplicationStateActive) {
            NSLog(@"<--AudioSession notification--> set category in background");
            [audioSession setCategory:sessionCategory withOptions:AVAudioSessionCategoryOptionAllowBluetooth|AVAudioSessionCategoryOptionAllowBluetoothA2DP error:nil];
            [audioSession setMode:sessionMode error:nil];
             
            //коллкит корректно понимает переключение на динамик только так
            if (currentspeaker) {
                //[audioSession overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:nil];
            }
            else {
                //[audioSession overrideOutputAudioPort:AVAudioSessionPortOverrideNone error:nil];
            }
            
            return;
        }
        
        //[audioSession overrideOutputAudioPort:AVAudioSessionPortOverrideNone error:nil];
        
        BOOL speaker = NO;
        BOOL sessionActive = YES;
        
        switch (callState) {
            case SWCallStateReady:
                speaker = YES;
                //AVAudioSessionCategoryPlayAndRecord не глушится silent switch'ом
                
                sessionCategory = inbound ? AVAudioSessionCategorySoloAmbient : AVAudioSessionCategoryPlayAndRecord;
                
                break;
            case SWCallStateIncoming:
                speaker = YES;
                sessionCategory = inbound ? AVAudioSessionCategorySoloAmbient : AVAudioSessionCategoryPlayAndRecord;
                break;
            case SWCallStateCalling:
                speaker = currentspeaker || inbound;
                sessionCategory = inbound ? AVAudioSessionCategorySoloAmbient : AVAudioSessionCategoryPlayAndRecord;
                break;
            case SWCallStateConnecting:
                sessionActive = NO;
                speaker = currentspeaker;
                break;
            case SWCallStateConnected:
                sessionActive = YES;
                NSLog(@"<--swcall--> ", audioSession);
                speaker = currentspeaker;
                
                sessionMode = AVAudioSessionModeDefault;
                //sessionMode = AVAudioSessionModeVoiceChat; //в этом моде не переключается громкая связь.
                //sessionMode = speaker ? AVAudioSessionModeVideoChat : AVAudioSessionModeDefault;
                break;
                
            case SWCallStateDisconnected: {
                sessionActive = NO;
                speaker = NO;
                
#warning костыль
                dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0);
                
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), queue, ^{
                    
                    [[NSNotificationCenter defaultCenter] postNotificationName:AVAudioSessionInterruptionNotification object:[AVAudioSession sharedInstance] userInfo:@{AVAudioSessionInterruptionTypeKey: [NSNumber numberWithUnsignedInteger:AVAudioSessionInterruptionTypeEnded]}];
                });
                
                break;
            }
                
            case SWCallStateDisconnectRingtone:
                speaker = currentspeaker;
                break;
            default:
                break;
        }
        
        //Если используется коллкит, нам не нужно проигрывать звонок самостоятельно, поэтому не нужен режим, который глушится свитчом (и не запускается в бэкграунде!)
        if ([[[UIDevice currentDevice] systemVersion] floatValue] >= 10.0) {
            sessionCategory = AVAudioSessionCategoryPlayAndRecord;
        }
        
        NSError *error = nil;
        
        NSTimeInterval bufferDuration = .005;
        [audioSession setPreferredIOBufferDuration:bufferDuration error:&error];
        [audioSession setPreferredSampleRate:44100 error:&error];
        
        [audioSession setMode:sessionMode error:&error];
        
        NSLog(@"<--swcall-->audioSession: %@ speaker value:%@", audioSession, speaker ? @"true" : @"false");
        //[audioSession setCategory:sessionCategory error:&error];
        if (speaker) {
            NSLog(@"<--AudioSession notification--> set category on callstate, speaker on, callstate: %d", callState);
            [audioSession setCategory:sessionCategory withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker|AVAudioSessionCategoryOptionAllowBluetooth|AVAudioSessionCategoryOptionAllowBluetoothA2DP error:&error];
            
            //[audioSession overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&error];
        }
        
        else {
            NSLog(@"<--AudioSession notification--> set category on callstate, speaker off, callstate: %d", callState);
            [audioSession setCategory:sessionCategory withOptions:AVAudioSessionCategoryOptionAllowBluetooth|AVAudioSessionCategoryOptionAllowBluetoothA2DP error:&error];
            //[audioSession setCategory:sessionCategory error:&error];
            
            //[audioSession overrideOutputAudioPort:AVAudioSessionPortOverrideNone error:&error];
            
        }
        
        NSLog(@"<--AudioSession notification--> set category on callstate error: %@", error);
        
        NSLog(@"<--swcall--> audiosession options: %d", audioSession.categoryOptions);
        
        if (!isOnlyBuiltinInput) {
            for (AVAudioSessionPortDescription* desc in [audioSession availableInputs]) {
                NSString *porttype = [desc portType];
                if ([porttype isEqualToString:AVAudioSessionPortBluetoothLE]
                    ||[porttype isEqualToString:AVAudioSessionPortCarAudio]
                    ||[porttype isEqualToString:AVAudioSessionPortBluetoothHFP]
                    ||[porttype isEqualToString:AVAudioSessionPortBluetoothA2DP]
                    ) {
                    [audioSession setPreferredInput:desc error:nil];
                    break;
                }
            }
            
            return;
        }
        
        //NSLog(@"<--speaker--> available inputs: %d", [audioSession availableInputs]);
        for (AVAudioSessionPortDescription* desc in [audioSession availableInputs]) {
            NSString *porttype = [desc portType];
            NSString *portname = [desc portName];
            NSArray<AVAudioSessionDataSourceDescription *> *dataSources = desc.dataSources;
            
            
            NSLog(@"<--speaker--> input: %@", porttype);
            
            //        if (!([porttype isEqualToString:AVAudioSessionPortBuiltInSpeaker] || [porttype isEqualToString:AVAudioSessionPortBuiltInReceiver])) {
            //            NSLog(@"!([porttype isEqualToString:AVAudioSessionPortBuiltInSpeaker] || [porttype isEqualToString:AVAudioSessionPortBuiltInReceiver])");
            //            return;
            //        }
            
            AVAudioSessionDataSourceDescription *frontMicrophone;
            AVAudioSessionDataSourceDescription *topMicrophone;
            AVAudioSessionDataSourceDescription *bottomMicrophone;
            
            //NSLog(@"<--speaker--> available input porttype: %@ : %@. DataSources: %d", porttype, portname, dataSources.count);
            //NSLog(@"<--speaker--> selectedDataSource:%@. location=%@; orientation=%@; selectedPolarPattern: %@", frontMicrophone.dataSourceName, frontMicrophone.location, frontMicrophone.orientation, frontMicrophone.selectedPolarPattern);
            
            
            for(AVAudioSessionDataSourceDescription* source in dataSources) {
                NSLog(@"<--speaker--> dataSource: %@", source);
                if ([source.orientation isEqualToString:AVAudioSessionOrientationFront]) {
                    frontMicrophone = source;
                }
                else if ([source.orientation isEqualToString:AVAudioSessionOrientationTop]) {
                    topMicrophone = source;
                }
                else if ([source.orientation isEqualToString:AVAudioSessionOrientationBottom]) {
                    bottomMicrophone = source;
                }
            }
            
            BOOL ok;
            
            if (speaker) {
                //Если нашли передний микрофон, используем его (на 6 и выше?), иначе верхний (на 4s и на 5-х?)
                if (frontMicrophone) {
                    NSLog(@"<--speaker--> front microphone");
                    
                    ok = [audioSession setPreferredInput:desc error:&error];
                    if ((error != nil) || (!ok)) {
                        NSLog(@"<--speaker--> error: %@", error);
                    }
                    
                    ok = [desc setPreferredDataSource:frontMicrophone error:&error];
                    if ((error != nil) || (!ok)) {
                        NSLog(@"<--speaker--> error: %@", error);
                    }
                    
                    ok = [frontMicrophone setPreferredPolarPattern:AVAudioSessionPolarPatternOmnidirectional error:&error];
                    if ((error != nil) || (!ok)) {
                        NSLog(@"<--speaker--> error: %@", error);
                    }
                    
                }
                else if (topMicrophone) {
                    NSLog(@"<--speaker--> top microphone");
                    
                    ok = [audioSession setPreferredInput:desc error:&error];
                    if ((error != nil) || (!ok)) {
                        NSLog(@"<--speaker--> error: %@", error);
                    }
                    
                    ok = [desc setPreferredDataSource:topMicrophone error:&error];
                    if ((error != nil) || (!ok)) {
                        NSLog(@"<--speaker--> error: %@", error);
                    }
                    
                    ok = [topMicrophone setPreferredPolarPattern:AVAudioSessionPolarPatternOmnidirectional error:&error];
                    if ((error != nil) || (!ok)) {
                        NSLog(@"<--speaker--> error: %@", error);
                    }
                }
                ok = [audioSession setInputGain:1.0 error:&error];
                
                if ((error != nil) || (!ok)) {
                    NSLog(@"<--speaker--> error: %@", error);
                }
            }
            else {
                //переключаемся на нижний микрофон
                if (bottomMicrophone) {
                    NSLog(@"<--speaker--> bottom microphone");
                    
                    ok = [audioSession setPreferredInput:desc error:&error];
                    if ((error != nil) || (!ok)) {
                        NSLog(@"<--speaker--> error: %@", error);
                    }
                    
                    ok = [desc setPreferredDataSource:bottomMicrophone error:&error];
                    if ((error != nil) || (!ok)) {
                        NSLog(@"<--speaker--> error: %@", error);
                    }
                    
                    
                    ok = [bottomMicrophone setPreferredPolarPattern:AVAudioSessionPolarPatternOmnidirectional error:&error];
                    if ((error != nil) || (!ok)) {
                        NSLog(@"<--speaker--> error: %@", error);
                    }
                }
            }
        }
        
        /*
         NSLog(@"<--speaker--> audioSession.category:%@", audioSession.category);
         NSLog(@"<--speaker--> audioSession.mode:%@", audioSession.mode);
         NSLog(@"<--speaker--> audioSession.inputGain:%f", audioSession.inputGain);
         NSLog(@"<--speaker--> audioSession.categoryOptions:%d", audioSession.categoryOptions);
         */
    });
}

#warning deprecated
-(void)toggleSpeaker:(void(^)(NSError *error))handler {
    NSError *error = nil;
    if (!_speaker) {
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayAndRecord error:&error];
        [[AVAudioSession sharedInstance] overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&error];
        _speaker = YES;
    }
    
    else {
        [[AVAudioSession sharedInstance] overrideOutputAudioPort:AVAudioSessionPortOverrideNone error:&error];
        _speaker = NO;
    }
    handler(error);
}

-(void)sendDTMF:(NSString *)dtmf handler:(void(^)(NSError *error))handler {
    
    pj_status_t status;
    NSError *error;
    pj_str_t digits = [dtmf pjString];
    
    
    status = pjsua_call_dial_dtmf((int)self.callId, &digits);
    
    if (status != PJ_SUCCESS) {
        error = [NSError errorWithDomain:@"Error sending DTMF" code:0 userInfo:nil];
    }
    
    if (handler) {
        handler(error);
    }
}

#pragma Application Methods

-(void)returnToBackground:(NSNotificationCenter *)notification {
    
    if (self.callState == SWCallStateIncoming) {
        [self createLocalNotification];
    }
}

+ (BOOL)isOnlySpeakerOutput {
    AVAudioSessionRouteDescription* route = [[AVAudioSession sharedInstance] currentRoute];
    for (AVAudioSessionPortDescription* desc in [route outputs]) {
        NSString *porttype = [desc portType];
        if (!([porttype isEqualToString:AVAudioSessionPortBuiltInSpeaker] || [porttype isEqualToString:AVAudioSessionPortBuiltInReceiver]))
            return NO;
    }
    return YES;
}

+ (BOOL)isOnlyBuiltinInput {
    AVAudioSessionRouteDescription* route = [[AVAudioSession sharedInstance] currentRoute];
    for (AVAudioSessionPortDescription* desc in [route outputs]) {
        NSString *porttype = [desc portType];
        if (![porttype isEqualToString:AVAudioSessionPortBuiltInMic])
            return NO;
    }
    return YES;
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    if (self.callState == SWCallStateDisconnectRingtone) {
        [self hangup:^(NSError *error) {}];
    }
}

- (NSTimeInterval)spendTime {
    //Либо время разговора уже сохранено
    if (_spendTime > 0) {
        return _spendTime;
    }
    
    //...либо разговор еще не начался
    if (_dateStartSpeaking == nil) {
        return 0;
    }
    
    //...либо посчитаем по дате начала разговора
    return [[NSDate date] timeIntervalSinceDate:self.dateStartSpeaking];
}

-(BOOL)callkitAreHandlingAudioSession {
    return _callkitAreHandlingAudioSession;
}

-(void)setCallkitAreHandlingAudioSession:(BOOL)callkitAreHandlingAudioSession {
    _callkitAreHandlingAudioSession = callkitAreHandlingAudioSession;
    
    if ((callkitAreHandlingAudioSession != nil) && (self.answerHandler != nil)) {
        [self answer:self.answerHandler];
    }
}

@end
