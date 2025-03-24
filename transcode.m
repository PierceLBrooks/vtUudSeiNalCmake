
// Author: Pierce Brooks

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>

#include "transcode.h"
#include "h264bitstream/h264_avcc.h"

#include <stdint.h>
#include <stdlib.h>
#include <stdbool.h>

#include <os/log.h>

typedef struct _TranscoderPrivate {
    VTCompressionSessionRef encoder;
    VTDecompressionSessionRef decoder;
    CMVideoFormatDescriptionRef decoderFormatDescription;
    bool needsConvertedFromAnnexBToNALU;
    uint8_t *annexBConverterBuffer;
    size_t annexBConverterBufferLength;
} TranscoderPrivate;

typedef TranscoderPrivate *TranscoderPrivateRef;

static unsigned int FindNextAnnexBStart(uint8_t *data, size_t size, unsigned int currentStart, int *startCodeLen);
static bool AnnexB2AvcC(uint8_t *annexBData, size_t annexBSize, uint8_t **avcCData, size_t *avcCSize);
static bool AnnexB2NALU(uint8_t *buffer, size_t length, uint8_t *outBuffer, size_t *outLength);
static void DecoderDidDecode(void *compressionContext, void *sourceContext, OSStatus status, VTDecodeInfoFlags infoFlags, CVImageBufferRef imageBuffer, CMTime presetationTimeStamp, CMTime presentationDuration);
static void EncoderDidEncode(void *outputCallbackRefCon, void *sourceFrameRefCon, OSStatus status, VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer);
static void TranscoderDidTranscode(TranscoderRef self, CMSampleBufferRef sampleBuffer);

static unsigned int FindNextAnnexBStart(uint8_t *data, size_t size, unsigned int currentStart, int *startCodeLen)
{
    unsigned int nextStart = currentStart;
    int scLen = 0;
    while (nextStart < size - 4) {
        if ((data[nextStart] == 0x00) && (data[nextStart + 1] == 0x00) && (data[nextStart + 2] == 0x00) && (data[nextStart + 3] == 0x01)) {
            scLen = 4;
            *startCodeLen = scLen;
            return nextStart;
        }
        else if ((data[nextStart] == 0x00) && (data[nextStart + 1] == 0x00) && (data[nextStart + 2] == 0x01)) {
            scLen = 3;
            *startCodeLen = scLen;
            return nextStart;
        }
        nextStart++;
    }
    *startCodeLen = scLen;
    return (unsigned int)size;
}

static bool AnnexB2AvcC(uint8_t *annexBData, size_t annexBSize, uint8_t **avcCData, size_t *avcCSize)
{
    unsigned int firstStart;
    unsigned int nextStart;
    
    uint8_t *sps = NULL;
    size_t spsSize = 0;
    
    uint8_t *pps = NULL;
    size_t ppsSize = 0;
    
    uint8_t *start;
    size_t size;
    
    unsigned int type;
    
    uint8_t *data;
    size_t dataSize;
    
    if (annexBData == NULL || annexBSize < 4) {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "(annexBData == NULL || annexBSize < 4)");
        return false;
    }
    
	if ((annexBData[0] != 0x00 && annexBData[1] != 0x00 && annexBData[2] != 0x00 && annexBData[3] != 0x01) && (annexBData[0] != 0x00 && annexBData[1] != 0x00 && annexBData[2] != 0x01)) {
        data = (uint8_t *)malloc(sizeof(uint8_t) * annexBSize);
        memcpy(data, annexBData, annexBSize);
        dataSize = annexBSize;
        
        *avcCData = data;
        *avcCSize = dataSize;
        return true;
    }
    
    int firstStartCodeLength = 0;
    int nextStartCodeLength = 0;
    
    firstStart = FindNextAnnexBStart(annexBData, annexBSize, 0, &firstStartCodeLength);
    
    if (firstStart == annexBSize) {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "(firstStart == annexBSize)");
        return false;
    }
    
    nextStart = firstStart + firstStartCodeLength;
    while (nextStart < annexBSize) {
        nextStart = FindNextAnnexBStart(annexBData, annexBSize, nextStart, &nextStartCodeLength);
        
        start = annexBData + firstStart + firstStartCodeLength;
        size = (nextStart - firstStart) - firstStartCodeLength;
        
        type = start[0] & 0x1F;
        
        if (type == 7) {
            sps = start;
            spsSize = size;
        } else if (type == 8) {
            pps = start;
            ppsSize = size;
        } else {
            //abort();
        }
        
        firstStart = nextStart;
        nextStart += firstStartCodeLength;
        firstStartCodeLength = nextStartCodeLength;
    }
    
    if (spsSize == 0 || ppsSize == 0) {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "(spsSize == 0 || ppsSize == 0)");
        *avcCSize = 0;
        *avcCData = NULL;
        return false;
    }
    
    dataSize = 5 + 1 + 2 + spsSize + 1 + 2 + ppsSize;
    data = (uint8_t *)malloc(sizeof(uint8_t) * dataSize);
    
    data[0] = 1;
    data[1] = sps[1];
    data[2] = sps[2];
    data[3] = sps[3];
    data[4] = 0xFF;
    data[5] = 0xE1;
    data[6] = spsSize >> 8;
    data[7] = spsSize & 0xFF;
    memcpy(data + 8, sps, spsSize);
    data[8 + spsSize] = 1;
    data[9 + spsSize] = ppsSize >> 8;
    data[10 + spsSize] = ppsSize & 0xFF;
    memcpy(data + 11 + spsSize, pps, ppsSize);
    
    *avcCData = data;
    *avcCSize = dataSize;

    return true;
}

