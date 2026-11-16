# LLM on RISC-V + 가속기 + FPGA — 실전 플레이북 (Stories260K에서 얻은 것, 15M 이후에 적용)

작성 2026-11-17. 대상 독자: 이 프로젝트를 이어서 하는 사람과 다음 세션의 Claude.
근거: 이 저장소의 커밋(`ea5a90c` … `9c47285`), 단계 문서(`PROGRESS.md`의 표), Notion `업무 / LLM HW Architecture`.
표기: **사실**(실행·리포트로 확인), **추정**(계산·판단, 미측정), **가정**(입력값, 근거 없음)을 구분한다.

---

## 0. 한 장 요약

### 0.1 무엇을 했나
llama2.c Stories260K를 CV32E40P(RV32IMFC + FPU) RTL에서 실행하고, 연산 대부분을 가속기로 옮기고, ZCU104(XCZU7EV)에
150 MHz로 올릴 RTL까지 만들었다. **모든 단계에서 결과 수치는 RISC 소프트웨어와 bit 단위로 같다**(Option A 이후는
새 수치 정의와 bit 동일).

| 단계 | 핵심 결과 (사실) | 기록 |
|---|---|---|
| G0 재현 | 로컬 툴체인으로 HOLD dump byte 동일 | `g0/G0_REPRO.md` |
| ① 연속 생성 | 512 step RISC 생성, host와 토큰열 일치 | `gen/P1_GEN.md` |
| ② 기준선 | 무침습 프로파일러, `-O2 -funroll-loops`(bit 동일, 2.1×) | `prof/P2_PROFILE.md` |
| ③④ 가속 | GEMV(전 행렬) + VFU(softmax·SiLU·expf) + lane 4/4 → 10× | `acc/P3_ACC.md`, `P4B_VFU.md`, `P4C_LANES.md` |
| 메모리 모델 | DDR/SRAM sim 모델, burst fetch, FIFO 256 → DDR에서도 9.9× | `acc/P5_MEMORY_PLAN.md` |
| FPGA 1차 | LUT 101.7%, WNS −9.9 ns → 구조 문제 3가지 | `fpga/P6_FPGA_SYNTH.md` |
| v2 RTL + D2 | BRAM 버퍼·FPU lat 4, 150 MHz P&R 충족 | `fpga/P6_FPGA_SYNTH.md`, `prof/STAGE_PROFILE.md` |
| S2 DDR 수치 | ZCU104 문서값으로 모델 설정, 72조건 bit-exact | `acc/S2_ZCU104_DDR.md` |
| S3 Option A | exp2q softmax/SiLU, ctx512 36×, E2E 31.5×, 150 MHz 충족 | `opta/S3_OPTA.md` |
| S5 메모리 RTL | imem + SRAM 2 MiB(URAM) + AXI-Lite 보드 top, sim byte 동일 | `acc/S5_ONCHIP_MEM.md` |
| S6 칩 합성 | URAM 64 매핑 성공, timing은 진행 중(아래 §10) | `fpga/P6_FPGA_SYNTH.md` |

### 0.2 가장 중요한 교훈 7개 (15M에서 그대로 쓸 것)
1. **기준선을 먼저 고정하고, 모든 변경을 그 기준선과 bit 비교한다.** 비교 대상이 흔들리면 가속비도 버그도 판단할 수 없다.
2. **bit-exact의 열쇠는 "같은 연산을 같은 순서로, 같은 FPU 모듈로"** 하는 것. CPU의 `cv32e40p_fp_wrapper`를 가속기에서 그대로 재사용했다.
3. **"동작할 것"이 아니라 "동작을 확인함"만 보고한다.** 회귀 스크립트(`reproduce.sh`)를 일찍 만들고, 기본값이 바뀔 때마다 기준값을 다시 만든다.
4. **sim에서 FPU 지연 0으로 잰 성능은 FPGA에서 실현되지 않는다.** 합성을 너무 늦게 해서 RTL을 한 번 다시 짰다(v1 → v2). 15M은 **초기에 합성**한다.
5. **메모리 모델이 성능 결론을 바꾼다.** 이상 모델 10×가 RUN=1 DDR 모델에서 3.2×였다. burst가 생기도록 fetch 순서를 바꾸고서야 9.9×로 돌아왔다.
6. **결정 기록(Notion)을 작업 전에 다시 읽는다.** 11-14 "260K 전부 온칩" 결정을 놓치고 AXI4 master를 계획에 넣었다(§9).
7. **Vivado의 "추론"을 믿지 말고 보고서를 읽는다.** URAM 속성 무시(경고만), 두 개의 read 문장으로 BRAM 추론 실패 등은 에러 없이 지나간다.

### 0.3 15M에 가져갈 것 / 바꿀 것
| 그대로 | 바꿔야 함 |
|---|---|
| 검증 체계(host golden, `-Os` 비교, 단위 테스트, reproduce) | 메모리 맵(가중치 58 MiB → PS DDR4), 주소 폭 |
| GEMV 엔진 구조(행 병렬 lane, R행 interleave, RUN fetch) | XBUF 512 → 1024 이상(W2 입력 768), LM head 32,000행 분할 호출 |
| VFU + Option A exp2 pipeline | VFU BUF(SiLU 768) 분할, softmax ctx ≤ 256 |
| D2 구성(FPU lat 4, 150 MHz) | **AXI4 master(DDR 가중치 스트리밍) 필수** |
| AXI-Lite 보드 top·로더 | KV 배치 결정(fp32 3.375 MiB는 URAM 3.0 MiB 초과, §12) |

