# 실습 문서: LLM → C → RISC-V 어셈블리 → 칩 (2026-11-28)

`docs/LEARNING_PATH.md`의 목표(펌웨어 읽기와 수정, 검증과 운영 / 툴체인은 만들지 않고 개발 과정에서 쓰는 수준 / 최종 목표는 칩 수준: 합성, 보드, 디버그)에 맞춘 실습이다. 각 실습은 **실행 명령, 이 PC에서 실제로 얻은 결과, 확인 질문과 답**으로 구성하고, 실제로 돌려서 확인한 것만 넣었다.
표기: **측정** = 이 PC에서 직접 실행해 얻은 값, **소스** = 저장소 파일에서 읽음, **이전 검증** = 오늘 앞서 실행했고 이번에 다시 돌리지 않음, **미확인** = 모름.

## 0. 준비
- 저장소 루트에서 실행한다.
- 보드 방식 칩 시뮬레이터를 빌드해 둔다(수 분): `TOP=chip_axi_top ./build_sim.sh` → `obj_axi/Vchip_axi_top`. 이 문서의 결과는 같은 RTL로 빌드한 `obj_axi_d7`로 얻었고, 다르게 둔 경우 `TEST_SIM=<경로>`로 지정한다.
- 작은 C 프로그램을 컴파일해서 칩 시뮬레이터에서 돌리는 도구: `python3 docs/labs/run_c.py <파일.c> [--opt O2] [--ctrl N] [--words 주소:개수]`. 컴파일은 프로젝트의 `build.sh`(RISC-V gcc, `start.S`, `link.ld`)를 그대로 쓰고, 결과 파일(`prog.elf`, `prog.dis`, `prog.map`, `image.bin`)은 `.scratch/labs/<프로그램 이름>/`에 남는다.

## 1. LLM에서 RISC-V 어셈블리까지: 이 프로젝트의 흐름 (소스)
```
llama2.c run.c (호스트용 원본, 기준)  ──┐
firmware.c  (같은 forward()를 RISC-V용으로 정리, HOLD 기준선)  ─┤
gen/firmware_gen.c (생성 루프 + 가속기 호출 함수. 매크로 USE_ACC, OPTA 등으로 선택) ─┘
        │  build.sh: riscv64-unknown-elf-gcc -march=rv32imfc_zicsr -mabi=ilp32f -Os -ffp-contract=off ... start.S link.ld
        ▼
   fw.elf (디버그 정보 포함) → fw.dis (역어셈블리), fw.map (주소 지도)
        │  gen/run_gen.py: 가중치와 입력을 메모리 이미지로 묶음
        ▼
   image.bin (SRAM 0~2 MiB: 가중치, KV, 데이터 / imem 0x0100_0000: 코드 16 KB) → 시뮬레이터 또는 보드(pynq/run_chip.py)
```
- **`-ffp-contract=off`**: 곱셈과 덧셈을 하나의 FMA 명령으로 합치지 못하게 한다. 합치면 반올림이 달라져 호스트 결과와 비트 단위로 같지 않게 된다(소스: `build.sh`, 실습 2에서 확인).
- 최적화 수준(`-Os`, `-O2`)을 바꿔도 결과는 비트 단위로 같음이 이 프로젝트의 이전 실험에서 확인됐다(`gen/P1_GEN.md`, 이번에 다시 돌리지 않음).

## 실습 1. 가장 작은 프로그램과 `_start` 읽기 (읽기, 실행)
```
python3 docs/labs/run_c.py docs/labs/lab_out.c
```
**측정 결과:** `built lab_out.c with -Os: text 88 bytes`, `DONE after 39 cycles`, `OUT = 0xcafef00d, written 2 time(s)`.
읽을 것: `.scratch/labs/lab_out/prog.dis`(앞에 시작 코드 `start.S`가 붙어 있다), `link.ld`, `start.S`(둘 다 짧다).
- Q1. 코드는 어느 주소에서 시작하는가? 스택 맨 위는? 변수 영역(.bss)은 어디인가?
  **답(소스, `link.ld`):** 코드 영역 `INST`는 0x01000080부터 16K−128바이트, 데이터 영역 `CTRL`은 0x001b4000부터 304K, 스택 맨 위는 `ORIGIN(CTRL)+LENGTH(CTRL)` = 0x200000. 변수 영역(.bss)은 `CTRL` 안.
