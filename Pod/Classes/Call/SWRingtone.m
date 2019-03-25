//
//  SWRingtone.m
//
//
//  Created by Pierre-Marc Airoldi on 2014-09-04.
//
//

#import "SWRingtone.h"
#import "SWCall.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
//#import "SharkfoodMuteSwitchDetector.h"
#import <UIKit/UIKit.h>
#import <libextobjc/extobjc.h>
#import "Logger.h"


#define kVibrateDuration 2.0

@interface SWRingtone ()

@property (nonatomic, strong) AVAudioPlayer *audioPlayer;
@property (nonatomic, weak) id<AVAudioPlayerDelegate> playerDelegate;
@property (nonatomic, strong) NSTimer *virbateTimer;

@end

@implementation SWRingtone

-(instancetype)init {
    
    NSURL *fileURL = [[NSURL alloc] initFileURLWithPath:[[NSBundle mainBundle] pathForResource:@"Ringtone" ofType:@"caf"]];
    
    return [self initWithFileAtPath:fileURL];
}

-(instancetype)initWithFileAtPath:(NSURL *)path {
    
    self = [super init];
    
    if (!self) {
        return nil;
    }
    
    _fileURL = path;
    
    NSError *error;
    
    _audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:_fileURL error:&error];
    _audioPlayer.numberOfLoops = -1;
    
    if (error) {
        
    }
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector: @selector(handleEnteredBackground:) name: UIApplicationDidEnterBackgroundNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector: @selector(handleEnteredForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];

    self.volume = 1;
    
//    @weakify(self);
//    [SharkfoodMuteSwitchDetector shared].silentNotify = ^(BOOL silent){
//        
//        @strongify(self);
//        
//        if (silent) {
//            
//            self.volume = 0.0;
//        }
//        
//        else {
//            
//            self.volume = 1.0;
//        }
//    };
    
    return self;
}

-(void)dealloc {
    
    [_audioPlayer stop];
    _audioPlayer = nil;
    
    [_virbateTimer invalidate];
    _virbateTimer = nil;
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillEnterForegroundNotification object:nil];
}

-(BOOL)isPlaying {
    return self.audioPlayer.isPlaying;
}

#pragma mark start/stop ringtone anyway

-(void)startRingtone {
    
    if (!self.audioPlayer.isPlaying) {
        
        BOOL prepareToPlay = [self.audioPlayer prepareToPlay];
        self.audioPlayer.delegate = self.playerDelegate;
        
        //[self configureAudioSession];
        
        BOOL play =  [self.audioPlayer play];
        
        NSLog(@"%@ %@", @(prepareToPlay), @(play));
        
        [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:nil];
        
        if(self.noVibrations) {
            return;
        }
        
        self.virbateTimer = [NSTimer timerWithTimeInterval:kVibrateDuration target:self selector:@selector(vibrate) userInfo:nil repeats:YES];
        
        [[NSRunLoop mainRunLoop] addTimer:self.virbateTimer forMode:NSRunLoopCommonModes];
    }
    
}

-(void) stopRingtone {
    
    if (self.audioPlayer.isPlaying) {
        [self.audioPlayer stop];
        
    }
    
    [self.virbateTimer invalidate];
    self.virbateTimer = nil;
    
    [self.audioPlayer setCurrentTime:0];
}

#pragma mark start/stop ringtone if no callKit

-(void)start {
    
    if ([[[UIDevice currentDevice] systemVersion] floatValue] < 10.0) {
        [self startRingtone];
    }
}

-(void)stop {
#warning experiment
    [self stopRingtone];
    /*
    if ([[[UIDevice currentDevice] systemVersion] floatValue] < 10.0) {
        [self stopRingtone];
    }
     */
}

-(void)setVolume:(float)volume {
    
    [self willChangeValueForKey:@"volume"];
    
    if (volume < 0.0) {
        _volume = 0.0;
    }
    
    else if (volume > 0.0) {
        _volume = 1.0;
    }
    
    else {
        _volume = volume;
    }
    
    [self didChangeValueForKey:@"volume"];
 
    self.audioPlayer.volume = _volume;
}

-(void)vibrate {
    
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
}

-(void)configureAudioSession {
    
#warning experiment
    return;
    //[SWCall closeSoundTrack:^(NSError *error) {}];
    
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    
    NSError *error = nil;
    //[audioSession setCategory:AVAudioSessionCategoryPlayAndRecord error:&error];
    
    NSError *setCategoryError;
    
    NSLog(@"<--AudioSession notification--> set category on ringtone");
    if (![audioSession setCategory:AVAudioSessionCategoryPlayAndRecord withOptions:(AVAudioSessionCategoryOptionDuckOthers|AVAudioSessionCategoryOptionAllowBluetooth|AVAudioSessionCategoryOptionAllowBluetoothA2DP|AVAudioSessionCategoryOptionDefaultToSpeaker) error:&setCategoryError]) {
        
    }
    
    
    NSError *setModeError;
    
    if (![audioSession setMode:AVAudioSessionModeDefault error:&setModeError]) {
        
    }
    
    NSError *overrideError;
    
    /*
    if ([audioSession overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&overrideError]) {
        
    }
    */
     
    NSError *activationError;
    
    [audioSession setActive:NO error:&activationError];
    if (![audioSession setActive:YES error:&activationError]) {
        
    }
    
    //[SWCall openSoundTrack:^(NSError *error) {}];

}

#pragma Notification Methods

-(void)handleEnteredBackground:(NSNotification *)notification {
    
    self.volume = 0.0;
    
}

-(void)handleEnteredForeground:(NSNotification *)notification {
    self.volume = 1.0;
//    if ([SharkfoodMuteSwitchDetector shared].isMute) {
//        self.volume = 0.0;
//    }
//    
//    else {
//        self.volume = 1.0;
//    }
}

- (void) setAudioPlayerDelegate: (id<AVAudioPlayerDelegate>) delegate {
    _playerDelegate = delegate;
    if(self.audioPlayer.isPlaying) {
        self.audioPlayer.delegate = delegate;
    }
}

- (void)setIsFinite:(BOOL)isFinite {
    _audioPlayer.numberOfLoops = isFinite ? 0 : -1;
}

- (BOOL)isFinite {
    return _audioPlayer.numberOfLoops >= 0;
}

@end