---

## 1. 작업 방식 (모든 단계 공통)

### 1.1 단계마다 같은 순서
1. **목표·통과 기준을 숫자로 적는다**(예: "logits rel L2 < 1e-5, 토큰 일치, `-Os`와 bit 동일").
2. **기준선을 재현한다**(이전 단계 수치가 그대로 나오는지).
3. 구현 → **단위 테스트** → **single-step 3 ctx(1/128/512)** → **E2E 8/64(/512) step**.
4. 기본값이 바뀌면 **reference 재생성 + `reproduce.sh` 갱신**.
5. 단계 문서(결론 → 설계 → 결과 → 한계/미검증 → 재현 명령) + `PROGRESS.md` 표 갱신 → 커밋 → main merge.
6. 결정·교훈은 Notion에 제안 → 승인 후 기록.

### 1.2 비교의 3층 구조 (사실, ①부터 사용)
| 층 | 비교 | 기준 |
|---|---|---|
| host ↔ RISC | host llama2.c(무수정 `run.c`)를 RISC가 고른 토큰으로 teacher-forcing | 매 step logits rel L2 < 1e-5, KV rel L2 < 1e-5, RISC 토큰 = 자신의 argmax, argmax 불일치는 near-tie(margin < 1e-4)만 허용 |
| RISC SW ↔ RISC SW | `-Os` 빌드 vs `-O2 -funroll-loops` 빌드 | logits·KV·토큰 **bit 동일** (컴파일 플래그가 수치를 바꾸지 않음을 증명) |
| RISC HW ↔ RISC SW | 가속기 경로 vs `-Os` SW | logits·KV·토큰 **bit 동일** |

host와 RISC가 bit 동일이 아닌 이유: host glibc `expf`/`sqrtf` vs RISC picolibc(사실). 그래서 host와는 tolerance, RISC 내부는 bit.

### 1.3 측정의 원칙
- **single-step(ctx 1/128/512)**로 영역별 원인을 보고, **E2E**로 실제 생성 성능을 확인한다. ctx1은 GEMV가, ctx512는 attention·softmax가 지배한다.
- 가속비는 **같은 CPU 구성의 SW 기준선** 대비로 쓴다(D2 이후 CPU FPU lat 4). `-Os` 대비로 쓰면 2배 과대평가된다(사실, ② 문서).
- sim 속도: CPU 단독 약 0.58M cycles/s(사실, ①). 512 step SW는 1–2시간, 가속 512 step은 30분 내외. 긴 run은 백그라운드로 먼저 시작한다.

---

## 2. 단계별 상세

각 단계는 같은 틀: **문제 → 검토한 선택지 → 결정과 근거 → 결과 → 함정 → 재현 → 15M에서.**

### 2.1 G0 — 재현 환경 복구
- **문제:** HOLD 결과(GCC 14.2 + picolibc prefix, Verilator 5.032)를 다른 PC(WSL2, apt GCC 13.2, picolibc 1.8.6, Verilator 5.038)에서 재현해야 했다.
- **결정:** 저장된 ELF로 RTL dump byte 동일을 먼저 확인 → 로컬 툴체인 재빌드는 **수치 bit 동일 + cycle 차이 허용**(+0.01~0.08%)으로 판정 → 이후 기준선은 로컬 툴체인 수치.
- **결과(사실):** 3 case dump byte 동일, host reference 9개 파일 byte 동일.
- **함정:** Windows 복사로 스크립트 실행 권한 소실(`chmod +x`), CRLF 변환(`.gitattributes * -text`, `core.autocrlf input`). sim `DONE cycles`는 firmware 측정 window보다 8,787 큰 상수(boot 포함)라 혼동하지 말 것.
- **15M에서:** 모델 파일(`stories15M.bin`)과 토크나이저(32,000 vocab)의 SHA256을 먼저 기록. host golden(`reference.c` 계열)으로 ctx별 기준 파일을 만든다.

### 2.2 ① RISC 단독 연속 생성
- **문제:** HOLD는 1 step teacher-forced였다. 실제 생성(KV 누적, 512 step)을 RTL에서 돌려야 했다.
- **구현:** `gen/firmware_gen.c`(llama2.c `generate()` 루프, KV를 RISC가 누적), `gen/host_gen.c`(encode / tf / free / decode), `gen/run_gen.py`(빌드 → 이미지 → sim → host 비교 → `result.json`). 프롬프트는 이미지의 0x1ae000, step 로그는 MMIO 0x20000004에 step마다 logits 2 KB.
- **결과(사실):** 512 step PASS, host 단독 greedy와 토큰열 일치, `-Os`와 `-O2u` bit 동일. 토큰당 4.66M cycles(SW 기준선).
- **함정:** 하나의 프롬프트·greedy만 검증(범위 결정, 11-15). BOS 이후에도 512까지 진행해 KV 전체를 사용하게 했다.
- **15M에서:** vocab 32,000이라 step 로그가 128 KB/step → 512 step 로그 64 MB. 필요한 step만 기록하거나 argmax+일부만 저장하는 옵션을 먼저 만든다(추정).

