# hot/cold 분리 실험

작성: 2026-11-12 · 갱신: 2026-11-17 (서버 파일럿·로컬 비교 결과와 분석, 선배 답변, 과제 요구사항 대조: 1·2·4·5·6·7절) · 진행 상황 전체는 `notes/FEMU_진행상황.md`, 이 문서는 hot/cold 실험의 설계·실행 방법·결과만 다룸.

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
| `exp/hotcold2` | `3650f6880` | 빈도 기반 분류용 (7절). 로컬 worktree `~/femu-hotcold2`에만 있고 push 안 함. 11/17 기준 코드 변경 없음 |

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
- **11/13 로컬 결과로 확인**: `hot_ratio`는 정확히 1.0이었음. 하지만 `zone80`에서도 WAF 차이가 거의 없었음 (7.97 → 7.94). 위 예상 중 "치우친 워크로드에서 WAF 차이"는 맞지 않았고, 이유는 6.3절 (GC 75에서는 WAF가 약 8로 고정됨).

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
   - **11/12 확인 (서버 출력 기준)**: sudo는 `~/FEMU/build-femu/qemu-system-x86_64` **한 경로만** 허용됨. 그래서:
     - worktree의 `build-femu`로는 실행할 수 없어서, baseline을 `~/FEMU/build-femu`에 다시 빌드함 (`~/femu-baseline`의 소스로 configure). 실행은 `WT_PREFIX=$HOME/ ./run_one.sh FEMU zone80 0` (버전 이름 `FEMU` → 빌드 폴더 `~/FEMU/build-femu`, 결과 폴더 `~/femu-results/FEMU/`).
     - 버전을 바꿀 때마다 `~/FEMU/build-femu`를 그 버전으로 다시 빌드해야 함. `run_all.sh`로 두 버전을 한 번에 돌릴 수 없음.
     - `run_one.sh:59`의 강제 종료 `sudo pkill`이 거부됨 (`not allowed to execute '/usr/bin/pkill ...'`). 게스트가 정상 종료하지 않으면 다음 줄의 대기 루프가 끝나지 않음. **아직 고치지 않음.**
3. 게스트 준비 (VM을 한 번 수동으로 띄운 상태에서, 서버 터미널에서. 이미지가 같으므로 한 번만):
   ```bash
   ls ~/.ssh/id_*.pub || ssh-keygen -t ed25519
   ssh-copy-id -p 8080 femu@localhost
   ssh -p 8080 femu@localhost 'sudo apt update && sudo apt install -y fio nvme-cli && echo "femu ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/femu'
   ssh -p 8080 femu@localhost 'sudo -n true && which fio nvme && echo READY'
   ssh -p 8080 femu@localhost 'sudo poweroff'
   ```
   - **11/12 완료** (서버). `sudo`가 비밀번호를 물어야 하는 명령(위 세 번째 줄)은 터미널이 필요해서 `ssh -t -p 8080 ...`로 실행해야 함. `-t` 없이 하면 `sudo: a terminal is required to read the password`로 실패함.
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

검증 상태: 11/12에는 `bash -n` 문법 검사와 가짜 로그로 `parse.py` 동작만 확인했음. **11/12 서버 파일럿, 11/13 로컬 실행에서 실제로 동작함** (스냅샷 3개, `parse.py` 집계 정상. 6절). 남은 문제는 서버의 `sudo pkill` 거부 (4절).

## 6. 결과

### 6.1 서버 파일럿 (11/12, `exp/baseline`, `zone80`, rep0)

설정은 3절 그대로 (NAND 64GB, 노출 48GB, line 1024개, GC 75/95, `CAP=48g`). 실행 방법은 4절의 sudo 제약 참고.

| 지표 (측정 구간 S2−S1) | 값 |
|---|---|
| WAF | **7.98** |
| host / gc_write 페이지 | 12,582,912 / 87,822,336 |
| gc_count / erase 블록 | 6,126 / 392,064 |
| IOPS / 대역폭 | 22.1K / 90.4MB/s |
| 평균 / p99 지연 | 1.43ms / 55.8ms |
| 걸린 시간 | fill 41초, warmup 8분 52초 (1회 약 20분, 사용자 보고) |

