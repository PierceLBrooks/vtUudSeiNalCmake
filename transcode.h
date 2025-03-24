
// Author: Pierce Brooks

#ifndef TRANSCODE_H
#define TRANSCODE_H

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

#ifdef __cplusplus
extern "C" {
#endif

struct _Transcoder;

typedef void (* TranscoderCallback)(struct _Transcoder *self, uint8_t *extraData, size_t extraDataSize, uint8_t *data, size_t dataSize, void *callbackContext);

typedef struct _Transcoder {
    TranscoderCallback callback;
    void *callbackContext;
    void *privates;
    uint8_t *avcC;
    size_t avcCLength;
    uint8_t *extraData;
    size_t extraDataSize;
    int outputWidth;
    int outputHeight;
    int fps;
} Transcoder;

typedef Transcoder *TranscoderRef;

TranscoderRef TranscoderCreate(uint8_t *extraData, size_t extraDataSize, TranscoderCallback callback, void *callbackContext);
void TranscoderDestroy(TranscoderRef self);
bool TranscoderTranscode(TranscoderRef self, uint8_t *inputBuffer, size_t inputLength);

#ifdef __cplusplus
}
#endif

#endif

