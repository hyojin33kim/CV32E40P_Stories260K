# CV32E40P Stories260K — 진행 기록 (index)

목표: llama2.c Stories260K를 CV32E40P(RV32IMFC+FPU) RISC 단독으로 실행 → 대표 연산을 HW로 교체 →
**RISC-SW와 bit-exact**를 유지하며 가속 → ZCU104 통합.

기록 원칙: 구현·테스트 결과는 이 저장소(GitHub)가 최종 근거, 승인된 결정·이력은 Notion
(`업무 / LLM HW Architecture`). 수치는 모두 이 저장소의 실행 결과에서 옮긴 것.

**다른 모델(15M 등)에 적용할 때는 [`docs/PLAYBOOK.md`](docs/PLAYBOOK.md)부터 읽을 것** — 단계별 문제·결정·결과·함정·재현 명령·15M 체크리스트.

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
| v2 FPGA RTL | 11-15 | BRAM/LUTRAM 버퍼, FPU latency 4 파이프라인, **150 MHz 합성+P&R 충족(WNS +0.025 ns, LUT 21.4%)** | `fpga/P6_FPGA_SYNTH.md` | `fpga/reports_v2_soc` |
| S1 D2 기본화 | 11-15 | CPU/ACC/VFU FPU lat 4(D2)로 SW 기준선·전 단계 재측정, 전부 bit-exact. full offload ctx512 9.2×, E2E 512 **10.1×** | `prof/STAGE_PROFILE.md` | `prof/*_d2`, `gen/out_*_d2*` |
| S2 ZCU104 DDR 수치 | 11-15 | UG1267/PG201/UG1085 기반 모델 파라미터, 72조건 sweep bit-exact, 기본값 유지(RDISSUE ≥ 8 필요) | `acc/S2_ZCU104_DDR.md` | `acc/sweep/zcu104_acc_full_d2` |
| S3 Option A | 11-15 | exp2q(정수, 최대 1.34 ulp) softmax·SiLU + deferred normalization, RTL exp2 2³² 전수 일치, host 대비 512 토큰 동일. ctx512 **36.0×**, E2E 512 **31.5×**(DDR 29.2×), 150 MHz WNS +0.136 ns | `opta/S3_OPTA.md` | `prof/*_opta_d2`, `gen/out_*_opta*`, `fpga/reports_opta_soc` |
| S5a on-chip 메모리 RTL | 11-15 | imem 16 KB + SRAM 1 MB(KV·activation·control) RTL화(`soc_chip`), soc_top sim과 byte·cycle 동일 | `acc/S5_ONCHIP_MEM.md` | `prof/chip_*` |
| S5/S6 가중치 온칩 + 보드 top | 11-16~17 | 11-14 Decision대로 가중치 포함 2 MiB URAM, AXI4-Lite 보드 top(보드 흐름 sim byte 동일), **150 MHz P&R 충족(WNS +0.005 ns)**, Option A +0.2–0.3 % | `acc/S5_ONCHIP_MEM.md`, `fpga/P6_FPGA_SYNTH.md` | `fpga/reports_chip_axi_top`, `prof/chip_full_opta_d2` |
| 플레이북 | 11-17 | 15M 이후 적용용 정리 | `docs/PLAYBOOK.md` | — |
| P1-2 정밀도 관문 | 11-20 | host 실측(4 prompt × 512 step): int8 W/A(+KV) ≤ +0.003 nats/token(행 단위 scale도 충분), 무보정 int4 +0.10~0.18·argmax 82~85 %, int4 KV 불가. **통과 기준은 미결정(사용자)** | `docs/P1_REPORT.md` §1 | `quant/results/gate_512.json` |
| P1-3 DDR row/bank 모델 | 11-20 | 1차 모델(미검증): 단일 스트림 95.7 %(bank group 인터리브)/64 %(페이지 선형), 2 master 교대 128 B 24 %·8 KB 91 %·16 KB 94 %. sim.cpp DDR 모델은 변경 없음 | `docs/P1_REPORT.md` §2 | `ddr/ddr_model_results.md` |
| P1-4 CPU 잔여 | 11-20 | 측정: rmsnorm+RoPE+residual+기타 = ctx1 26.7 % / ctx128 19.3 % / ctx512 10.6 %. rmsnorm·residual VFU 이전 상한 3~8 % → **구현하지 않기를 권고**(단기 문맥 위주면 재검토) | `docs/P1_REPORT.md` §3 | `prof/chip_full_opta_d2.txt` |
| P1-1 보드 통합 | 11-20~21 | **125 MHz 비트스트림 생성 완료(보드 실행 전)**: Windows Vivado GUI에서 PS+칩 블록 디자인 합성·구현·bitgen 성공, WNS +0.320 ns / WHS +0.010 ns / 실패 0, LUT 55,775·URAM 64·DSP 85(OOC와 동일 규모). 스크립트(batch `-mode batch`) 경로는 프로젝트 합성 충돌로 6회 중 5회 실패, 원인 미발견. 150 MHz는 이 구성에서 미시험 | `fpga/bd/`, `docs/P1_REPORT.md` §4 | `E:/fpga_work/board_gui/.../board_wrapper.bit`(저장소 밖) | `fpga/bd/`, `docs/P1_REPORT.md` §4 | — |

