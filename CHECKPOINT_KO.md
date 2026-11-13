# CV32E40P Stories260K — HOLD checkpoint

사용자 요청으로 현재 시뮬레이션 완료 후 보류. 추가 구현/측정은 시작하지 않음.

## 완료된 실측
| context | forward cycles, 계측 제외 | logits 상대 L2 | 관측 스택 쓰기 |
|---|---:|---:|---:|
|1|3,119,811|2.726e-7|224 B|
|128|5,778,780|2.314e-7|224 B|
|512|13,842,513|2.376e-7|224 B|

- 세 경우 logits/argmax 및 전체 KV 수치 비교 PASS. 기존 KV prefix와 가중치 불변 확인.
- 토큰 ID 1을 반복한 teacher-forced 입력. 과거 KV는 원본 host C에서 준비하여 해당 한 step을 RTL에서 실행. 자연어 품질 평가 또는 512-step 연속 RTL 검증이 아님.
- baseline .text 2,676 B, rodata 124 B, eh_frame 248 B, bss 156 B. tokenizer, 문자열 입출력, top-p, OS/interrupt 미포함.
- 계측 포함 profile .text 2,804 B. 스택 224 B는 이 세 입력의 쓰기 watermark이며 최대 스택 보장이 아님. 4 KiB 예약 유지.
- FPU=1, RV32IMFC, FPU_ADDMUL_LAT=0, FPU_OTHERS_LAT=0. 1-cycle 응답 instruction/data 독립 메모리, 경쟁/캐시/버스 wait 없음. FPGA 실측 아님.
- 첫 측정은 clock gate forced-on. reset 중 scan enable 후 정상 gating으로 전환한 재실행에서 context 1/512의 전체 DATA dump 및 cycles 동일 확인.
- profile exp 누적 window: 113003 / 833048 / 3029382 cycles, 호출 900 / 5980 / 21340. sqrt 11회, 누적 window 264 cycles. 이 값에는 CSR 계측 window 비용이 포함되어 순수 함수 latency가 아님.
- 별도 256회 입력 microbench에서 대응 passthrough를 뺀 평균 exp 123.0625 cycles, sqrt 10.6992 cycles. exp 입력 -8,-2,0,2,8; sqrt 입력 0.1,1,100. 입력/정렬/컴파일 결과에 의존하며 위 실제 호출 전체의 정확한 overhead 보정값으로 대입하면 안 됨.

## 보류 시 판단
- 현재 범위에서는 INST 16 KiB 후보가 충분. linker만 128→16 KiB로 축소한 후 loadable ELF segments 동일 확인. 전체 시스템 최종 용량으로 확정하지 않음.
- sqrt 전용 가속 우선순위 낮음. exp는 후속 MAC 가속 포함 E2E 기준으로 채택 결정. 가속 RTL은 아직 없음.
- 다음 재개 시 함수별 계측 오버헤드 정밀 보정과 MAC 이후 exp 병목 재평가. 사용자 재개 요청 전 진행하지 않음.

## 재현 및 파일
- results.json, baseline/profile ELF·map·dis·stack usage, base/out/gated dumps 포함.
- build.sh: TC를 GCC 14.2.0 + picolibc 설치 prefix(usr)에 설정. GCC flags 및 library path는 스크립트 참조.
- build_sim.sh: Verilator 5.032 필요. BLKANDNBLK 경고 억제 사용; upstream packed array의 서로 다른 element에 continuous/sequential 할당이 섞인 코드 때문. 해당 RTL 수정 없음.
- reproduce.sh는 다음 재개 시에만 실행. calibration bench는 저장된 bench_out.bin 사용. bench 재실행 자동화는 아직 통합하지 않음.
- sim.cpp는 reset 중 gating 개방 후 정상 gating 사용. sim_forced_clock.cpp는 최초 측정 조건.
- run.c 원본과 CV32E40P/vendor RTL snapshot 포함. model과 source의 SHA256은 SHA256SUMS 기록.
- 모델 주소 0은 bare-metal 의미로 사용: -fno-delete-null-pointer-checks 적용.
- 모델 DATA 2 MiB, INST base 0x01000000, entry 0x01000080, 제어 0x1B4000, 스택 top 0x200000. 결과 MMIO 0x20000000.
- 앞선 대화의 .text 3908 B/bit-exact 주장은 이번 실행에서 재현한 결과가 아님. 위 수치를 현재 근거로 사용.