### 2.3 ② 기준선과 무침습 프로파일러
- **문제:** 어디가 병목인지 알아야 가속 범위를 정한다. firmware에 계측 코드를 넣으면 측정이 교란된다.
- **결정:** sim 쪽 프로파일러(`SIM_PROF`): 매 cycle을 ID stage PC와 "현재 call site"(forward() 안 마지막 PC)에 귀속, `-g` 빌드의 addr2line으로 source line → 영역(앵커 문자열). firmware 무수정, `-g` 유무로 `.text` byte 동일 assert. 정합성: 합계 = firmware mcycle window − 11.
- **SW 최적화:** FP 순서를 바꾸지 않는 플래그만 허용(`-ffp-contract=off`, 재결합·역수곱 금지). `-O2 -funroll-loops` 채택(ctx1 2.14× vs `-Os`, bit 동일).
- **결과(사실, 채택 기준선):** ctx1 GEMV 87.7%, ctx512 softmax 44.9%·QK 20.1%·AV 16.0%. expf 1회 ≈ 117.5 cycles. Amdahl 상한: GEMV만 8.1×(ctx1), softmax까지 36.3×(ctx512).
- **판단:** 짧은 context는 GEMV, 긴 context는 attention + expf. bit-exact 하에서 HW expf는 picolibc `sf_exp.c`와 bit 동일해야 함 → 연산 순서 재현이 가능함을 disassembly로 확인.
- **15M에서:** 프로파일러 앵커(`prof/run_prof.py`의 ANCHORS)는 소스 문자열 기반이라 펌웨어가 바뀌면 갱신. 15M은 LM head(32,000 × 288)가 커서 ctx1 지배 항목이 LM head일 가능성(추정).

### 2.4 ③ GEMV 가속기 (FFN → attention → 전 행렬)
- **문제:** GEMV를 HW로 옮기되 bit-exact여야 한다.
- **결정:** `y[i] = Σ_j W[i·WS + j·JS] · x[j]`, 행마다 +0.0에서 j 순서로 fmul → fadd(곱·합 분리, fmadd 금지). 산술은 **CPU와 같은 `cv32e40p_fp_wrapper`**. stride(W_STRIDE, J_STRIDE)로 FFN·QK(K 행)·AV(V 열)·모든 weight matmul을 한 엔진으로.
- **결과(사실):** FFN만 ctx1 1.80×, +QK/AV ctx512 1.55×, 메모리 24조건 bit-exact. 전 행렬(`USE_ACC_MM`)까지 1 lane ctx1 4.1×.
- **함정:** QK 뒤 `/√8`를 VFU로 옮기면 오히려 느렸다(나눗셈기 지연 + load/store). 나중에 softmax에 **융합**(CMD 5)해서 해결.
- **15M에서:** GEMV 크기: dim 288, hidden 768, vocab 32,000. `XBUF`(x 버퍼) ≥ 768, `YBUF`는 호출당 행 수 제한으로 두고 펌웨어가 분할. 15M MAC/token ≈ 15.2M(추정).

### 2.5 ④-b VFU (softmax · SiLU · expf, bit-exact)
- **문제:** softmax(expf)가 ctx512에서 68.9%(④-a 후).
- **결정:** picolibc 1.8.6 `sf_exp.c`의 **컴파일된 연산 순서 그대로** FPU 1개로 시퀀싱(범위 검사 비트 패턴, `k=(int)RTZ(x·invln2±0.5)`, 5항 다항식, `(x·c)/(2−c)`, 지수 가산, k<−125면 2^−100 곱). 컴파일러가 `a + P2`를 `a − |P2|`로 바꾼 것까지 따른다. max는 IEEE 비트 정수 비교(+0 = −0).
- **결과(사실):** 1,048,576 원소 불일치 0, ctx512 2.69×.
- **함정:** subnormal 지원 FPU 필요(fpnew 지원, Xilinx FP IP는 flush 가능성 — 미확인). softmax 합은 원소 순서대로 1개 가산기에서(bit-exact 조건).
- **15M에서:** Option A(§2.10) 이후는 이 fdlibm 경로를 쓰지 않는다. 다만 원 수치(llama2.c 그대로)를 유지하려면 이 VFU가 필요하다.

### 2.6 lane 병렬화와 융합
- **결정:** MAC lane p = 행 i0+p(행 내부 순서 불변 → bit 동일). 128-bit 메모리 line, fetch 모드 A(행 연속)/B(AV: 같은 j의 4행)/C(word). VFU lane 4개(원소 독립), 합은 순차.
- **결과(사실):** 11.93× / 10.67× / 10.07× (ctx 1/128/512), E2E 512 10.29×.
- **15M에서:** lane 수는 DDR 대역폭과 함께 정한다(§12). HP 1포트 12.8 B/cycle이면 4 lane이 대략 균형(추정).

### 2.7 메모리 모델 현실화
- **문제:** 이상 모델(16 B/cycle, outstanding 무제한)의 10×가 실제 DDR에서 얼마인가.
- **구현:** `sim.cpp` `SIM_DDR=1`: 주소 < 0x100000 = DDR(latency, burst 시작 overhead, 연속 line burst 묶기, 지속 B/cycle, burst 단위 outstanding), 나머지 = SRAM. 응답 in-order.
- **발견(사실):** RUN=1(lane마다 line 번갈아 요청)은 주소가 불연속 → burst가 안 생겨 3.19×. **RUN=16(lane별 연속 line)** 8.10× → RMS weight SRAM 복사 9.60× → embedding word 복사 10.27×.
- **후속:** lane FIFO 256 words면 latency 100에서도 손실 작음 → 명령 간 prefetch 불필요(구조 복잡도 회피).
- **15M에서:** 가중치 58 MiB가 전부 DDR → 이 모델이 그대로 성능을 결정. AXI4 master는 RUN 단위 연속 burst를 내도록 설계(§12).

