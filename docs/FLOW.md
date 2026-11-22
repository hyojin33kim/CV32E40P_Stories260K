# Stories260K 단일 Tile 개발 흐름

**기준 구성** · Stories260K, 기본 프롬프트 `Once upon a time`, 16 step, W8 가중치·FP32 누산, Option A, D2, 온칩 가중치, ZCU104 PL 125 MHz. Linux 개발 서버에서 이미지와 기대값을 준비하고 ZCU104의 PS Linux에서 실측한다. 16은 프롬프트 처리를 포함한 실행 step 수다.

## 단계별 입력·출력과 진행 상태

2026-11-22 저장소 기록 기준. 실측을 추가할 때는 상태와 함께 해당 실행 로그 또는 결과 파일의 위치를 갱신한다.

| 단계 | 입력 | 실행 명령 또는 진입점 | 출력 → 소비 단계 | 합격 기준 | 최근 결과·상태 |
|---|---|---|---|---|---|
| 1. 모델·수치 기준 | `stories260K.bin`, `gen/tok512.bin`, 프롬프트, W8·OPTA 설정 | [run_gen.py](../gen/run_gen.py)의 host C 실행 | 기준 token·logits·KV → 3 | 같은 입력의 logits·KV 상대 L2 각각 < 1e-5, token 판정은 실행 스크립트 기준 | [W8 결과](../w8/W8_I1.md)에 8·64 step 기록 |
| 2. RISC-V 펌웨어 | `gen/firmware_gen.c`, 모델, 실행 옵션 | 같은 스크립트가 `build.sh`, `image.py`, W8 pack 호출 | `fw.elf`, `image.bin` → 3·4·6 | ELF·이미지 생성 후 해당 이미지로 3 통과 | [빌드·실행 스크립트](../gen/run_gen.py) |
| 3. CPU 기준·가속 SoC RTL | CPU 및 SoC RTL, SW 전용 및 가속 펌웨어 이미지 | 아래 A의 CPU 기준 → 가속 실행 | `result.json`, `steps.bin`, `cycles.npy`, 가속 실행의 `image.bin` → 4·6 | `pass=true`, 가속 결과의 `logits_kv_tokens_bitexact_vs_Os=true` | [W8 검증 기록](../w8/W8_I1.md). 16-step 결과는 해당 실행에서 기록 |
| 4. Chip RTL 기대값 | 3의 **가속** `image.bin`, imem·SRAM 포함 `soc_chip` | 아래 A의 `Vsoc_chip` 실행 | `dump_sim.bin`, DONE 값·cycle 로그 → 6 | DONE 도달, 2 MiB dump 생성. 최종 대조는 6 | [Chip 시뮬레이션 절차](SIM_GUIDE.md) |
| 5. FPGA 구현 | 온칩형 `chip_axi_top`, ZCU104 PS–PL BD, 125 MHz 설정 | 아래 B 또는 기존 동일 구성 배포본 | 같은 빌드의 `board.bit`·`board.hwh`, timing report → 6 | setup/hold 위반 0, 생성물과 빌드 SHA 식별 | [Windows GUI 빌드](BOARD_BRINGUP.md) RTL `d3b41bf`, WNS +0.100 ns, WHS +0.008 ns. Linux 빌드 미확인 |
| 6. 보드 Linux 실행 | 3의 이미지 + 4의 기대 dump·cycle + 5의 bit/hwh | 아래 C의 PYNQ 실행 | 보드 `dump.bin`, DONE 값, cycles, 비교 로그 | DONE 값·cycles 일치 및 2 MiB 전체 byte 일치 | [실보드 실행 대기](BOARD_BRINGUP.md) |

1·2·3은 하나의 드라이버가 묶어 실행한다. 4와 5는 독립적으로 준비할 수 있다. 외부 DDR 가중치용 top은 별도 구성이다.

## A. Linux 개발 서버에서 16-step 기준 실행 만들기

