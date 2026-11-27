# 검증 계획서 (Verification Plan)

이 파일은 `docs/gen_verification_plan.py`가 생성한다(데이터 원본은 그 스크립트). 같은 내용이 `docs/VERIFICATION_PLAN.xlsx`에 있다. 직접 고치지 말고 스크립트를 고친 뒤 다시 실행한다.

"통과"는 **시뮬레이션 또는 합성 보고서에서 통과**했다는 뜻이다. **보드에서는 아무것도 실행하지 않았다.**

## 1. 요약

전체 52개: 통과 33, 부분 3, 미실행 14, 미정 1, 제외 1

| 단계 | 통과 | 부분 | 미실행 | 미정 | 제외 |
|---|---|---|---|---|---|
| L0 도구 점검 | 3 | 0 | 0 | 0 | 0 |
| L1 단위 | 6 | 0 | 0 | 0 | 0 |
| L2 통합 | 11 | 0 | 1 | 1 | 0 |
| L3 타이밍 | 3 | 0 | 0 | 0 | 1 |
| L4 합성 후 | 0 | 0 | 1 | 0 | 0 |
| L5 보드 | 0 | 1 | 5 | 0 | 0 |
| 격차 | 10 | 2 | 7 | 0 | 0 |

## 2. 게이트

| 게이트 | 조건 | 현재 |
|---|---|---|
| Gate A: 시뮬레이션 완료 | L0~L2 전 항목 통과, quick 42/42, xsim 일치 | 대부분 통과. V-U2, V-P3 부분/미실행, V-N1 기준 미정 |
| Gate B: 합성 후 확인 | V-M1~M3 통과 + V-S1 통과 | V-M 통과, V-S1 미실행 |
| Gate C: 보드 확인 | V-B0~B5 통과(DONE_V, CYCLES, 2 MiB 덤프 일치) | 미실행 |

## 3. 검증 항목 (단계별)

### L0 도구 점검

| ID | 분류 | 점검 항목 | 방법 / 자극 | 합격 기준 | 실행 위치 | 상태 | 근거 | 비고 |
|---|---|---|---|---|---|---|---|---|
| V-T1 | 도구 | xsim 신뢰도 점검(FPU) | 3,896 벡터(정상 범위 + SUB/F2I/비교 + 경계값, numpy IEEE와 RISC-V 규칙 기준)를 FPU RTL과 합성 네트리스트에 입력 | 3,896/3,896 일치 | fpga/xsim/run_fpu_test.sh, run_fpu_verilator.sh | 통과 | 우회 패치 후 xsim RTL 3896/3896, 네트리스트 3896/3896, Verilator RTL 3896/3896 (11-22의 1,402개 벡터는 패치 전 671/1402) | xsim 결과를 믿기 전에 매번 먼저 실행(LESSONS_LEARNED C단계) |
| V-T2 | 도구 | 시뮬레이션 환경 빌드 | CPU, CPU 프로파일러, SoC 시뮬레이터 빌드 | 빌드 성공 | reproduce.sh 첫 단계 | 통과 | reproduce.sh quick 42/42 | Ubuntu 24.04, verilator 5.038, riscv64 gcc + picolibc |
| V-T3 | 도구 | 시험이 틀림을 잡는지(변이 시험) | 기대값 또는 RTL을 일부러 훼손한 뒤 단위 시험 실행 | 불일치가 검출됨 | w8/test_w8_gemv.c, w8/run_test_w8.py | 통과 | 불일치 1,019건 검출 | 새 단위 시험을 추가할 때마다 반복 |

### L1 단위

| ID | 분류 | 점검 항목 | 방법 / 자극 | 합격 기준 | 실행 위치 | 상태 | 근거 | 비고 |
|---|---|---|---|---|---|---|---|---|
| V-U1 | RTL | VFU(expf, softmax, SiLU, 나눗셈, 나눗셈+softmax) | RISC-V 소프트웨어 결과와 비교. 7개 명령 전부, softmax 계열 벡터 길이 1, 2, 8, 512와 무작위 1~512 포함. 규모는 quick/standard/full로 선택 | 비트 단위 일치 | vfu/run_test.py (reproduce.sh) | 통과 | PR #3 기록: 1.31M 벡터 불일치 0 | quick은 작은 규모만 재실행. 이번 세션에서 1.31M을 다시 돌리지는 않음 |
| V-U2 | RTL | exp2 RTL vs C 모델 (입력 전체 2^32) | vfu_exp2의 32비트 입력 패턴 전부(inf, NaN 포함, 4,294,967,296개)를 한 cycle에 하나씩 넣고 5 cycle 뒤 출력을 C 모델 exp2q_bits와 비트 비교 | 불일치 0 | acc/tb_exp2/run.sh (Verilator), opta/exp2q.h | 통과 | 4개 구간(0x00000000~0x3fffffff, 0x40000000~0x7fffffff, 0x80000000~0xbfffffff, 0xc0000000~0xffffffff) 모두 1,073,741,824개 불일치 0, 합계 4,294,967,296개(구간당 약 1분 15초) | C 모델과의 일치이며, 모델이 수학적 2^y에 얼마나 가까운지(정확도)는 별개(opta/test_exp2q.c, reproduce.sh의 exp2_accuracy.txt). 입력을 연속으로 넣는 경우만 시험(정지, 리셋 중간은 아님). vfu_exp2 단독이며 VFU 안에서 앞단과 연결된 경우는 V-U1이 확인. 실험 E12 |
| V-U3 | RTL | GEMV 모드 D(int8 가중치, 행별 scale) 무작위 시험 | 무작위 행렬과 scale, 모드 D 실행 후 C 기준과 비교 | 불일치 0 | w8/test_w8_gemv.c, w8/run_test_w8.py | 통과 | 366건 불일치 0 (이어서 355건, 14건 추가 시험) | fmul+fadd, FMA 미사용 기준 |
| V-U4 | RTL | 15M 크기 GEMV(버퍼 1024) | 15M 모델 행렬 크기로 GEMV 실행 | 일치 | w8/test_w8_gemv.c (BIGLAYOUT) | 통과 | 기록된 세션 결과 | 15M 전체 모델이 아니라 GEMV 한 형태만 확인 |
| V-U5 | RTL | pre-tiled 가중치 모드(CTRL bit2) | w8/pretile.py로 재배열한 가중치로 모드 A, D 실행 | 일치 | w8/test_w8_gemv.c (tiled run), w8/pretile.py | 통과 | 기록된 세션 결과 | DDR top에서의 버스트 효과는 V-P3 |
| V-U6 | RTL | AXI 외부 읽기 master(axi_ext_rd) | DDR top 시뮬레이션으로 가중치를 DDR에서 읽음(지연 있는 메모리 모델) | 온칩 결과와 바이트 동일 | sim_axi_ddr.cpp, acc/S5B_DDR_AXI.md | 통과 | 8/64 토큰 동일 | 단독 단위 시험이 아니라 DDR top 통합 시험으로 확인 |

