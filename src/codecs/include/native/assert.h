#ifndef GAIN_ASSERT_H
#define GAIN_ASSERT_H
#ifdef NDEBUG
#define assert(x) ((void)0)
#else
#define assert(x) ((x)?(void)0:abort())
#endif
#endif
