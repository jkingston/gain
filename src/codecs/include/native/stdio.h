#ifndef GAIN_CODEC_STDIO_H
#define GAIN_CODEC_STDIO_H
#include <stddef.h>
typedef struct FILE FILE;
extern FILE *stderr;
int fprintf(FILE *, const char *, ...);
#endif
