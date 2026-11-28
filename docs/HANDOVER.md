# 프로젝트 인수인계 문서 (2026-11-28)

CV32E40P(RV32IMFC + FPU) 위에서 llama2.c Stories260K를 돌리고, GEMV와 VFU 가속기로 옮겨도 **RISC-V 소프트웨어 실행과 비트 단위로 같은 결과**를 유지하는 프로젝트다. 대상 보드는 ZCU104(XCZU7EV). FPGA는 ASIC의 전 단계로 본다.
표기: **측정** = 이 저장소의 명령이 낸 값, **계산**, **추정**, **미확인**. 상태는 이 문서가 아니라 `git log`와 `git status`, 시험 실행 결과가 최종 근거다.
새 Claude 세션용 요약은 `docs/HANDOFF_NEXT_SESSION.md`(이 문서와 겹치는 부분은 이 문서가 더 자세하다).

## 1. 현재 상태 한눈에
| 영역 | 상태 | 근거 |
|---|---|---|
| RTL 시뮬레이션(Verilator) | 모든 오프로드 단계가 소프트웨어와 비트 일치. `reproduce.sh quick` 42/42 | 11-28 실행, `docs/REPRODUCE_CHECKS.md` |
| 디버그 모듈(DM) + JTAG | 시뮬레이션에서 halt, 레지스터 읽기/쓰기, 단계 실행, 하드웨어 breakpoint 통과. 보드와 OpenOCD는 미확인 | `dbg/tb_dm`, `docs/DEBUG_MODULE.md` |
| 합성 타이밍(OOC, 120 MHz) | DM 포함 WNS +0.752 ns, DM 없음 +0.673 ns, 둘 다 통과 | E17 |
| 합성 타이밍(125 MHz, 보드용 PS 연결 GUI 구현) | WNS +0.100 ns, 통과(비트스트림 `board_release_125_int8`, **DM 없음**, 이후 RTL 변경 미반영) | V-M3 |
| 150 MHz | 이후 RTL에서 최선 -0.001 ns로 미달. 사용자가 불필요로 결정 | V-M4 |
| xsim(합성 후 전체 칩 네트리스트) | 막힘: xsim BASIC 라이선스 한도, Verilator 메모리(D4) | V-S1 |
| 보드 실행 | **한 번도 하지 않음**(보드 없음, D5) | - |
| 15M | 모델 파일 있음(저장소 루트, 추적 안 됨). 펌웨어 이식과 DDR 구조는 미착수 | `docs/DDR_ARCH_PLAN.md` |

검증 계획서: 항목 52개 중 통과 34, 부분 2, 미실행 14, 미정 1, 제외 1(`docs/VERIFICATION_PLAN.md`, 엑셀판 `.xlsx`).

## 2. 시스템 구조
```
CPU (cv32e40p-master) --- 데이터 포트 --- soc_chip 내부 버스 --- on-chip SRAM(URAM 64) + imem(BRAM 16 KB)
   |                                              |
   |-- MMIO 0x3000_0000: gemv_acc (GEMV)          +-- (DDR 구성) axi_ext_rd: 가중치 읽기 AXI4 마스터
   |-- MMIO 0x3000_0040: vfu (softmax, SiLU, 나눗셈)
   +-- 디버그: dm_obi_top + dmi_jtag (DM_BUILD일 때), 영역 0x1A11_0000
보드 최상위 chip_axi_top: soc_chip + AXI4-Lite 슬레이브(PS가 메모리 적재, RUN/DONE, 성능 카운터, 관찰 레지스터)
```
- 그림: `docs/figures/rtl_structure.png`, `sw_debug_structure.png`, `boot_stages.png`. 부팅 과정: `docs/BOOT_WALKTHROUGH.md`, 파형: `docs/SIM_HOWTO.md`.
- 가속기: `acc/gemv_acc.sv`(모드 A/B/C/D, 헤더 주석에 접근 방식 설명), `acc/vfu.sv`, `acc/vfu_lane.sv`, `acc/vfu_exp2.sv`. 둘 다 CPU의 FPU 모듈로 연산해 **연산 순서가 소프트웨어와 같다**(비트 일치의 근거).
- 메모리 맵 요약: 외부 가중치 창(DDR 구성) 0x0 ..., SRAM 1 MiB(DDR 구성) 또는 2 MiB(온칩 구성), imem 0x0100_0000(16 KB), 시뮬레이션 DONE 0x2000_0000, 출력 채널 0x2000_0010, GEMV 0x3000_0000, VFU 0x3000_0040. 보드 AXI 창의 레지스터: `acc/chip_axi_top.sv` 머리 주석.
- 하드웨어 보호(11-27): GEMV와 VFU가 버퍼 한계 초과나 동시 시작을 거부하고 STATUS bit1(sticky err)로 알린다. 펌웨어는 아직 bit1을 확인하지 않는다.
- 관찰 레지스터(0x200_0040~0x54): 출력 워드, 출력 횟수, 마지막 PC, 인출 횟수, trap 횟수와 PC. JTAG 없이 멈춘 위치를 본다.