- Q2. `_start`는 무엇을 하고 어디서 `boot`를 부르는가?
  **답(소스, `start.S`):** 스택 포인터 설정(`la sp, __stack_top`), 부동소수점 허용(`csrs mstatus, 0x6000`), .bss 지우기 루프, `call boot`, 돌아오면 무한 루프(`j 3b`). 지난 파형 안내(`docs/BOOT_WALKTHROUGH.md`)의 단계 2~4와 같은 코드다.
- Q3. C2x에서 리셋 후 초기화 코드와 무엇이 다른가? (사용자의 경험으로 답한다.)

## 실습 2. C가 어셈블리가 되는 모습: 최적화 수준 비교 (컴파일러 출력 읽기)
`docs/labs/lab_float.c`의 `dot()`(float 내적)을 프로젝트 옵션(`-march=rv32imfc_zicsr -mabi=ilp32f -ffp-contract=off`)으로 `-O0`, `-O2`, `-Os`로 컴파일해서 어셈블리(`-S`)를 읽는다. 실습 문서 작성 중 같은 함수로 얻은 결과:

| 수준 | 어셈블리 줄 수 | 비고 |
|---|---|---|
| `-O0` | 35 | 35줄 중 18줄이 스택 접근(인자와 지역 변수 `s`, `i`를 메모리에 두고 매번 읽고 씀) |
| `-O2` | 13 | 스택 접근 0줄(모두 레지스터) |
| `-Os` | 13 | |

`-Os` 결과(측정):
```
dot:    fmv.s.x fa0,zero          # s = 0.0f
        li      a5,0              # i = 0
.L2:    blt     a5,a2,.L3         # i < n ?
        ret
.L3:    slli    a4,a5,2           # i * 4
        add     a3,a0,a4          # &a[i]
        add     a4,a1,a4          # &b[i]
        flw     fa5,0(a3)         # a[i]
        flw     fa4,0(a4)         # b[i]
        addi    a5,a5,1
        fmul.s  fa5,fa5,fa4       # a[i] * b[i]
        fadd.s  fa0,fa0,fa5       # s += ...
        j       .L2
```
- Q1. 함수 인자 `a`, `b`, `n`은 어느 레지스터에, 반환값은 어디에 있는가? **답:** `a0`, `a1`, `a2`, 반환값(float)은 `fa0`. 호출 규약(ABI)이 정한 것이다.
- Q2. `s += a[i] * b[i]`가 곱셈 한 번과 덧셈 한 번(`fmul.s`, `fadd.s`)으로 나뉘어 있다. 하나의 명령(곱셈-덧셈 합성)으로 합치지 않은 이유는? **답:** `-ffp-contract=off` 때문이다. 합치면 곱셈의 중간 반올림이 사라져 호스트 결과와 비트가 달라진다.
- Q3. 같은 함수를 C2x에서 손으로 짠다면 어떤 레지스터와 반복 구조를 쓰겠는가? 컴파일러 결과와 비교한다. (사용자의 경험으로 답한다.)

