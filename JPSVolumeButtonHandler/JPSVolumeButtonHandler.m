//
//  JPSVolumeButtonHandler.m
//  JPSImagePickerController
//
//  Created by JP Simard on 1/31/2014.
//  Copyright (c) 2014 JP Simard. All rights reserved.
//

#import "JPSVolumeButtonHandler.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>

static NSString *const sessionVolumeKeyPath = @"outputVolume";
static void *sessionContext                 = &sessionContext;
static CGFloat maxVolume                    = 0.99999f;
static CGFloat minVolume                    = 0.00001f;

@interface JPSVolumeButtonHandler ()

@property (nonatomic, assign) CGFloat          initialVolume;
@property (nonatomic, strong) AVAudioSession * session;
@property (nonatomic, strong) MPVolumeView   * volumeView;
@property (nonatomic, assign) BOOL             appIsActive;
@property (nonatomic, assign) BOOL             isStarted;
@property (nonatomic, assign) BOOL             disableSystemVolumeHandler;
@property (nonatomic, assign) BOOL             isAdjustingInitialVolume;

@end

@implementation JPSVolumeButtonHandler

#pragma mark - Init

- (id)init {
    self = [super init];
    if (self) {
        _appIsActive = YES;
        _volumeView = [[MPVolumeView alloc] initWithFrame:CGRectMake(1, 1, 100, 100)];
		[_volumeView sizeToFit];
        [[UIApplication sharedApplication].windows.firstObject addSubview:_volumeView];
        _volumeView.hidden = YES;
    }
    return self;
}

- (void)dealloc {
    if (_isStarted) {
        [self stopHandler];
        [self.volumeView removeFromSuperview];
    }
}

- (void)startHandler:(BOOL)disableSystemVolumeHandler {
    self.isStarted = YES;
    self.volumeView.hidden = NO; // Start visible to prevent changes made during setup from showing default volume
    self.disableSystemVolumeHandler = disableSystemVolumeHandler;

    // There is a delay between setting the volume view before the system actually disables the HUD
    [self performSelector:@selector(setupSession) withObject:nil afterDelay:1];
}

- (void)stopHandler {
    self.isStarted = NO;
    self.volumeView.hidden = YES;
    // https://github.com/jpsim/JPSVolumeButtonHandler/issues/11
    // http://nshipster.com/key-value-observing/#safe-unsubscribe-with-@try-/-@catch
    @try {
        [self.session removeObserver:self forKeyPath:sessionVolumeKeyPath];
    }
    @catch (NSException * __unused exception) {
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setupSession {
    if (!self.isStarted) {
        // Has since been stopped, do not actually do the setup.
        return;
    }

    NSError *error = nil;
    self.session = [AVAudioSession sharedInstance];
    // this must be done before calling setCategory or else the initial volume is reset
    [self setInitialVolume];
    [self.session setCategory:AVAudioSessionCategoryPlayAndRecord withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&error];
    if (error) {
        NSLog(@"%@", error);
        return;
    }
    [self.session setActive:YES error:&error];
    if (error) {
        NSLog(@"%@", error);
        return;
    }

    // Observe outputVolume
    [self.session addObserver:self
                   forKeyPath:sessionVolumeKeyPath
                      options:(NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew)
                      context:sessionContext];

    // Audio session is interrupted when you send the app to the background,
    // and needs to be set to active again when it goes to app goes back to the foreground
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(audioSessionInterrupted:)
                                                 name:AVAudioSessionInterruptionNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidChangeActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidChangeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];

    self.volumeView.hidden = !self.disableSystemVolumeHandler;
}

- (void)audioSessionInterrupted:(NSNotification*)notification {
    NSDictionary *interuptionDict = notification.userInfo;
    NSInteger interuptionType = [[interuptionDict valueForKey:AVAudioSessionInterruptionTypeKey] integerValue];
    switch (interuptionType) {
        case AVAudioSessionInterruptionTypeBegan:
            // NSLog(@"Audio Session Interruption case started.");
            break;
        case AVAudioSessionInterruptionTypeEnded:
        {
            // NSLog(@"Audio Session Interruption case ended.");
            NSError *error = nil;
            [self.session setActive:YES error:&error];
            if (error) {
                NSLog(@"%@", error);
            }
            break;
        }
        default:
            // NSLog(@"Audio Session Interruption Notification case default.");
            break;
    }
}

- (void)setInitialVolume {
    self.initialVolume = self.session.outputVolume;
    if (self.initialVolume > maxVolume) {
        self.initialVolume = maxVolume;
        self.isAdjustingInitialVolume = YES;
        [self setSystemVolume:self.initialVolume];
    } else if (self.initialVolume < minVolume) {
        self.initialVolume = minVolume;
        self.isAdjustingInitialVolume = YES;
        [self setSystemVolume:self.initialVolume];
    }
}

- (void)applicationDidChangeActive:(NSNotification *)notification {
    self.appIsActive = [notification.name isEqualToString:UIApplicationDidBecomeActiveNotification];
    if (self.appIsActive && self.isStarted) {
        [self setInitialVolume];
    }
}

#pragma mark - Convenience

+ (instancetype)volumeButtonHandlerWithUpBlock:(JPSVolumeButtonBlock)upBlock downBlock:(JPSVolumeButtonBlock)downBlock {
    JPSVolumeButtonHandler *instance = [[JPSVolumeButtonHandler alloc] init];
    if (instance) {
        instance.upBlock = upBlock;
        instance.downBlock = downBlock;
    }
    return instance;
}

#pragma mark - KVO

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context == sessionContext) {
        if (!self.appIsActive) {
            // Probably control center, skip blocks
            return;
        }
        
        CGFloat newVolume = [change[NSKeyValueChangeNewKey] floatValue];
        CGFloat oldVolume = [change[NSKeyValueChangeOldKey] floatValue];

        if (self.disableSystemVolumeHandler && newVolume == self.initialVolume) {
            // Resetting volume, skip blocks
            return;
        } else if (self.isAdjustingInitialVolume) {
            if (newVolume == maxVolume || newVolume == minVolume) {
                // Sometimes when setting initial volume during setup the callback is triggered incorrectly
                return;
            }
            self.isAdjustingInitialVolume = NO;
        }
        
        if (newVolume > oldVolume) {
            if (self.upBlock) self.upBlock();
        } else {
            if (self.downBlock) self.downBlock();
        }

        if (!self.disableSystemVolumeHandler) {
            // Don't reset volume if default handling is enabled
            return;
        }

        // Reset volume
        [self setSystemVolume:self.initialVolume];
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

#pragma mark - System Volume

- (void)setSystemVolume:(CGFloat)volume {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [[MPMusicPlayerController applicationMusicPlayer] setVolume:(float)volume];
#pragma clang diagnostic pop
}

@end