### 2.8 FPGA 1차 합성 (실패에서 배운 것)
- **결과(사실, 200 MHz):** LUT 101.7%, BRAM 0, WNS −9.876 ns. 원인 3가지: ① FPU 지연 0(조합) — CPU FPU가 최악 경로(≈68 MHz), ② 버퍼·FIFO가 FF+대형 mux, ③ VFU lane마다 fpnew 전체.
- **교훈:** sim 전용으로 짠 RTL은 FPGA에서 그대로 안 된다. **15M은 RTL 초안 단계에서 합성부터.**

### 2.9 v2 RTL과 D2 기본화
- **CPU 단독 합성(사실):** FPU lat 4 + PipeConfig DISTRIBUTED ≈ 169 MHz, core 제어 경로 ≈ 6.2 ns → **150 MHz 목표**(사용자 결정 11-15).
- **v2 변경:** xbuf/ybuf/abuf/bbuf를 lane별 bank BRAM(registered read, 태그로 읽기 결과 매칭), FIFO는 LUTRAM, FPU lat 4. GEMV는 **R = FPU_LAT 개 행을 lane에서 interleave**(각 행 j 순서 유지) → 1 MAC/cycle/lane 유지. VFU는 handshake라 지연 무관.
- **D1 / D2 결정(사용자, 11-15):** D2(CPU/ACC/VFU FPU lat 4, RUN 8) 기본, D1(ideal, lat 0)은 이력용 빌드(`CFG=d1`).
- **결과(사실):** 150 MHz P&R WNS +0.025 ns, LUT 21.4%. D2 SW 기준선 3.04M / 5.61M / 13.43M(CPU FPU lat 4로 1.7–2.1× 느려짐), full offload 18.5× / 11.6× / 9.2×, E2E 512 10.1×.
- **함정:** RUN 16 + lat 4에서 lane FIFO가 run 크기에 굶주림 → RUN 8. 병렬 Vivado 5개 → 크래시(최대 3, 최근엔 2개도 1개 죽음).
- **15M에서:** D2를 출발점으로. CPU FPU lat 4 때문에 CPU가 하는 일(RoPE, rmsnorm, argmax 32,000)이 상대적으로 커진다 → 프로파일 먼저.

### 2.10 S3 Option A (수치 정의를 바꾸는 절차)
- **문제:** D2에서 ctx512 softmax가 78%. fdlibm expf는 원소당 수십 FP 연산.
- **선택지:** (a) VFU lane 증설 (b) 테이블 기반 exp2 + deferred normalization (c) LUT 근사. → **(b) 채택**(사용자, 11-15). 이유: 1 원소/cycle 파이프라인이 가능하고 연산 순서를 새로 정의해도 host·SW·HW를 같은 정의로 묶을 수 있음.
- **정의(`opta/exp2q.h`, `softmax2.h`):** y = (s − m)·K(K = fp32(log2e/√8), ÷√8 흡수) → exp2q(정수만: Q8.23, 64-entry 2^(i/64) 표, 2차 다항식, round half up, underflow → 0) → 4-way 부분합 (S0+S1)+(S2+S3) → AV는 비정규화 p로 → 출력 8개만 ÷sum. SiLU = x·(1/(1+exp2q(x·(−log2e)))).
- **절차(15M에서 수치를 바꿀 때 그대로 따를 것):**
  1. C 모델 + **입력 전수 정확도**(2^32, `opta/test_exp2q.c`: 최대 1.34 ulp, 94.4% 정확 반올림).
  2. host 모델(`opta/run_opta.c`, `make_run_opta.py`로 run.c에서 자동 생성) vs 원본 llama2.c: 512 step 토큰 동일, logits rel L2 ≤ 3.4e-6 → 수용 판단.
  3. RISC SW(`-DOPTA`) vs host Option A: bit 동일.
  4. RTL(`vfu_exp2.sv`) vs C 모델: **2^32 전수**(`acc/tb_exp2`, Verilator 1/4씩 병렬, 각 1.5분).
  5. VFU 단위 테스트(cmd 6/7, 합까지 비교) → E2E(host Option A와 512 step bit 동일).
- **결과(사실):** ctx 1/128/512 147,875 / 204,175 / 373,168 (20.6× / 27.5× / **36.0×**), E2E 512 **31.5×**, 150 MHz WNS +0.136 ns(EXPLORE).
- **함정:** 
  - `r*r`(17 bit²)이 32 bit overflow → 전수 테스트에서 124 ulp 오류로 발견. **전수 테스트 없이는 못 찾았을 버그.**
  - 입력 양자화를 절삭으로 하면 최대 2.0 ulp → 반올림으로 1.34 ulp.
  - MMIO 레지스터 번호 충돌(0x18은 LAST_CYCLES) → SUM은 0x1C.
- **15M에서:** Option A 그대로 사용 가능(dim/ctx와 무관). **정확도 수용 판단은 15M으로 다시**(`opta/compare_host.py`를 15M 모델로).

