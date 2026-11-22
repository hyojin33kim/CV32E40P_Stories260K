# Stories260K 단일 Tile 개발 흐름

**기준 구성** · Stories260K, 기본 프롬프트 `Once upon a time`, 16 step, W8 가중치·FP32 누산, Option A, D2, 온칩 가중치, ZCU104 PL 125 MHz. Linux 개발 서버에서 이미지와 기대값을 준비하고 ZCU104의 PS Linux에서 실측한다. 16은 프롬프트 처리를 포함한 실행 step 수다.

## 자동화 목표와 실행 기준

Linux 서버의 단일 실행 명령이 **변경 감지 → 영향받는 산출물 재생성 → 검증 → Vivado bitgen → 원격 보드 실행 → 결과 회수**를 처리한다. 다음은 구현 목표다. 아래 A–C는 현재 스크립트로 단계별 실행을 재현하는 절차다.

| 변경 입력 | 자동 실행 범위 | 재사용 조건 |
|---|---|---|
| 모델·토크나이저·양자화 규칙 | Golden과 펌웨어 이미지 → SoC 회귀·Chip 기대값 → 보드 | 유효한 FPGA 배포본의 구현 입력이 동일하면 bit/hwh 재사용 |
| 펌웨어·링커·메모리맵 | 펌웨어 이미지 → SoC 회귀·Chip 기대값 → 보드 | 레지스터나 메모리맵 계약이 RTL·BD 입력에도 반영되면 FPGA 경로도 실행 |
| RTL·IP 설정 | 관련 RTL 테스트 → SoC 회귀·Chip 기대값, Vivado 합성·배치배선·bitgen → 보드 | 펌웨어와 모델 입력이 동일하면 이미지 재사용. 현재 통합 드라이버는 실행 중 이미지를 다시 만들 수 있음 |
| 보드 BD·XDC·클록·Vivado 환경 | Vivado 합성 → 배치배선 → setup/hold 확인 및 bitgen → 보드 | 기존 Chip 기대값은 메모리 타이밍과 인터페이스 등 시뮬레이션 가정이 같을 때 재사용 |
| PYNQ 호스트 코드·보드 설정 | 보드 실행 및 결과 회수 | 입력 bit/hwh·이미지·기대값의 해시 확인 |

각 실행은 Git SHA, 보드 프로필, 도구 버전과 설정, 입력·출력 파일의 SHA-256을 기록한다. 재사용 여부는 단계별 입력 지문과 이전 PASS 결과로 판정한다. 도구나 설정이 바뀌면 해당 단계도 재실행한다. 상류 실패에 의존하는 단계는 `BLOCKED`로 기록하고, 독립 단계의 결과는 계속 수집한다. 배포 전에는 조합된 산출물의 레지스터맵, 메모리 구성, 클록을 보드 프로필과 대조한다.

### Vivado와 원격 보드

1. **Linux Vivado**에서 실행별 작업 디렉터리를 사용한다. 합성, 배치배선, 타이밍 보고서, bitgen 각각의 결과를 기록한다. Vivado 종료 상태, setup/hold, bit/hwh 파일의 동일 빌드 여부를 확인한 뒤 보드에 넘긴다. 현재 래퍼의 마지막 보고서 출력과 별개로 Vivado 실패 상태를 호출자에 전달하도록 보강해야 한다.
2. **ZCU104 프로필**에 SSH 대상, 보드 작업 경로, PYNQ 환경, 보드 실행 명령을 둔다. 실행기가 같은 보드에 대한 작업을 직렬화하고, SHA 검증된 배포본을 실행별 경로로 전송해 타임아웃을 적용한다. 다른 원격 보드는 해당 보드의 배포·실행 명령과 PASS 조건을 프로필에 정의한다.
3. **Linux 서버로 회수**할 파일은 원격 stdout/stderr, 종료 상태, `dump.bin`, DONE·cycles, 비교 결과다. 원격 실행이 실패해도 생성된 로그를 회수한다. 연결·타임아웃 때문에 실행 결과를 얻지 못한 경우와 하드웨어 비교 불일치를 별도로 기록한다.

### 실패 로그와 수정 제안

`~/runs/stories260k/<run-id>/`에 실행 명세, 단계별 명령·종료 코드·로그, 판정 결과를 모은다. RTL 실패 시 첫 mismatch와 재현 명령을, Vivado 실패 시 최초 오류 또는 timing 경로를, 보드 실패 시 명령 종료 상태와 첫 dump 차이 주소를 남긴다.

수정 제안은 **실패 단계 → 로그·보고서 근거 → 원인 가설 → 수정할 파일과 변경안 → 재검증 명령** 순서로 작성한다. 예를 들어 timing이 실패하면 가장 나쁜 setup/hold 경로와 관련 RTL·제약을 인용한다. 보드 dump가 다르면 첫 차이 주소를 메모리맵에 대조하고 같은 이미지로 좁힌 재현 절차를 붙인다. 수정 후보는 별도 커밋에서 동일 입력으로 검증한다.