static bool AnnexB2NALU(uint8_t *buffer, size_t length, uint8_t *outBuffer, size_t *outLength)
{
    unsigned int firstStart = 0;
    unsigned int nextStart = 0;
    
    uint8_t *start = NULL;
    size_t size = 0;
    
    if (buffer == NULL || length < 4) {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "(buffer == NULL || length < 4)");
        return false;
    }
    
    int firstStartCodeLength = 0;
    int nextStartCodeLength = 0;
    
    firstStart = FindNextAnnexBStart(buffer, length, 0, &firstStartCodeLength);
    
    if (firstStart == length) {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "(firstStart == length)");
        return false;
    }
    
    int position = 0;
    
    if (outBuffer != NULL) {
        nextStart = firstStart + firstStartCodeLength;
        while (nextStart < length) {
            nextStart = FindNextAnnexBStart(buffer, length, nextStart, &nextStartCodeLength);
            start = buffer + firstStart + firstStartCodeLength;
            size = (nextStart - firstStart) - firstStartCodeLength;
            
            (outBuffer + position)[0] = size >> 24;
            (outBuffer + position)[1] = size >> 16;
            (outBuffer + position)[2] = size >> 8;
            (outBuffer + position)[3] = size;
            
            position += 4;
            
            memcpy(outBuffer + position, start, size);
            
            position += size;
            
            firstStart = nextStart;
            nextStart += firstStartCodeLength;
            firstStartCodeLength = nextStartCodeLength;
        }
    }
    
    if (outLength != NULL) {
        *outLength = position;
    }
    
    return true;
}

static void DecoderDidDecode(void *compressionContext, void *sourceContext, OSStatus status, VTDecodeInfoFlags infoFlags, CVImageBufferRef imageBuffer, CMTime presentationTimeStamp, CMTime presentationDuration)
{
    //os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "DecoderDidDecode");
    TranscoderRef self = (TranscoderRef)compressionContext;
    TranscoderPrivateRef privates = (TranscoderPrivateRef)self->privates;
    
    if (status == noErr && imageBuffer != NULL) {
        CFMutableDictionaryRef properties = NULL;

#if 0
        properties = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(properties, kVTEncodeFrameOptionKey_ForceKeyFrame, kCFBooleanTrue);
#endif
        
        VTEncodeInfoFlags infoFlags;
        
        if (@available(macOS 10.11, *)) {
            status = VTCompressionSessionEncodeFrameWithOutputHandler(privates->encoder, imageBuffer, presentationTimeStamp, presentationDuration, properties, &infoFlags, ^(OSStatus status, VTEncodeInfoFlags infoFlags, CMSampleBufferRef  _Nullable sampleBuffer) {
                if (status == noErr && sampleBuffer != NULL) {
                    TranscoderDidTranscode(self, sampleBuffer);
                }
            });
        } else {
            status = VTCompressionSessionEncodeFrame(privates->encoder, imageBuffer, presentationTimeStamp, presentationDuration, properties, self, &infoFlags);
        }
        
        if (@available(macOS 10.10, *)) {
            //VTCompressionSessionEndPass(privates->encoder, NULL, NULL);
        }
        
        if (properties != NULL) {
            CFRelease(properties);
        }
        
        if ((infoFlags & kVTEncodeInfo_Asynchronous) == kVTEncodeInfo_Asynchronous) {
            VTCompressionSessionCompleteFrames(privates->encoder, kCMTimeInvalid);
        }
    } else {
        abort();
    }
}

