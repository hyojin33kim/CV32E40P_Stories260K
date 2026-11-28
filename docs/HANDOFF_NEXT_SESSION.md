# 새 세션 인계 (2026-11-28 15:20)

새 세션은 이 파일과 `docs/DDR_ARCH_PLAN.md`, `docs/EXPERIMENT_LOG.md`(E16, E17), `docs/VERIFICATION_PLAN.md`를 읽고 시작한다. 코드와 시험 상태는 기억에 의존하지 말고 `git log`, `git status`로 다시 확인한다.

## 작업 위치
- 워크트리: `/home/hyojinkim/work/3_Company_PJT/CSO/Server/LLM/CV32E40P_Stories260K/.claude/worktrees/g0-repro`, 브랜치 `verification-followup`. 푸시는 `git push origin verification-followup`. PR 병합은 소유자가 한다.
- Vivado 작업 폴더는 `/mnt/e/fpga_work/`(chip_dm120b, chip_g120b 등). Vivado는 호스트 메모리를 최대 약 13 GB 쓰므로 합성은 한 번에 하나만 돌린다.

## 확인된 것 (측정)
- 120 MHz 합성(OOC, 배치배선 후)이 DM 포함 빌드와 DM 없는 빌드 모두 통과: WNS +0.752 / +0.673 ns (E17). 수정 전 DM 포함은 -3.114 ns였고 원인은 코어 클럭 게이트(BUFGCE)로 생긴 skew였다.
- `reproduce.sh quick` 42/42, 사이클 변화 +0. `dbg/tb_dm` PASSED. 42개의 구성은 `docs/REPRODUCE_CHECKS.md`.
- 높은 클럭: 확인된 한계 없음. 이전 기록은 150 MHz 최선 -0.001 ns(미달). 오늘 스윕(143 MHz)은 중단했고 결과가 없다.

## 하지 않았거나 확인하지 못한 것
- 보드 실행 없음(보드 없음, D5 미정). DM 포함 비트스트림 없음. JTAG은 PS EMIO GPIO로 구동하기로 결정(D8)했으나 구현과 OpenOCD 접속은 미확인.
- 직결한 클럭 게이트는 시뮬레이션에 쓰이지 않음(시뮬레이션은 래치 모델). xsim과 보드에서 확인 필요.
- 15M 모델 파일은 받지 않았다(사용자가 다운로드 명령을 두 번 거부했다. 허락 여부를 다시 물을 것). 주소는 사용자가 알려 준 `https://huggingface.co/karpathy/tinyllamas/resolve/main/stories15M.bin`.

## 진행 중: DDR 구조 (결정 D9, `docs/DDR_ARCH_PLAN.md`)
P0 측정(KV를 DDR에 두었을 때 어텐션 읽기 비용, 배치 두 가지 비교)이 준비 단계에서 멈췄다.
- 새 파일(실행한 적 없음, 이 커밋에 포함): `acc/tb_kvddr/test_kv.c`, `acc/tb_kvddr/run_test.py`.
- **막힌 곳:** `python3 acc/tb_kvddr/run_test.py`가 펌웨어 빌드(`build.sh`, `SRC=acc/tb_kvddr/test_kv.c CFLAGS_EXTRA=-O2`)에서 실패했다. 오류 메시지를 아직 보지 못했다. 다음에 `build.sh`를 직접 실행해 메시지를 읽는 것부터 한다.
- DDR 시뮬레이터 `obj_axi_ddr/Vchip_axi_ddr_top`은 오늘 15:05에 현재 RTL로 다시 빌드했다.
- P0가 통과하면 P1(쓰기 경로 `axi_ext_wr`와 하드웨어 인터락, 변조 시험 포함)로 간다. 가설: KV를 헤드마다 연속으로 놓으면 어텐션 읽기가 긴 버스트가 된다(코드를 읽고 한 판단이며 아직 측정 전).

## 주의 (이 세션에서 겪은 것)
- `pkill -f 패턴`은 같은 문자열을 가진 자기 쉘 명령까지 종료시킨다. PID로 종료한다.
- `pgrep -f`로 대기 루프를 만들면 자기 명령에 걸린다. 빌드 완료는 산출물 시간으로 본다.
- 사용자는 긴 명령 실행이나 다운로드 앞에서 중단시키는 일이 있다. 오래 걸리는 작업은 한 줄로 이유를 먼저 말한다.
- 사용자 선호: 결론 먼저, 사실과 추정을 구분, 완료/미완료/미검증을 나눠 보고(전역 지침과 메모리 참고).