**구현 순서** · A를 하나의 실행기로 묶고 실패 전달을 확인한다. 이어 Linux Vivado를 연결하고, 마지막으로 보드 프로필과 로그 회수를 연결한다. 최초 통합 완료 기준은 RTL 변경 한 건으로 **회귀 PASS → 새 bit/hwh 생성 → 원격 ZCU104 dump 비교 PASS**까지 실행하고, 실패한 실행 한 건에서도 관련 로그와 수정 제안이 남는 것이다.

## 모델 변경 시 RISC-V 프로파일과 HW·메모리 개선 후보

모델이나 연산 정밀도가 바뀌면 **CPU 기준 실행 → 동일 워크로드의 병목 분리 → 개선 후보 평가**를 2단계와 가속 검증 사이에 추가한다. 이 절은 자동화 목표다. CPU 기준이 Golden 검증을 통과하면 프로파일을 실행하고, 결과와 개선 후보를 남긴다. 기존 HW로 실행할 수 있는 구성은 다음 검증으로 이어간다. RTL 추가·수정은 후보를 선택한 뒤 별도 커밋으로 검증한다.

| 단계 | 입력 | 출력과 판정 |
|---|---|---|
| CPU 기준 | 모델·토크나이저 SHA, 수치 형식, workload, CV32E40P 클록·FPU·툴체인, 메모리맵 | 가속기 호출을 끈 펌웨어와 Golden 비교. 수용 오차는 수치 형식별 명세를 적용한다. 모델·KV·scratch의 용량 적합성을 먼저 확인하고, 수용 불가 시 필요한 용량과 초과 구간을 기록한다. 외부 메모리로 측정할 경우 CPU 읽기 경로를 먼저 검증한다. |
| 연산·메모리 프로파일 | 동일 펌웨어와 입력, prefill 길이·decode context 조합 | 연산별 호출 수·cycle·MAC, W/KV/activation별 주소·읽기/쓰기 바이트, 메모리 대기, 최대 동시 SRAM 사용량. TTFT와 decode cycle/token은 구분한다. 계측 합계와 전체 실행 cycle의 차이를 미분류 항목으로 표시한다. |
| 후보 비교 | 위 측정과 목표 TTFT·ms/token, SRAM·DDR 용량 및 유효 BW, FPGA 자원·클록 제약 | 연산 오프로딩, SRAM 배치·재사용, DDR burst·동시 요청 등 최대 세 후보. 각 후보에 예상 절감 cycle/token, 추가 SRAM, DDR traffic 변화, 수치 정확도·타이밍 영향, 가정과 확인 시험을 붙인다. |

**병목 판정** · CPU/FPU 설정과 입력을 고정하고 동일 접근 경로에서 메모리 응답 지연·대역폭을 바꿔 cycle 민감도를 비교한다. 가능한 경우 빠른 응답 기준과 타깃 DDR 조건을 함께 실행한다. 빠른 메모리에서도 비용이 큰 구간은 HW 후보로 평가하고, 오프로딩 예상 cycle에는 명령 발행·DMA·동기화 비용을 포함한다. 대기 시간이 크게 줄어드는 구간은 주소·burst·outstanding을 확인한다. SRAM 증설은 buffer lifetime과 재사용 분석에서 **추가 SRAM으로 실제로 줄일 수 있는 DDR 바이트**가 확인된 경우에 평가한다.

**순위 기준** · 실제 workload 분포에서의 E2E 절감량으로 비교한다. 순차 실행에서 후보 구간의 기존 cycle share는 해당 구간을 제거했을 때의 절감 상한이다. 각 안의 순절감은 기존 구간 cycle에서 새 실행·전송·제어의 임계 경로 cycle을 뺀 값으로 추정한다. 필요 BW는 단계별 실제 DDR 전송량을 목표 시간으로 나눈 값으로 계산하고, burst 효율과 동시 요청 조건을 반영한 **유효 BW**와 비교한다. 중첩 실행 구간은 합산 대신 타임라인을 사용한다.

**기존 코드 연결** · [run_prof.py](../prof/run_prof.py)는 Stories260K에서 ctx 1/128/512의 연산별 cycle과 W/KV/activation 읽기, `summary.json`을 제공한다. 소스 주석·함수 형태와 고정 주소를 사용하므로 다른 모델에는 안정적인 연산 ID와 tensor 메모리맵을 입력으로 연결한다. prefill 집계, 물리 DDR 전송량·stall, SRAM peak는 별도 계측 또는 모델 확장이 필요하다. [P1 보고서](P1_REPORT.md)의 CPU 잔여 연산 분석과 [DDR 모델](../ddr/ddr_model.py)을 출발점으로 하되, 보고서는 **RTL 측정·모델 추정·보드 실측**의 근거를 항목별로 표시한다.

실행별로 `profile/summary.json`, 원시 trace, `profile/recommendations.md`를 보관한다. 프로파일러의 첫 검증은 기존 Stories260K 결과를 재현한 뒤, **HW 후보 한 건과 메모리 후보 한 건의 예상 효과를 실제 RTL A/B 실행으로 비교**하는 것이다. 최종 채택은 동일 workload에서 수치 검증을 유지하고 목표 지연·자원·타이밍 조건을 만족하는지로 판단한다.

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