static void EncoderDidEncode(void *outputCallbackRefCon, void *sourceFrameRefCon, OSStatus status, VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer)
{
    //os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "EncoderDidEncode");
    TranscoderRef self = (TranscoderRef)outputCallbackRefCon;
    
    if (status == noErr && sampleBuffer != NULL) {
        TranscoderDidTranscode(self, sampleBuffer);
    }
}

static void TranscoderDidTranscode(TranscoderRef self, CMSampleBufferRef sampleBuffer)
{
    //os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "TranscoderDidTranscode");
    CMTime pts = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer);
    CMTime dts = CMSampleBufferGetOutputDecodeTimeStamp(sampleBuffer);
    
    if (self->extraData == NULL) {
        CMFormatDescriptionRef description = CMSampleBufferGetFormatDescription(sampleBuffer);
        NSDictionary *atoms = CMFormatDescriptionGetExtension(description, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
        
        if (atoms != NULL) {
            if (atoms[@"avcC"] != nil) {
                NSData *data = atoms[@"avcC"];
                
                self->extraData = (uint8_t *)malloc(sizeof(uint8_t) * data.length);
                memcpy(self->extraData, data.bytes, data.length);
                
                self->extraDataSize = data.length;
            }
        }
    }
    
    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    
    size_t lengthAtOffset = 0;
    size_t totalLength = 0;
    char *data = NULL;
    
    OSStatus result = CMBlockBufferGetDataPointer(blockBuffer, 0, &lengthAtOffset, &totalLength, &data);
    if (result == kCMBlockBufferNoErr && self->callback != NULL) {
        self->callback(self, self->extraData, self->extraDataSize, (uint8_t *)data, lengthAtOffset,/* pts.value, dts.value,*/ self->callbackContext);
    }
}