### L2 통합

| ID | 분류 | 점검 항목 | 방법 / 자극 | 합격 기준 | 실행 위치 | 상태 | 근거 | 비고 |
|---|---|---|---|---|---|---|---|---|
| V-I1 | RISC-V | G0 HOLD 회귀 | 저장된 ELF를 ctx 1/128/512로 CPU sim, SoC sim, chip sim 3곳에서 실행 | 덤프가 기준과 바이트 동일(cycle 워드 제외) | reproduce.sh G0 단계 | 통과 | 9건 OK (quick 42/42에 포함) | RTL을 바꿀 때마다 실행 |
| V-I2 | RISC-V | 호스트 기준 C vs llama2.c | llama2.c와 512 step 정확도 비교 | 정확도 일치 | reproduce.sh Option A | 통과 | reproduce.sh quick 42/42에 포함 | 이번 세션에서 개별 수치 재확인은 안 함 |
| V-I3 | RISC-V | 단일 step 프로파일 | SW 기준과 오프로딩 단계별 cycle 및 결과 | 결과 일치 | reproduce.sh 프로파일 단계 | 통과 | quick 42/42에 포함 |  |
| V-I4 | RISC-V | E2E 생성 | 8 step(quick), 64 step(standard), 512 step(full) | 토큰과 덤프가 기준과 일치 | reproduce.sh quick/standard/full | 통과 | 8 step quick 포함, 512 step 기록 10.29x(PR #3) | 512 step은 수 시간이라 이번에 재실행 안 함 |
| V-I5 | 수치 | int8 경로 비트 일치(host = RISC-V = GEMV) | 8, 64 토큰 생성 후 세 구현 비교 | 비트 일치 | w8/, gen/run_gen.py (W8=1) | 통과 | 8/64 토큰 일치 |  |
| V-I6 | RTL | DDR top vs 온칩 top | 같은 이미지를 두 top에서 실행 | 덤프 바이트 동일 | sim_axi_ddr.cpp (chip_axi_ddr_top) | 통과 | 8/64 토큰 동일 | 지연 모델과 row/bank 모델 포함 |
| V-I7 | 보드 흐름 | PS 역할 시뮬레이션 | AXI4-Lite 레지스터 + AXI4 메모리 모델로 보드 흐름 재현 | 결과와 CYCLES 일치 | sim_axi.cpp, sim_axi_ddr.cpp | 통과 | 시뮬레이션 일치 | 실제 PS/PYNQ는 아님 |
| V-I8 | RTL | xsim 전체 칩 vs Verilator | XPM URAM과 UNISIM 모델로 전체 칩을 xsim에서 실행 | 2 MiB 덤프 일치, DONE 도달 | fpga/xsim/run_xsim.sh | 통과 | run_cycles 157,433 (sim.cpp 157,437), 덤프 일치 | 작업 복사본 우회 패치 2건 필요(docs/XSIM_VS_VERILATOR.md) |
| V-I9 | 전체 | 빠른 회귀 reproduce.sh quick | 42개 항목 일괄 | 42/42 OK | reproduce.sh quick | 통과 | RTL 변경마다 42/42 | 11-26: acc/chip_axi_top.sv에 DBG_PROBE(기본 0) 추가 후 42/42 OK(약 36분, raw/repro_dbgprobe.out); 이어서 soc_top, soc_chip, chip_axi_top에 디버그 모듈 연결(DM_EN 기본 0, DM_BUILD 없음) 후 42/42 OK(약 28분, 실패 0건, raw/repro_dm.out). 11-25 병합 상태에서도 42/42 |
| V-N1 | 수치 | int8 정확도 | fp32 대비 nll과 argmax 일치율 측정 | 제안: nll_delta ≤0.01, argmax ≥0.97 | w8/eval_w8.py, quant/ | 미정 | 측정 nll_delta +0.0023, argmax 0.987 | 합격 기준은 사용자 결정 대기 |
| V-P1 | 성능 | 성능 카운터(gemv busy, vfu busy, acc stall, 읽은 line, tq_full, eq_max) | 카운터 레지스터 읽기 | 값이 시뮬레이션 모델과 일치 | acc/chip_axi_top.sv (0x200_0020..0x34) | 통과 | 구현과 시뮬레이션 확인 | 보드에서의 읽기는 미실행 |
| V-P2 | 성능 | DRAM 지연과 row/bank 영향 | SIM_ROWBANK=1 (page, map, core MHz 환경변수) | 영향을 정량화 | sim_axi_ddr.cpp | 통과 | 단일 타일 영향 2% 이하 | 두 master가 동시에 접근하는 경우는 미시험 |
| V-P3 | 성능 | pre-tiling의 DDR top 실측 | AXI_MAXB 64/256으로 빌드해 버스트 길이 효과 측정 | 버스트 6~8 line에서 늘어남 확인 | build_sim.sh (AXI_MAXB) | 미실행 | 버스트 통계만 계산됨(6~8 line에서 최대 256) | AXI_MAXB를 늘릴 때 CRED ≥ MAXB와 외부 FIFO(64 line) 한도를 함께 키워야 함(V-A2에서 확인) |

### L3 타이밍

| ID | 분류 | 점검 항목 | 방법 / 자극 | 합격 기준 | 실행 위치 | 상태 | 근거 | 비고 |
|---|---|---|---|---|---|---|---|---|
| V-M1 | 타이밍 | 온칩 top 125 MHz (OOC) | fpga/run_chip.sh 단독 배치 합성 | WNS ≥ 0 | fpga/run_chip.sh | 통과 | WNS +0.249 ns |  |
| V-M2 | 타이밍 | DDR top 125 MHz (OOC) | int8 모드 + 외부 FIFO 포함 | WNS ≥ 0 | fpga/run_chip.sh (WITH_DDR=1) | 통과 | WNS +0.155 ns |  |
| V-M3 | 타이밍 | PS 연결 비트스트림 125 MHz | Vivado GUI에서 구현 후 보고서 확인 | WNS, WHS ≥ 0 | E:/fpga_work/board_release_125_int8/ | 통과 | WNS +0.100, WHS +0.008, WPWS 2.5, LUT 60,179, URAM 64, DSP 93 | 사용자가 GUI에서 구현. 스크립트 경로는 불안정 |
| V-M4 | 타이밍 | 150 MHz | OOC 반복 합성 | WNS ≥ 0 | fpga/run_chip.sh | 제외 | 최선 −0.001 ns, 미달 | 사용자가 150 MHz 불필요로 결정 |

### L4 합성 후

| ID | 분류 | 점검 항목 | 방법 / 자극 | 합격 기준 | 실행 위치 | 상태 | 근거 | 비고 |
|---|---|---|---|---|---|---|---|---|
| V-S1 | RTL | 합성 후 전체 칩 네트리스트 기능 시뮬레이션 | soc_chip 합성(fpga/synth.tcl의 NETLIST 토큰)으로 기능 네트리스트를 만들어 같은 이미지에 실행하고 덤프 비교 | 덤프 일치, DONE 도달 | fpga/xsim/run_xsim_net.sh, fpga/xsim/net_verilator/ | 미실행 | 합성은 완료(5분 45초, 네트리스트 45 MB, LUT 60,189, URAM 64, DSP 93). xsim은 시작 못 함: BASIC 라이선스의 인스턴스 한도 50,000개 < 네트리스트 107,091개. Verilator도 막힘: 변환만으로 6.5 GB 이상(호스트 7.9 GB)이고 10분 넘게 끝나지 않아 중단. FPU 단위만 네트리스트로 확인(3,896/3,896) | 막힌 이유와 선택지는 결정 D4. 11-26: 회사 Linux 서버에서 Verilator로 실행하기로 함. 준비 완료(fpga/xsim/net_verilator/: net_sim.cpp 포트 드라이버를 RTL soc_chip에서 시험해 run_cycles=157,433, 덤프 일치 확인, pack_handoff.sh로 묶음 5 MB, run_net_vl.sh). 네트리스트 변환 자체는 이 PC에서 돌리지 못해 미확인(README.md 참조). 하드웨어가 Verilator와 같다는 근거를 보강하는 가장 큰 빈칸으로 남음. 실험 E11 |

### L5 보드

| ID | 분류 | 점검 항목 | 방법 / 자극 | 합격 기준 | 실행 위치 | 상태 | 근거 | 비고 |
|---|---|---|---|---|---|---|---|---|
| V-B0 | 보드 | 보드 준비 | bit와 hwh 이름 정리, 기준 덤프 생성, SHA256 기록 | 파일과 체크섬 목록 | docs/BOARD_BRINGUP.md 3절 step 0 | 부분 |  | 11-26: 묶음 폴더 준비(pynq/pack_board_kit.sh -> /mnt/e/fpga_work/board_kit: bit, hwh, run_chip.py, image_1/128/512, Verilator 기준 덤프, SHA256SUMS; 기준 DONE 157,437 / 214,257 / 382,970 cycle, 저장된 덤프와 일치). 확인 필요: (1) bit는 커밋 d3b41bf에서 빌드, 이후 acc/gemv_acc.sv와 soc_top.sv가 바뀜(CTRL bit2 tiled, 버퍼 파라미터; 기본값에서 동작 동일하다고 읽었으나 해당 bit로 증명하지 않음), (2) .hwh가 .bit와 같은 블록 디자인에서 나왔는지, (3) docs/BOARD_BRINGUP.md 0, 3, 4절은 11-26에 정정함(image_N은 문맥 길이 N에서 한 단계이며 image_512는 382,970 cycle, 이전 문서의 512토큰 약 4.5M cycle은 다른 실행) |
| V-B1 | 보드 | PYNQ 부팅과 오버레이 | Overlay("board.bit"), ip_dict 확인, base 0xA000_0000, PL 125 MHz | 오류 없이 로드 | docs/BOARD_BRINGUP.md step 1 | 미실행 |  | 보드와 PYNQ 이미지 확보 필요 |
| V-B2 | 보드 | AXI 경로만(CTRL=0) | SRAM과 imem에 패턴을 쓰고 읽기 | 읽은 값이 쓴 값과 동일 | docs/BOARD_BRINGUP.md step 2 | 미실행 |  |  |
| V-B3 | 보드 | image_1 실행(문맥 길이 1에서 한 단계) | python3 run_chip.py board.bit image_1.bin dump_sim_1.bin | 2 MiB 덤프 바이트 동일, DONE_V 동일, CYCLES는 시뮬레이터 값(157,437과 157,433)과 나란히 기록 | pynq/run_chip.py | 미실행 |  | run_chip.py는 한 번도 실행된 적 없음 |
| V-B4 | 보드 | image_128과 image_512 실행(문맥 길이 128, 512에서 한 단계) | sim.cpp 기준 214,257과 382,970 cycle(125 MHz에서 약 1.7 ms와 3.1 ms, 계산값) | 위와 같은 세 가지 기준 | docs/BOARD_BRINGUP.md step 4 | 미실행 |  |  |
| V-B5 | 보드 | 결과 기록 | cycle, 시간, 일치 여부를 PROGRESS.md와 P1_REPORT.md에 반영 | 문서 갱신 | docs/BOARD_BRINGUP.md step 5 | 미실행 |  |  |

### 격차

| ID | 분류 | 점검 항목 | 방법 / 자극 | 합격 기준 | 실행 위치 | 상태 | 근거 | 비고 |
|---|---|---|---|---|---|---|---|---|
| V-G1 | RTL | `assign` 안에서 함수가 인자가 아닌 변수를 읽는 패턴 전수 탐색 | 프로젝트 RTL(acc/*.sv)의 모든 function을 읽어 본문이 읽는 신호와 호출 위치(assign, always_comb, always_ff)를 확인 | 해당 패턴 없음 또는 인자화 | acc/gemv_acc.sv, acc/vfu.sv | 부분 | function 4개 중 nact(상수 LL만), i8_to_f32, fgt는 인자와 지역 변수만 읽는 순수 함수이고 always_comb 또는 always_ff에서 호출. rd_ok만 rd_v_q, rd_st_q, rd_elem_q를 읽고 assign 3곳(sum_in, x_req, max_go)에서 호출됨 | 패턴이 rd_ok 한 곳에 남아 있음(수정 여부는 D3). 벤더 코드(cv32e40p, fpnew, common_cells)의 함수는 소스를 전수 읽지 않았고, xsim 전체 칩이 Verilator와 일치한 것(E04)으로 동적 확인된 상태 |
| V-G2 | RTL | 저장소 RTL의 `rd_ok` 수정 여부 | 인자로 넘기거나 인라인한 뒤 회귀와 재합성 확인 | reproduce quick 42/42 + 타이밍 영향 없음 | acc/vfu.sv | 부분 | 11-27 rd_ok를 저장소 RTL에서 인라인함. reproduce.sh quick 42/42 OK, xsim(FPU 표 패치만)이 끝까지 가서 157,433 cycle, 덤프 Verilator와 동일(수정 전에는 멈춤) | 타이밍 영향은 120 MHz 합성의 배치배선 결과 대기(호스트 메모리 부족으로 두 번 실패, 재시도 중, E16). 함수 형태(인자 전달)는 xsim 구문 오류로 불가, 직접 인라인으로 구현 |
| V-G3 | RTL | 커버리지, 어서션, 형식 검증 |  |  |  | 미실행 | 현재 사용하지 않음 | 도입 여부는 별도 결정 |
| V-G4 | RISC-V | 15M 모델용 펌웨어와 RTL 주소 일반화 | 15M 주소 맵대로 펌웨어와 RTL 파라미터 수정 | 15M 시뮬레이션 통과 | docs/15M_ADDRESS_MAP.md | 미실행 | 주소 맵 문서와 GEMV 형태 시험만 있음 | 모델 파일과 범위 결정 대기 |
| V-G5 | RTL | KV cache를 DDR에 두는 쓰기 경로 | AXI write 경로 설계와 시험 |  |  | 미실행 | 설계되지 않음(KV fp32 3.375 MiB는 URAM 3.0 MiB에 안 맞음) | int8 KV는 0.914 MiB |
| V-G6 | RTL | 정수 lane(I2: int8×int8 MAC + 활성화 양자화) | 고정소수점 C 기준부터 새로 시작 |  |  | 미실행 |  | 별도 세션에서 진행하기로 결정 |
| V-G7 | 도구 | 이전 xsim 불일치에서 패치별 기여 분리 | 같은 이미지로 전체 칩 xsim을 (A) 패치 없음, (B) rd_ok 인라인만, (C) FPU 표 패치만으로 실행(MAXCYC=600000, 40분 상한)하고 DONE과 덤프를 비교 | 각 패치의 효과 정량화 | fpga/xsim/run_xsim.sh, xsim_workaround.py (XW), .scratch/vg7.sh | 통과 | A 패치 없음: 600,000 cycle까지 DONE 없음. B rd_ok만: DONE 149,074 cycle, 덤프 5,718 바이트 다름. C FPU 표만: 600,000 cycle까지 DONE 없음. 두 패치 모두(E04): 157,433 cycle, 덤프 일치 | 멈춤은 rd_ok, 틀린 값은 FPU 표 때문으로 분리됨(E13). 실행 중 도구 오류 발견: 환경변수가 Windows vivado에 전달되지 않아 MAXCYC가 적용 안 됨, plusargs.txt로 수정 |
| V-D3 | RTL | 펌웨어 출력 채널과 코어 관찰 레지스터 | acc/tb_dbgregs: 펌웨어가 0x2000_0010에 3번 쓰고 종료(시나리오 0), 3번 쓴 뒤 불법 명령어 실행(시나리오 1). 보드 최상위 시뮬레이션이 출력하는 DBGREGS 줄 확인 | 출력 값과 횟수, 불법 명령어에서 trap_cnt 1과 trap_pc가 불법 명령어 근처, 정상 종료는 trap_cnt 0 | acc/tb_dbgregs/run_test.py, acc/chip_axi_top.sv (0x200_0040..) | 통과 | 시나리오 0: out=0xabcd0003, out_cnt=3, trap_cnt=0, DONE. 시나리오 1: trap_cnt=1, trap_pc=0x010000f8(불법 명령어 0x010000f0의 8바이트 앞), last_pc=0x01000000, fetch_cnt 계속 증가. 정상 펌웨어(image_1): out_cnt=0, trap_cnt=0. 기본 cycle과 덤프 불변 | 합성 타이밍 영향 미확인(주소는 먼저 레지스터에 담도록 구현함). trap_pc는 프리페처가 앞서 가므로 근사값. 보드에서는 실행하지 않음. 실험 E16 |
| V-D1 | RTL | RISC-V 디버그 모듈과 JTAG(DM_EN) | dbg/tb_dm: JTAG 핀 구동으로 IDCODE, dmactive, 실행 중 6번 halt와 레지스터 읽기/쓰기, resume, 끝까지 실행 후 덤프 비교 | 모든 확인 통과, 덤프는 cycle 워드 외 동일, 변이 시험 검출 | dbg/, acc/soc_chip.sv, dbg/tb_dm/run.sh | 통과 | 모든 검사 통과(IDCODE, DTMCS, 6회 halt/resume, x5 쓰기 복원), 덤프 차이는 0x1aff00과 0x1ad000 두 워드(cycle), 변이 시험 검출. 기본 빌드(DM_EN=0)는 image_1/128/512 cycle과 덤프 불변 | 단일 스텝 4회, 하드웨어 breakpoint(재개 직후, 그리고 실행하다가 도달하는 주소), ebreak(이미지에서 c.lui를 c.ebreak로 교체)는 통과. BSCANE2 변형은 시뮬레이션 불가(합성만), OpenOCD 연결, 가속기 동작 중 중간 메모리 비교는 미확인. SBA는 오류 응답. 실험 E14, docs/DEBUG_MODULE.md |
| V-D2 | 타이밍 | DM 포함 125 MHz 합성(OOC, chip_axi_top, DM_BUILD) | DM=1 PERIOD=8.0 fpga/run_chip.sh <dir> DM_BUILD | WNS, WHS >= 0 | fpga/run_chip.sh, fpga/prepare.py (DM=1), fpga/synth.tcl (DM_BUILD) | 통과 | WNS +0.110 ns, TNS 0, 실패 끝점 0, WHS +0.012 ns, LUT 60,456, 레지스터 21,932, BRAM 7, URAM 64, DSP 93(DM 없는 기준 V-M1은 WNS +0.249) | 중간 버전(DM 요청만 레지스터, 영역 판별이 명령어 grant에 남음)은 WNS -2.579 ns로 실패해 명령어 grant를 레지스터 값만으로 정하도록 재설계. 같은 RTL에서 Vivado가 간헐적으로 비정상 종료한 적 있음(E14). 정식 비트스트림에 넣을지는 별도 결정 |
| V-F1 | FPU | FPU 경계값 벡터(subnormal, Inf, NaN, ±0) | 17개 특수 피연산자의 모든 쌍을 ADD, SUB, MUL, DIV, 비교에, 특수값을 SQRT, I2F, F2I에 입력(1,494개). NaN 결과는 정규 NaN 0x7fc00000, F2I는 포화 규칙 | RISC-V F 규칙의 기대값과 비트 일치 | fpga/xsim/fpu_vectors.py (edge-*) | 통과 | xsim RTL, 네트리스트, Verilator RTL(AFTER, DISTRIBUTED) 모두 3896/3896. 변이 시험(SUB→ADD 등 4건)이 모두 검출됨 | 예외 플래그는 비교하지 않음(V-F2) |
| V-F2 | FPU | FPU 예외 플래그(rflags) 비교 | 연산별 NV, DZ, OF, UF, NX 기대값을 만들어 rflags와 비교 | 플래그 일치 | fpga/xsim/fpu_vectors.py, tb_fpu.sv | 미실행 | 현재 기대값 파일에 결과만 있음 |  |
| V-F3 | FPU | 펌웨어가 쓰지만 벡터에 없던 연산: SUB(fsub.s), F2I(fcvt.w.s, RTZ), 비교(flt.s, RTZ) | 정상 범위 SUB 300, F2I 300, FLT 400(무작위, 동일 값, 이웃 값)을 numpy와 비교. 펌웨어는 FMA, fmin, fmax를 쓰지 않음(fw.dis 0건) | 일치 | fpga/xsim/fpu_vectors.py | 통과 | xsim RTL, 네트리스트, Verilator RTL 모두 일치 | fw.dis 사용 횟수: fsub 36, flt 27, fcvt.w.s 1 |
| V-F4 | FPU | FPU 연속 요청(back-to-back, 파이프라인 중첩) | 같은 연산 그룹(ADDMUL, DIVSQRT, NONCOMP, CONV)의 요청을 gnt가 허용하는 매 cycle 입력하고 결과를 순서대로 수집(발행과 수집을 분리한 fork) | 순서 보존, 값 일치, 요청 없는 결과 0 | fpga/xsim/fpu_verilator.cpp(stream), fpga/xsim/tb_fpu.sv(STREAM) | 통과 | Verilator RTL(AFTER, DISTRIBUTED), xsim RTL, xsim 합성 네트리스트 모두 3896/3896, 요청 없는 결과 0. ADDMUL, NONCOMP, CONV 1.00 cycle/op, DIVSQRT 13.4 cycle/op. 합성 네트리스트는 그룹마다 1 cycle 길고 동시 진행이 1 더 많음(1,771→1,772 cycle, 3→4) | 서로 다른 그룹 사이 중첩은 시험하지 않음. 네트리스트의 1 cycle 차이 원인은 미확인(가설: 시험대 샘플 시점, 실험 E09) |
| V-R1 | RISC-V | 코어 ISA 적합성(펌웨어가 쓰는 RV32IMFC 부분집합) | riscv-arch-test에서 펌웨어가 쓰는 명령군만 골라 CPU sim에서 실행 | 서명(signature) 일치 | (환경 구성 필요) | 미실행 | 코어는 현재 펌웨어 실행으로만 간접 확인 |  |
| V-A1 | RTL | GEMV, VFU 버퍼 한계 경계 | GEMV 모드 D: 한계(n 또는 d = XBUF/YBUF)와 초과(+1, +8, 2배, 양쪽 동시)를 하나씩 실행해 소프트웨어 기준과 비교. VFU softmax, divsoftmax, softmax2: 청크 길이 512, 513, 520, 1024. 11-27 이후 초과 시작은 거부되므로 판정은 acc/tb_conc 시나리오 5, 6 | 한계 안은 일치, 초과는 정의된 동작(오류 신호 또는 안전한 거부) | w8/overlimit.sh, vfu/overlimit.sh, acc/tb_conc/run_test.py (시나리오 5, 6) | 통과 | 11-23: 한계 안 통과, 초과는 전부 조용히 틀림(GEMV 512 빌드 7/7, 1024 빌드 6/6, VFU 513 불일치 3,115, 520 5,887, 1024 12,279). 11-27 RTL 보호 추가 후: GEMV N=513 시작 거부(STATUS bit1), D=513 거부, VFU n=513 거부, 각 거부 뒤 정상 시작은 수락되고 오류가 지워지며 결과 일치(시나리오 5, 6 통과) | 초과 값은 513 한 점만 시험(조건은 단조 비교). w8/overlimit.sh, vfu/overlimit.sh는 보호 추가 후 다시 돌리지 않음(이제 출력이 쓰이지 않아 불일치가 정상). 15M 빌드(XBUF 1024)는 미시험. 펌웨어가 STATUS bit1을 확인하는 코드는 아직 없음. 실험 E16 |
| V-A2 | RTL | AXI 외부 읽기 경계: 4 KB 경계, 슬레이브 지연·정지·beat 간격, 오류 응답 | 무작위 AXI 슬레이브(ready 확률 1/0.5/0.1과 긴 정지, 지연 0~200 cycle, R beat 간격)에 가속기 line 요청(4 KB 경계 걸침, 긴 연속, 점프, 반복, 내림차순)과 CPU word 읽기를 섞어 입력. 오류 주입 시험은 한 beat에 SLVERR/DECERR | 매 cycle 프로토콜 검사 통과(16 B 정렬, 4 KB 비횡단, arlen≤MAXB, AR 안정, TD, CRED+1), 응답 데이터가 주소 해시와 일치, 오류 시 err_o 설정 후 리셋으로 해제 | acc/tb_axi_ext_rd/run.sh, checks.sh | 통과 | 5개 구성(MAXB/CRED/TD = 16/48/8, 8/16/2, 4/8/2, 32/48/8, 48/63/4) × 일반 21 seed(약 10.8만 line, 6,562 CPU 읽기, burst 약 2.4만) + 오류 주입 11 seed 모두 PASS. 변이 5건(4 KB 검사, 오류 플래그, 크레딧, CPU word 선택, TD 한도 제거)을 모두 검출 | 구성 제약(시험으로 확인): CRED ≥ MAXB(아니면 deadlock), TD는 2 이상의 2의 거듭제곱(TD=1, 3, 6은 응답이 밀림). 마스터 쪽 백프레셔는 rready=1이라 없음. 오류 정책은 현재 동작(sticky 플래그, 실행 계속)을 확인한 것이고 더 엄격한 정책 여부는 결정 대기(D7). 전체 칩에서의 오류 주입은 미시험 |
| V-A3 | RTL | CPU, GEMV, VFU 동시 메모리 접근 충돌 | 펌웨어 시험(acc/tb_conc): 호출 전에 GEMV(256×128 int8), VFU softmax(512), CPU 계산을 각각 블로킹으로 측정(보정)한 뒤 시나리오를 시뮬레이터 실행 하나씩. 1 GEMV 중 CPU 계산, 2 VFU 중 CPU 계산, 3 GEMV 실행 중(⅓ 지점) VFU 시작, 4 VFU 실행 중(⅓ 지점) GEMV 시작, 5와 6은 한계 초과 시작(V-A1) | 1, 2: 결과가 순차 실행과 동일하고 실제로 겹침. 3: VFU 시작이 거부되고 GEMV는 정상 완료, VFU 데이터 불변. 4: 직렬화되어 정상 | acc/tb_conc/run_test.py, test_conc.c | 통과 | 1, 2 통과(불일치 0, 겹침 확인). 4 정상(직렬화). 3: 11-24에는 GEMV가 멈추고 결과 훼손(GEMV 128/128, VFU 508/512 틀림); 11-27 보호 추가 후 VFU 시작 거부(VFU STATUS bit1, err 0x2), GEMV 128/128 일치, 시간 초과 없음, VFU 데이터 변경 0워드. 보호를 막은 변이 시험은 GEMV 128/128 틀림, 시간 초과, VFU 데이터 512워드 변경으로 FAIL(검출) | 펌웨어가 busy를 먼저 확인하므로 정상 사용에서는 거부가 일어나지 않음(회귀 42/42 불변). CPU가 거부를 확인하는 코드는 아직 없음. 실험 E10, E16 |
| V-A4 | RTL | 가속기 레지스터 인터페이스 경계: busy 중 쓰기, 잘못된 CTRL 값 | busy 상태에서 새 명령/설정 쓰기, 정의되지 않은 모드 값 | 정의된 동작(무시 또는 오류 표시) | acc/gemv_acc.sv, acc/vfu.sv | 미실행 | 펌웨어는 busy 폴링 후에만 씀 |  |

## 4. 신규 시험 등록부

블록별 점검에서 빈칸으로 나온 시험의 계획과 결과. 상태와 결과는 3절의 같은 ID와 같은 값이다. 작업량은 추정이며 측정값이 아니다.

| ID | 시험 | 분류 | 우선순위 | 추정 작업량 | 선행 결정 | 상태 | 결과 / 근거 | 구현 위치 | 갱신일 |
|---|---|---|---|---|---|---|---|---|---|
| V-F3 | 펌웨어가 쓰지만 벡터에 없던 연산: SUB(fsub.s), F2I(fcvt.w.s, RTZ), 비교(flt.s, RTZ) | FPU | 1 | 0.5일 | 없음 | 통과 | xsim RTL, 네트리스트, Verilator RTL 모두 일치 | fpga/xsim/fpu_vectors.py | 2026-11-23 |
| V-A2 | AXI 외부 읽기 경계: 4 KB 경계, 슬레이브 지연·정지·beat 간격, 오류 응답 | RTL | 2 | 1일 | 없음(오류 정책은 현재 동작을 확인, 변경 여부는 결정 D7) | 통과 | 5개 구성(MAXB/CRED/TD = 16/48/8, 8/16/2, 4/8/2, 32/48/8, 48/63/4) × 일반 21 seed(약 10.8만 line, 6,562 CPU 읽기, burst 약 2.4만) + 오류 주입 11 seed 모두 PASS. 변이 5건(4 KB 검사, 오류 플래그, 크레딧, CPU word 선택, TD 한도 제거)을 모두 검출 | acc/tb_axi_ext_rd/run.sh, checks.sh | 2026-11-23 |
| V-F1 | FPU 경계값 벡터(subnormal, Inf, NaN, ±0) | FPU | 2 | 0.5일 | 없음 | 통과 | xsim RTL, 네트리스트, Verilator RTL(AFTER, DISTRIBUTED) 모두 3896/3896. 변이 시험(SUB→ADD 등 4건)이 모두 검출됨 | fpga/xsim/fpu_vectors.py (edge-*) | 2026-11-23 |
| V-A1 | GEMV, VFU 버퍼 한계 경계 | RTL | 3 | 0.5일 | 확인 결과: 하드웨어는 막지 않음(조용한 오류). 어서션 추가는 결정 D7 | 통과 | 11-23: 한계 안 통과, 초과는 전부 조용히 틀림(GEMV 512 빌드 7/7, 1024 빌드 6/6, VFU 513 불일치 3,115, 520 5,887, 1024 12,279). 11-27 RTL 보호 추가 후: GEMV N=513 시작 거부(STATUS bit1), D=513 거부, VFU n=513 거부, 각 거부 뒤 정상 시작은 수락되고 오류가 지워지며 결과 일치(시나리오 5, 6 통과) | w8/overlimit.sh, vfu/overlimit.sh, acc/tb_conc/run_test.py (시나리오 5, 6) | 2026-11-23 |
| V-A3 | CPU, GEMV, VFU 동시 메모리 접근 충돌 | RTL | 3 | 1일 | 없음(가속기끼리 겹침의 하드웨어 보호 여부는 결정 D7) | 통과 | 1, 2 통과(불일치 0, 겹침 확인). 4 정상(직렬화). 3: 11-24에는 GEMV가 멈추고 결과 훼손(GEMV 128/128, VFU 508/512 틀림); 11-27 보호 추가 후 VFU 시작 거부(VFU STATUS bit1, err 0x2), GEMV 128/128 일치, 시간 초과 없음, VFU 데이터 변경 0워드. 보호를 막은 변이 시험은 GEMV 128/128 틀림, 시간 초과, VFU 데이터 512워드 변경으로 FAIL(검출) | acc/tb_conc/run_test.py, test_conc.c | 2026-11-24 |
| V-F4 | FPU 연속 요청(back-to-back, 파이프라인 중첩) | FPU | 3 | 0.5일(xsim 포함 1일) | 없음 | 통과 | Verilator RTL(AFTER, DISTRIBUTED), xsim RTL, xsim 합성 네트리스트 모두 3896/3896, 요청 없는 결과 0. ADDMUL, NONCOMP, CONV 1.00 cycle/op, DIVSQRT 13.4 cycle/op. 합성 네트리스트는 그룹마다 1 cycle 길고 동시 진행이 1 더 많음(1,771→1,772 cycle, 3→4) | fpga/xsim/fpu_verilator.cpp(stream), fpga/xsim/tb_fpu.sv(STREAM) | 2026-11-24 |
| V-A4 | 가속기 레지스터 인터페이스 경계: busy 중 쓰기, 잘못된 CTRL 값 | RTL | 4 | 0.5일 | busy 중 쓰기 등 정의되지 않은 동작의 정책 | 미실행 | 펌웨어는 busy 폴링 후에만 씀 | acc/gemv_acc.sv, acc/vfu.sv | - |
| V-F2 | FPU 예외 플래그(rflags) 비교 | FPU | 4 | 1일 | 플래그 기준 구현 선택(softfloat 등) | 미실행 | 현재 기대값 파일에 결과만 있음 | fpga/xsim/fpu_vectors.py, tb_fpu.sv | - |
| V-R1 | 코어 ISA 적합성(펌웨어가 쓰는 RV32IMFC 부분집합) | RISC-V | 5 | 1~2일 | 툴체인과 riscv-arch-test 환경 준비 | 미실행 | 코어는 현재 펌웨어 실행으로만 간접 확인 | (환경 구성 필요) | - |

## 5. 블록별 점검 (FPU, RISC-V 코어, 가속기)

"확인" = 시험 코드나 기록에서 확인, "간접" = 펌웨어/E2E 실행으로만 확인, "없음" = 확인한 범위에서 시험 없음, "제외" = 대상 아님. "연결 ID"는 3절의 항목이다.

### FPU

| 점검 항목 | 확인 내용 | 현재 | 근거와 위치 | 연결 ID |
|---|---|---|---|---|
| ADD, MUL | numpy float32(정확한 반올림)와 비트 일치 | 확인 | fpga/xsim/fpu_vectors.py, 각 300 이상 + 경계값 | V-T1 |
| DIV, SQRT | 위와 동일 | 확인 | 같은 벡터 파일 | V-T1 |
| I2F(정수→실수) | 부호 있는 정수 200개 | 확인 | 같은 벡터 파일 | V-T1 |
| 반올림 모드 | RNE(연산), RTZ(F2I, 비교) | 간접 | 펌웨어가 쓰는 모드만. RDN, RUP, RMM은 시험하지 않음 |  |
| 피연산자 범위 | subnormal, Inf, NaN(조용한/신호), ±0, 최대·최소 정규수 | 확인 | 경계값 1,494개, xsim RTL, 네트리스트, Verilator 모두 일치 | V-F1 |
| 예외 플래그(rflags) | 플래그 비교 | 없음 | 기대값 파일에 결과만 있음 | V-F2 |
| SUB, F2I, 비교(펌웨어가 쓰는 연산) | numpy와 RISC-V 규칙 기준 일치 | 확인 | fw.dis: fsub 36, flt 27, fcvt.w.s 1 사용. 3곳 시뮬레이터 모두 일치 | V-F3 |
| FMA, fmin, fmax | 펌웨어가 쓰지 않음 | 제외 | fw.dis 0건 |  |
| 지연(latency) | FPU_LAT 0과 4에서 동작 | 간접 | D1(0), D2(4) 설정 회귀 | V-I1 |
| 연속 요청 핸드셰이크 | req→gnt→rvalid 중첩, 결과 순서 | 확인 | Verilator RTL, xsim RTL, 합성 네트리스트 모두 3896/3896(네트리스트는 1 cycle 길게 보임, E09) | V-F4 |
| 합성 후 네트리스트 | 같은 벡터 | 확인 | 3,896/3,896 | V-T1 |

### RISC-V 코어

| 점검 항목 | 확인 내용 | 현재 | 근거와 위치 | 연결 ID |
|---|---|---|---|---|
| 명령 I, M, F, C | 펌웨어가 쓰는 범위 실행 | 간접 | HOLD 회귀, E2E 덤프 일치 | V-I1, V-I4 |
| 부팅 | _start, bss 초기화, imem 0x0100_0000 | 간접 | chip sim, xsim 실행 | V-I1, V-I8 |
| CSR | mstatus FS, mcountinhibit, mcycle | 간접 | 시작 코드에서 사용 |  |
| 트랩 | 예기치 않은 예외 | 간접 | sim.cpp가 TRAP mepc를 감지해 중단 |  |
| 데이터 포트 | 바이트 마스크, 크기, 정렬 | 간접 | xsim과 Verilator trace가 9,910 cycle까지 4,462 이벤트 동일 | V-I8 |
| 스택 | 최소 스택 주소 | 간접 | 실행 로그의 min_stack_write |  |
| 외부 인터럽트 | 사용하지 않음 | 제외 |  |  |
| ISA 적합성(riscv-arch-test 등) | 명령 하나하나 | 없음 |  | V-R1 |

### 가속기

| 점검 항목 | 확인 내용 | 현재 | 근거와 위치 | 연결 ID |
|---|---|---|---|---|
| GEMV 모드 A(fp32) | 온칩과 DDR에서 일치 | 확인 |  | V-I5, V-I6 |
| GEMV 모드 D(int8 + scale) | 무작위 366건, 불일치 0 | 확인 | w8/test_w8_gemv.c | V-U3 |
| GEMV 15M 형태, pre-tiled(bit2) | 일치 | 확인 |  | V-U4, V-U5 |
| GEMV 행 stride 16 B 배수, scale 16 B 라인 적재 | 오류 없이 동작 | 확인 | LOADS 상태 수정 후 비트 비교 |  |
| GEMV, VFU 버퍼 한계 | 한계 안 일치, 한계 초과 시 동작 | 확인 | 한계 안 통과(버퍼 512, 1024 빌드). 초과는 조용히 틀림(오류 신호, 어서션 없음). 실험 E08 | V-A1 |
| 레지스터 인터페이스 | CTRL, W_ADDR, SC_ADDR, busy 폴링 | 간접 | 펌웨어가 사용. 경계 입력은 미시험 | V-A4 |
| VFU 명령 1~7 | exp, softmax, SiLU, 나눗셈, 나눗셈+softmax, softmax2, SiLU2를 소프트웨어와 비트 일치 | 확인 | vfu/run_test.py | V-U1 |
| VFU 벡터 길이 경계 | softmax 계열 길이 1, 2, 8, 512, 무작위 1~512 | 확인 | vfu/run_test.py (53행 부근) | V-U1 |
| VFU 연속 명령, 상태 전이 | 명령 사이 상태 정리 | 간접 | E2E에서 확인 |  |
| AXI 외부 읽기 | 버스트 병합, 크레딧, 태그 FIFO, 지연 | 확인 | DDR top 시뮬레이션 | V-U6 |
| AXI 4 KB 경계, 슬레이브 정지·지연, 오류 응답 | 프로토콜 검사와 데이터 일치, 오류 시 err_o | 확인 | acc/tb_axi_ext_rd (5개 구성, 변이 5건 검출). 구성 제약 CRED≥MAXB, TD=2의 거듭제곱 | V-A2 |
| 성능 카운터 | 6종 값이 모델과 일치 | 확인 |  | V-P1 |
| CPU, GEMV, VFU 동시 접근 | CPU와 가속기 겹침, 가속기끼리 겹침 | 확인 | CPU와 가속기 겹침 통과. VFU 실행 중 GEMV 시작은 직렬화되어 정상. GEMV 실행 중 VFU 시작은 멈춤과 오류(보호 없음, 실험 E10) | V-A3 |

## 6. 사용자 결정 대기

| ID | 결정 | 현재 | 관련 항목 |
|---|---|---|---|
| D1 | int8 합격 기준 | nll_delta ≤0.01, argmax ≥0.97 (제안) | V-N1 |
| D2 | 15M 모델 파일과 범위(임베딩 int8 조회, KV 위치, 주소 맵 Option I/II) | 미정 | V-G4, V-G5 |
| D3 | 저장소 RTL의 rd_ok 수정 여부 | 결정함(11-27): 인라인으로 수정함(E16). 타이밍 영향은 합성 결과 대기 | V-G2 |
| D4 | 합성 후 전체 칩 시뮬레이션: 막힌 경로를 어떻게 풀지 | 승인되어 진행했으나 막힘: xsim BASIC 라이선스 한도(인스턴스 50,000개, 네트리스트 107,091개), Verilator 메모리(변환만 6.5 GB 이상, 호스트 7.9 GB). 선택지: (a) xsim 라이선스 상향(사용자 작업), (b) WSL 메모리 상향(.wslconfig, 사용자 작업), (c) 소자를 assign/always로 바꾸는 변환기를 직접 작성(수 시간, 변환 오류 위험은 FPU 네트리스트 교차 검증으로 관리). 권고: (a) 또는 (b)를 먼저 확인 | V-S1 |
| D5 | 보드 확보와 PYNQ 이미지 | 미정(보드 없음) | V-B0..V-B5 |
| D6 | 커버리지, 어서션, 형식 검증 도입 여부 | 미정 | V-G3 |
| D7 | AXI 외부 읽기 오류 응답 정책, 버퍼 한계와 가속기 겹침 보호 | 결정함(11-27): 오류 정책은 현재 동작(sticky err_o, 실행 계속) 유지. 파라미터 제약은 시뮬레이션 전용 어서션, 버퍼 한계 초과와 GEMV 실행 중 VFU 시작은 하드웨어가 시작을 거부하고 STATUS bit1 오류를 켬(E16). 펌웨어가 오류 비트를 확인하는 코드는 아직 없음 | V-A1, V-A2, V-A3 |

## 7. 실행 규칙 (LESSONS_LEARNED 반영)

1. 실행 전에 `tasklist.exe`로 남은 `vivado.exe`, `xsimk.exe`를 확인하고, Vivado와 대형 시뮬레이션은 직렬로 돌린다.
2. xsim 결과는 V-T1(FPU 1,402 벡터)을 먼저 통과시킨 뒤에만 신뢰한다.
3. 장시간 실행은 로그의 단위와 예상 종료 시점을 계산해 두고, 상한을 넘으면 중단한다.
4. RTL을 바꾸면 V-I9(quick 42/42)를 다시 돌린다. 시험을 새로 만들면 V-T3(변이 시험)로 검출력을 확인한다.
5. "통과"는 시뮬레이션 또는 합성 보고서 기준이며 보드 결과가 아니다. 보고할 때 둘을 구분한다.
6. 결과 파일을 재사용하는 시험 스크립트는 입력이 바뀌면 낡은 결과를 비교하지 않는지 확인한다(`run_fpu_test.sh`는 실행 시작 때 결과 파일을 지운다).

## 8. 한계

- 이 표는 `reproduce.sh`, `docs/`, 이번 세션 기록에서 확인한 것만 담았다. 저장소의 모든 시험을 찾아본 것은 아니다.
- "근거" 열의 수치는 저장소 문서와 세션 기록에서 옮겼고, 이번 세션에서 다시 측정한 것은 V-I8(xsim 전체 칩)과 V-T1뿐이다.
- 단위 시험으로 따로 분리되지 않은 항목(V-U6)은 통합 시험으로 확인했다고 표시했다.
- 4절 "블록별 점검"의 "없음"은 코드를 검색해 찾지 못했다는 뜻이며, 다른 위치에 시험이 있을 가능성을 완전히 배제하지는 않는다.
- V-F1~V-A4(신규 시험)의 "추정 N일"은 작업량 추정이며 측정값이 아니다.
