#ifdef __cplusplus
extern "C" {
#endif
#ifndef GAIN_CODEC_MATH_H
#define GAIN_CODEC_MATH_H
#define M_PI 3.14159265358979323846
float sqrtf(float); double sqrt(double);
float fabsf(float); double fabs(double);
float floorf(float); double floor(double);
float ceilf(float); double ceil(double);
float expf(float); double exp(double);
float logf(float); double log(double);
float log2f(float); double log2(double);
float powf(float,float); double pow(double,double);
float cosf(float); double cos(double);
float sinf(float); double sin(double);
float tanhf(float); double tanh(double);
long lrintf(float); long lrint(double);
double acos(double); double asin(double); double atan(double); double atan2(double,double);
double log10(double); double tan(double); double fmod(double,double);
#endif
double rint(double); double ldexp(double,int); float ldexpf(float,int);

#ifdef __cplusplus
}
#endif