### 6.2 로컬 비교 (11/13, `zone80`, rep0)

- 설정: `run-blackbox-local.sh` (NAND 8GB, 노출 6GB, line 128개, GC 75/95 → free ≤ 32 / ≤ 6), 측정 구간 6GiB (host 1,572,864페이지).
- 빌드: 로컬 worktree `~/femu-baseline`, `~/femu-hotcold1`의 `build-femu` (11/13). 로컬 KVM이 다시 동작해서 로컬에서 실행함.
- 결과 폴더: `~/femu-results/{baseline,hotcold1}/zone80/rep0/`. 두 `femu.log` 모두 스냅샷 3개, `STATS` 47줄.
- 표는 11/17에 `parse.py ~/femu-results`로 다시 집계한 값. (`exp-scripts/results.csv`는 커밋 안 한 파일이고 baseline 한 줄만 들어 있음.)

| 지표 (측정 구간) | baseline | hotcold1 |
|---|---|---|
| WAF | 7.9727 | 7.9362 |
| hot_ratio | 0 (카운터 없음) | **1.0000** |
| gc_write 페이지 | 10,967,040 | 10,909,696 |
| gc_count / erase 블록 | 765 / 48,960 | 761 / 48,704 |
| IOPS | 24,102 | 24,425 |
| 평균 / p99 / p99.9 지연 (µs) | 1,314 / 56,361 / 58,458 | 1,297 / 56,885 / 57,410 |

- 1회 실행이라 차이(WAF 0.5% 미만)가 의미 있는지는 반복이 필요함. 다만 6.3절 이유로 GC 75에서는 차이가 날 여지가 거의 없음.
- 로컬 수치는 동작 확인용임 (2.1절 원칙: 발표 수치는 서버 결과). 로컬과 서버 모두 WAF가 약 8로 같은 현상을 보임.

### 6.3 분석: GC 75에서는 WAF가 약 8로 고정됨

**코드로 확인한 사실** (9.0.1, `ad2d9fc71`):
- 배경 GC는 `free_line_cnt <= gc_thres_lines`일 때 요청 하나를 처리한 뒤 한 번 돎 (ftl.c:7-9, 998-999). `gc_thres_lines = (int)((1 - 0.75) × tt_lines)` (ftl.c:279-280) → 서버 256, 로컬 32.
- greedy는 배경 GC에서 victim의 `ipc < pgs_per_line/8`(= 2,048)이면 회수하지 않음 (ftl.c:678).

**측정으로 확인한 사실**: 세 실행 모두 `gc_write / gc_count = 14,336 = 16,384 − 2,048`. 즉 victim line은 **invalid가 정확히 2,048개(line의 1/8)일 때** 회수됐고, WAF = 16,384 / 2,048 = 8에 가까움.

**해석 (계산과 추정)**:
- OP 25%와 배경 GC 기준 25%가 같음. 노출 공간을 100% 채우면 데이터가 line 768개(서버)를 차지해서, free line이 항상 기준(256) 이하가 됨 → 배경 GC가 계속 켜져 있음.
- 4KB 랜덤 쓰기 하나는 invalid 페이지 하나를 만듦. invalid가 쌓이자마자 어떤 line이든 2,048개가 되는 순간 회수되므로, **데이터를 어떻게 배치하든(hot/cold 분리) WAF는 약 8에 머묾.** 예외는 line이 닫힐 때 이미 invalid가 2,048개를 넘는 경우(아주 hot한 데이터만 모은 line)뿐임.
- 배경 GC가 시작되기 전의 여유 line ≈ `tt_lines − gc_thres_lines − 768 × f` (f = 노출 공간 중 실제로 쓰는 비율). GC 75, f = 1이면 여유가 0임. 여유를 만들려면 GC 기준을 올리거나(예: 90), 워크로드가 쓰는 범위(f)를 줄여야 함.
- 따라서 빈도 기반 분류(hotcold2)로 바꿔도, GC 75 + 100% 채움 조건에서는 WAF가 약 8 근처일 가능성이 큼 (추정, 실험으로 확인 필요).
- p99 약 55.8ms는 GC 1회가 LUN 하나를 점유하는 시간과 비슷함: valid 14,336 / LUN 64 = 224페이지 × (읽기 40 + 쓰기 200µs) + erase 2ms ≈ 55.8ms (계산).

