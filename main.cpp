
// Author: Pierce Brooks

#include <string>
#include <iostream>
#include <stdint.h>
#include <unistd.h>
#include <time.h>
#include <sys/time.h>

#include "transcode.h"
#include "h264bitstream/h264_stream.h"

static bool ConvertDataToAnnexB(uint8_t *bytes, size_t length);
static void ConvertExtraDataToAnnexB(uint8_t *avcCData, size_t avcCSize, uint8_t **annexBData, size_t *annexBSize);
static int WriteOut(const char *path, uint8_t *bytes, size_t length);
static uint8_t *ReadIn(const char *path, size_t *length);
static void TranscoderDidTranscode(TranscoderRef transcoder, uint8_t *extraData, size_t extraDataSize, uint8_t *data, size_t dataSize, void *callbackContext);

int main(int argc, char **argv)
{
    size_t length = 0;
    std::cout << "Hello, world!" << std::endl;
    for (int i = 0; i < argc; i++) {
        std::cout << argv[i] << std::endl;
    }
    if (argc < 2) {
        std::cout << "(argc < 2)" << std::endl;
        return -1;
    }
    uint8_t *in = ReadIn(argv[argc-1], &length);
    //uint8_t *in = ReadIn((std::string(argv[argc-1])+".base").c_str(), &length);
    if (in == NULL || length == 0) {
        std::cout << "(in == NULL || length == 0)" << std::endl;
        return -2;
    }
    //std::cout << length << std::endl;
    TranscoderRef transcoder = NULL;
    transcoder = TranscoderCreate(in, length, (TranscoderCallback)TranscoderDidTranscode, NULL);
    if (transcoder == NULL) {
        std::cout << "(transcoder == NULL)" << std::endl;
        return -3;
    }
    for (int i = 0; i < 100; i++) {
        free(in);
        in = ReadIn((std::string(argv[argc-1])+"_"+std::to_string(i+1)).c_str(), &length);
        //std::cout << length << std::endl;
        if (in == NULL || length == 0) {
            std::cout << "(in[" << i << "] == NULL || length[" << i << "] == 0)" << std::endl;
            return -4;
        }
        if (transcoder == NULL) {
            transcoder = TranscoderCreate(in, length, (TranscoderCallback)TranscoderDidTranscode, NULL);
            if (transcoder == NULL) {
                std::cout << "(transcoder == NULL)" << std::endl;
                return -5;
            }
        }
        if (!TranscoderTranscode(transcoder, in, length)) {
            std::cout << "(!TranscoderTranscode(transcoder, in, length))" << std::endl;
            return -6;
        }
    }
    /*for (int i = 0; i < 10; i++) {
        std::cout << "usleep(1000000)" << std::endl;
        usleep(1000000);
        TranscoderTranscode(transcoder, NULL, 0);
    }*/
    TranscoderDestroy(transcoder);
    free(in);
    return 0;
}

static bool ConvertDataToAnnexB(uint8_t *bytes, size_t length) {
    unsigned int position = 0;
    size_t nalLength;
    size_t remainingLength = length;

    if (length > 4 && bytes[0] == 0x00 && bytes[1] == 0x00 && bytes[2] == 0x00 && bytes[3] == 0x01) {
        return true;
    }

    while (remainingLength > 0) {
        nalLength  = (bytes + position)[0] << 24;
        nalLength += (bytes + position)[1] << 16;
        nalLength += (bytes + position)[2] << 8;
        nalLength += (bytes + position)[3];

        if (nalLength > length) {
            return false;
        }

        (bytes + position)[0] = 0x00;
        (bytes + position)[1] = 0x00;
        (bytes + position)[2] = 0x00;
        (bytes + position)[3] = 0x01;

        position += 4 + nalLength;
        remainingLength -= 4 + nalLength;
    }

    return true;
}

