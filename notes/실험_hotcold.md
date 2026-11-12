# hot/cold 분리 실험

작성: 2026-11-12 · 진행 상황 전체는 `notes/FEMU_진행상황.md`, 이 문서는 hot/cold 실험의 설계·실행 방법·결과만 다룸.

## 1. 브랜치와 역할

- **실험 코드는 `exp/*` 브랜치, 문서와 실험 스크립트는 `ftl-test`.** `exp/*`에서는 `notes/`를 고치지 않음 (세 브랜치가 같은 파일을 갖고 있어서, 한쪽만 고치면 갈라지고 merge 때 충돌함).
- 측정용 코드(카운터, 스냅샷)는 **항상 `exp/baseline`에 먼저 커밋하고 hot/cold 브랜치에 merge**함. 두 쪽의 측정 방법이 같아야 비교가 됨.
- 분류 규칙을 바꾸는 새 실험은 `exp/hotcold2`, `exp/hotcold3` …으로 `exp/baseline`(또는 `exp/hotcold1`)에서 만듦.

| 브랜치 | 커밋 | 내용 |
|---|---|---|
| `exp/baseline` | `383cb5044` | 9.0.1 FTL + 카운터 (사용자 작성): `host_write_pages`, `gc_write_pages`, `gc_count`, `erase_count`(블록 단위), WAF |
| | `cecdf2320` | 스냅샷 명령 (사용자 작성): flip `cdw10=8` → `ftl_print_stats("SNAPSHOT")`, 주기 출력(10만 페이지마다 `STATS`)을 덮어쓰기 `if` 밖으로 옮김 |
| `exp/hotcold1` | `f980c7c00` → `8d00e3819` | Claude가 만든 참고 구현과 그 revert (사용자가 직접 따라 치기 위해 되돌림, 답 맞춰보기용으로 기록에 남김) |
| | `75dd49abf` | 사용자 구현: 10.1 `hot_cold_sep` 규칙 |
| | `3650f6880` | `exp/baseline` merge (스냅샷 코드 반영) |

`exp/hotcold1`이 baseline과 다른 곳 (`git diff exp/baseline exp/hotcold1 -- hw/`):
- `ftl.h`: `struct ssd`에 `hot_wp` 추가.
- `ftl.c`: `ssd_advance_write_pointer`, `get_new_page`가 write pointer를 인자로 받음 (GC 호출은 `&ssd->wp`). `ssd_hot_wp()`가 처음 쓸 때 free line을 가져오고 없으면 `wp`로 대체. `ssd_write`에서 `bool hot = mapped_ppa(&ppa)`로 분류해 hot은 `hot_wp`로 씀. `hot_write_pages` 카운터.
- 분류 기준을 바꾸는 실험은 `bool hot = ...` 한 줄만 바꾸면 됨.

## 2. 10.1 hot/cold 규칙과 예상 (추정)

- 10.1 규칙: 이미 매핑된 LPN을 다시 쓰면 hot, 처음 쓰면 cold. hot은 별도 write pointer, GC 이동은 기본 write pointer (10.1 `ftl-map.c:62-71`, `ftl-line-gc.c:300-325, 606-610`).
- **장치를 한 번 채운 뒤에는 호스트 쓰기가 사실상 전부 hot이 됨.** 그래서 실제로 갈리는 것은 "호스트가 쓴 데이터(`hot_wp`)"와 "GC가 옮긴 데이터(`wp`)"임.
- 예상 (측정 전, 코드로 추론한 것):
  - `uniform`에서는 차이가 작고, 치우친 워크로드(`zone80`, `zone95`)에서 WAF 차이가 날 것.
  - 측정 구간의 `hot_ratio`(Δhot / Δhost)는 1에 가까울 것. 이 값으로 분류가 실제로 동작하는지 확인하고, `hotcold2`(분류 기준 개선)의 근거로 씀.

## 3. 실험 설계

| 구분 | 내용 |
|---|---|
| 바꾸는 것 | FTL 버전(`baseline`, `hotcold1`), 워크로드(`uniform`, `zone80`, `zone95`) |
| 고정 | 서버 geometry(`run-blackbox-server.sh`: NAND 64GB, 노출 48GB, line 1024개, GC 75/95%), VM `-m 4G -smp 4`, fio 4KB·QD32·seed 1234 |
| FTL 지표 | WAF, `gc_write_pages`, `gc_count`, `erase_count`, `hot_ratio` (측정 구간 차분) |
| fio 지표 | IOPS, 대역폭, 평균·p99·p99.9 완료 지연 (`measure.json`) |

워크로드 (측정 구간은 모두 4KB 랜덤 쓰기, 분포만 다름):

| 이름 | fio 옵션 | 의미 |
|---|---|---|
| `uniform` | `--random_distribution=random` | 대조군 |
| `zone80` | `zoned:80/20:20/80` | 쓰기 80%가 LBA 20%에 몰림 |
| `zone95` | `zoned:95/5:5/95` | 더 치우친 경우 |

실행 1회 (`exp-scripts/run_one.sh`):

```
FEMU 새로 시작 (FTL 상태·카운터 0)
 → fill    : 순차 쓰기로 노출 용량 100% (bs=1M, QD32)      → 스냅샷 S0
 → warmup  : 측정과 같은 워크로드, CAP(기본 48g)만큼       → 스냅샷 S1
 → measure : 같은 워크로드, CAP만큼 (fio JSON 저장)        → 스냅샷 S2
 → 게스트 종료, FEMU 로그 복사
WAF = (Δhost + Δgc) / Δhost,  Δ = S2 − S1
```