## 현재 성능 (D2 = 150 MHz 실현 구성, 11-15; SW 기준선 = 같은 CPU(FPU lat 4)의 llama2.c `-O2 -funroll-loops`)
| | SW 기준선 cycles | full offload (원 수치) | 배율 | **Option A** | 배율 | Option A + DDR 모델 | 배율 |
|---|---:|---:|---:|---:|---:|---:|---:|
| single step ctx1 | 3,041,363 | 164,143 | 18.5× | **147,875** | 20.6× | 168,278 | 18.1× |
| single step ctx128 | 5,611,118 | 482,555 | 11.6× | **204,175** | 27.5× | 224,578 | 25.0× |
| single step ctx512 | 13,425,011 | 1,454,026 | 9.2× | **373,168** | 36.0× | 393,571 | 34.1× |
| E2E 64 step | 235,632,942 | 15,784,236 | 14.9× | **10,409,428** | 22.6× | 11,715,220 | 20.1× |
| E2E 512 step | 4,215,725,794 | 416,300,007 | 10.1× | **133,803,651** | 31.5× | 144,249,987 | 29.2× |

150 MHz에서 512 token: SW 28.1 s(18 tok/s) → Option A 0.89 s(574 tok/s). 원 수치 결과는 -Os SW와 bit-exact,
Option A 결과는 Option A SW(-Os)·host Option A 모델과 bit-exact. Option A 수치는 원 llama2.c 대비 512 토큰 동일,
logits rel L2 ≤ 3.4e-6.

### 이전 기준 (D1 ideal: FPU 지연 0, FPGA 비실현 — 이력)
| | SW 기준선 cycles | 이상 메모리 | 배율 | DDR 모델 | 배율 |
|---|---:|---:|---:|---:|---:|
| single step ctx1 | 1,454,871 | 121,501 | 11.97× | 141,694 | 10.27× |
| single step ctx128 | 3,039,674 | 284,733 | 10.68× | 304,926 | 9.97× |
| single step ctx512 | 7,854,556 | 779,756 | 10.07× | 799,949 | 9.82× |
| E2E 64 step | 118,431,746 | 10,444,536 | 11.34× | 11,736,888 | 10.09× |
| E2E 512 step | 2,383,853,770 | 231,415,107 | 10.30× | 241,753,923 | 9.86× |

DDR 모델: Weight는 DDR(latency 40, burst 16, 12.8 B/cycle, outstanding 8), KV·activation은 SRAM. 스윕 범위 ctx1 2.82×~11.77×.
**주의: FPU 지연 0(조합) 가정의 cycle 수.** FPGA 합성 결과 이 구성은 ~68 MHz(추정). 현재 기준은 위 D2 표.

## 사용자 결정 이력
| 날짜 | 결정 |
|---|---|
| 11-08 | FFN(W1/W3→SwiGLU→W2) 우선 가속, Weight는 외부 메모리에서 재로딩 (Notion) |
| 11-13 | 목표 FPGA ZCU104 / 동일성 = bit-exact / 성능 목표 없음 / FP32 우선 |
| 11-13 | 승인은 사용자만 아는 정보만 질문, 반복 yes/no 금지 |
| 11-14 | PL DDR 도터보드 미사용 → 보드 기본 메모리(해석: PS DDR4) / ⑤ ZCU104 통합 대기 |
| 11-14 | 순서: ④-b → MAC lane → 메모리 모델 현실화 |
| 11-15 | clock 150 MHz(CPU는 150 MHz 이하 허용, 합리적 수준), on-chip RAM은 BRAM/URAM 사용 필수 |
| 11-15 | Option A(table exp2 + deferred normalization, fully pipelined exp2) 채택 |
| 11-15 | 기본 구성 D2, 프롬프트 1종·greedy만, CPU inst/data·KV/activation SRAM RTL화, DDR 수치는 ZCU104 문서 기준 |