static void ConvertExtraDataToAnnexB(uint8_t *avcCData, size_t avcCSize, uint8_t **annexBData, size_t *annexBSize) {
    if (avcCSize > 4 && avcCData[0] == 0x00 && avcCData[1] == 0x00 && avcCData[2] == 0x00 && avcCData[3] == 0x01) {
        *annexBData = (uint8_t *)malloc(avcCSize);
        memcpy(*annexBData, avcCData, avcCSize);

        *annexBSize = avcCSize;

        return;
    }

    int offset = 6;
    size_t spsLength = avcCData[offset] << 8;
    spsLength += avcCData[offset + 1];
    uint8_t *spsData = avcCData + offset + 2;

    offset = 8 + spsLength + 1;
    size_t ppsLength = avcCData[offset] << 8;
    ppsLength += avcCData[offset + 1];
    uint8_t *ppsData = avcCData + offset + 2;

    size_t length = 4 + spsLength + 4 + ppsLength;
    uint8_t *data = (uint8_t *)malloc(length);

    data[0] = 0x00;
    data[1] = 0x00;
    data[2] = 0x00;
    data[3] = 0x01;

    memcpy(data + 4, spsData, spsLength);

    offset = 4 + spsLength;
    data[offset + 0] = 0x00;
    data[offset + 1] = 0x00;
    data[offset + 2] = 0x00;
    data[offset + 3] = 0x01;

    offset = 4 + spsLength + 4;
    memcpy(data + offset, ppsData, ppsLength);

    *annexBData = data;
    *annexBSize = length;
}


static int WriteOut(const char *path, uint8_t *bytes, size_t length)
{
    int error = 1;
    if (path == NULL || bytes == NULL || length == 0) {
        return 3;
    }
#ifdef OS_WINDOWS
	  FILE *out = NULL;
    fopen_s(&out, path, "wb");
#else
    FILE *out = fopen(path, "wb");
#endif

    if (out != NULL) {
        size_t result = fwrite(bytes, length, 1, out);
        if (result == 0) {
            error = 2;
        } else {
            error = 0;
        }

        fclose(out);
    }
    return error;
}

#ifdef OS_WINDOWS
uint8_t *ReadIn(const char *path, size_t *length)
{
    uint8_t *bytes = NULL;
    if (path == NULL || length == NULL) {
        return bytes;
    }

    struct stat st;
    stat(path, &st);

    FILE *in = NULL;
    errno_t result = fopen_s(&in, path, "rb");

    size_t seek = st.st_size;
    *length = seek;
    if (size > 0 && in != NULL) {
        size_t read = 0;
        size_t chunk = 2048;
        uint8_t *buffer = malloc(sizeof(uint8_t) * chunk);
        bytes = malloc(sizeof(uint8_t) * seek);
        
        while ((read = fread(buffer, 1, chunk, in)) > 0) {
            memcpy(bytes + total, buffer, read);
            total += read;
        }

        free(buffer);
        fclose(in);
    }

    return data;
}
#else
uint8_t *ReadIn(const char *path, size_t *length)
{
    uint8_t *bytes = NULL;
    if (path == NULL || length == NULL) {
        return bytes;
    }

    FILE *in = fopen(path, "rb");
    if (in != NULL) {
        size_t seek;

        fseek(in, 0, SEEK_END);
        seek = ftell(in);
        fseek(in, 0, SEEK_SET);

        bytes = (uint8_t *)malloc(sizeof(uint8_t) * seek);

        if (seek > 0) {
            while (!feof(in)) {
                fread(bytes, seek, 1, in);
            }
        }

        *length = seek;

        fclose(in);
    }
    return bytes;
}
#endif

static void TranscoderDidTranscode(TranscoderRef transcoder, uint8_t *extraData, size_t extraDataSize, uint8_t *data, size_t dataSize, void *callbackContext)
{
    uint8_t *finalData = data;
    size_t finalDataSize = dataSize;
    uint8_t *finalExtraData = extraData;
    size_t finalExtraDataSize = extraDataSize;
    bool success = ConvertDataToAnnexB(data, dataSize);
    if (!success) {
        return;
    }
    if (extraData != NULL) {
        ConvertExtraDataToAnnexB(extraData, extraDataSize, &finalExtraData, &finalExtraDataSize);
    }

    std::cout << finalExtraDataSize << " " << finalDataSize << std::endl;
    size_t sz = finalDataSize;
    h264_stream_t* h = h264_new();
    uint8_t *p = finalData;
    int nal_start, nal_end;
    while (find_nal_unit(p, sz, &nal_start, &nal_end) > 0) {
        p += nal_start;
        read_debug_nal_unit(h, p, nal_end - nal_start);
        p += (nal_end - nal_start);
        sz -= nal_end;
    }

    if (finalData != data) {
        free(finalData);
    }
    if (finalExtraData != extraData) {
        free(finalExtraData);
    }
}

