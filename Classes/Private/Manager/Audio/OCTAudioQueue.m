//
//  OCTAudioUnitWrapper.m
//  DesktopNao
//
//  Created by stal on 15/12/2015.
//  Copyright © 2015 Zodiac Labs. All rights reserved.
//

#import "OCTToxAV.h"
#import "OCTAudioQueue.h"
#import "TPCircularBuffer.h"

@import AVFoundation;
@import AudioToolbox;

const int kBufferLength = 384000;
const int kNumberOfInputChannels = 2;
const int kDefaultSampleRate = 48000;
const int kSampleCount = 1920;
const int kBitsPerByte = 8;
const int kFramesPerPacket = 1;
// if you make this too small, the output queue will silently not play,
// but you will still get fill callbacks; it's really weird
const int kFramesPerOutputBuffer = kSampleCount / 4;
const int kBytesPerSample = sizeof(SInt16);
const int kNumberOfAudioQueueBuffers = 8;

#if ! TARGET_OS_IPHONE
static NSString *_OCTGetSystemAudioDevice(AudioObjectPropertySelector sel)
{
    AudioDeviceID devID = 0;
    OSStatus ok = 0;
    UInt32 size = sizeof(AudioDeviceID);
    AudioObjectPropertyAddress address = {
        .mSelector = sel,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMaster
    };

    ok = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &devID);
    if (ok != kAudioHardwareNoError) {
        NSLog(@"failed AudioObjectGetPropertyData for system object: %d! Crash may or may not be imminent", ok);
        return nil;
    }

    address.mSelector = kAudioDevicePropertyDeviceUID;
    CFStringRef unique = NULL;
    size = sizeof(unique);
    ok = AudioObjectGetPropertyData(devID, &address, 0, NULL, &size, &unique);
    if (ok != kAudioHardwareNoError) {
        NSLog(@"failed AudioObjectGetPropertyData for selected device: %d! Crash may or may not be imminent", ok);
        return nil;
    }

    return (__bridge NSString *)unique;
}
#endif

@interface OCTAudioQueue ()

// use this to track what nil means in terms of audio device
@property BOOL isOutput;
@property AudioStreamBasicDescription streamFmt;
@property AudioQueueRef audioQueue;
@property (nonatomic) TPCircularBuffer buffer;
@property BOOL running;

@end

@implementation OCTAudioQueue {
    AudioQueueBufferRef _AQBuffers[kNumberOfAudioQueueBuffers];
}

- (instancetype)initWithInputDeviceID:(NSString *)devID
{
#if TARGET_OS_IPHONE
    AVAudioSession *session = [AVAudioSession sharedInstance];
    _streamFmt.mSampleRate = session.sampleRate;
#else
    _streamFmt.mSampleRate = kDefaultSampleRate;
#endif
    _streamFmt.mFormatID = kAudioFormatLinearPCM;
    _streamFmt.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger;
    _streamFmt.mChannelsPerFrame = kNumberOfInputChannels;
    _streamFmt.mBytesPerFrame = kBytesPerSample * kNumberOfInputChannels;
    _streamFmt.mBitsPerChannel = kBitsPerByte * kBytesPerSample;
    _streamFmt.mFramesPerPacket = kFramesPerPacket;
    _streamFmt.mBytesPerPacket = kBytesPerSample * kNumberOfInputChannels * kFramesPerPacket;
    _isOutput = NO;
    _deviceID = devID;

    TPCircularBufferInit(&_buffer, kBufferLength);
    if ([self createAudioQueue] != 0) {
        return nil;
    }

    return self;
}

- (instancetype)initWithOutputDeviceID:(NSString *)devID
{
    _streamFmt.mSampleRate = kDefaultSampleRate;
    _streamFmt.mFormatID = kAudioFormatLinearPCM;
    _streamFmt.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    _streamFmt.mChannelsPerFrame = kNumberOfInputChannels;
    _streamFmt.mBytesPerFrame = kBytesPerSample * kNumberOfInputChannels;
    _streamFmt.mBitsPerChannel = kBitsPerByte * kBytesPerSample;
    _streamFmt.mFramesPerPacket = kFramesPerPacket;
    _streamFmt.mBytesPerPacket = kBytesPerSample * kNumberOfInputChannels * kFramesPerPacket;
    _isOutput = YES;
    _deviceID = devID;

    TPCircularBufferInit(&_buffer, kBufferLength);
    if ([self createAudioQueue] != 0) {
        return nil;
    }

    return self;
}

- (void)dealloc
{
    if (self.audioQueue) {
        AudioQueueDispose(self.audioQueue, true);
    }
    TPCircularBufferCleanup(&_buffer);
}

- (OSStatus)createAudioQueue
{
    OSStatus err;
    if (self.isOutput) {
        err = AudioQueueNewOutput(&_streamFmt, (void *)&FillOutputBuffer, (__bridge void *)self, NULL, kCFRunLoopCommonModes, 0, &_audioQueue);
    }
    else {
        err = AudioQueueNewInput(&_streamFmt, (void *)&InputAvailable, (__bridge void *)self, NULL, kCFRunLoopCommonModes, 0, &_audioQueue);
    }

    if (err != 0) {
        return err;
    }

    if (_deviceID) {
        AudioQueueSetProperty(self.audioQueue, kAudioQueueProperty_CurrentDevice, &_deviceID, sizeof(CFStringRef));
    }

    return err;
}