## 3. 저장소 지도
| 경로 | 내용 |
|---|---|
| `cv32e40p-master/` | 코어 RTL(수정 최소) |
| `acc/` | 가속기와 칩 최상위(`soc_chip.sv`, `soc_top.sv`, `chip_axi_top.sv`, `chip_axi_ddr_top.sv`, `axi_ext_rd.sv`, `sram_dp.sv`), 시험 `tb_*`, 설계 노트 `P*_*.md`, `S*_*.md` |
| `dbg/` | RISC-V 디버그 모듈(riscv-dbg 643607e 부분 복사, `VENDOR.md`), `soc_chip_dm.sv`, `tb_dm/` |
| `fpga/` | 합성 스크립트(`prepare.py`, `synth.tcl`, `run_chip.sh`), `bd/`(블록 디자인), `xsim/`(Vivado 시뮬레이션), 합성 보고서 |
| `gen/`, `baseline/`, `prof/` | 생성기 펌웨어 `firmware_gen.c`, 기준 펌웨어, 프로파일(`run_prof.py`)과 결과 |
| `w8/`, `quant/` | int8 가중치 양자화와 시험 |
| `opta/` | Option A 수치(exp2q softmax, 지연 정규화) |
| `vfu/` | VFU 단위 시험 |
| `pynq/` | 보드 실행 스크립트와 키트 패키징(`pack_board_kit.sh`) |
| `docs/` | 모든 설명 문서(아래 5절), `experiments/`(실험 기록 데이터와 원본), `figures/`, `wave/`, `labs/` |
| 루트 | `build.sh`(펌웨어), `build_sim.sh`(시뮬레이터), `reproduce.sh`, `reproduce_check.py`, `sim*.cpp`, `reference.c`(호스트 기준), `stories260K.bin`, `stories15M.bin`(15M, 추적 안 됨) |

## 4. 환경
- 개발은 WSL2(Ubuntu 24.04) 리눅스. Verilator 5.038, RISC-V GCC 13.2(apt `gcc-riscv64-unknown-elf`)와 picolibc, Python3(numpy; 계획서 생성에는 openpyxl). 원래 기준값은 GCC 14.2로 만들어서 같은 소스라도 바이너리가 다르다(.text 2,708 대 2,676 바이트). `reproduce.sh`는 기준값과 사이클 0.01 % 이내로 비교한다.
- 합성은 **Windows 호스트의 Vivado 2026.1**을 리눅스에서 `~/bin/vivado`(cmd.exe 경유)로 부른다. 작업 폴더는 `/mnt/e/fpga_work/`. 환경변수는 Windows로 전달되지 않는다(plusargs 파일을 쓸 것, R13).
- 호스트 메모리: 합성 최대 약 13 GB. 호스트 가용 메모리가 5 GB대이면 라우터가 메모리 부족으로 실패했다. 한 번에 합성 하나만 돌리고 `.scratch/run_syn_retry.sh`처럼 멈춤(25분 무출력)과 크래시를 감지하는 래퍼를 쓴다(`.scratch`는 추적되지 않음, 필요하면 스크립트를 `fpga/`로 올릴 것).
- 보드용 비트스트림 구현은 Windows Vivado GUI에서 사용자가 한다(스크립트 경로는 불안정). 보드 PC(PYNQ)는 회사에 있다.

## 5. 자주 쓰는 명령
| 목적 | 명령 | 소요 |
|---|---|---|
| 시뮬레이터 빌드 | `TOP=soc_chip ./build_sim.sh` (또는 `soc_top`, `chip_axi_top`, `chip_axi_ddr_top`) | 수 분 |
| 회귀 | `./reproduce.sh quick` | 11-26 실행 28분(스크립트 주석 8분은 오래된 값) |
| DM 시험 | `dbg/tb_dm/run.sh prof/chip_full_opta_d2/image_1.bin prof/chip_full_opta_d2/dump_1.bin <작업폴더> +HALTS=6 +FIRST=20000 +STEP=22000` | 수 분 |
| 동시 접근, 보호 시험 | `python3 acc/tb_conc/run_test.py`, `python3 acc/tb_dbgregs/run_test.py` | 수 분 |
| 합성(OOC) | `[DM=1] PERIOD=8.333 fpga/run_chip.sh <작업폴더> [DM_BUILD]` | 약 20~40분 |
| Vivado xsim | `fpga/xsim/run_xsim.sh`, `fpga/xsim/README_LINUX.md` | 시간 상한을 두고 실행(E13) |
| 계획서와 실험 기록 재생성 | `python3 docs/gen_verification_plan.py` | 초 |
| 원본 보관 | `python3 docs/experiments/archive_raw.py` | 초 |
- 새 시험을 추가할 때: 계획서 행(`docs/gen_verification_plan.py`)과 실험 기록(`docs/experiments/experiment_log_data.py`)을 같이 고치고 원본을 보관한 뒤 시험과 같은 커밋에 넣는다.