### 2.11 S2 ZCU104 DDR 수치
- **사실(문서):** PS DDR4 2 GB 64-bit DDR4-2400(UG1267), HP 포트 32/64/128-bit(PG201), RDISSUE 1~16·리셋 4(UG1085). **latency는 문서 근거 없음**(가정 40 cycle @150 MHz = 267 ns).
- **결과:** 72조건 bit-exact. outstanding 4(리셋값)면 ctx1 +15% → **RDISSUE ≥ 8 설정 필요**. latency 30→100은 outstanding 8에서 ctx1 +22%.
- **15M에서:** 가중치 스트리밍이 전부라 대역폭이 성능 상한. HP 2포트 병렬 검토(§12).

### 2.12 S5 메모리를 RTL로, 보드 top
- **문제:** sim은 메모리를 C++ 배열로 흉내냈다. 보드에는 RTL 메모리와 PS가 적재하는 경로가 있어야 한다.
- **결정과 근거:**
  - `soc_chip` = `soc_top` + imem 16 KB + `sram_dp`(128-bit true dual port, byte enable). 포트 A = CPU, 포트 B = 가속기.
  - **가중치 온칩**(`WEIGHTS_ONCHIP=1`, SRAM 0x0–0x20_0000 = 2 MiB): Notion Decision 11-14 "260K 전부 온칩". `=0`은 S5a 배치(가중치 외부 포트)로 15M용으로 유지.
  - 응답 순서: CPU 포트는 SRAM/외부 응답이 겹치지 않게 grant를 막는다. 가속기 포트는 tag FIFO + fall-through 데이터 FIFO로 요청 순서대로 반환.
  - `chip_axi_top`: AXI4-Lite slave(SRAM 창, imem 창, CTRL.RUN, STATUS.DONE, DONE 값, CYCLES). 로더 포트 `ld_*`는 core가 리셋일 때만 동작.
  - sim: `sim.cpp -DCHIP`(public 배열로 preload/dump), `sim_axi.cpp`(PS 흐름을 AXI-Lite로만 수행).
- **결과(사실):** HOLD·SW 기준선·Option A가 `soc_top` sim과 **byte·cycle 동일**. AXI-Lite 보드 흐름 6 run이 preload 방식과 2 MiB 전체 byte 동일.
- **함정 (모두 실제로 겪음):**
  - `scan_cg_en_i`를 0으로 묶음 → **FPU 나눗셈기가 첫 `fdiv.s`에서 grant 안 줌**(gated clock이 리셋을 못 받음). VCD로 apu handshake를 보고 찾음. 해결: `!rst_ni`.
  - DDR 모델 모드에서 boot 시간 176 cycle 차이: 구 sim 모델은 DDR load 응답 cycle에 SRAM 접근까지 막았다. RTL이 더 현실적이라 차이를 설명하고 수용.
  - `pkill -f <pattern>`이 자기 셸까지 죽임(명령줄에 pattern 포함). Windows Vivado는 `taskkill.exe /PID`.
- **15M에서:** SRAM은 KV·activation·펌웨어만(가중치 DDR). `WEIGHTS_ONCHIP=0` 경로 + AXI4 master. 로더는 그대로(가중치는 PS가 DDR에 직접 두고, `DDR_BASE` 레지스터로 주소 이동 — 미구현).

### 2.13 S6 칩 합성 (진행 중, 11-17)
| 시도 | 결과 (사실) | 원인 → 조치 |
|---|---|---|
| `ram_style = RAM_STYLE`(파라미터) | Synth 에러 | 속성 값은 리터럴만 → `"ultra"` 고정 |
| RTL 추론, read-first | "invalid write mode"로 URAM 무시, BRAM 259 tile(83%), WNS −1.483 | URAM은 NO_CHANGE만 → 그래도 추론 실패 → **XPM `xpm_memory_tdpram`** |
| XPM URAM, RLAT 1 | URAM 64 ✔, imem이 URAM으로 → fetch 주소 → URAM EN −1.58 | imem `ram_style "block"` |
| imem block + 로더 read 문장 추가 | imem이 LUT로(BRAM 추론 실패) −1.905 | **read 문장 하나**(주소 mux) |
| imem BRAM 4, URAM 64, RLAT 1 | route WNS −0.913 (4,060) | 가속기 주소 → **URAM 32단 cascade 주소** |
| RLAT 3 | route WNS −0.718 (881) | 읽기 latency는 출력 쪽만 파이프라인, 주소 cascade 경로 그대로 |
| RLAT 2 + cascade 8 / RLAT 3 + cascade 4 | 진행 중 | XPM `CASCADE_HEIGHT`로 cascade 분할 |

sim cycle 영향(사실): RLAT 2 → Option A +4.7/+3.4/+1.9 %, SW +9.5 %; RLAT 3 → +7.0/+5.2/+2.8 %, SW +15 %. 모두 bit-exact.

**대안(아직 안 함):** SRAM 앞에 주소 레지스터 1단(soc_chip) · 2 MiB를 1 MiB 두 뱅크로 나눠 주소 상위 bit로 선택 · 가속기 쪽 주소 레지스터 복제.

---

## 3. bit-exact 방법론 (재사용용)