저장소 루트의 Bash에서 실행한다. [도구 설치 및 시뮬레이션 안내](SIM_GUIDE.md)를 따른다. 기존 설정 회귀는 `./reproduce.sh quick`으로 실행할 수 있다. 아래 명령은 새 출력 디렉터리에서 W8의 동일 프롬프트 SW 기준을 먼저 만든다.

```bash
set -euo pipefail
mkdir -p "$HOME/runs/stories260k"
RUN=$(mktemp -d "$HOME/runs/stories260k/w8-16-XXXXXX")
export GEN_OUT="$RUN/gen" CFG=d2 W8=1 OPTA=1
git rev-parse HEAD > "$RUN/source.sha"
sha256sum stories260K.bin gen/tok512.bin > "$RUN/model.sha256"

TOP=cv32e40p_top ./build_sim.sh
TOP=soc_top ./build_sim.sh
TOP=soc_chip ./build_sim.sh
GEN_ACC='' GEN_CFLAGS='' python3 gen/run_gen.py 16 > "$RUN/sw.log"
GEN_ACC=full GEN_CFLAGS='-O2 -funroll-loops' python3 gen/run_gen.py 16 > "$RUN/soc.log"

SW="$GEN_OUT/out_16_Os_opta_w8_d2"
ACC="$GEN_OUT/out_16_O2u_opta_w8_accfull_d2_L0_G1"
python3 - "$SW/result.json" "$ACC/result.json" <<'PY'
import json, sys
from pathlib import Path
sw, acc = (json.loads(Path(p).read_text()) for p in sys.argv[1:])
if not (sw["pass"] and acc["pass"] and acc["logits_kv_tokens_bitexact_vs_Os"] is True):
    sys.exit("FAIL: inspect SW and accelerator result.json")
PY
cp "$ACC/image.bin" "$RUN/image.bin"
obj_chip/Vsoc_chip "$RUN/image.bin" "$RUN/dump_sim.bin" | tee "$RUN/chip.log"
test "$(stat -c %s "$RUN/dump_sim.bin")" -eq 2097152
```

`chip.log`에서 DONE과 cycle을 확인한다. 단계 3의 SoC dump와 단계 4의 Chip dump는 메모리 구현과 cycle 정보가 다를 수 있으므로 보드 대조에는 단계 4의 파일을 사용한다.

## B. ZCU104 배포본 준비

Linux 빌드 진입점은 `bash fpga/bd/run_board.sh 125 "$RUN/vivado"`이다. 현재 래퍼는 `~/bin/vivado`를 호출한다. 실행 후 `out/board.bit`, `out/board.hwh`, `out/timing_impl.rpt`를 확인한다. 기존 Windows GUI 배포본을 쓰는 경우 [보드 기록 §0](BOARD_BRINGUP.md)의 같은 빌드 쌍을 사용한다.

배포 디렉터리에 `board.bit`, `board.hwh`, A의 `image.bin`, `dump_sim.bin`, `chip.log`, [run_chip.py](../pynq/run_chip.py)를 모은다. 펌웨어 소스 SHA와 FPGA 빌드 SHA를 각각 기록하고 아래 명령을 그 디렉터리에서 실행한다.

```bash
sha256sum board.bit board.hwh image.bin dump_sim.bin run_chip.py > SHA256SUMS
```

## C. ZCU104 PS Linux에서 비교

배포 디렉터리를 보드로 복사한 뒤 그 안에서 실행한다. 첫 보드에서는 [bring-up 절차](BOARD_BRINGUP.md)에 따라 overlay 적재와 AXI 접근을 먼저 점검한다.

```bash
set -euo pipefail
sha256sum -c SHA256SUMS
sudo python3 run_chip.py board.bit image.bin dump_sim.bin | tee board.log
cmp dump_sim.bin dump.bin
```

최종 PASS는 `cmp` 성공과 `board.log`의 DONE 값·cycle이 `chip.log`와 일치할 때 기록한다. 보드 스크립트는 데이터 차이를 출력하므로 자동 판정에는 `cmp` 결과도 사용한다. 실행 날짜, 두 소스 SHA, 두 로그, 비교 결과를 한 실행 기록에 보관한다.
