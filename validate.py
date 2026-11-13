from pathlib import Path
import json,struct,numpy as np
p=Path(__file__).parent
rows=[]
for t in [1,128,512]:
 b=(p/f'base_{t}.bin').read_bytes();pr=(p/f'out_{t}.bin').read_bytes();ref=np.fromfile(p/f'ref_{t}.bin',dtype='<f4');out=np.frombuffer(b[0x1a4a00:0x1a5200],dtype='<f4')
 kv=np.fromfile(p/f'after_kv_{t}.bin',dtype='<f4').reshape(2,5,512,32)
 hw=np.stack([np.stack([np.frombuffer(b[0x100000+l*0x20000+j*0x10000:0x110000+l*0x20000+j*0x10000],dtype='<f4').reshape(512,32) for l in range(5)]) for j in range(2)])
 rel=float(np.linalg.norm(out-ref)/np.linalg.norm(ref));krel=float(np.linalg.norm(hw-kv)/np.linalg.norm(kv))
 assert np.isfinite(out).all() and rel<1e-5 and krel<1e-5
 assert out.argmax()==ref.argmax()
 image=(p/'image.bin').read_bytes();assert b[:0x100000]==image[:0x100000]
 old=(p/f'kv_{t}.bin').read_bytes()
 for j in range(2):
  for l in range(5):
   a=0x100000+l*0x20000+j*0x10000;offset=j*327680+l*65536
   assert b[a:a+(t-1)*128]==old[offset:offset+(t-1)*128]
 stat=struct.unpack_from('6I',pr,0x1aff00);assert stat[3]==40*t+860 and stat[4]==11
 stack=b[0x1ff000:0x200000];first=next(i for i,x in enumerate(stack) if x!=0xa5)
 rows.append(dict(context=t,baseline_cycles=struct.unpack_from('I',b,0x1aff00)[0],profile_cycles=stat[0],exp_window_cycles_raw=stat[1],sqrt_window_cycles_raw=stat[2],exp_calls=stat[3],sqrt_calls=stat[4],argmax=int(out.argmax()),logits_relative_L2=rel,logits_max_abs=float(max(abs(out-ref))),KV_relative_L2=krel,stack_written_bytes=4096-first))
bench=list(struct.unpack_from('4I',(p/'bench_out.bin').read_bytes(),0x1aff00))
res={'cases':rows,'bench_256_calls_raw_totals':dict(zip(['pass_through_fmv','exp_with_fmv','sqrt_with_fmv','adjacent_csr_reads'],bench)),'bench_corrected_mean_cycles':{'exp':(bench[1]-bench[0])/256,'sqrt':(bench[2]-bench[0])/256},'pass':True}
(p/'results.json').write_text(json.dumps(res,indent=2));print(json.dumps(res,indent=2))
