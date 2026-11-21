#ifndef CNN_IN_MATH_H
#define CNN_IN_MATH_H
#include <stdint.h>
/* Exact integer helpers: no FPU/libm or non-RV32I ISA requirement. */
static uint32_t cnn_in_isqrt64(uint64_t value) {
    uint64_t result=0,bit=(uint64_t)1<<62;
    while(bit>value) bit>>=2;
    while(bit) { if(value>=result+bit) { value-=result+bit; result=(result>>1)+bit; } else result>>=1; bit>>=2; }
    return (uint32_t)result;
}
static uint32_t cnn_in_last_root;
typedef struct { int32_t bias;uint32_t multiplier,shift; } cnn_in_coef;
/* gamma_q8 = positive gamma/output_scale in Q8.8, beta_q8 likewise;
 * eps_q16 is variance regularization in shifted accumulator units, Q16.
 * Normalized output = (acc+bias)*multiplier / 2^shift, then original clip.
 * Return 0 on overflow; never silently install an invalid coefficient.
 */
static int cnn_in_coefficient(int64_t s1,uint64_t s2,uint32_t n,uint32_t gamma_q8,int32_t beta_q8,uint32_t eps_q16,cnn_in_coef *out) {
    int64_t mean_q8;uint64_t moment,var,root,den,m;int64_t bias;uint32_t shift;
    if(!n || !gamma_q8 || gamma_q8>32767 || beta_q8<-32768 || beta_q8>32767 || s2>((uint64_t)-1>>16)) return 0;
    mean_q8=s1*256/(int64_t)n;moment=(s2<<16)/n;
    var=moment>(uint64_t)(mean_q8*mean_q8)?moment-(uint64_t)(mean_q8*mean_q8):0;
    if(eps_q16<65536) eps_q16=65536; /* at least one shifted accumulator unit */
    root=cnn_in_isqrt64(var+eps_q16);if(!root) return 0;den=root<<8;
    shift=32;m=((uint64_t)gamma_q8<<shift)/den;
    while(m<0x40000000u && shift<47) { shift++;m=((uint64_t)gamma_q8<<shift)/den; }
    if(!m || m>0x7fffffffu) return 0;
    bias=((int64_t)beta_q8*(int64_t)root)/(int64_t)gamma_q8-mean_q8;
    /* STAT_SHIFT=8 cancels Q8 mean/beta fraction: pre-bias in raw acc units. */
    if(bias<-524288 || bias>524287) return 0;
    cnn_in_last_root=(uint32_t)root;
    out->bias=(int32_t)bias;out->multiplier=(uint32_t)m;out->shift=shift;return 1;
}
#endif
