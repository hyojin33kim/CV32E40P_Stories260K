# ④-b VFU: softmax · SiLU · expf 가속, bit-exact (2026-11-14)

## 결론
- **expf를 포함한 softmax와 SwiGLU를 HW로 옮기고도 bit-exact 유지.**
  단위 테스트 1,048,576 원소 불일치 0, single-step ctx 1/128/512 logits·KV가 HOLD와 bit 동일, 메모리 조건 24종 bit 동일.
  E2E 연속 생성 결과는 아래 E2E 절.
- **토큰당 (SW 기준선 대비, 4 B/cycle)**: ctx1 **2.00×**, ctx128 **2.39×**, ctx512 **2.69×** (④-a까지 1.82/1.64/1.55×).
- 남은 최대 항목(ctx512): softmax 1.42M(48%) — VFU가 FPU 1개로 원소를 순차 처리(원소당 ≈69 cycles). 다음 레버는 lane 병렬화.

## 설계 (사실)
| 항목 | 내용 |
|---|---|
| 모듈 | `acc/vfu.sv`, MMIO 0x3000_0040 (CMD/STATUS/A/B/N/SCALAR/LAST_CYCLES) |
| 명령 | 1 softmax(a,n) · 2 a[i]=(a[i]·(1/(1+expf(-a[i]))))·b[i] · 3 a[i]/=s · 4 a[i]=expf(a[i]) |
| 산술 | `cv32e40p_fp_wrapper` 1개(CPU FPU와 동일 모듈: ADD/SUB/MUL/DIV/F2I/I2F). 연산 1개씩 handshake(나눗셈은 다중 cycle) |
| expf | picolibc 1.8.6 `newlib/libm/math/sf_exp.c`(fdlibm)의 **컴파일된 연산 순서 그대로**: 비트 패턴 범위 검사(NaN·Inf·0x42b17217·0x42cff1b5·0x3eb17218·0x3f851592·0x34000000) → k=(int)RTZ(x·invln2±0.5) → 5항 다항식 → (x·c)/(2−c) → 지수 가산, k<−125이면 2^−100 곱 |
| 음수 계수 | 컴파일러가 `a + P2/P4`를 `a − |P2|/|P4|`로 바꿈 → 동일하게 구현(IEEE에서 bit 동일) |
| max | softmax의 `x[i] > max`는 IEEE 비트 패턴 정수 비교(+0 = −0, 유한값) — flt.s와 동일 |
| 메모리 | gemv_acc와 master 포트 공유(CPU가 명령마다 대기 → 동시에 하나만 busy) |
| 펌웨어 | `-DUSE_ACC_VFU`: softmax → cmd 1, SwiGLU 루프 → cmd 2. 미정의 시 코드 byte 동일 확인 |

## 검증 (사실)
| 항목 | 결과 |
|---|---|
| 단위 테스트 `vfu/run_test.py 4 65536` | exp·softmax·silu·divs 각 4 seed × 65,536 = **1,048,576 원소, 불일치 0** |
| exp 입력 | 모든 임계값 ±64 ulp(양·음), ±0·±inf·NaN·±FLT_MAX·subnormal, k<−125/subnormal 결과 구간, |x|<2⁻²³, 균일 범위, softmax형 [−40,0], 무작위 비트 패턴 |
| softmax 입력 | 길이 1/2/8/512/무작위, 동점·±0 포함 |
| single-step (`prof/acc_all_L0_G1`) | ctx 1/128/512 logits+KV HOLD와 bit 동일 |
| 메모리 스윕 (`acc/sweep/acc_all_L0_G1`) | 24 조건 bit 동일 |
| SoC 회귀 | VFU idle 시 HOLD dump byte 동일, FFN+QK/AV 8 step cycles 이전과 동일 |

## 성능 (사실)
| | SW 기준선 | FFN+QK/AV (④-a) | + VFU (④-b) |
|---|---:|---:|---:|
| ctx1 | 1,454,871 | 798,337 (1.82×) | **728,297 (2.00×)** |
| ctx128 | 3,039,674 | 1,852,500 (1.64×) | **1,272,041 (2.39×)** |
| ctx512 | 7,854,556 | 5,064,342 (1.55×) | **2,925,226 (2.69×)** |

영역별 ctx512: softmax 3,490,124 → 1,417,128, SwiGLU 129,883 → 55,095.
원소당 (단위 테스트): exp SW 141 → HW 63 cycles, softmax 206 → 105, silu 197 → 103, divs 57 → 58.

**QK 뒤 `/√8`는 CPU 유지**: VFU divs로 옮기면 QK 영역 603,379 → 639,939(+6%)로 느려짐.
나눗셈기 지연(≈20 cycles, CPU와 동일 유닛)이 지배하고 VFU는 load/store가 추가되기 때문.

메모리 스윕 ctx512: 4 B/cycle 2.69×, 2 B/cycle 2.24×, 1 B/cycle 1.68× (VFU 부분은 버퍼 내 계산이라 대역폭 영향 작음).

## E2E 연속 생성
(실행 완료 후 기입)

## 한계 / 미검증
- expf 전수(2³²) 비교는 하지 않음 — RTL sim 속도상 불가. 위 1M 원소 + E2E로 대체.
- FPU 1개 순차 실행: 원소당 exp ≈ 연산 25~30개 + 나눗셈 1회. FPGA 타이밍 미검증(조합 FPU 가정은 ③과 동일).
- NaN 입력은 단위 테스트에서만(softmax/SiLU 실제 입력에는 없음).

## 다음
- VFU lane 병렬화: 원소별 expf는 독립 → P개 sequencer/FPU. softmax 합(sum)은 원소 순서대로 1개 가산기에서 누적해야 bit-exact 유지.
- GEMV lane 확장, 메모리 모델 현실화(로드맵 순서).