- `--norandommap`: 없으면 fio가 한 바퀴 동안 모든 블록을 정확히 한 번씩 써서 진짜 랜덤 덮어쓰기가 아님.
- 반복: 조합마다 3회. FTL 카운터는 seed 고정이라 거의 같을 것으로 예상(exp5 때 3회 동일), 지연·IOPS는 평균±표준편차로 정리.
- 2 버전 × 3 워크로드 × 3회 = 18회. **파일럿 1회로 시간을 먼저 재고** `CAP`·반복 수를 정함.

## 4. 서버 준비 (cpslab02)

1. 버전별 worktree와 빌드:
   ```bash
   cd ~/FEMU && git fetch origin
   git worktree add ~/femu-baseline exp/baseline
   git worktree add ~/femu-hotcold1 exp/hotcold1
   # 각 worktree에서
   mkdir -p build-femu && cd build-femu
   cp ../femu-scripts/femu-copy-scripts.sh . && ./femu-copy-scripts.sh . && ./femu-compile.sh
   ```
   - 코드를 고친 뒤에는 그 worktree에서 `git pull` → `build-femu`에서 `make -j$(nproc)`.
   - 11/12: `git worktree add ~/femu-hotcold1`이 한 번 실패해서 빈 `build-femu`만 생긴 적이 있음. `git worktree list`로 확인할 것.
2. 실행 권한 (11/12 기준):
   - KVM: `/dev/kvm` 권한 없음 (`Could not access KVM kernel module: Permission denied`). 관리자에게 `kvm` 그룹 추가를 요청할 수 있음. 추가되면 재접속 후 `run-blackbox-server.sh`에서 `sudo`를 뺀 사본(`run-nosudo.sh`)을 `RUN=./run-nosudo.sh`로 씀.
   - sudo: 한때 `qemu-system-x86_64` 실행이 sudoers에서 거부됐으나, 이후 sudo로 실행 가능해졌다고 함 (사용자 보고). 지금은 원본 `run-blackbox-server.sh`(sudo 포함)로 실행함.
   - **비밀번호는 스크립트·문서에 넣지 않음.** `run_all.sh`가 시작할 때 `sudo -v`로 한 번 입력받고 60초마다 갱신함.
3. 게스트 준비 (VM을 한 번 수동으로 띄운 상태에서, 서버 터미널에서. 이미지가 같으므로 한 번만):
   ```bash
   ls ~/.ssh/id_*.pub || ssh-keygen -t ed25519
   ssh-copy-id -p 8080 femu@localhost
   ssh -p 8080 femu@localhost 'sudo apt update && sudo apt install -y fio nvme-cli && echo "femu ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/femu'
   ssh -p 8080 femu@localhost 'sudo -n true && which fio nvme && echo READY'
   ssh -p 8080 femu@localhost 'sudo poweroff'
   ```
   - 11/12 기준 완료 여부 미확인.
4. 동시에 하나만 실행: 두 버전이 같은 게스트 이미지와 8080 포트를 씀. `run_one.sh`는 이미 떠 있는 FEMU가 있으면 시작하지 않음.

## 5. 스크립트 (`exp-scripts/`, `ftl-test`)

버전과 무관한 도구라 `ftl-test`에 한 벌만 둠. 서버에서는 `~/FEMU`(메인 clone)를 `ftl-test`로 두고 실행.

| 파일 | 하는 일 |
|---|---|
| `run_one.sh <버전> <워크로드> <회차>` | FEMU 시작 → 게스트 부팅 대기 → fill/warmup/measure + 스냅샷 3개 → 종료 → `~/femu-results/<버전>/<워크로드>/rep<회차>/`에 `fill.json`, `warmup.json`, `measure.json`, `femu.log` 저장. 실패해도 게스트를 끄고 로그를 남김 |
| `run_all.sh` | 모든 조합 실행 (회차를 바깥 루프에 두어 시간에 따른 서버 상태 변화가 두 버전에 고르게 섞이게 함). `VARIANTS`, `WORKLOADS`, `REPS`로 범위 조정 |
| `parse.py <결과 폴더>` | 실행마다 CSV 한 줄: 측정 구간 FTL 차분(S2−S1)과 fio 지표 |

환경 변수: `RUN`(기본 `./run-blackbox-server.sh`), `CAP`(기본 `48g`), `WT_PREFIX`(기본 `~/femu-`), `RESULTS`(기본 `~/femu-results`).

```bash
# 서버: 파일럿 1회 (시간 측정)
cd ~/FEMU/exp-scripts && ./run_one.sh baseline zone80 0

# 서버: 전체 (tmux 안에서)
tmux new -s exp
cd ~/FEMU/exp-scripts && ./run_all.sh 2>&1 | tee run_all.log

# 결과 정리
python3 parse.py ~/femu-results > results.csv

# 로컬 디버깅 (작은 크기, 로컬에도 같은 방식으로 worktree를 만든 경우)
CAP=1g RUN=./run-blackbox-local.sh ./run_one.sh baseline uniform 0
```

검증 상태 (11/12): `bash -n` 문법 검사와 가짜 로그로 `parse.py` 동작만 확인함. **실제 FEMU로는 아직 실행하지 않음.**

## 6. 결과

(아직 없음)
