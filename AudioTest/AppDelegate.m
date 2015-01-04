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
#import <mach/mach_time.h>
#import <libkern/OSAtomic.h>

static double __hostTicksToSeconds = 0.0;
static double __secondsToHostTicks = 0.0;

#define checkResult(result,operation) (_checkResult((result),(operation),strrchr(__FILE__, '/')+1,__LINE__))
static inline BOOL _checkResult(OSStatus result, const char *operation, const char* file, int line) {
    if ( result != noErr ) {
        NSLog(@"%s:%d: %s result %d %08X %4.4s\n", file, line, operation, (int)result, (int)result, (char*)&result);
        return NO;
    }
    return YES;
}

static const int kMaxTimingEntries = 256;

struct timing_entry_t { uint64_t timestamp; uint64_t start; uint64_t end; };

@interface AppDelegate () {
    AudioUnit _audioUnit;
    struct timing_entry_t _timingEntries[kMaxTimingEntries];
    volatile int32_t _timingEntriesHead;
    volatile int32_t _timingEntriesTail;
}
@property (nonatomic, strong) id observerToken;
@end

@implementation AppDelegate

+(void)initialize {
    mach_timebase_info_data_t tinfo;
    mach_timebase_info(&tinfo);
    __hostTicksToSeconds = ((double)tinfo.numer / tinfo.denom) * 1.0e-9;
    __secondsToHostTicks = 1.0 / __hostTicksToSeconds;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [self setupAudioSystem];
    [self startAudioSystem];
    [NSTimer scheduledTimerWithTimeInterval:0.01 target:self selector:@selector(pollTimingEntries) userInfo:nil repeats:YES];
    return YES;
}

-(void)dealloc {
    [self teardownAudioSystem];
}

- (void)setupAudioSystem {
    
    NSError *error = nil;
    if ( ![[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&error] ) {
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
    
    // Set the stream formats
    AudioStreamBasicDescription clientFormat = [AppDelegate nonInterleavedFloatStereoAudioDescription];
    checkResult(AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &clientFormat, sizeof(clientFormat)),
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

+ (AudioStreamBasicDescription)nonInterleavedFloatStereoAudioDescription {
    AudioStreamBasicDescription audioDescription;
    memset(&audioDescription, 0, sizeof(audioDescription));
    audioDescription.mFormatID          = kAudioFormatLinearPCM;
    audioDescription.mFormatFlags       = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
    audioDescription.mChannelsPerFrame  = 2;
    audioDescription.mBytesPerPacket    = sizeof(float);
    audioDescription.mFramesPerPacket   = 1;
    audioDescription.mBytesPerFrame     = sizeof(float);
    audioDescription.mBitsPerChannel    = 8 * sizeof(float);
    audioDescription.mSampleRate        = 44100.0;
    return audioDescription;
}

static OSStatus audioUnitRenderCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    __unsafe_unretained AppDelegate * THIS = (__bridge AppDelegate*)inRefCon;
    
    uint64_t start = mach_absolute_time();
    
    // Quick sin-esque oscillator
    const float oscillatorFrequency = 400.0;
    static float oscillatorPosition = 0.0;
    float oscillatorRate = oscillatorFrequency / 44100.0;
    for ( int i=0; i<inNumberFrames; i++ ) {
        float x = oscillatorPosition;
        x *= x; x -= 1.0; x *= x; x -= 0.5; x *= 0.4;
        oscillatorPosition += oscillatorRate;
        if ( oscillatorPosition > 1.0 ) oscillatorPosition -= 2.0;
        ((float*)ioData->mBuffers[0].mData)[i] = x;
        ((float*)ioData->mBuffers[1].mData)[i] = x;
    }
    
    uint64_t end = mach_absolute_time();
    
    int32_t head = THIS->_timingEntriesHead;
    int32_t tail = THIS->_timingEntriesTail;
    if ( (head+1)%kMaxTimingEntries == tail ) {
        NSLog(@"Timing buffer full");
    } else {
        THIS->_timingEntries[head] = (struct timing_entry_t){ .timestamp = inTimeStamp->mHostTime, .start = start, .end = end };
        OSAtomicCompareAndSwap32Barrier(head, (head+1) % kMaxTimingEntries, &THIS->_timingEntriesHead);
    }
    
    return noErr;
}

- (void)pollTimingEntries {
    for ( int i=_timingEntriesTail; i != _timingEntriesHead; i = (i+1)%kMaxTimingEntries ) {
        NSLog(@"%lf: render start %lf, end %lf, duration %lf ms",
              _timingEntries[i].timestamp * __hostTicksToSeconds,
              _timingEntries[i].start * __hostTicksToSeconds,
              _timingEntries[i].end * __hostTicksToSeconds,
              (_timingEntries[i].end - _timingEntries[i].start) * __hostTicksToSeconds * 1000.0);
        OSAtomicCompareAndSwap32Barrier(i, (i+1)%kMaxTimingEntries, &_timingEntriesTail);
    }
}

@end
