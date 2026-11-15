# CV32E40P Stories260K — 진행 기록 (index)

목표: llama2.c Stories260K를 CV32E40P(RV32IMFC+FPU) RISC 단독으로 실행 → 대표 연산을 HW로 교체 →
**RISC-SW와 bit-exact**를 유지하며 가속 → ZCU104 통합.

기록 원칙: 구현·테스트 결과는 이 저장소(GitHub)가 최종 근거, 승인된 결정·이력은 Notion
(`업무 / LLM HW Architecture`). 수치는 모두 이 저장소의 실행 결과에서 옮긴 것.

## 단계별 기록
| 단계 | 날짜 | 결과 | 상세 기록 | 결과 데이터 |
|---|---|---|---|---|
| HOLD | ~11-13 | forward 1 step RTL 실행(ctx 1/128/512), host와 비교 | `CHECKPOINT_KO.md` | `results.json`, `base_*.bin` |
| G0 재현 환경 | 11-13 | 로컬 툴체인으로 HOLD byte 동일 재현 | `g0/G0_REPRO.md` | `g0/results_local_tc.json` |
| ① 연속 생성 | 11-13 | 512 step 생성 PASS, host greedy와 토큰열 일치 | `gen/P1_GEN.md` | `gen/out_*_Os`, `gen/out_*_O2u` |
| ② 기준선 | 11-13 | 비침습 프로파일러, SW 기준선 `-O2 -funroll-loops`(bit 동일, −43~53%) | `prof/P2_PROFILE.md` | `prof/O2u`, `prof/gen_O2u` |
| ③ FFN GEMV 가속 | 11-13 | CPU와 같은 FPU 모듈 재사용 → bit-exact, ctx1 1.80× | `acc/P3_ACC.md` | `prof/acc_ffn_L0_G1` |
| ④-a QK/AV | 11-13 | 같은 엔진 stride 재사용, ctx512 1.55× | `acc/P3_ACC.md` | `prof/acc_ffn_attn_L0_G1` |
| ④-b VFU | 11-14 | softmax·SiLU·expf HW(picolibc sf_exp 연산 순서), 1M 원소 불일치 0 | `acc/P4B_VFU.md` | `prof/acc_all_L0_G1`, `vfu/` |
| 범위 확대 + lanes | 11-14 | 모든 GEMV, MAC 4 lanes, VFU 4 lanes, ÷√8 융합 → **11.93×/10.67×/10.07×**, E2E 512 step **10.29×** | `acc/P4C_LANES.md` | `prof/acc_full_l4v4`, `gen/out_512_O2u_accfull_l4v4_L0_G1` |
| 메모리 모델 현실화 | 11-14 | DDR/SRAM sim 모델, burst run fetch, RMS·embedding 최적화 → DDR에서도 **10.27×/9.97×/9.82×**, E2E 64 step **10.09×**, 스윕 162 조건 bit-exact | `acc/P5_MEMORY_PLAN.md` | `prof/ddr_full_opt`, `acc/sweep/ddr_ddr_full_opt`, `gen/out_64_O2u_accfull_l4v4r16_ddr_opt_L0_G1` |
| 메모리 후속 + 기본값 승격 | 11-15 | FIFO 256으로 고 latency 손실 해소(명령 간 prefetch 불필요), RUN16·FIFO256·RMS_SRAM·EMB_WORDS 기본화, reference 재생성(`_l4v4r16`) | `acc/P5_MEMORY_PLAN.md` | `prof/*_l4v4r16`, `gen/out_*_l4v4r16*`, `acc/sweep/fdepth_ddr` |
| ② FPGA 합성 1차 | 11-15 | Vivado 2026.1, ZCU104: **LUT 101.7%(초과), BRAM 0, WNS −9.9 ns @200 MHz** → FPU 파이프라인·BRAM화 필요 | `fpga/P6_FPGA_SYNTH.md` | `fpga/reports_v1_soc_top` |