### 3.1 원칙
1. **연산 종류·순서·반올림이 C와 같으면 bit 동일.** IEEE 곱셈·덧셈의 교환법칙(비 NaN)은 이용해도 되지만 결합법칙은 안 된다.
2. **FMA 금지**(`-ffp-contract=off`, HW도 fmul → fadd 분리).
3. **누적은 원래 순서로.** 병렬화는 서로 다른 출력 사이에서만(행 병렬, 원소 병렬). 하나의 합을 나누면 수치가 바뀐다(Option A의 4-way 합은 **정의를 바꾼 것**).
4. **같은 FPU 모듈 재사용**(`cv32e40p_fp_wrapper`): subnormal·RNE·RTZ 변환 동작이 CPU와 같다.
5. **파이프라인 지연은 수치를 바꾸지 않는다.** 단 의존 체인을 지키는 스케줄(R행 interleave, partial sum rotation + forwarding)이 필요하다.

### 3.2 수치 정의를 바꿀 때 (Option A 절차, §2.10)
C 모델 → 입력 전수 정확도 → host 모델 vs 원본(토큰·rel L2) → **사용자 수용 결정** → RISC SW = host 모델 bit → RTL = C 모델 전수 → 단위 테스트 → E2E. 수용 기준은 기존 host tolerance(rel L2 < 1e-5, 토큰 일치)를 재사용.

### 3.3 검증 도구 사다리
| 수준 | 도구 | 비용 |
|---|---|---|
| 함수 단위 전수 | C 테스트(OpenMP), Verilator 전용 TB(`acc/tb_exp2`) | 분 단위 |
| 블록 단위 | `vfu/run_test.py`(RISC SW vs HW, 원소 bit 비교) | 분 |
| single step | `prof/run_prof.py`(dump vs HOLD, cycle·영역) | 분 |
| E2E | `gen/run_gen.py`(host·`-Os` 비교) | 8 step 분, 512 step 시간 |
| 회귀 | `./reproduce.sh quick/standard/full` + `reproduce_check.py` | 8분 / 40분 / 수 시간 |

---

## 4. 함정 목록 (증상 → 원인 → 해결)

| # | 증상 | 원인 | 해결 | 분류 |
|---|---|---|---|---|
| 1 | Vivado가 generic을 무시(FPU=0으로 합성) | Windows cmd.exe가 `NAME=VALUE`의 `=`에서 인자 분리 | `NAME:VALUE` 토큰 → synth.tcl에서 변환 | 툴 |
| 2 | 병렬 Vivado 비정상 종료(로그 없음) | 동시 실행 크래시(5개에서 EXCEPTION_ACCESS_VIOLATION, 2개 중 1개도 사망) | 최대 2–3개, 시작 시간차(4분) | 툴 |
| 3 | `-retiming` 무효 | deprecated | `-global_retiming on`(효과 없음) | 툴 |
| 4 | Vivado 실행 실패 | H: 드라이브(설치) 미연결, cwd가 `/mnt/<drive>` 아님 | 드라이브 확인, 작업 디렉토리 `E:\fpga_work` | 환경 |
| 5 | `ERROR: Failed to create directory 'C'` | 무해한 메시지 | 무시(합성 계속). 실패 판정은 `Command failed`로 | 툴 |
| 6 | URAM 속성 무시, BRAM으로 | 쓰기 모드(NO_CHANGE 아님), 속성에 파라미터 | XPM `xpm_memory_tdpram` | 합성 |
| 7 | BRAM 추론 실패 → LUT | 같은 배열에 read 문장 2개 | 주소 mux로 read 하나 | 합성 |
| 8 | URAM cascade 주소 경로 −0.7~−0.9 ns | 2 MiB = 32단 cascade, 주소가 cascade를 통과 | CASCADE_HEIGHT 분할 / 주소 레지스터(진행 중) | 합성 |
| 9 | 150 MHz −0.137 ns, CPU store → VFU 레지스터 CE | 명령 시작 시 불필요한 카운터 clear | clear 제거(동작 불변) + EXPLORE flow | 타이밍 |
| 10 | 첫 `fdiv.s`에서 CPU 멈춤 | `scan_cg_en_i = 0`: FPU gated clock이 리셋 못 받음 | `scan_cg_en_i = !rst_ni` | RTL |
| 11 | exp2 RTL/C 124 ulp 오류 | 17-bit `r*r`의 32-bit overflow | 64-bit 곱 (**전수 테스트로 발견**) | 수치 |
| 12 | 병렬 run에서 하나가 build 실패 | 같은 firmware 파일을 동시에 빌드(race) | run별 디렉토리에서 빌드 후 atomic replace | 스크립트 |
| 13 | 커밋된 ELF가 소스와 다름 | 과거에 ELF를 재커밋하지 않음 | `.text` 비교 후 갱신 | 기록 |
| 14 | MMIO 읽기 값 이상 | 레지스터 번호 충돌(0x18 LAST_CYCLES) | 0x1C로 | RTL |
| 15 | 용량 계산 오류(0.17 MB → 실제 384 KiB) | MB/MiB 혼용, URAM ECC bit 포함 용량 | MiB로 통일, URAM 데이터 32 KiB/개 | 계산 |
| 16 | 계획이 기존 결정과 충돌 | Notion Decision(11-14) 미확인 | 계획 전 Notion `Decision` 검색 | 절차 |
| 17 | worktree guard가 명령 거부 | 명령에 `git`/`logits` 같은 문자열, heredoc, main checkout `cd` | 스크립트 파일로 실행, main 작업은 사용자에게 | 환경 |
| 18 | `pkill -f` 후 셸 종료(exit 144) | pattern이 자기 명령줄과 일치 | PID로 종료 | 환경 |
| 19 | 대기 루프가 끝나지 않음 | `pgrep -f`가 자기 루프 명령줄을 매칭 | 결과 파일 존재·로그 문자열로 판정 | 환경 |
| 20 | 합성 단계 WNS가 나쁨 | 배치 전 추정치(비관적), hold 값은 의미 없음 | route 결과로 판단(−1.05 → +0.14 사례) | 판단 |
| 21 | CPU 단독 SW가 D2에서 2배 느림 | FPU lat 4 + 순차 누적 체인 | 같은 CPU 기준선과 비교(가속비는 오히려 커짐) | 해석 |

