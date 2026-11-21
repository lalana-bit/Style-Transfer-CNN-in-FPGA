"""Codec16 raw DDR scan image. No board/Flash operations."""
from pathlib import Path
import struct,json,hashlib,zlib,math,re

def multiplier_shift(ratio):
    mantissa,exponent=math.frexp(float(ratio));m=round(mantissa*(1<<31))
    if m==1<<31:m//=2;exponent+=1
    shift=31-exponent
    if not 0<m<2**31 or not 1<=shift<=62:raise ValueError('Unsupported quantization ratio')
    return m,shift

def rne(v,m,s):
    q,r=divmod(abs(v)*m,1<<s);q+=(r>(1<<(s-1))) or (r==(1<<(s-1)) and q&1)
    return -q if v<0 else q

def residual_table(m,index):
    prefix=f'body.{index}.';pairs={k:m['residual_conversions'][prefix+k] for k in ['shortcut_to_add','branch_to_add','add_to_output']}
    limit=m['relu6_limits'][prefix+'add_quant'];lut=bytearray(1024)
    def convert(key,v):
        p=pairs[key];return rne(v,p['multiplier'],p['shift'])
    for v in range(128):lut[v]=max(-127,min(127,convert('shortcut_to_add',v)))&255
    for bits in range(256):lut[256+bits]=max(-127,min(127,convert('branch_to_add',bits if bits<128 else bits-256)))&255
    for bits in range(512):lut[512+bits]=max(0,min(127,convert('add_to_output',max(0,min(limit,bits if bits<256 else bits-512)))))
    return bytes(lut)

def pack(directory,output):
    directory=Path(directory);output=Path(output);m=json.loads((directory/'quantization_manifest.json').read_text())
    if m['architecture']!='stem8_enc16_32_stdres1_sep4_stddec16_8_3_v1':raise ValueError('Wrong architecture')
    expected=[('stem.conv',[8,3,3,3],1,1),('enc1.conv',[16,8,3,3],1,2),('enc2.conv',[32,16,3,3],1,2)]
    expected.extend([('body.0.conv1.conv',[32,32,3,3],1,1),('body.0.conv2.conv',[32,32,3,3],1,1)])
    for i in range(1,5):expected.extend([(f'body.{i}.dw.conv',[32,1,3,3],32,1),(f'body.{i}.pw.conv',[32,32,1,1],1,1)])
    expected.extend([('decode_pw.conv',[16,32,1,1],1,1),('decode1.conv',[8,16,3,3],1,1),('out',[3,8,3,3],1,1)])
    if len(m['layers'])!=len(expected):raise ValueError('Expected exactly 16 convolutions')
    for row,(name,shape,groups,stride) in zip(m['layers'],expected):
        if (row['name']!=name or row['weight_shape']!=shape or row.get('groups',1)!=groups or
            row['stride']!=[stride,stride] or row['padding']!=[shape[2]//2,shape[3]//2] or row.get('upsample_before',1)!=(2 if name in ['decode1.conv','out'] else 1) or
            row.get('padding_mode','replicate')!='replicate' or row['weight_bytes']!=math.prod(shape) or
            row['bias_bytes']!=shape[0]*4 or row['requant_bytes']!=shape[0]*8):
            raise ValueError(f'{name}: incompatible convolution contract')
    w=(directory/'weights_int8.bin').read_bytes();b=(directory/'bias_int32.bin').read_bytes();rq=(directory/'requant_int32.bin').read_bytes()
    ctl=(directory/'activation_control_int32.bin').read_bytes();image=bytearray();segments=[];numeric=[]
    def append(name,width,data):
        assert len(image)%4==0
        segments.append(dict(index=len(segments),name=name,width=width,units=len(data)//(width//8),offset=len(image),bytes=len(data)))
        image.extend(data);image.extend(bytes((-len(image))%4))
    for i,row in enumerate(m['layers']):
        co,ci,kh,kw=row['weight_shape'];weight=w[row['weight_offset']:row['weight_offset']+row['weight_bytes']]
        bounds=[];shifts=[];params=bytearray()
        for c in range(co):
            bias=struct.unpack_from('<i',b,row['bias_offset']+c*4)[0];mult,shift=struct.unpack_from('<ii',rq,row['requant_offset']+c*8)
            values=struct.unpack_from(f'{ci*kh*kw}b',weight,c*ci*kh*kw)
            low=127*sum(min(v,0) for v in values);high=127*sum(max(v,0) for v in values)
            bounds.extend([low,high,low+bias,high+bias]);shifts.append(shift)
            if not -2**19<=bias<2**19:raise ValueError(f'{row["name"]}: bias exceeds signed INT20')
            if not 0<mult<2**31:raise ValueError('Multiplier must fit positive INT31')
            params.extend(struct.pack('<iii',bias,mult,shift))
        bits=next((n for n in range(17,25) if min(bounds)>=-2**(n-1) and max(bounds)<2**(n-1)),None)
        if bits is None:raise ValueError('Accumulator exceeds INT24')
        if min(shifts)<32 or max(shifts)>47:raise ValueError(f'{row["name"]}: Codec16 shift must be 32..47; adjust QAT scales')
        numeric.append(dict(acc_bits=bits,shift_base=min(shifts),shift_span=max(shifts)-min(shifts),signed_output=bool(i in [4,6,8,10,12])))
        append(row['name']+'.weights',8,weight);append(row['name']+'.bias_multiplier_shift',32,params)
        qi=m['activation_control_order'].index(row['output_quantizer']);control=ctl[qi*16:qi*16+12]
        qmin,qmax,relu=struct.unpack('<iii',control)
        if qmin!=(-127 if i in [4,6,8,10,12] else 0) or qmax!=127:raise ValueError('Quantizer bounds differ from RTL')
        if i not in [4,6,8,10,12,15] and relu<127:raise ValueError('ReLU6 bound would require a tighter hardware clip')
        append(row['name']+'.qmin_qmax_relu6',32,control)
    for i in range(5):append(f'body.{i}.conversion_lut',8,residual_table(m,i))
    input_lut=(directory/'input_u8_to_i8_lut.bin').read_bytes();output_lut=(directory/'output_i8_to_u8_lut.bin').read_bytes()
    if len(input_lut)!=256 or len(output_lut)!=128 or max(input_lut)>127:raise ValueError('Invalid RGB conversion LUT')
    append('input_lut',8,input_lut);append('output_lut',8,output_lut)
    image.extend(bytes((-len(image))%16));assert len(image)==42080 and len(segments)==55
    output.mkdir(parents=True,exist_ok=True);(output/'codec16_rtl_ddr.bin').write_bytes(image)
    for width in [4,16,20]:(output/f'codec16_rtl_ddr_u{width*8}.mem').write_text(''.join(f'{int.from_bytes(image[i:i+width],"little"):0{width*2}x}\n' for i in range(0,len(image),width)))
    result=dict(architecture=m['architecture'],bytes=len(image),words=len(image)//4,axi_beats=len(image)//16,
        crc32=zlib.crc32(image),sha256=hashlib.sha256(image).hexdigest(),segments=segments,numeric=numeric,
        deployable=bool(m.get('trained_for_standard_first')) and bool(m.get('trained_for_in')) and not m.get('synthetic_fixture',False))
    (output/'rtl_address_map.json').write_text(json.dumps(result,indent=2));return result