TranscoderRef TranscoderCreate(uint8_t *extraData, size_t extraDataSize, TranscoderCallback callback, void *callbackContext)
{
    TranscoderRef self = NULL;
    TranscoderPrivateRef privates = NULL;
    if (@available(macOS 10.8, iOS 8.0, *)) {
        self = (TranscoderRef)malloc(sizeof(Transcoder));
    } else {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "(@available(macOS 10.8, iOS 8.0, *))");
        return self;
    }

    if (extraData == NULL || extraDataSize == 0) {
        return self;
    }
    privates = (TranscoderPrivateRef)malloc(sizeof(TranscoderPrivate));
    memset(self, '\0', sizeof(Transcoder));
    memset(privates, '\0', sizeof(TranscoderPrivate));
    self->callback = callback;
    self->callbackContext = callbackContext;
    self->privates = (void *)privates;
    self->fps = 30;
    self->outputWidth = 1920;
    self->outputHeight = 1080;
    if ((extraDataSize >= 3 && extraData[0] == 0x00 && extraData[1] == 0x00 && extraData[2] == 0x01) || (extraDataSize >= 4 && extraData[0] == 0x00 && extraData[1] == 0x00 && extraData[2] == 0x00 && extraData[3] == 0x01)) {
        uint8_t * avcCDataBuffer = NULL;
        size_t avcCDataBufferLen = 0;
        AnnexB2AvcC(extraData, extraDataSize, (uint8_t **)&avcCDataBuffer, &avcCDataBufferLen);
        if (avcCDataBuffer != NULL && avcCDataBufferLen > 0) {
            if (!AnnexB2NALU(extraData, extraDataSize, NULL, NULL)) {
                os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "(!AnnexB2NALU(self->avcC, self->avcCLength, NULL, NULL))");
                return NULL;
            }
            self->avcCLength = avcCDataBufferLen;
            self->avcC = (uint8_t*)malloc(sizeof(uint8_t) * avcCDataBufferLen);
            memcpy(self->avcC, avcCDataBuffer, avcCDataBufferLen);
            free(avcCDataBuffer);
            privates->needsConvertedFromAnnexBToNALU = true;
        } else {
            os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "(avcCDataBuffer != NULL && avcCDataBufferLen > 0)");
            return NULL;
        }
    } else {
#if 0
        size_t sz = extraDataSize;
        avcc_t* a = avcc_new();
        bs_t* b = bs_new(extraData, extraDataSize);
        h264_stream_t* h = h264_new();
        uint8_t *p = extraData;
        int nal_start, nal_end;
        read_avcc(a, h, b);
        debug_avcc(a);
        //privates->needsConvertedFromAnnexBToNALU = true;
#endif
    }
    if (self->avcC == NULL || self->avcCLength == 0) {
        self->avcCLength = extraDataSize;
        self->avcC = (uint8_t*)malloc(sizeof(uint8_t) * extraDataSize);
        memcpy(self->avcC, extraData, extraDataSize);
    } else {
#if 0
        size_t sz = self->avcCLength;
        avcc_t* a = avcc_new();
        bs_t* b = bs_new(self->avcC, self->avcCLength);
        h264_stream_t* h = h264_new();
        uint8_t *p = self->avcC;
        int nal_start, nal_end;
        read_avcc(a, h, b);
        debug_avcc(a);
#endif
    }

    NSData *nsData = [NSData dataWithBytes:self->avcC length:self->avcCLength];
    NSDictionary *extraInfo = @{
                                (id)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms : @{ @"avcC" : nsData }
                                };

    CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_H264, self->outputWidth, self->outputHeight, (__bridge CFDictionaryRef)(extraInfo), &privates->decoderFormatDescription);

    NSDictionary *pixelBufferDescription = @{
#if 0
                                            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                                            (id)kCVPixelBufferMetalCompatibilityKey: @(YES),
#else
#if ((!defined(ARCH_ARM)) || (!defined(BITNESS_64)))
                                            (id)kCVPixelBufferPixelFormatTypeKey     : @(kCVPixelFormatType_420YpCbCr8Planar),
#endif
                                            (id)kCVPixelBufferOpenGLCompatibilityKey: @(YES),
#endif
#if ((defined(ARCH_ARM)) && (defined(BITNESS_64)))
                                            (id)kCVPixelBufferPixelFormatTypeKey     : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
#endif
                                             (id)kCVPixelBufferHeightKey              : @(self->outputHeight),
                                             (id)kCVPixelBufferWidthKey               : @(self->outputWidth),
                                             };

    VTDecompressionOutputCallbackRecord callbackRecord;
    callbackRecord.decompressionOutputCallback = DecoderDidDecode;
    callbackRecord.decompressionOutputRefCon = self;

    OSStatus result = VTDecompressionSessionCreate(kCFAllocatorDefault, privates->decoderFormatDescription, NULL, (__bridge CFDictionaryRef)(pixelBufferDescription), &callbackRecord, &privates->decoder);

    if (result != noErr) {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "(result != noErr)");
        return NULL;
    }

    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    
    if (@available(macOS 10.9, iOS 8.0, *)) {
        CFDictionarySetValue(properties, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
        CFDictionarySetValue(properties, kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder, kCFBooleanTrue);
        //CFDictionarySetValue(properties, kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder, kCFBooleanTrue);
    }
    
    int value = 550 * 1000;
    
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
    CFDictionarySetValue(properties, kVTCompressionPropertyKey_AverageBitRate, number);
    CFRelease(number);
    
    //CFDictionarySetValue(properties, kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder, kCFBooleanFalse);
    
    OSStatus status = noErr;
    
    if (@available(macOS 10.11, *)) {
        status = VTCompressionSessionCreate(kCFAllocatorDefault, self->outputWidth, self->outputHeight, kCMVideoCodecType_H264, properties, NULL, NULL, NULL, NULL, &privates->encoder);
    } else {
        status = VTCompressionSessionCreate(kCFAllocatorDefault, self->outputWidth, self->outputHeight, kCMVideoCodecType_H264, properties, NULL, NULL, EncoderDidEncode, self, &privates->encoder);
    }
    
    CFRelease(properties);
    
    if (status != noErr) {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "(status != noErr)");
        return NULL;
    }
    
    if (@available(macOS 10.9, iOS 8.0, *)) {
        BOOL hardwareAccelerationFailed = NO;
        CFBooleanRef out = NULL;
        
        OSStatus vsRes = VTSessionCopyProperty(privates->encoder, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, CFAllocatorGetDefault(), &out);
        if (vsRes != noErr) {
            hardwareAccelerationFailed = YES;
        }
        else {
            if (!CFBooleanGetValue(out)) {
                hardwareAccelerationFailed = YES;
            }
        }
        
        if (hardwareAccelerationFailed) {
            os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "(hardwareAccelerationFailed)");
            return NULL;
        }
        
        if (out != NULL) {
            CFRelease(out);
        }
    }
    
    /*
    CFDictionaryRef dict = NULL;
    VTSessionCopySupportedPropertyDictionary(privates->encoder, &dict);
    NSLog(@"Hardware encoder supported: %@", (NSDictionary*)dict);
    */
    
    VTSessionSetProperty(privates->encoder, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    
    if (@available(macOS 10.13, *)) {
        VTSessionSetProperty(privates->encoder, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel);
    }
    else {
        VTSessionSetProperty(privates->encoder, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_4_2);
    }
    
    value = 3;
    number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
    VTSessionSetProperty(privates->encoder, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, number);
    CFRelease(number);
    
    value = self->fps * 3;
    number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
    VTSessionSetProperty(privates->encoder, kVTCompressionPropertyKey_MaxKeyFrameInterval, number);
    CFRelease(number);
    
    value = 0;
    number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
    VTSessionSetProperty(privates->encoder, kVTCompressionPropertyKey_MaxFrameDelayCount, number);
    CFRelease(number);
    
    value = self->fps;
    number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
    VTSessionSetProperty(privates->encoder, kVTCompressionPropertyKey_ExpectedFrameRate, number);
    CFRelease(number);
    
    double doubleValue = 0.5;
    number = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &doubleValue);
    VTSessionSetProperty(privates->encoder, kVTCompressionPropertyKey_Quality, number);
    CFRelease(number);
    
    value = 550 * 1000;
    number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
    VTSessionSetProperty(privates->encoder, kVTCompressionPropertyKey_AverageBitRate, number);
    CFRelease(number);
    
    if (@available(macOS 10.9, iOS 8.0, *)) {
        VTSessionSetProperty(privates->encoder, kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CAVLC);
        VTSessionSetProperty(privates->encoder, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
        
        VTCompressionSessionPrepareToEncodeFrames(privates->encoder);
    }
    
    return self;
}