---

## 5. 도구와 스크립트

### 5.1 빌드 (`build_sim.sh`)
```
./build_sim.sh                                 # CPU 단독 (D2: FPU lat 4)          -> obj/
MDIR=obj_prof ./build_sim.sh                   # 프로파일러용 CPU
TOP=soc_top ./build_sim.sh                     # CPU + gemv_acc + vfu              -> obj_soc/
TOP=soc_chip ./build_sim.sh                    # + imem + SRAM 2 MiB(가중치 온칩)  -> obj_chip/
TOP=soc_chip CHIP_WEIGHTS=ddr ./build_sim.sh   # S5a 배치(가중치 외부 + DDR 모델)
TOP=chip_axi_top ./build_sim.sh                # 보드 top, AXI-Lite 흐름(sim_axi.cpp) -> obj_axi/
CFG=d1 ...                                     # ideal(FPU lat 0, 이력)
옵션: ACC_LANES VFU_LANES ACC_RUN ACC_FDEPTH CPU/ACC/VFU_FPU_LAT SRAM_RLAT
```

### 5.2 실행·측정
```
python3 gen/run_gen.py 64                                    # SW 기준선 E2E (out_64_O2u_d2)
GEN_CFLAGS="" python3 gen/run_gen.py 64                      # -Os 기준 (bit 비교용)
GEN_ACC=full python3 gen/run_gen.py 512                      # 전체 가속 E2E
OPTA=1 GEN_ACC=full python3 gen/run_gen.py 512               # Option A
SIM_DDR=1 GEN_HW=_d2_ddr GEN_ACC=full python3 gen/run_gen.py 64   # DDR 모델
PROF_CFLAGS="-O2 -funroll-loops" python3 prof/run_prof.py gen/firmware_gen.c gen_O2u_d2
python3 prof/stage_profile.py 150 d2                         # 단계별 시간표
python3 vfu/run_test.py 2 16384                              # VFU 단위 테스트 (TEST_ONLY=6,7)
SWEEP_GRID=zcu104 python3 acc/sweep_ddr.py <prof tag>        # DDR 파라미터 스윕
acc/tb_exp2/run.sh [lo hi]                                   # exp2 RTL 전수
python3 opta/compare_host.py 512                             # Option A vs 원본 (host)
./reproduce.sh standard                                      # 회귀 (repro/, 53 항목)
```

### 5.3 FPGA
```
fpga/run_soc_v2.sh [workdir] [EXPLORE]                                # soc_top D2 @150 MHz
fpga/run_chip.sh [workdir] [EXPLORE] [SRAM_RLAT:n SRAM_CASCADE:n]     # chip_axi_top
python3 fpga/prepare.py <workdir>          # RTL 사본 + files.tcl (PIPE_DIST=1: fp_wrapper DISTRIBUTED)
```
리포트는 `<workdir>/reports_<tag>/`. 의미 있는 것은 `fpga/reports_*`로 복사해 커밋.

---

## 6. 15M 적용 계획 (권장 순서와 Gate)

### 6.0 시작 전 결정 (사용자)
| 항목 | 선택지 | 권고 | 근거 |
|---|---|---|---|
| KV 정밀도·위치 | A: fp32 DDR · B: fp32 URAM+BRAM · C: fp16 URAM(기존 Decision) | **A** | bit-exact 유지, DDR 읽기 +≤6% (추정) |
| 수치 기준 | bit-exact fp32 유지 / 15M부터 tolerance | 유지 | 260K 검증 체계 재사용 |
| softmax | 원 수치(fdlibm VFU) / Option A | Option A | 정확도는 15M으로 재확인 필요 |

### 6.1 단계 (각 단계 끝에 Gate)
| # | 단계 | 해야 할 일 | Gate |
|---|---|---|---|
| 15-0 | 모델 확보 | `stories15M.bin`, tokenizer, SHA256, config 확인(dim 288 등 미확인값) | config 사실 확인 |
| 15-1 | host golden | `run.c`로 ctx 1/128/256 기준 파일, 생성 256 step(ctx 상한 256) | host 기준 파일 |
| 15-2 | 메모리 맵 | 가중치 58 MiB(DDR 주소), KV 3.375 MiB(A안: DDR), SRAM(activation·logits 125 KiB·펌웨어), sim 메모리 크기 | 맵 문서 |
| 15-3 | RISC SW | `firmware_gen.c` 15M 대응(vocab 32,000, n_heads 6, head_size 48), D2 CPU sim | host tolerance PASS, `-Os`/`-O2u` bit 동일 |
| 15-4 | 프로파일 | 영역별 cycle(LM head 비중 확인) | 병목 표 |
| 15-5 | 가속 연결 | GEMV XBUF ≥ 768, 행 분할 호출, VFU 분할, `WEIGHTS_ONCHIP=0` | single step bit-exact |
| 15-6 | **초기 합성** | 변경 RTL을 바로 150 MHz 합성 | WNS ≥ 0 또는 원인 확인 |
| 15-7 | AXI4 master | RUN 단위 연속 burst, outstanding ≥ 8, in-order 반환, sim AXI slave 모델(현 DDR 모델 이식) | 현 DDR 모델과 cycle 근접, bit-exact |
| 15-8 | E2E | 256 step, Option A 포함 | host 토큰 동일 |
| 15-9 | 칩 합성 | AXI4 master + SRAM + PS 연결 | 150 MHz |
| 15-10 | 보드(⑤) | Vivado block design(PS + HP0 + HPM0 AXI-Lite), PS 소프트웨어(로더) | 보드 결과 = sim |