## 재현
`./reproduce.sh [quick|standard|full]` — 결과는 `repro/`, 커밋된 값과 비교(`reproduce_check.py`).
마지막 확인: 11-14 `standard` 29/29 OK (main `f46934d` 기준).

## 환경 메모
- RISC-V: apt gcc-riscv64-unknown-elf 13.2 + picolibc 1.8.6, Verilator 5.038 (WSL2 Ubuntu 24.04).
- Vivado: `~/bin/vivado`는 Windows Vivado 2026.1(`H:\2026.1\Vivado\bin\vivado.bat`) wrapper, `/mnt/<drive>` 아래에서만 실행.
  11-15 H: 연결 확인, `vivado v2026.1` 동작. 합성 작업 디렉토리 `E:\fpga_work\<run>` (`fpga/run_*.sh` 기본값, 다른 경로는 첫 인자로 지정).

## 기본 구성 (11-15 결정)
| 이름 | CPU/ACC/VFU FPU latency | RUN | 용도 |
|---|---|---|---|
| **D2 `fpga` (기본)** | 4 / 4 / 4 | 8 | 150 MHz에서 합성·P&R timing 충족한 구성(v2, WNS +0.025 ns). 모든 신규 수치의 기준 |
| D1 `ideal` | 0 / 0 / 0 | 16 | 이전 결과(~12×/10×) 재현·회귀용. FPGA 비실현 |

## 남은 일 (권장 순서, 11-15 기준) — 작업 브랜치 `worktree-g0-repro`, ✔에서 main merge
| 단계 | 내용 | merge |
|---|---|---|
| **S1** ✅ | v2 RTL D2 기준: CPU FPU lat4 sim, SW 기준선·전 offload 재측정(profile, E2E 64/512 ideal·DDR), bit-exact, D2 기본화, 기준값 재생성, reproduce | ✔ M1 |
| **S2** ✅ | ZCU104 문서(UG1267/UG1085) 기반 PS DDR4·HP port 수치 → 150 MHz 기준 DDR 모델 설정, 재sweep (latency는 추정 명시) | S1/S3와 함께 |
| **S3** ✅ | Option A: 고정소수점 exp2 C 모델+전수 정확도, 새 firmware 기준(4-way sum, deferred normalization, SiLU via exp2), host tolerance+512 token, VFU pipelined exp2 RTL+단위 테스트, E2E·profile·150 MHz 합성 | ✔ M2 |
| **S4** | 프롬프트 1종, greedy decoding 유지(11-15 결정 — 다중 프롬프트·sampling은 범위 밖) | — |
| **S5** (a ✅, b 미착수) | on-chip 메모리 RTL: CPU inst/data SRAM(BRAM/URAM), KV·activation SRAM(URAM), 가속기 SRAM port + weight용 DDR(AXI) port. sim은 DDR slave 모델만 | ✔ M4 |
| **S6** | 메모리 포함 full SoC 합성+P&R @150 MHz, E2E 재확인 | ✔ M5 |
| ⑤ | ZCU104 보드 통합 — 비트스트림(125 MHz) 완료, 보드 실행 대기(PYNQ 이미지·`pynq/run_chip.py` 미검증), 절차: `docs/BOARD_BRINGUP.md` | — |

## 미검증
- 실제 DDR 수치(현재 가정값 → S2에서 문서값, 보드 실측은 ⑤), on-chip 메모리 포함 timing·면적(S6).
- PS 연결 후 timing(OOC 마진 5 ps), 실제 보드 실행(블록 디자인·PYNQ 스크립트는 한 번도 실행되지 않음).
- Vivado xsim 전체 칩이 Verilator와 불일치(run_cycles 4,347,318 vs 4,501,912, FPU 단독 xsim 671/1402), 원인 미발견. Verilator가 기준.
- DDR row/bank 모델의 타이밍 값은 기억 기반이며 컨트롤러·보드와 대조하지 않음.
- 정밀도 관문은 fake-quantization(fp32 연산)이며 실제 정수 lane RTL이 아님. 보정(GPTQ 등) int4는 미시험.

## 기록 위치
- 이 파일(`PROGRESS.md`): 현재 상태의 단일 원본 — 단계가 끝날 때마다 갱신.
- 단계별 상세: 위 표의 기록 파일.
- Notion(`업무 / LLM HW Architecture`): 승인된 결정·이력·교훈. 상태 표는 이 파일을 링크.