- (void)begin
{
    NSLog(@"OCTAudioQueue begin");

    int framesPerBuffer = 1;
    if (self.isOutput) {
        framesPerBuffer = kFramesPerOutputBuffer;
    }

    for (int i = 0; i < kNumberOfAudioQueueBuffers; ++i) {
        AudioQueueAllocateBuffer(self.audioQueue, kBytesPerSample * kNumberOfInputChannels * framesPerBuffer, &(_AQBuffers[i]));
        AudioQueueEnqueueBuffer(self.audioQueue, _AQBuffers[i], 0, NULL);
        if (self.isOutput) {
            // For some reason we have to fill it with zero or the callback never gets called.
            FillOutputBuffer(self, self.audioQueue, _AQBuffers[i]);
        }
    }

    NSLog(@"Allocated buffers; starting now!");
    AudioQueueStart(self.audioQueue, NULL);
    self.running = YES;
}

- (void)stop
{
    NSLog(@"OCTAudioQueue stop");
    AudioQueueStop(self.audioQueue, true);

    for (int i = 0; i < kNumberOfAudioQueueBuffers; ++i) {
        AudioQueueFreeBuffer(self.audioQueue, _AQBuffers[i]);
    }

    NSLog(@"Freed buffers");
    self.running = NO;
}

- (TPCircularBuffer *)getBufferPointer
{
    return &_buffer;
}

- (void)setDeviceID:(NSString *)deviceID
{
#if ! TARGET_OS_IPHONE
    if (deviceID == nil) {
        NSLog(@"using the default device because nil passed to OCTAudioQueue setDeviceID:");
        deviceID = _OCTGetSystemAudioDevice(self.isOutput ?
                                            kAudioHardwarePropertyDefaultOutputDevice :
                                            kAudioHardwarePropertyDefaultInputDevice);
    }

    // we need to pause the queue for a sec
    [self stop];
    OSStatus ok = AudioQueueSetProperty(self.audioQueue, kAudioQueueProperty_CurrentDevice, &deviceID, sizeof(CFStringRef));

    if (ok != 0) {
        NSLog(@"OCTAudioQueue setDeviceID: Error while live setting device to '%@': %d", deviceID, ok);
    }
    else {
        _deviceID = deviceID;
        NSLog(@"Successfully set the device id to %@", deviceID);
    }

    [self begin];
#endif
}

- (void)updateSampleRate:(Float64)sampleRate numberOfChannels:(UInt32)numberOfChannels
{
    NSLog(@"updateSampleRate %lf, %u", sampleRate, numberOfChannels);

    [self stop];
    AudioQueueRef aq = self.audioQueue;
    self.audioQueue = nil;
    AudioQueueDispose(aq, true);

    _streamFmt.mSampleRate = sampleRate;
    _streamFmt.mChannelsPerFrame = numberOfChannels;
    _streamFmt.mBytesPerFrame = kBytesPerSample * numberOfChannels;
    _streamFmt.mBitsPerChannel = kBitsPerByte * kBytesPerSample;
    _streamFmt.mFramesPerPacket = kFramesPerPacket;
    _streamFmt.mBytesPerPacket = kBytesPerSample * numberOfChannels * kFramesPerPacket;

    OSStatus err = [self createAudioQueue];
    if (err != 0) {
        NSLog(@"oops, could not recreate the audio queue: %d after samplerate/nc change. enjoy your overflowing buffer", err);
    }
    else {
        [self begin];
    }
}

// avoid annoying bridge cast in 1st param!
static void InputAvailable(OCTAudioQueue *__unsafe_unretained context,
                           AudioQueueRef inAQ,
                           AudioQueueBufferRef inBuffer,
                           const AudioTimeStamp *inStartTime,
                           UInt32 inNumPackets,
                           const AudioStreamPacketDescription *inPacketDesc)
{
    TPCircularBufferProduceBytes(&(context->_buffer),
                                 inBuffer->mAudioData,
                                 inBuffer->mAudioDataByteSize);

    int32_t availableBytesToConsume;
    void *tail = TPCircularBufferTail(&context->_buffer, &availableBytesToConsume);
    int32_t minimalBytesToConsume = kSampleCount * kNumberOfInputChannels * sizeof(SInt16);
    int32_t cyclesToConsume = availableBytesToConsume / minimalBytesToConsume;

    for (int32_t i = 0; i < cyclesToConsume; i++) {
        context.sendDataBlock(tail, kSampleCount, kDefaultSampleRate, kNumberOfInputChannels);
        TPCircularBufferConsume(&context->_buffer, minimalBytesToConsume);
        tail = TPCircularBufferTail(&context->_buffer, &availableBytesToConsume);
    }

    AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
}

static void FillOutputBuffer(OCTAudioQueue *__unsafe_unretained context,
                             AudioQueueRef inAQ,
                             AudioQueueBufferRef inBuffer)
{
    int32_t targetBufferSize = inBuffer->mAudioDataBytesCapacity;
    SInt16 *targetBuffer = inBuffer->mAudioData;

    int32_t availableBytes;
    SInt16 *buffer = TPCircularBufferTail(&context->_buffer, &availableBytes);
    // NSLog(@"%d %d %d", availableBytes, targetBufferSize, availableBytes < targetBufferSize);

    if (buffer) {
        uint32_t cpy = MIN(availableBytes, targetBufferSize);
        memcpy(targetBuffer, buffer, cpy);
        TPCircularBufferConsume(&context->_buffer, cpy);

        if (cpy != targetBufferSize) {
            memset(targetBuffer + cpy, 0, targetBufferSize - cpy);
            NSLog(@"warning not enough frames!!!");
        }
        inBuffer->mAudioDataByteSize = targetBufferSize;
    }
    else {
        memset(targetBuffer, 0, targetBufferSize);
        inBuffer->mAudioDataByteSize = targetBufferSize;
    }

    AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
}

@end
