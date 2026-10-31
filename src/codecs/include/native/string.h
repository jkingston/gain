#ifdef __cplusplus
extern "C" {
#endif
#ifndef GAIN_SPIKE_STRING_H
#define GAIN_SPIKE_STRING_H
#include <stddef.h>
void *memcpy(void *, const void *, size_t);
void *memmove(void *, const void *, size_t);
void *memset(void *, int, size_t);
#endif
int memcmp(const void*,const void*,size_t);
size_t strlen(const char*);
char *strcpy(char*,const char*);
char *strcat(char*,const char*);
void *memchr(const void*,int,size_t);

#ifdef __cplusplus
}
#endif