## 6. 문서 안내
| 문서 | 용도 |
|---|---|
| `docs/PLAYBOOK.md` | 다른 모델(15M 이상)에 적용하는 절차와 게이트 |
| `docs/DDR_ARCH_PLAN.md` | **다음 작업**: DDR 중심 구조의 설계와 단계 P0~P6 |
| `docs/VERIFICATION_PLAN.md`(.xlsx), `docs/EXPERIMENT_LOG.md` | 검증 항목, 실험 기록 E01~E17, 판단 정정 이력 |
| `docs/LESSONS_LEARNED.md` | 규칙 R1~R14(시간 낭비 원인과 방지) |
| `docs/DEBUG_MODULE.md`, `DEBUG_CHIP_LEVEL.md`, `BOARD_ILA.md` | 디버그 모듈, 보드 디버깅 요구, ILA |
| `docs/BOARD_BRINGUP.md`, `P1_REPORT.md` | 보드 비트스트림과 실행 절차(보드 실행은 아직 안 함) |
| `docs/15M_ADDRESS_MAP.md`, `NPU_SCALING.md` | 15M 크기 계산, NPU 확장 분석 |
| `docs/LEARNING_PATH.md`, `LEARNING_LABS.md`, `SIM_HOWTO.md` | 학습 경로와 실습(RISC-V 도구 흐름과 칩 수준) |
| `docs/REPRODUCE_CHECKS.md` | 회귀 42개 항목의 의미 |
| `README.md`, `PROGRESS.md`, `CHECKPOINT_KO.md` | 개요와 이력(README의 150 MHz 상태 줄은 이후 결과와 어긋나 있음: 아래 8절) |

## 7. 결정 이력 (요약, 전체는 계획서 6절)
| ID | 결정 | 상태 |
|---|---|---|
| D1 | int8 합격 기준 nll_delta ≤0.01, argmax ≥0.97 | 제안 상태, 미확정 |
| D2 | 15M 범위(임베딩 int8 조회, KV 위치, 주소 맵) | 미정(D9가 방향을 정함) |
| D3 | rd_ok 인라인 수정 | 결정함(11-27), xsim에서 효과 확인 |
| D4 | 합성 후 전체 칩 시뮬레이션 | 막힘(라이선스, 메모리). 회사 서버의 xsim 라이선스, 또는 Verilator 키트 `fpga/xsim/net_verilator/` 사용 가능, 선택 대기 |
| D5 | 보드 확보와 PYNQ 이미지 | 미정(보드 없음) |
| D6 | 커버리지, 어서션, 형식 검증 | 미정 |
| D7 | 보호 장치와 오류 정책 | 결정함(11-27) |
| D8 | JTAG을 PS EMIO GPIO로 구동(OpenOCD on PYNQ) | 결정함(11-28), 구현 전 |
| D9 | DDR 중심 구조(가중치와 KV는 DDR, 칩 안 RAM은 CPU용 최소) | 결정함(11-28), P0 준비 중 |
- 클럭: 120 MHz로 양보(150 MHz 불필요, 사용자 결정). 최대 클럭은 측정하지 않았다(스윕 중단).
- 원칙(사용자): 실제 칩을 염두에 두고 **FPGA 전용 요소(BSCANE2, BUFGCE)는 넣지 않고, 디버그 모듈은 필수**로 둔다.

