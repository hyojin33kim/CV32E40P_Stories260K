# `reproduce.sh quick`의 42개 항목

`./reproduce.sh quick`이 마지막에 출력하는 `42/42 OK`가 무엇을 센 것인지 정리한다. 근거는 `reproduce.sh`와 `reproduce_check.py`의 코드이고, 수치는 2026-11-28 실행(E17 RTL 변경 후, 원본 `docs/experiments/raw/repro_e17.out`)에서 가져왔다.

## 1. 한눈에

- 42는 **`reproduce_check.py`가 커밋된 기준값과 비교하는 항목 수**다. 시뮬레이션 시나리오 42가지가 아니다.
- 구성: 프로파일 11가지 구성 × 컨텍스트 3종 = **33** + 8스텝 생성 **6** + 기타 **3** = **42**.
- 출력에는 `OK` 줄이 60개 있다. 나머지 18개(HOLD 9 + 참조 파일 9)는 `reproduce.sh` 쉘이 직접 검사하고 출력한 것이며 42에 **포함되지 않는다**. 한 줄이라도 틀리면 `FAIL`이고 쉘 단계는 즉시 중단된다(`exit 1`).
- 모든 항목은 FPU 지연 4, MAC 레인 4, VFU 레인 4, RUN 8, FIFO 256인 기본 구성 D2(태그 `_d2`)에서 본다. 이 구성이 FPGA 실제 값이다.
- 판정 기준(`reproduce_check.py`): 사이클 수는 커밋된 값과 **0.01 % 이내**(`TOL = 1e-4`)이어야 하고, 통과/비트 일치 표식은 **완전히 같아야** 한다. 이번 실행은 모든 항목이 `delta +0`(사이클 수까지 정확히 같음)이었다.

## 2. 쉘 단계의 사전 검사 18개 (42에 포함되지 않음)

| 단계 | 개수 | 내용 |
|---|---|---|
| HOLD 회귀 | 9 | 저장된 HOLD 펌웨어(ELF)를 3개 시뮬레이터(`Vcv32e40p_top` 코어만, `Vsoc_top` 코어+가속기, `Vsoc_chip` 코어+가속기+imem+SRAM) × 컨텍스트 1, 128, 512로 실행. 2 MiB 메모리 덤프가 기준 `base_<t>.bin`과 바이트 단위로 같아야 함. 펌웨어 사이클 워드(0x1aff00)는 FPU 지연에 따라 달라서 제외 |
| 참조 C | 9 | 호스트 C 참조 `reference.c`(`-ffp-contract=off`, FMA 없음)를 새로 빌드해 실행한 `ref`, `kv`, `after_kv` × 1, 128, 512 파일이 커밋된 파일과 같음 |

## 3. 프로파일 33개: 11가지 구성 × 컨텍스트 3종

`prof/run_prof.py`가 **토큰 1개 forward 한 번**을 컨텍스트 위치 `pos0 = t-1`에서 실행한다(`t` = 1, 128, 512, 토큰 id 1). 골든 KV 캐시를 메모리에 미리 넣고 시작하므로 "컨텍스트가 t개 쌓인 상태의 한 스텝"이다. 이 시험이 측정하는 `fw_measured_cycles`는 그 한 스텝의 펌웨어 사이클 수다.