### 6.4 선배 답변 (11/17 기록, 사용자 전달)

1. GC threshold는 **원칙적으로 바꾸지 않고**, 다른 방법으로 WAF를 개선하는 과정을 경험하도록 설정한 것임. 높게 설정하면 기본 WAF는 줄일 수 있음. 어려우면 바꿔서 해도 됨.
2. 결과는 baseline과 ours의 WAF 변화를 **시간에 따른 꺾은선 그래프**로 나타내면 됨.

→ 6.3절 분석상 GC 75를 유지하려면 배치만 바꾸는 것으로는 부족하고, GC 동작(victim 선택, GC가 옮기는 데이터의 배치, free line 선택 등)이나 워크로드 범위도 함께 봐야 함 (추정). 7절 참고.

## 7. 과제 요구사항과 현재 상태

선배 과제 PDF의 요구사항. 원본 PDF는 이 저장소에 없고, 11/12 다른 세션에서 PDF 이미지를 보고 정리한 내용을 옮긴 것이라 문구가 원문과 다를 수 있음.

| 요구사항 | 상태 (11/17) |
|---|---|
| 1) **라인 재설계** | 일부. `hot_wp`만 추가함. `struct line`, free line 선택, GC는 그대로 |
| 2) **hot/cold 판단**: 일정 시간 동안의 LBA 요청 빈도 + 블록 erase 횟수 | 안 됨. hotcold1은 "이미 매핑된 LPN = hot" 규칙이라 빈도도 erase 횟수도 쓰지 않음 |
| 3) **WAF 계산 기능 추가** | 됨. `exp/baseline`의 카운터, 스냅샷, `STATS` 주기 출력 |
| 시나리오 1 (분리 미적용) vs 시나리오 2 (분리 적용) | 1 = `exp/baseline` 측정 완료. 2는 hotcold1로 로컬 1회만 측정 |
| 시각화: WAF 비교 그래프와 결과 분석 | 안 됨. 선배 답변대로 시간에 따른 꺾은선 그래프로 할 예정 |

- 과제의 주제는 "수명 극대화"임.
- **선배에게 확인할 것**: erase 횟수를 (a) hot/cold **판단**에 쓰는지(자주 지워지는 블록에 있던 데이터를 hot으로 봄), (b) **배치**에 쓰는지(hot 데이터는 erase가 적은 line에 둠). 9.0.1에서 `nand_block.erase_cnt`는 증가만 하고 어디서도 읽지 않음 (ftl.c:614).

다음 방향 (계획, 아직 구현 안 함):
- **hotcold2 (빈도 기반 판단)**: LPN마다 쓰기 횟수 카운터(`uint8_t`)를 두고, 일정 window(예: 노출 LPN 수만큼 쓸 때마다)마다 절반으로 줄임. 카운터가 N 이상이면 hot (N = 2, 4, 8 비교).
- **라인 재설계 후보**: GC가 옮기는 데이터를 별도 write pointer로 분리, free line을 고를 때 erase 횟수가 적은 line 우선. 수명 비교를 위해 블록별 erase 횟수 분포도 측정.
- **시간에 따른 WAF 그래프**: `femu.log`의 `STATS` 줄(host 10만 페이지마다 누적 카운터 출력, `exp/baseline` ftl.c:872-873)에서 구간 WAF를 계산해 baseline과 ours를 같은 축에 그림. 스크립트는 아직 없음.