## 8. 열린 항목과 우선순위
1. **DDR 구조 P0**: `python3 acc/tb_kvddr/run_test.py`가 펌웨어 빌드에서 실패한다(`build.sh`의 오류 메시지를 아직 읽지 않았다). 고친 뒤 8가지 구성(DDR 배치 2 × 컨텍스트 2 + 칩 안 기준)의 사이클과 버스트 통계를 얻어 KV 레이아웃(헤드별 연속) 가설을 확인한다. 이어서 P1 쓰기 경로.
2. **15M 준비(P4)**: `stories15M.bin`(60,816,028 바이트, SHA-256 `cd590644d963867a2b6e5a1107f51fad663c41d79c149fbecbbb1f95fa81f49a`, 헤더: dim 288, hidden 768, 층 6, 헤드 6, KV 헤드 6, vocab 32,000, seq 256)이 저장소 루트에 있다. 이 해시를 공개된 값과 대조하지는 않았다. 토크나이저 확보, int8 양자화, 호스트 기준 출력, D1 확정이 필요하다. 커밋하지 말 것(60 MB). `stories15M.bin:Zone.Identifier`는 Windows 다운로드 표식이라 지워도 된다.
3. **DM 포함 비트스트림**(Vivado GUI, 사용자 작업)과 **D8 구현**(블록 디자인에 EMIO GPIO 추가). 보드가 있어야 확인 가능.
4. **직결한 클럭 게이트**의 시뮬레이션 확인(Verilator는 래치 모델을 쓴다). xsim 또는 보드.
5. **합성 후 시뮬레이션 D4**: 회사 서버 xsim 또는 Verilator 네트리스트 키트(157,433사이클, 덤프 일치까지 RTL에서 검증된 드라이버가 있음).
6. 펌웨어가 GEMV와 VFU의 STATUS bit1(err)를 확인하도록 하는 것, CPU 고정 구간(약 6.4만 사이클) 함수별 프로파일.
7. 최대 클럭 스윕(143, 133, 150 MHz): 새 최악 경로는 VFU의 FPU 내부이고 120 MHz에서 여유 +0.673~0.752 ns. 중단했고 결과 없음.
8. 문서 정리: `README.md`의 150 MHz 통과 문구는 이전 RTL의 결과(+0.005 ns)이고 이후 RTL에서는 미달이다. 계획서의 미실행 14개 목록은 `docs/VERIFICATION_PLAN.md`.

## 9. 알려진 함정과 교훈
- **Vivado 호스트 메모리**: 최대 약 13 GB. 부족하면 멈춤, 라우터 메모리 부족, `EXCEPTION_ACCESS_VIOLATION`이 간헐적으로 난다. 합성은 하나씩, 다른 큰 프로그램을 닫고 실행한다. 페이지 파일을 SSD로 옮기는 안이 있다(미시행).
- **환경변수가 Windows Vivado에 전달되지 않는다**: xsim의 `MAXCYC`가 적용되지 않아 3시간을 잃었다(R13). plusargs 파일을 쓴다.
- **xsim의 함수 인자 `rd_ok` 문제**: 인라인으로 고쳤고 FPU 표 패치(`xsim_workaround.py`)가 별도로 필요하다. xsim과 Verilator는 다르게 동작할 수 있다(`docs/XSIM_VS_VERILATOR.md`).
- **긴 작업에는 시계 시간 상한과 진행 출력을 둘 것**, 대기 스크립트는 크래시와 멈춤을 감지할 것(R14). "OK" 판정은 새로 생긴 산출물(`timing_route.rpt`)로 한다.
- **FMA 금지(`-ffp-contract=off`)**: 비트 일치의 전제다. 호스트 기준도 같은 옵션으로 빌드한다.
- 쉘: `pkill -f 패턴`은 자기 명령까지 종료시키므로 PID로 종료한다.
- **지금 결과를 한 번의 통과로 보지 말 것**: 합성은 배치에 따라 달라진다(같은 RTL에서 DM 유무로 WNS가 크게 변한 적 있음).

## 10. 첫 주 체크리스트
1. `git log --oneline -10`, `git status`로 상태 확인. 브랜치 `verification-followup`이 `main`보다 앞서 있고 푸시되어 있다. PR 여부와 병합은 소유자가 한다(PR 상태는 확인하지 않았다).
2. `./reproduce.sh quick`을 한 번 실행해 환경을 확인(42/42, 사이클 변화 +0이 나와야 한다).
3. `docs/DDR_ARCH_PLAN.md`를 읽고 P0 시험 빌드 오류부터 해결.
4. `docs/LESSONS_LEARNED.md`의 R1~R14와 `docs/VERIFICATION_PLAN.md` 7절 실행 규칙을 읽는다.
5. 사용자와 확정할 것: D1(int8 기준), D2의 범위, 15M 토크나이저 확보 경로, 보드 확보(D5)와 JTAG 연결(D8).

## 11. 기록 원칙
- 결정, 근거, 교훈은 Notion에, 구현 코드와 시험 결과는 GitHub에 둔다(최종 근거는 GitHub). Notion에는 초안 페이지가 개인 공간에 만들어져 있다(칩 수준 디버깅 요구, NPU 확장, 학습 경로, 실습). 이 인수인계 문서는 Notion에 올리지 않았다.