### 6.2 미리 알고 갈 수치 (추정)
- 가중치 60.8 MB/token. HP 1포트 12.8 B/cycle이면 31.7 ms, MAC 4 lane 연산 25.3 ms → **약 30 ms/token(25–35 tok/s)**.
- HP 2포트 + 8 lane이면 약 16 ms(≈60 tok/s).
- 기존 Decision의 "HP 포트당 4.8 GB/s"는 300 MHz 가정이다. 현재 설계 150 MHz에서는 포트당 이론 2.4 GB/s.

---

## 7. 부록

### 7.1 핵심 수치 (D2, 150 MHz 실현 구성, 사실)
| | SW 기준선 | full offload | Option A | Option A + DDR 모델 |
|---|---:|---:|---:|---:|
| ctx1 1 step | 3,041,363 | 164,143 (18.5×) | 147,875 (20.6×) | 168,278 (18.1×) |
| ctx128 | 5,611,118 | 482,555 (11.6×) | 204,175 (27.5×) | 224,578 (25.0×) |
| ctx512 | 13,425,011 | 1,454,026 (9.2×) | 373,168 (36.0×) | 393,571 (34.1×) |
| E2E 512 | 4,215,725,794 | 416,300,007 (10.1×) | 133,803,651 (31.5×) | 144,249,987 (29.2×) |

512 token @150 MHz: SW 28.1 s → Option A 0.89 s(574 tok/s). 가중치 온칩(260K 최종 구성)에서는 DDR 열이 아니라 Option A 열이 해당한다(SRAM 읽기 latency를 늘리면 §2.13의 증가분만큼 느려짐).

### 7.2 FPGA 자원 (사실)
| 구성 | LUT | FF | BRAM | URAM | DSP | WNS @150 |
|---|---:|---:|---:|---:|---:|---:|
| soc_top v2 | 49,286 | 16,818 | 0.5 | 0 | 39 | +0.025 |
| soc_top Option A | 54,545 | 18,716 | 3 | 0 | 85 | +0.136 |
| chip_axi_top RLAT1 | 56,479 | 18,923 | 7 | 64 | 85 | −0.913 |
| chip_axi_top RLAT3 | 55,507 | — | 7 | 64 | 85 | −0.718 |

### 7.3 사용자 결정 이력
| 날짜 | 결정 |
|---|---|
| 11-08 | FFN 우선 가속, 가중치 외부 재로딩 (260K는 11-14로 대체) |
| 11-13 | ZCU104, bit-exact, 성능 목표 없음, FP32 우선; 승인 질문은 사용자만 아는 것만 |
| 11-14 | PL DDR 도터보드 미사용, ⑤ 보드 대기, 순서 ④-b → lane → 메모리 모델; (Notion) 260K 전부 온칩, 15M 주력·KV fp16, 42M fallback, 110M 도전 |
| 11-15 | 150 MHz(CPU는 합리적 저하 허용), on-chip RAM은 BRAM/URAM 필수, Option A, D2 기본, 프롬프트 1종·greedy, DDR 수치는 문서 기준 |

### 7.4 문서·코드 색인
| 주제 | 파일 |
|---|---|
| 진행 인덱스 | `PROGRESS.md` |
| 단계 문서 | `g0/G0_REPRO.md`, `gen/P1_GEN.md`, `prof/P2_PROFILE.md`, `acc/P3_ACC.md`, `acc/P4B_VFU.md`, `acc/P4C_LANES.md`, `acc/P5_MEMORY_PLAN.md`, `fpga/P6_FPGA_SYNTH.md`, `acc/S2_ZCU104_DDR.md`, `opta/S3_OPTA.md`, `acc/S5_ONCHIP_MEM.md`, `prof/STAGE_PROFILE.md` |
| RTL | `acc/gemv_acc.sv`, `acc/vfu.sv`, `acc/vfu_lane.sv`, `acc/vfu_exp2.sv`, `acc/soc_top.sv`, `acc/sram_dp.sv`, `acc/soc_chip.sv`, `acc/chip_axi_top.sv` |
| sim | `sim.cpp`(-DSOC, -DCHIP, SIM_PROF, SIM_DDR, VTRACE), `sim_axi.cpp` |
| 펌웨어 | `gen/firmware_gen.c`(USE_ACC*, OPTA, RMS_SRAM, EMB_WORDS), `baseline/firmware.c` |
| 수치 모델 | `opta/exp2q.h`, `opta/softmax2.h`, `opta/run_opta.c` |
| 그림 | soc_chip 남은 일 (claude.ai/artifact/VLkxU4gufjtjgwPVG6bPFB), Stories15M on ZCU104 (claude.ai/artifact/Ab44bRNKb7UUkcP5VC5Ff9) |
