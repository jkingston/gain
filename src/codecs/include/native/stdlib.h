#ifdef __cplusplus
extern "C" {
#endif
#ifndef GAIN_CODEC_STDLIB_H
#define GAIN_CODEC_STDLIB_H
#include <stddef.h>
void *malloc(size_t);
void *calloc(size_t, size_t);
void *realloc(void *, size_t);
void free(void *);
int abs(int);
long labs(long);
void abort(void) __attribute__((noreturn));
#endif
void qsort(void*,size_t,size_t,int(*)(const void*,const void*));
void exit(int) __attribute__((noreturn));

#ifdef __cplusplus
}
#endif
