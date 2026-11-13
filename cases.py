from pathlib import Path
import struct
p=Path(__file__).parent
for t in [1,128,512]:
 m=bytearray((p/'image.bin').read_bytes());kv=(p/f'kv_{t}.bin').read_bytes()
 for l in range(5):
  for j in range(2):m[0x100000+l*0x20000+j*0x10000:0x110000+l*0x20000+j*0x10000]=kv[j*327680+l*65536:j*327680+(l+1)*65536]
 struct.pack_into('I',m,0x1afff0,t-1);(p/f'image_{t}.bin').write_bytes(m)