## 실습 3. LLM의 `matmul`이 RISC-V에서 어떻게 보이는가
`firmware.c`의 `matmul()`(99행, llama2.c와 같은 C)과 `firmware.dis`의 `<matmul>`(주소 0x010001ae)을 나란히 읽는다. 함수 보기 도구: `docs/labs/show_func.sh firmware.dis matmul 40`.
**측정 결과(`firmware.dis`):** `matmul`은 24개 명령이고, 안쪽 루프(`j`에 대한 반복, 주소 0x10001c4~0x10001dc)는 9개 명령이다: `slli`, `add`, `flw`(w), `flw`(x), `addi`, `addi`, `fmul.s`, `fadd.s`, `blt`.
- Q1. `matmul(xout, x, w, n, d)`의 다섯 인자는 어느 레지스터에 있는가? **답:** `a0`~`a4` 순서대로(`xout`=a0, `x`=a1, `w`=a2, `n`=a3, `d`=a4). 반환값이 없다.
- Q2. 가속기(`gemv_acc`)가 대신하는 것은 이 루프의 어느 부분인가? **답:** 이 안쪽 루프 전체(곱셈과 덧셈의 반복). `gen/firmware_gen.c`의 `acc_matmul()`이 같은 이름의 함수로 가속기를 부르고, 결과가 소프트웨어와 비트 단위로 같음이 회귀로 확인되어 있다(실습 5).
- **주의할 점(측정):** 이 PC에서 `firmware.c`를 다시 컴파일하면 `.text`가 2,708바이트로, 저장소에 있는 `firmware.dis`(2,676바이트)와 **다르다**(역어셈블리 1,594줄 차이). 이 PC의 gcc(13.2)와 원래 빌드에 쓴 컴파일러(`build.sh` 주석: GCC 14.2)가 달라서 생긴 차이로 **추정**한다(원인을 직접 확인하지는 않았다). 컴파일러 버전이 바뀌면 어셈블리가 바뀐다는 뜻이고, 그래서 이 프로젝트는 결과(덤프)를 비트 단위로 비교하는 회귀를 둔다(`reproduce.sh quick`). 이 실습은 바이너리 비교만 했고 결과 비교는 하지 않았다.

## 실습 4. 실수(float)와 비트 패턴: 고정소수점 경험에서 IEEE-754로
```
python3 docs/labs/run_c.py docs/labs/lab_float.c --opt O2
```
**측정 결과:** `DONE after 152 cycles`, `OUT = 0x411c0000 (as float 9.75)`.
- Q1. 1.5×0.5 + 2×1 + 3×2 + 4×0.25 = 9.75가 왜 `0x411c0000`인가? **답:** 9.75 = 1001.11₂ = 1.00111₂ × 2³. 부호 0, 지수 = 3+127 = 130 = `10000010`₂, 가수(소수 부분) `00111`을 23비트로 채우면 `0 10000010 00111000000000000000000`₂ = `0x411C0000`.
- Q2. 값을 바꿔 보고(`lab_float.c`의 배열), 결과를 먼저 손으로 예측한 뒤 시뮬레이터로 확인한다. 0.1처럼 2진수로 정확히 표현되지 않는 수를 넣으면 어떻게 되는가?
- Q3. Q 포맷 고정소수점과 비교해 새로 생기는 문제는? **생각해 볼 점:** 반올림, 연산 순서에 따라 결과가 달라질 수 있다는 것. 이 프로젝트가 "소프트웨어와 하드웨어의 비트 일치"를 요구하는 이유다.

## 실습 5. 가속기를 C에서 부르기: 소프트웨어와 하드웨어의 비트 일치
```
python3 docs/labs/run_c.py docs/labs/lab_gemv.c --opt O2 --words 0x1aff00:5
python3 docs/labs/run_c.py docs/labs/lab_gemv.c --opt O2 --ctrl 513 --words 0x1aff00:5
```
`lab_gemv.c`는 같은 행렬 곱(4×8)을 CPU 루프와 `gemv_acc`로 각각 계산해 비트 단위로 비교한다. 가속기 호출 코드는 `gen/firmware_gen.c`의 `acc_gemv()`와 같은 모양이다(MMIO 레지스터 7개 쓰기, 시작, busy 확인 반복).
**측정 결과(N=8):** `DONE after 1395 cycles`, 결과 영역 `0x1aff00`: `0x00000000 0x00000000 0x402b7c59 0x402b7c59 0x600d600d`. 즉 다른 워드 0개, `err` 비트 0, 하드웨어와 소프트웨어의 `y[0]`이 모두 `0x402b7c59`(비트 단위로 같음).
**측정 결과(`--ctrl 513`, 즉 N=513으로 시작 요청):** `DONE after 1331 cycles`(멈추지 않음), 결과 영역: `0x00000004 0x00000001 0x00000000 0x402b7c59 0x600d600d`. 즉 4개 출력이 모두 불일치(하드웨어가 쓰지 않음), `err` 비트 1, `y_hw[0]`은 0.
- Q1. 가속기를 시작하는 데 쓰는 레지스터와 의미는? **답(소스, `acc/gemv_acc.sv` 머리말):** `0x08` X 주소, `0x0C` W 주소, `0x10` Y 주소, `0x14` N, `0x18` D, `0x1C` 행 간격(바이트), `0x24` 원소 간격, `0x00` 시작(bit0). 상태는 `0x04`(bit0 busy, bit1 err).
- Q2. CPU는 가속기가 끝났는지 어떻게 아는가? **답:** `STATUS`의 bit0(busy)를 반복해서 읽는다(`while (G[1] & 1)`). 파형에서 이 대기 루프를 `docs/figures/waveform_gemv.png`에서 볼 수 있다.
- Q3. N=513이면 왜 거부되는가? **답:** `N`이 `XBUF`(512)보다 크면 하드웨어가 시작을 거부하고 `err` 비트를 켠다(오늘 추가한 보호, `docs/DEBUG_MODULE.md`, `EXPERIMENT_LOG.md` E16). 펌웨어가 이 비트를 확인하는 코드는 아직 없다.