| 구성(태그) | 펌웨어 | 시뮬레이터 | ctx 1 | ctx 128 | ctx 512 |
|---|---|---|---|---|---|
| `O2u_d2` | baseline/firmware.c (HOLD 단일 스텝 부트 코드), 소프트웨어만, `-O2 -funroll-loops` | obj_prof(CPU 프로파일러 시뮬레이터) | 3,041,364 | 5,611,119 | 13,425,012 |
| `gen_O2u_d2` | gen/firmware_gen.c (생성기 펌웨어), 소프트웨어만, `-O2 -funroll-loops` | obj_prof | 3,041,363 | 5,611,118 | 13,425,011 |
| `acc_ffn_d2` | 위 + `USE_ACC`: FFN의 W1/W3/W2 GEMV를 `gemv_acc`로 | obj_soc(Vsoc_top) | 1,317,111 | 3,882,654 | 11,685,010 |
| `acc_attn_d2` | 위 + `USE_ACC_ATTN`: 어텐션 QK와 AV도 `gemv_acc`로 | obj_soc | 1,304,469 | 2,754,424 | 7,183,397 |
| `acc_all_d2` | 위 + `USE_ACC_VFU`: softmax와 SwiGLU를 `vfu`로 | obj_soc | 1,154,135 | 1,545,727 | 2,738,004 |
| `acc_full_d2` | 위 + `USE_ACC_MM`(Wq/Wk/Wv/Wo/LM head), `USE_ACC_VFU_DIV`(QK/sqrt(8)를 VFU softmax에 융합), `RMS_SRAM`(RMSNorm 가중치를 SRAM에), `EMB_WORDS`(임베딩 행을 워드 단위로 복사) | obj_soc | 164,143 | 482,555 | 1,454,026 |
| `ddr_full_d2` | acc_full과 같은 펌웨어, 메모리를 DDR/SRAM 모델로(`SIM_DDR=1`) | obj_soc, DDR 모델 | 184,546 | 502,958 | 1,474,429 |
| `gen_O2u_opta_d2` | gen_O2u + `OPTA`: Option A 수치(exp2q softmax/SiLU, 지연 정규화), 소프트웨어만 | obj_prof | 2,960,330 | 4,747,806 | 10,143,044 |
| `acc_full_opta_d2` | acc_full + `OPTA` | obj_soc | 147,875 | 204,175 | 373,168 |
| `ddr_full_opta_d2` | ddr_full + `OPTA` | obj_soc, DDR 모델 | 168,278 | 224,578 | 393,571 |
| `chip_full_opta_d2` | acc_full + `OPTA`, imem과 1 MB SRAM까지 RTL인 칩 시뮬레이터 | obj_chip(Vsoc_chip) | 148,262 | 205,082 | 373,795 |

**합격 조건(항목마다 두 가지 모두)**
1. 사이클 수가 `prof/<태그>/summary.json`(커밋됨)의 값과 0.01 % 이내.
2. 결과가 기준과 **비트 단위로 같음**. 비교 영역은 KV 캐시(0x100000 ~ 0x1a0000)와 출력 로짓(0x1a4a00 ~ 0x1a5200).
   - 일반 구성(태그에 `opta` 없음): 기준은 HOLD 덤프(`logits_kv_bitexact_vs_hold`). 출력의 `bit-exact vs HOLD True`.
   - Option A 구성(태그에 `opta`): 수치가 달라 HOLD와는 비교하지 않고 **소프트웨어만의 Option A 실행(`gen_O2u_opta_d2`)** 과 같은 두 영역이 비트 단위로 같아야 한다. 출력의 `bit-exact vs SW Option A True`.

이 33개가 보증하는 것: 가속기(GEMV, VFU)를 단계별로 켜도 소프트웨어와 같은 결과가 나오고, 각 구성의 사이클 수가 변하지 않았다. 위 표의 오프로드 단계가 올라갈수록 사이클이 줄어드는 것(ctx 1에서 약 304만 에서 약 16만)이 가속 효과이고, 이번 변경(RTL 타이밍 수정)이 그 사이클을 바꾸지 않았다는 것이 `delta +0`이다.

## 4. 8스텝 생성 6개

`gen/run_gen.py 8`이 프롬프트에서 **8토큰을 연속 생성**하고 호스트 llama2.c 골든과 비교한다. 위 프로파일과 달리 KV 캐시가 스텝마다 쌓이는 실제 생성이다. 태그의 `_L0_G1`은 가속기 메모리 지연 0, 승인 주기 1(이상적 메모리)이다.

| 항목 | 구성 | 총 사이클 | 비교값 |
|---|---|---|---|
| `out_8_O2u_accall_d2_L0_G1` | `-O2u`, GEN_ACC=all (+ softmax, SwiGLU를 VFU로) | 9,339,411 | pass True, vs -Os True |
| `out_8_O2u_accattn_d2_L0_G1` | `-O2u`, GEN_ACC=attn (FFN + 어텐션 가속) | 10,761,937 | pass True, vs -Os True |
| `out_8_O2u_accfull_d2_L0_G1` | `-O2u`, GEN_ACC=full (모든 matmul과 VFU 나눗셈 융합) | 1,399,103 | pass True, vs -Os True |
| `out_8_O2u_opta_accfull_d2_L0_G1` | Option A 수치 + GEN_ACC=full | 1,198,891 | pass True, vs -Os True |
| `out_8_Os_d2` | -Os 소프트웨어만. **이후 gen 항목들의 기준**(자기 자신이라 비교값이 None) | 36,692,796 | pass True, vs -Os None |
| `out_8_Os_opta_d2` | Option A 수치, -Os 소프트웨어만. **opta 계열의 기준** | 36,043,332 | pass True, vs -Os None |

