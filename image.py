import struct,ctypes,sys
from pathlib import Path
p=Path(__file__).parent
# optional args: [elf] [out image] (defaults: firmware.elf, image.bin next to this script)
elf_path=Path(sys.argv[1]) if len(sys.argv)>1 else p/'firmware.elf'
out_path=Path(sys.argv[2]) if len(sys.argv)>2 else p/'image.bin'
m=bytearray(0x1020000);b=(p/'stories260K.bin').read_bytes();assert struct.unpack_from('7i',b)==(64,172,5,8,4,512,512)
o=28
for a,n in [(0,32768),(0xfd400,320),(0x20000,20480),(0x34000,10240),(0x3e000,10240),(0x48000,20480),(0xfd900,320),(0x5c000,55040),(0x91c00,55040),(0xc7800,55040),(0xfde00,64)]:
 m[a:a+n*4]=b[o:o+n*4];o+=n*4
lib=ctypes.CDLL('libm.so.6')
for f in ['powf','sinf','cosf']:
 fn=getattr(lib,f);fn.restype=ctypes.c_float;fn.argtypes=[ctypes.c_float]*(2 if f=='powf' else 1)
f32=lambda x:ctypes.c_float(x).value
for pos in range(512):
 for d in range(0,8,2):
  freq=f32(1/lib.powf(10000,f32(d/8)));v=f32(pos*freq)
  struct.pack_into('ff',m,0x1b0000+pos*32+d*4,lib.cosf(v),lib.sinf(v))
m[0x1ff000:0x200000]=bytes([0xa5])*4096
elf=elf_path.read_bytes();phoff=struct.unpack_from('<I',elf,28)[0];sz,num=struct.unpack_from('<HH',elf,42)
for i in range(num):
 typ,off,va,pa,fs,ms,fl,al=struct.unpack_from('<8I',elf,phoff+i*sz)
 if typ==1:m[pa:pa+fs]=elf[off:off+fs]
out_path.write_bytes(m)