## 현재 성능 (sim, 기본 빌드 `_l4v4r16`, SW 기준선 `-O2 -funroll-loops` 이상 메모리 대비, 전부 bit-exact)
| | SW 기준선 cycles | 이상 메모리 | 배율 | DDR 모델 | 배율 |
|---|---:|---:|---:|---:|---:|
| single step ctx1 | 1,454,871 | 121,501 | 11.97× | 141,694 | 10.27× |
| single step ctx128 | 3,039,674 | 284,733 | 10.68× | 304,926 | 9.97× |
| single step ctx512 | 7,854,556 | 779,756 | 10.07× | 799,949 | 9.82× |
| E2E 64 step | 118,431,746 | 10,444,536 | 11.34× | 11,736,888 | 10.09× |
| E2E 512 step | 2,383,853,770 | 231,415,107 | 10.30× | 241,753,923 | 9.86× |

DDR 모델: Weight는 DDR(latency 40, burst 16, 12.8 B/cycle, outstanding 8), KV·activation은 SRAM. 스윕 범위 ctx1 2.82×~11.77×.
**주의: FPU 지연 0(조합) 가정의 cycle 수.** FPGA 합성 결과 이 구성은 ~68 MHz(추정)이며, FPU 파이프라인화 후 cycle 수가 바뀜.

## 사용자 결정 이력
| 날짜 | 결정 |
|---|---|
| 11-08 | FFN(W1/W3→SwiGLU→W2) 우선 가속, Weight는 외부 메모리에서 재로딩 (Notion) |
| 11-13 | 목표 FPGA ZCU104 / 동일성 = bit-exact / 성능 목표 없음 / FP32 우선 |
| 11-13 | 승인은 사용자만 아는 정보만 질문, 반복 yes/no 금지 |
| 11-14 | PL DDR 도터보드 미사용 → 보드 기본 메모리(해석: PS DDR4) / ⑤ ZCU104 통합 대기 |
| 11-14 | 순서: ④-b → MAC lane → 메모리 모델 현실화 |

## 재현
`./reproduce.sh [quick|standard|full]` — 결과는 `repro/`, 커밋된 값과 비교(`reproduce_check.py`).
마지막 확인: 11-14 `standard` 29/29 OK (main `f46934d` 기준).

## 환경 메모
- RISC-V: apt gcc-riscv64-unknown-elf 13.2 + picolibc 1.8.6, Verilator 5.038 (WSL2 Ubuntu 24.04).
- Vivado: `~/bin/vivado`는 Windows Vivado 2026.1(`H:\2026.1\Vivado\bin\vivado.bat`) wrapper, `/mnt/<drive>` 아래에서만 실행.
  11-15 H: 연결 확인, `vivado v2026.1` 동작. 합성 작업 디렉토리 `E:\fpga_work\cv32e40p_stories` (`fpga/prepare.py`).

## 남은 일 (권장 순서, 11-15 기준)
1. **② FPGA 대응 RTL 수정** (`fpga/P6_FPGA_SYNTH.md`)
   - CPU 단독 FPU_ADDMUL_LAT 0/1/2 합성으로 Fmax 확인.
   - FPU 파이프라인(가속기 GEMV는 행 interleave로 1 MAC/cycle 유지), 버퍼 BRAM화(lane별 bank, 1R1W), VFU lane 면적 축소.
   - sim bit-exact 재확인(단위 테스트·E2E) → 재합성 → place & route → timing·면적.
   - 새 FPU 지연 기준으로 SW 기준선·가속비 재측정.
2. **선택 최적화** — ctx512 softmax(VFU) 비중, CPU 잔여 작업 overlap.
3. **검증 보강(선택)** — 다중 프롬프트, temperature·top-p sampling, expf 2³² 전수 비교.
4. **⑤ ZCU104 통합** — 대기. DDR latency·대역폭 실측으로 메모리 모델 보정.

## 미검증
- place & route 후 timing(합성 단계만 수행), 실제 DDR 수치(현재 가정값), 다중 프롬프트·sampling.

## 기록 위치
- 이 파일(`PROGRESS.md`): 현재 상태의 단일 원본 — 단계가 끝날 때마다 갱신.
- 단계별 상세: 위 표의 기록 파일.
- Notion(`업무 / LLM HW Architecture`): 승인된 결정·이력·교훈. 상태 표는 이 파일을 링크.