**합격 조건**
- `pass`가 True. `run_gen.py`의 통과 기준: 스텝마다 로짓 상대 L2 < 1e-5, RISC-V 토큰이 자기 로짓의 argmax와 같음, 호스트 argmax와 다르면 근소 차(상위 2개 마진 < 1e-4)에서만 허용, KV 상대 L2 < 1e-5, 이후 스텝이 앞선 KV를 건드리지 않음.
- `-Os` 기준 실행과 로짓, KV, 토큰이 비트 단위로 같음(`bit-exact vs -Os`가 False가 아니면 통과. `None`은 기준 실행 자신).
- 총 사이클이 커밋된 `result.json`과 0.01 % 이내.

## 5. 기타 3개

| 항목 | 무엇을 비교하나 | 합격 조건 | 이번 값 |
|---|---|---|---|
| opta host accuracy | `opta/compare_host.py 512`: Option A 수치의 호스트 모델을 llama2.c와 512토큰 비교 | 자유 생성 토큰 일치율 = 1.0, 교사 강제 로짓 상대 L2 최대 < 1e-5 | 512 tokens match 1.000, rel L2 max 3.42e-06 |
| exp2 RTL vs C model | `acc/tb_exp2/run.sh bf000000 c0ffffff`: `vfu_exp2.sv` RTL을 C 모델 `opta/exp2q.h`와 비교. 입력 범위 [-8, -0.5](softmax 인자 범위)의 float 비트 패턴 전수 | 불일치 0 (줄 끝이 `0 mismatches`) | vfu_exp2: 33554432 inputs [bf000000..c0ffffff], 0 mismatches |
| vfu unit test | `vfu/run_test.py 1 4096`: expf, softmax, SiLU, 나눗셈, 나눗셈+softmax를 RISC-V 소프트웨어 결과와 비트 단위로 비교 | 모든 원소 일치(불일치 0) | 28,672 elements, 0 mismatches |

## 6. 42개가 보증하지 않는 것

| 영역 | 이 시험에서 | 다른 곳에서 |
|---|---|---|
| 보드 최상위 `chip_axi_top`(AXI 슬레이브, 제어 레지스터, 관찰 레지스터) | 쓰지 않음(`soc_chip`까지만) | `sim_axi.cpp`, `acc/tb_dbgregs`, `acc/tb_conc`, 보드 키트 |
| Debug Module, JTAG | 쓰지 않음 | `dbg/tb_dm/run.sh` |
| FPGA용 클럭 게이트 직결 파일(`fpga/cv32e40p_clock_gate_fpga.sv`) | 쓰지 않음(시뮬레이션은 래치 모델) | 합성 타이밍만 확인, 시뮬레이션과 보드는 미확인 |
| 타이밍, 합성, 배치배선 | 해당 없음 | `fpga/run_chip.sh` |
| Vivado xsim, 합성 후 네트리스트 | 해당 없음 | `fpga/xsim/` |
| 가속기 보호 장치(버퍼 한계 초과 거부) | 정상 사용에서 작동하지 않으므로 회귀가 불변인 것만 확인 | `acc/tb_conc` |
| 64, 512스텝 생성, DDR 지연 스윕 | `quick`에서는 하지 않음 | `standard`, `full` 모드 |
| 보드 실행 | 해당 없음 | 미실행 |

## 7. 모드별 항목 수 (코드에서 계산, `standard`와 `full`은 이번에 실행하지 않음)

| 모드 | 소요(스크립트 주석) | 추가되는 `gen` 항목 | 예상 총 항목 수 |
|---|---|---|---|
| `quick` | 약 8분(스크립트 주석). 11-26 실제 실행은 28분(docs/DEBUG_MODULE.md 기록) | 없음 | **42** (실행 확인) |
| `standard` | 약 30분 | 64스텝 11개 | 53 (계산) |
| `full` | 수 시간 | 512스텝 6개 추가(+ VFU 시험 확대, 스윕) | 59 (계산) |

## 8. 정정

2026-11-28 대화에서 "프로파일 14가지 구성, 44줄"이라고 말한 것은 틀렸다. 올바른 값은 프로파일 **11가지** 구성(33항목), 비교 항목 **42**, 쉘 사전 검사 18개를 더한 출력상의 `OK` 줄 **60**이다. 이 문서의 수치는 코드와 실행 출력에서 직접 센 것이다.
