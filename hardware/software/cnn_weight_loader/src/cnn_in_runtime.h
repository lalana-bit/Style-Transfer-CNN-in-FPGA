/* 三组完整帧IN统计，共用软核系数计算；0串行对照，1三组并行。 */
#ifndef CNN_IN_RUNTIME_H
#define CNN_IN_RUNTIME_H
#include "cnn_in_math.h"
#include "cnn_in_params.h"
static uint32_t cnn_in_next_layer,cnn_in_affine_checked;
static uint8_t cnn_in_next[3],cnn_in_waiting,cnn_in_cursor,cnn_in_mode_active;
static uint32_t crc32_update(uint32_t crc,const uint8_t *data,uint32_t count);
volatile uint32_t cnn_in_runtime_error,cnn_in_updates,cnn_in_capture_errors;
volatile uint32_t cnn_in_freeze_request,cnn_in_frozen;
volatile uint32_t cnn_in_parallel=1;
/* [0]写请求帧:采样帧；[1]CPU处理微秒:快照排队微秒；
 * [2]最小标准差整数:最大倍率Q16；[3]采样间隔帧:更新计数。 */
volatile uint32_t cnn_in_profile[15][4];
static void cnn_in_reset(void) {
    cnn_in_freeze_request=0;cnn_in_frozen=0;
    cnn_in_waiting=0;cnn_in_next_layer=0;cnn_in_cursor=0;
    cnn_in_next[0]=0;cnn_in_next[1]=5;cnn_in_next[2]=10;
    cnn_in_mode_active=cnn_in_parallel!=0;
    cnn_in_affine_checked=0;cnn_in_updates=0;cnn_in_capture_errors=0;
    for(uint32_t i=0;i<15;i++)for(uint32_t j=0;j<4;j++)cnn_in_profile[i][j]=0;
    if(CNN_IN_RUNTIME_ENABLED)cnn_in_runtime_error=0;
}
static uint32_t cnn_in_validate_affine(uint32_t style) {
    uint32_t offset,crc=0xffffffffu;
    if(style>=STYLE_COUNT)return 0u;
    for(offset=0;offset<CNN_IN_AFFINE_BYTES;offset+=CHUNK_BYTES) {
        uint32_t count=CNN_IN_AFFINE_BYTES-offset;
        if(count>CHUNK_BYTES)count=CHUNK_BYTES;
        if(!cnn_read_affine(style,offset,count))return 0u;
        crc=crc32_update(crc,chunk,count);
    }
    return (crc^0xffffffffu)==style_affine_crc[style];
}
static uint32_t cnn_in_limit16(uint32_t value) {return value>65535u?65535u:value;}
static __attribute__((noinline,noclone)) void cnn_in_service(void) {
    uint32_t mask,g,layer,bit,channels,n,start,finished,captured,queue_time;
    uint32_t min_std=65535u,max_gain=0u;cnn_in_coef values[32];
    if(!CNN_IN_RUNTIME_ENABLED || cnn_control_busy || cnn_runtime_fault || cnn_active_style>=STYLE_COUNT)return;
    if(!cnn_in_affine_checked) {
        cnn_in_affine_checked=1;
        if(!cnn_in_validate_affine(cnn_active_style)){cnn_in_runtime_error=1;return;}
    }
    if(cnn_in_runtime_error)return;
    /* 模式变化先排空已ARM任务，避免丢弃完整快照或打断视频。 */
    if(cnn_in_mode_active!=(cnn_in_parallel!=0) && !cnn_in_waiting) {
        cnn_in_mode_active=cnn_in_parallel!=0;cnn_in_next_layer=0;
        cnn_in_next[0]=0;cnn_in_next[1]=5;cnn_in_next[2]=10;cnn_in_cursor=0;
    }
    if(cnn_in_freeze_request && !cnn_in_waiting){cnn_in_frozen=1;return;}
    cnn_in_frozen=0;mask=reg_read(0x150u);
    if(!cnn_in_freeze_request && cnn_in_mode_active==(cnn_in_parallel!=0)) {
        if(cnn_in_mode_active) {
            for(g=0;g<3;g++)if(!(cnn_in_waiting&(1u<<g))) {
                reg_write(0x13cu,g);reg_write(0x100u,1u|((uint32_t)cnn_in_next[g]<<8));cnn_in_waiting|=1u<<g;
            }
        } else if(!cnn_in_waiting) {
            g=cnn_in_next_layer<5u?0u:(cnn_in_next_layer<10u?1u:2u);cnn_in_next[g]=cnn_in_next_layer;
            reg_write(0x13cu,g);reg_write(0x100u,1u|(cnn_in_next_layer<<8));cnn_in_waiting=1u<<g;
        }
    }
    for(uint32_t i=0;i<3;i++) {
        g=cnn_in_cursor+i;if(g>=3u)g-=3u;bit=1u<<g;
        if((cnn_in_waiting&bit) && (mask&((bit<<8)|(bit<<16))))goto selected;
    }
    return;
selected:
    reg_write(0x13cu,g);layer=cnn_in_next[g];
    if(mask&(bit<<16)) {
        if(reg_read(0x104u)&4u)return;
        reg_write(0x100u,4u);cnn_in_waiting&=~bit;cnn_in_capture_errors++;return;
    }
    captured=reg_read(0x140u);start=reg_read(0x14cu);
    queue_time=(start-reg_read(0x148u))&0xffffffu;
    channels=reg_read(0x138u);n=reg_read(0x11cu);
    if(!channels || channels>32 || !n){cnn_in_runtime_error=2;return;}
    {
        uint32_t prefix=0;
        for(uint32_t i=0;i<layer;i++)prefix+=(i==0 || i==14)?8u:((i==1 || i==13)?16u:32u);
        if(!cnn_read_affine(cnn_active_style,prefix*8u,channels*8u)){cnn_in_runtime_error=3;return;}
    }
    for(uint32_t ch=0;ch<channels;ch++) {
        int64_t s1;uint64_t s2;uint32_t lo,hi;
        reg_write(0x108u,ch);lo=reg_read(0x10cu);hi=reg_read(0x110u);
        s1=((int64_t)(int32_t)hi*4294967296LL)+(uint64_t)lo;
        lo=reg_read(0x114u);hi=reg_read(0x118u);s2=((uint64_t)hi<<32)|lo;
        uint32_t at=ch*8u,gamma=chunk[at]|((uint32_t)chunk[at+1]<<8);
        int32_t beta=(int16_t)(chunk[at+2]|((uint32_t)chunk[at+3]<<8));
        uint32_t eps=chunk[at+4]|((uint32_t)chunk[at+5]<<8)|((uint32_t)chunk[at+6]<<16)|((uint32_t)chunk[at+7]<<24);
        if(!cnn_in_coefficient(s1,s2,n,gamma,beta,eps,&values[ch])){cnn_in_runtime_error=2;return;}
        uint32_t sd=cnn_in_last_root>>8,gain=values[ch].multiplier>>(values[ch].shift-16u);
        if(sd<min_std)min_std=sd;
        if(gain>max_gain)max_gain=gain;
    }
    for(uint32_t ch=0;ch<channels;ch++) {
        reg_write(0x120u,ch);reg_write(0x124u,(uint32_t)values[ch].bias);
        reg_write(0x128u,values[ch].multiplier);reg_write(0x12cu,values[ch].shift);reg_write(0x100u,2u);
    }
    finished=reg_read(0x14cu);
    uint32_t count=(cnn_in_profile[layer][3]+1u)&65535u;
    uint32_t period=(cnn_in_profile[layer][3]&65535u)?((captured-cnn_in_profile[layer][0])&65535u):0u;
    cnn_in_profile[layer][0]=(reg_read(0x144u)<<16)|captured;
    cnn_in_profile[layer][1]=(cnn_in_limit16((finished-start)&0xffffffu)<<16)|cnn_in_limit16(queue_time);
    cnn_in_profile[layer][2]=(cnn_in_limit16(min_std)<<16)|cnn_in_limit16(max_gain);
    cnn_in_profile[layer][3]=(period<<16)|count;
    reg_write(0x100u,3u);cnn_in_waiting&=~bit;
    if(cnn_in_mode_active)cnn_in_next[g]=(layer+1u==g*5u+5u)?g*5u:layer+1u;
    else cnn_in_next_layer=layer==14u?0u:layer+1u;
    cnn_in_cursor=g==2u?0u:g+1u;cnn_in_updates++;
}
#endif