void TranscoderDestroy(TranscoderRef self) {
    if (self == NULL) {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "(self == NULL)");
        return;
    }
    TranscoderPrivateRef privates = (TranscoderPrivateRef)self->privates;
    if (privates->encoder != NULL) {
        VTCompressionSessionCompleteFrames(privates->encoder, kCMTimeInvalid);
        VTCompressionSessionInvalidate(privates->encoder);
        CFRelease(privates->encoder);
        privates->encoder = NULL;
    }
    if (privates->decoder != NULL) {
        VTDecompressionSessionWaitForAsynchronousFrames(privates->decoder);
        VTDecompressionSessionInvalidate(privates->decoder);
        CFRelease(privates->decoder);
        privates->decoder = NULL;
    }
    if (privates->decoderFormatDescription != NULL) {
        CFRelease(privates->decoderFormatDescription);
        privates->decoderFormatDescription = NULL;
    }
    if (privates->annexBConverterBuffer != NULL) {
        free(privates->annexBConverterBuffer);
        privates->annexBConverterBuffer = NULL;
        privates->annexBConverterBufferLength = 0;
    }
    free(privates);
    free(self);
}

bool TranscoderTranscode(TranscoderRef self, uint8_t *inputBuffer, size_t inputLength)
{
    if (self == NULL) {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "(self == NULL)");
        return false;
    }
    
    TranscoderPrivateRef privates = (TranscoderPrivateRef)self->privates;
    if (privates->decoder == NULL) {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "(privates->decoder == NULL)");
        return false;
    }
    if (inputBuffer == NULL || inputLength == 0) {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "(inputBuffer == NULL || inputLength == 0)");
        if (VTDecompressionSessionFinishDelayedFrames(privates->decoder) != noErr) {
            os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "(VTDecompressionSessionFinishDelayedFrames(privates->decoder) != noErr)");
        }
        if (VTCompressionSessionCompleteFrames(privates->encoder, kCMTimeInvalid) != noErr) {
            os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "(VTCompressionSessionCompleteFrames(privates->encoder) != noErr)");
        }
        return false;
    }
    
    if (privates->needsConvertedFromAnnexBToNALU) {
        if (privates->annexBConverterBuffer == NULL || privates->annexBConverterBufferLength < inputLength + 40) {
            if (privates->annexBConverterBuffer != NULL) {
                free(privates->annexBConverterBuffer);
                privates->annexBConverterBuffer = NULL;
                privates->annexBConverterBufferLength = 0;
            }
            
            privates->annexBConverterBuffer = (uint8_t*)malloc(sizeof(uint8_t) * (inputLength + 40));
            privates->annexBConverterBufferLength = inputLength + 40;
        }

        size_t tempBuffLen = 0;
        if (AnnexB2NALU(inputBuffer, inputLength, privates->annexBConverterBuffer, &tempBuffLen)) {
            inputBuffer = privates->annexBConverterBuffer;
            inputLength = tempBuffLen;
        } else {
            os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "(AnnexB2NALU(inputBuffer, inputLength, privates->annexBConverterBuffer, &tempBuffLen))");
            return false;
        }
    }
    
    CMBlockBufferRef blockBuffer = NULL;
    OSStatus result = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, inputLength, kCFAllocatorDefault, NULL, 0, inputLength, kCMBlockBufferAssureMemoryNowFlag, &blockBuffer);

    if (result != kCMBlockBufferNoErr) {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "(result != kCMBlockBufferNoErr)");
        return false;
    }

    result = CMBlockBufferReplaceDataBytes(inputBuffer, blockBuffer, 0, inputLength);
    if (result != noErr) {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "(result != noErr)");
        CFRelease(blockBuffer);
        return false;
    }

    CMSampleTimingInfo timing;
    memset(&timing, 0 ,sizeof(CMSampleTimingInfo));
    
    uint64_t duration = 1000 / self->fps;
    uint64_t dts = time(NULL) * 1000;
    uint64_t pts = dts;
    timing.duration = CMTimeMake(duration, 1);
    timing.decodeTimeStamp = CMTimeMake(dts, 1);
    timing.presentationTimeStamp = CMTimeMake(pts, 1);

    const size_t sampleSizes = inputLength;
    CMSampleBufferRef sampleBuffer = NULL;
    result = CMSampleBufferCreate(kCFAllocatorDefault, blockBuffer, YES, NULL, NULL, privates->decoderFormatDescription, 1, 1, &timing, 1, &sampleSizes, &sampleBuffer);

    if (result != noErr) {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "(result != noErr)");
        CFRelease(blockBuffer);
        return false;
    }

    //VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression | kVTDecodeFrame_EnableTemporalProcessing;
    VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression;
    VTDecodeInfoFlags flagsOut = 0;

    result = VTDecompressionSessionDecodeFrame(privates->decoder, sampleBuffer, flags, NULL, &flagsOut);

    CFRelease(sampleBuffer);
    CFRelease(blockBuffer);

    if (result != noErr) {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "(result != noErr)");
        return false;
    }
    if ((flagsOut & kVTDecodeInfo_FrameDropped) != 0) {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "((flagsOut & kVTDecodeInfo_FrameDropped) != 0)");
        return false;
    }
    
    return true;
}

