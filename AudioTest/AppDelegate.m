//
//  AppDelegate.m
//  AudioTest
//
//  Created by Michael Tyson on 19/09/2013.
//  Copyright (c) 2013 A Tasty Pixel. All rights reserved.
//

#import "AppDelegate.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

#define checkResult(result,operation) (_checkResult((result),(operation),strrchr(__FILE__, '/')+1,__LINE__))
static inline BOOL _checkResult(OSStatus result, const char *operation, const char* file, int line) {
    if ( result != noErr ) {
        NSLog(@"%s:%d: %s result %d %08X %4.4s\n", file, line, operation, (int)result, (int)result, (char*)&result);
        return NO;
    }
    return YES;
}

static AudioStreamBasicDescription kNonInterleavedFloatingPoint = {
    .mFormatID          = kAudioFormatLinearPCM,
    .mFormatFlags       = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
    .mChannelsPerFrame  = 2,
    .mBytesPerPacket    = sizeof(float),
    .mFramesPerPacket   = 1,
    .mBytesPerFrame     = sizeof(float),
    .mBitsPerChannel    = 8 * sizeof(float),
    .mSampleRate        = 44100.0,
};

@interface AppDelegate () {
    AudioUnit _audioUnit;
}
@property (nonatomic, strong) id observerToken;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [self setupAudioSystem];
    [self startAudioSystem];
    return YES;
}

-(void)dealloc {
    [self teardownAudioSystem];
}

- (void)setupAudioSystem {
    
    NSError *error = nil;
    if ( ![[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayAndRecord
                                           withOptions:AVAudioSessionCategoryOptionMixWithOthers |
                                                       AVAudioSessionCategoryOptionAllowBluetoothA2DP
                                                 error:&error] ) {
        NSLog(@"Couldn't set audio session category: %@", error);
    }
    
    if ( ![[AVAudioSession sharedInstance] setPreferredIOBufferDuration:(128.0/44100.0) error:&error] ) {
        NSLog(@"Couldn't set preferred buffer duration: %@", error);
    }
    
    if ( ![[AVAudioSession sharedInstance] setActive:YES error:&error] ) {
        NSLog(@"Couldn't set audio session active: %@", error);
    }
    
    // Create the audio unit
    AudioComponentDescription desc = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = kAudioUnitSubType_RemoteIO,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentFlags = 0,
        .componentFlagsMask = 0
    };
    
    AudioComponent inputComponent = AudioComponentFindNext(NULL, &desc);
    checkResult(AudioComponentInstanceNew(inputComponent, &_audioUnit), "AudioComponentInstanceNew");
    
    // Enable input
    UInt32 enableFlag = 1;
    checkResult(AudioUnitSetProperty(_audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableFlag, sizeof(enableFlag)),
                "kAudioOutputUnitProperty_EnableIO");
    
    // Set the stream formats
    checkResult(AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &kNonInterleavedFloatingPoint, sizeof(kNonInterleavedFloatingPoint)),
                "kAudioUnitProperty_StreamFormat");
    checkResult(AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &kNonInterleavedFloatingPoint, sizeof(kNonInterleavedFloatingPoint)),
                "kAudioUnitProperty_StreamFormat");
    
    // Set the render callback
    AURenderCallbackStruct rcbs = { .inputProc = audioUnitRenderCallback, .inputProcRefCon = (__bridge void *)(self) };
    checkResult(AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, 0, &rcbs, sizeof(rcbs)),
                "kAudioUnitProperty_SetRenderCallback");
    
    UInt32 framesPerSlice = 4096;
    checkResult(AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &framesPerSlice, sizeof(framesPerSlice)),
                "AudioUnitSetProperty(kAudioUnitProperty_MaximumFramesPerSlice");
    
    // Initialize the audio unit
    checkResult(AudioUnitInitialize(_audioUnit), "AudioUnitInitialize");
    
    // Watch for session interruptions
    self.observerToken =
    [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:nil usingBlock:^(NSNotification *notification) {
        NSInteger type = [notification.userInfo[AVAudioSessionInterruptionTypeKey] integerValue];
        if ( type == AVAudioSessionInterruptionTypeBegan ) {
            [self stopAudioSystem];
        } else {
            if ( ![self startAudioSystem] ) {
                // Work around an iOS 7 audio interruption bug
                [self teardownAudioSystem];
                [self setupAudioSystem];
                [self startAudioSystem];
            }
        }
    }];
}

- (void)teardownAudioSystem {
    if ( _audioUnit ) {
        checkResult(AudioComponentInstanceDispose(_audioUnit), "AudioComponentInstanceDispose");
        _audioUnit = NULL;
    }
    
    if ( _observerToken ) {
        [[NSNotificationCenter defaultCenter] removeObserver:_observerToken];
        self.observerToken = nil;
    }
}

- (BOOL)stopAudioSystem {
    checkResult(AudioOutputUnitStop(_audioUnit), "AudioOutputUnitStop");
    [[AVAudioSession sharedInstance] setActive:NO error:NULL];
    return YES;
}

- (BOOL)startAudioSystem {
    NSError *error = nil;
    if ( ![[AVAudioSession sharedInstance] setActive:YES error:&error] ) {
        NSLog(@"Couldn't activate audio session: %@", error);
        return NO;
    }
    
    if ( !checkResult(AudioOutputUnitStart(_audioUnit), "AudioOutputUnitStart") ) {
        return NO;
    }
    
    return YES;
}

static OSStatus audioUnitRenderCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    
    __unsafe_unretained AppDelegate *THIS = (__bridge AppDelegate*)inRefCon;
    
    // Draw from the system audio input
    checkResult(AudioUnitRender(THIS->_audioUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, ioData), "AudioUnitRender");
    
    return noErr;
}

@end