## 실습 6. 내 프로그램의 파형 읽기 (reset부터)
```
# 실습 4의 이미지(.scratch/labs/lab_float/image.bin)가 있어야 한다
TRACE=1 TOP=soc_chip ./build_sim.sh                         # 파형 지원 시뮬레이터 (처음 한 번)
SIM_VCD=/tmp/p.vcd SIM_VCD_FROM=0 SIM_VCD_TO=300 obj_chip_trace/Vsoc_chip .scratch/labs/lab_float/image.bin /tmp/d.bin
python3 docs/wave/vcd_pick.py /tmp/p.vcd /tmp/p_small.vcd /tmp/p.gtkw TOP.clk_i TOP.rst_ni TOP.soc_chip.i_req TOP.soc_chip.i_gnt TOP.soc_chip.i_addr TOP.soc_chip.d_req TOP.soc_chip.d_we TOP.soc_chip.d_addr TOP.soc_chip.d_wdata
python3 docs/wave/walkthrough.py /tmp/p_small.vcd .scratch/labs/lab_float/prog.dis 30
```
**측정 결과(이 프로그램의 처음 구간):** `_start` 15번 fetch(cycle 2~19) 뒤 `boot`로 넘어간다. `boot`의 명령은 `lui a7,0x1b4`, `flw fa4,0(a7)`처럼 **`.rodata`(0x1b4000)에서 float 상수를 읽어** `fsw`로 스택(0x1fffe0)에 쓴다. 데이터 접근에서 `write 0x001fffe0 data 0x3fc00000`(1.5f)이 보인다.
- Q1. 배열 `a[4] = {1.5f, ...}`는 어디에 저장되어 있다가 스택으로 옮겨지는가? **답:** 컴파일러가 `.rodata`에 값을 두고 실행할 때 스택 배열로 복사한다(위 측정).
- Q2. `bgeu t0,t1,...` 다음 cycle 13에 `sw zero,0(t0)` 줄이 보이는 이유는? **추정:** 이 프로그램은 .bss가 비어 있어(`__bss_start == __bss_end`) 분기가 바로 성립하는데, 프리페처가 분기 뒤의 명령을 미리 가져온 것으로 읽는다.

## 실습 7. 디버거: JTAG로 멈추고 한 단계씩 (디버그 시뮬레이션)
```
dbg/tb_dm/run.sh prof/chip_full_opta_d2/image_1.bin /mnt/e/fpga_work/board_kit/dump_sim_1.bin .scratch/tb_dm +HALTS=3 +VERBOSE=1
```
**이전 검증(이번에 다시 돌리지 않음):** 모든 확인 통과(`PASSED: 0 check failure(s)`), 실행 중 halt, 레지스터 읽기와 쓰기, 단일 스텝 4회, 하드웨어 breakpoint, resume, 덤프는 cycle 워드 2개만 다름(`docs/DEBUG_MODULE.md`).
- Q1. 직접 만든 디버거(halt, 단계 실행, 레지스터 읽기)와 이 구조의 차이는? **생각해 볼 점:** 이 칩은 코어가 디버그 모드에 들어가 DM이 준 코드를 실행하는 방식(실행 기반)이고, 소프트웨어 breakpoint는 쓸 수 없으며 하드웨어 breakpoint가 1개다(`docs/DEBUG_CHIP_LEVEL.md`).

## 실습 8. 칩 수준 1: 합성 보고서 읽기
읽을 것: `docs/experiments/raw/dm_chip_route_summary.txt`, `docs/EXPERIMENT_LOG.md`의 E14와 E16. (합성은 약 40분이고 호스트 메모리를 많이 쓰므로 이 실습에서는 돌리지 않고 보고서만 읽는다. `docs/LESSONS_LEARNED.md` R14.)
**소스(E14, 디버그 모듈 포함 빌드, 125 MHz 목표):** 배치배선 후 WNS +0.110 ns, TNS 0, 실패 끝점 0, WHS +0.012 ns, LUT 60,456(26.2 %), 레지스터 21,932, BRAM 7, URAM 64, DSP 93.
- Q1. WNS가 +0.110 ns라는 것은 무슨 뜻인가? **답:** 가장 느린 경로가 클럭 주기(8 ns)보다 0.110 ns 빠르게 끝난다는 뜻(여유). 0보다 작으면 그 주파수에서는 타이밍을 만족하지 못한다.
- Q2. 클럭 주파수는 어디서 정하는가? **답:** `fpga/run_chip.sh`의 `PERIOD` 환경변수(8.0 ns = 125 MHz, 8.333 ns = 120 MHz)가 합성 제약(`create_clock -period`)이 된다. 보드에서는 PS가 주는 PL 클럭 설정과 맞춰야 한다.
- Q3. 합성이 실패한 적이 있다(배치배선의 메모리 부족, E16). 소프트웨어 개발과 다른 점은? **생각해 볼 점:** 결과가 호스트의 가용 메모리에도 좌우되고, 같은 입력에서도 도구가 간헐적으로 실패할 수 있다.

## 실습 9. 칩 수준 2: 보드에 가져갈 묶음 확인
```
cd /mnt/e/fpga_work/board_kit && sha256sum -c SHA256SUMS
```
**측정 결과:** `dump_sim_1.bin: OK`, `dump_sim_128.bin: OK`, `dump_sim_512.bin: OK`(그 밖의 파일도 같은 방식).
읽을 것: `docs/BOARD_BRINGUP.md` 3절(단계 0~5), `board_kit/README.txt`.
- Q1. 보드에서 첫 실행(`image_1`)의 합격 기준은? **답(소스, `BOARD_BRINGUP.md`):** 덤프 2 MiB가 기준 덤프와 바이트 단위로 같고 `DONE_V`가 같으며 `CYCLES`는 시뮬레이터 값(157,437과 157,433)과 나란히 기록한다.
- Q2. 지금 보드에서 실행해 본 것은? **답:** 없음(보드 미확보). 모든 결과는 시뮬레이션과 합성 보고서 기준이다.

## 순서 제안과 소요
- 목표가 "펌웨어 읽기, 수정, 검증과 운영 + 칩 수준"이므로 **1 → 2 → 3 → 5 → 4 → 6** 순으로 보고(소프트웨어 쪽), 이어서 **7 → 8 → 9**(칩 수준)를 본다.
- 각 실습은 시뮬레이터에서 수 초이고, 시간은 읽고 생각하는 데 드는 것이 대부분이다(소요 시간은 개인차가 커서 추정하지 않았다).
- 실습 6과 7은 파형 지원 시뮬레이터와 디버그 시험을 처음 한 번 빌드해야 한다(수 분).

## 한계
- 실습 7은 이번에 다시 돌리지 않았다. 실습 8은 합성을 돌리지 않았다. 실습 9는 보드 없이 파일 확인까지다.
- 실습 3의 컴파일러 차이 원인(버전)은 추정이다.
- 프로젝트 안의 다른 가속기 명령(VFU)과 int8 모드 실습은 포함하지 않았다.
