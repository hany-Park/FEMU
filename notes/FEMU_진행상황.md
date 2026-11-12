# FEMU 코드 분석 진행 상황 (인수인계용)

작성: 2026-10-22 · 갱신: 2026-10-23 (`ftl.h` 구조체 정리 완료, 5·6절), 2026-11-02 (코드 기준을 9.0.1로 변경, 2절 / 9.0.1 재확인과 노션 개편, 5.9·6절 / 로컬·서버 실행 스크립트 분리, 2.1절), 2026-11-12 (hot/cold 실험 시작: 실험 브랜치·서버 환경·스크립트, 1·2·2.1·3·6절, 상세는 `notes/실험_hotcold.md`) · 이 문서만 읽어도 지금까지의 진행 상황을 따라올 수 있도록 정리한 것임.

## 1. 목적과 작업 방식

- 목적: FEMU BlackBox SSD(BBSSD) FTL 코드를 이해하고 발표를 준비함. 11/12부터는 **hot/cold 분리 실험**도 함 (`exp/*` 브랜치에서만 코드를 고침, `notes/실험_hotcold.md`). 이전 문구("코드 수정·빌드·실험은 하지 않음")는 실험을 시작해서 고침.
- 선임이 요구한 발표 질문 5개: ① I/O 요청 전체 흐름 ② latency 계산 ③ bandwidth 계산 ④ WAF 계산 ⑤ GC·Deadline(요청 큐) 재설계.
- 설명 방식: 한국어, 파일 경로와 줄 번호를 근거로 들 것, 코드로 확인한 사실과 추정을 구분할 것.
- 분석 범위: 기본 경로만 봄. `femu_mode=1`, 단일 namespace, `mapping=page`, `gc_policy=greedy`이고, FDP·Streams·쓰기 버퍼·읽기 캐시·추가 타이밍 옵션은 꺼진 상태 기준.

## 2. 코드 기준 (중요)

> **2026-11-02: 코드 기준을 FEMU 9.0.1로 되돌림.** 아래 4~6절의 분석은 이전 기준인 10.1.0 계열(`601ddfe21`)에서 한 것이라, 파일 이름·줄 번호·일부 기능(WAF 카운터, GC 정책 5종, 쓰기 버퍼 등)이 9.0.1과 다름. 9.0.1 코드로 다시 확인하기 전까지는 참고용으로만 볼 것.

- 저장소: `github.com/hany-Park/FEMU` (MoatLab/FEMU의 fork), 로컬 경로 `/home/saram/FEMU` (WSL2, Ubuntu-22.04)
- 브랜치: `ftl-test` = `ad2d9fc71` (2025-07-15, QEMU 9.0.1 기반 FEMU의 마지막 커밋) 위에 문서 커밋만 올린 상태. `master`는 `ad2d9fc71`.
  - 공식 태그 `femu-v9.0.1`(`3690338cf`, 2024-06-20) 이후의 수정 12개가 포함됨: 메모리 누수 수정, BBSSD TRIM 지원, ZNS 수정 등. 바로 다음 upstream 커밋 `eafddfdd0`이 QEMU 10.1.0 업그레이드임.
- 이전 10.1.0 기준 코드는 GitHub 백업 브랜치에 있음: `backup/master-10.1.0-601ddfe21`, `backup/ftl-test-10.1.0-c78926d58`.
- 빌드: 서버는 실험 브랜치별 worktree(`~/femu-baseline`, `~/femu-hotcold1`)에서 9.0.1로 새로 빌드함 (11/12, 사용자 진행. 2.1절). 로컬 `build-femu/`는 아직 10.1.0 빌드임.
- 실험 브랜치 (11/12): `exp/baseline`(9.0.1 + 카운터·스냅샷), `exp/hotcold1`(+ 10.1 hot/cold 규칙). 구성과 커밋은 `notes/실험_hotcold.md` 1절.
- **9.0.1에서는 BBSSD FTL이 거의 `bbssd/ftl.c` 한 파일(약 1000줄)에 있음.** 처음 claude.ai가 만든 원본 가이드(`FEMU_코드분석_가이드.pdf`, 루트에 있음, 커밋 안 됨)가 이 구조에 더 가까움.

| 파일 (hw/femu/ 기준, 9.0.1) | 내용 |
|---|---|
| `bbssd/ftl.h` (237줄) | 자료구조 정의 |
| `bbssd/ftl.c` | FTL 전체: `should_gc`(7), `ssd_init_params`(237), `ssd_init`(363), `ssd_advance_status`(456), `gc_write_page`(630), `select_victim_line`(668), `clean_one_block`(691), `mark_line_free`(713), `do_gc`(724), `ssd_read`(770), `ssd_write`(806), `ftl_thread`(944) |
| `bbssd/bb.c` | BBSSD 모드 등록, 읽기·쓰기 명령 처리 |
| `nvme-io.c` | `nvme_process_sq_io`(39), `nvme_process_cq_cpl`(137), `nvme_poller`(207) |
| `femu.c` | 장치 초기화, 옵션 정의 |
| `nand/`, `timing-model/` | NAND 보조 코드, 타이밍 모델 |

### 2.1 실행 환경: 로컬과 서버 (11/02, Claude Code)

- **브랜치는 환경별로 나누지 않음.** 크기 차이는 코드가 아니라 실행 옵션 차이이기 때문임. 브랜치는 목적별로 둠(`ftl-test` = 분석·노트, 실험으로 코드를 고칠 때만 `exp/<이름>`). 환경 차이는 실행 스크립트로만 둠.
- `devsz_mb`만큼 호스트 RAM을 데이터 저장 공간으로 잡음 (femu.c:544-546, 옵션 정의 :620). 그래서 큰 장치는 서버에서만 돌릴 수 있음.
  - 로컬: WSL, RAM 15GB. 서버: `cpslab02`, RAM 251GB, CPU 64개.
- 실행 스크립트 (`femu-scripts/`, 원본 `run-blackbox.sh`를 복사해서 아래 값만 바꿈):

| 스크립트 | `blks_per_pl` | NAND 전체 | `ssd_size` (OP 25%) | line 수 / 배경 GC 기준 |
|---|---|---|---|---|
| `run-blackbox.sh` (원본) | 256 | 16GB | 12288 | 256 / free ≤ 64 |
| `run-blackbox-local.sh` | 128 | 8GB | 6144 | 128 / free ≤ 32 |
| `run-blackbox-server.sh` | 1024 | 64GB | 49152 | 1024 / free ≤ 256 |

  - 나머지(지연 값, GC 임계값 75/95, `-m 4G`, `-smp 4`)는 원본과 같음. `IMGDIR`·`OSIMGF`는 환경 변수로 바꿀 수 있게 함. 서버 64GB는 "NAND 전체 크기" 기준으로 정함.
  - `femu-copy-scripts.sh`의 `CPL` 목록에 두 스크립트를 추가함. `build-femu/`에서 복사 스크립트를 실행한 뒤 환경에 맞는 스크립트를 실행하면 됨 (스크립트가 `./qemu-system-x86_64`를 현재 디렉터리에서 찾음).
  - **아직 실행해 보지 않음** (`bash -n` 문법 검사만 함).
- **주의**: geometry가 다르면 line 수(`tt_lines = blks_per_lun`, ftl.c:279)와 GC 임계값(ftl.c:280-282)이 함께 바뀜. 로컬은 동작 확인·디버깅용으로만 쓰고, 발표용 수치는 서버 결과만 씀. VM 안의 워크로드 크기(fio `size` 등)도 장치 크기에 맞춰 비율로 정함.
- **서버 상태 (11/02 확인)**: 서버 `ftl-test`는 아직 `c78926d58`(10.1.0 계열)이고, `build-femu/`에 10.1.0 전용 스크립트(`run-blackbox-fdp.sh` 등)가 남아 있음. `c78926d58`은 지금 `origin/ftl-test`의 조상이 아니므로 `git pull`로는 맞출 수 없음. 서버에서 할 일:
  1. `git status`로 커밋 안 한 실험 결과가 있는지 확인하고, 있으면 따로 복사함
  2. `git fetch origin` → `git reset --hard origin/ftl-test` (`c78926d58`은 GitHub `backup/ftl-test-10.1.0-c78926d58`에 있음)
  3. `build-femu/`를 지우고 새로 만든 뒤 `femu-copy-scripts.sh` → `femu-compile.sh`
  - 로컬 `build-femu/`도 같은 방법으로 다시 빌드해야 함.
- **서버 상태 (11/12, 사용자 보고와 화면 출력 기준)**: 위 방법 대신 실험 브랜치별 worktree를 만들어 빌드함 (`~/femu-baseline`, `~/femu-hotcold1`. 메인 clone `~/FEMU`는 `ftl-test`로 두고 `exp-scripts/`를 실행). baseline 빌드 완료는 화면으로 확인함. hotcold1 worktree는 한 번 만들어지지 않은 적이 있어 다시 확인이 필요함.
  - KVM: 계정에 `/dev/kvm` 권한이 없음 (`Permission denied`). 관리자에게 `kvm` 그룹 추가를 요청할 수 있음.
  - sudo: 한때 sudoers가 QEMU 실행을 거부했으나 이후 sudo로 실행 가능해짐. 지금은 sudo가 들어 있는 원본 스크립트로 실행하고, 비밀번호는 실행할 때 `sudo -v`로만 입력함 (문서·스크립트에 넣지 않음).
  - 게스트 준비(ssh 키, fio·nvme-cli, 비밀번호 없는 sudo)와 실험 스크립트 실행은 아직 확인 안 됨.

## 3. 지금까지의 경과

1. **exp5 실험 (9월, 종료)**: 예전 코드에 직접 넣은 WAF 카운터로 GC 임계값 60~80%를 비교함. 결과는 이미 정리했고 **앞으로 쓰지 않음**. 예전 카운터 코드는 로컬 `backup/ftl-test-stats` 브랜치에만 남아 있음.
2. **코드를 최신 master로 교체 (10/08)**.
3. **코드 분석 가이드 개정 (10/08~09)**: 최신 master 기준으로 다시 씀. 파일은 `notes/FEMU_코드분석_가이드_master.pdf` (A4, 11쪽).
4. **Codex의 가이드 검토 (10/10)**: `notes/FEMU_코드분석_가이드_검토.md`. 아래 4절의 정정 사항을 지적함.
5. **Codex와 `ftl.h` 분석 (10/15)**: NAND 계층 구조체까지 진행함 (5절).
6. **Claude Code와 `ftl.h` 나머지 정리 (10/22~23)**: `ssdparams` 후반부부터 `struct ssd`까지, 그리고 `ssd_init_params()`와 GC 임계값 계산을 정리함 (5절). `struct ppa`는 노션에 따로 정리되어 있음. 노션 반영 현황은 6절 참고.
7. **코드 기준을 9.0.1로 되돌림 (11/02)**: 10.1.0 계열은 정식 릴리즈가 없고(upstream 태그는 `femu-v9.0.1`이 최신) 코드가 커서, 발표용으로는 9.0.1이 낫다고 판단함 (2절).
8. **노션을 9.0.1 기준으로 개편 (11/02, Claude Code)**: 10.1 기준 페이지는 백업으로 복제해 두고, 원본을 9.0.1 코드와 대조해 다시 씀. 새로 확인한 내용은 5.9절, 노션 현황은 6절.
9. **로컬·서버 실행 스크립트 분리 (11/02, Claude Code)**: 서버는 64GB, 로컬은 8GB NAND로 돌리도록 실행 스크립트를 2개로 나눔. 브랜치는 나누지 않음 (2.1절).
10. **측정 코드 (11/06~12, 사용자)**: 9.0.1에 WAF·GC 카운터를 직접 넣음. 처음 버전의 문제 두 개(호스트 쓰기를 덮어쓰기만 셈, erase를 line 단위로 셈)를 고치고, 구간 경계에서 값을 찍는 스냅샷 명령(flip `cdw10=8`)을 추가함 → `exp/baseline`.
11. **hot/cold 1차 (11/11~12)**: 10.1 `hot_cold_sep` 규칙(덮어쓰기 = hot, hot은 별도 write pointer)을 9.0.1에 옮김. Claude가 참고 구현을 만든 뒤 되돌리고, 사용자가 단계별 안내를 보고 직접 구현함 → `exp/hotcold1`. 두 구현은 동작이 같음을 diff로 확인함.
12. **실험 설계·스크립트 (11/12, Claude Code)**: 서버 실험 설계(버전 2 × 워크로드 3 × 3회)와 실행 스크립트 `exp-scripts/`(`run_one.sh`, `run_all.sh`, `parse.py`)를 `ftl-test`에 추가함. 문법 검사와 가짜 로그 시험만 했고 실제 실행은 아직 안 함. 상세는 `notes/실험_hotcold.md`.

## 4. 가이드에서 바로잡을 점 (Codex 검토, 일부 코드로 재확인함)

- **I/O 흐름 순서**: `stime = expire_time = now`는 데이터 복사(`nvme_rw` → `backend_rw`)보다 **먼저** 기록됨 (`nvme-io.c` 246 부근). 가이드는 복사 다음으로 적어 두어서 틀림.
  정확한 순서: SQ에서 명령 읽기 → stime 기록 → `nvme_io_cmd` → `bb_io_cmd` → `nvme_rw` → `backend_rw` → `to_ftl` 링 → `femu_ftl_thread` → `bb_ftl_process_req` → `ssd_read`/`ssd_write` → `expire_time += lat` → `to_poller` 링 → `nvme_process_cq_cpl`(expire_time 순 힙) → CQ 완료.
- **FIFO 표현**: 각 `to_ftl[i]` 링 안에서는 FIFO이지만, poller가 여러 개면 FTL 스레드가 링을 돌아가며 꺼냄. 완료 힙도 poller별로 따로 있음.
- **Deadline 제안**: `to_ftl` 링(MP/SC)을 `pqueue`로 단순 교체하면 경쟁 상태가 생김. `pqueue`에는 동기화가 없음. 안전한 구조는 "링은 그대로 두고, FTL 스레드만 쓰는 대기 힙을 두어 deadline 순으로 선택"하는 것. 이때 deadline의 기준, 모으는 범위, FLUSH/FUA·같은 LBA 사이의 의존성도 정해야 함.
- **GC 임계값**: `gc_thres_lines = (1 - gc_thres_pcent/100) × 전체 line 수`. 기본값(75%, 256 lines)이면 free line이 64개 이하일 때 배경 GC를 **시도**함. greedy는 무효 페이지가 `pgs_per_line/8`보다 적으면 회수하지 않음. 강제 GC 검사는 `ssd_write()` 시작 지점뿐 아니라 페이지별 루프에도 있음.
- **WAF 측정**: C0h 로그의 WAF는 장치를 켠 뒤부터의 누적값임. 실험 구간 WAF는 원시 카운터의 차이로 계산함: `(Δnand + Δgc) / Δhost`.
- **GC의 "페이지 이동"**: 데이터 바이트를 복사하는 게 아니라 매핑·페이지 상태·카운터·타이밍만 갱신함. 실제 데이터는 LBA 기준으로 RAM 백엔드에 있음.
- **bandwidth**: "지연만으로 결정된다"는 말은 너무 단정적임. LUN 병렬성, QD, 요청 크기, 채널·PCIe 모델, `fw_cpu_ns`도 영향을 줌.

## 5. `ftl.h` 분석 (10/23 완료, `ru_mgmt` 등 FDP 구조체는 제외)

> 5.1~5.8은 10.1.0 계열 기준임. 9.0.1에서 다시 확인한 내용은 **5.9절**에 있고, 둘이 다르면 5.9절이 맞음.

### 5.1 NAND 계층 (10/15, Codex)

확인한 것:
- **ECC read 지연 모델**: tier = `min(erase_cnt/750 + retention tier, 4)`. 추가 읽기 지연 = `tier × ecc_step_ns` (nand-media.c:218).
- **`nand_block.read_cnt`**: 호스트·GC의 실제 NAND 읽기를 셈. `MAP_IO`는 제외하고, 버퍼·캐시 hit는 세지 않음 (ftl-media.c:203). `mark_block_free()`에서 0으로 초기화 (ftl-line-gc.c:517).
- **`ssd_mp_batch`, `nand_lun.mp_prog`/`mp_rd`**: 같은 ch/lun/blk/pg와 같은 stime을 가진, 서로 다른 plane 요청을 묶음. 조건이 깨지거나 plane 수만큼 차거나 요청이 끝나면 flush함.
- **`nand_lun` / `ssd_channel`**:
  - 시간 필드는 모두 ns, 기준 시계는 `QEMU_CLOCK_REALTIME`.
  - `next_lun_avail_time`이 실제로 직렬화를 담당하는 상태: `start = max(stime, lun_avail)`, `done = start + 연산 지연`, `lun_avail = done`. CAS로 갱신함 (nand-media.c:413).
  - `next_ch_avail_time`은 채널 버스 지연(cmd/addr, xfer, status 중 하나라도 0이 아님)이 켜졌을 때만 쓰임. 미래 data-out 구간은 별도 예약 목록에 들어감.
  - **`busy`는 두 구조체 모두 사용되지 않음.** LUN `gc_endtime`은 기록만 하고 읽는 곳이 없음. 채널 `gc_endtime`은 아예 사용되지 않음.
  - GC가 호스트 요청을 늦추는 경로는 `gc_endtime`이 아니라, GC도 함께 갱신하는 LUN·채널 시간임.
- 요청 지연 = 페이지별 지연 중 최댓값 (ftl-datapath.c:708) → `femu_ftl_thread`에서 `expire_time += lat` (femu.c:1971) → poller가 그 시각까지 완료를 보류함.

### 5.2 구조체 역할 한 줄 요약 (10/22~23, Claude Code)

| 구조체 (`ftl.h` 줄) | 역할 |
|---|---|
| `ssdparams` (137) | 장치 구성(geometry), 지연 값, GC 임계값, 옵션을 담는 설정 묶음 |
| `nand_cmd` (271) | NAND 연산 하나를 지연 계산 함수에 넘기는 일회용 요청서 |
| `line` (223) | 모든 ch/lun/pl에서 블록 번호가 같은 블록들의 묶음. GC는 이 단위로 함 |
| `line_mgmt` (251) | line들을 free / victim / full로 나눠 관리 (`ssd->lm`) |
| `write_pointer` (242) | 다음에 쓸 물리 위치. ch → lun → pl → pg 순으로 진행 |
| `femu_ftl_policy_ops` (355) | GC 희생 line 선택 정책 테이블 (기본 greedy) |
| `femu_mapping_ops` (381) | L2P 매핑 방식 테이블 (기본 page) |
| `map_write_plan` (370) | 새 페이지를 보낼 클래스(DATA/LOG/HOT)와 정리 필요 여부 |
| `cmt_slot` (428) | DFTL 매핑 캐시 칸 하나 (범위 밖) |
| `buffer_entry` (264) | 쓰기 버퍼에 있는, 아직 프로그램되지 않은 페이지 하나 (범위 밖) |
| `rcache_slot` (420) | 읽기 캐시 칸 하나. 지연 시간만 계산함 (범위 밖) |
| `ssd` (435) | SSD 하나의 FTL 상태 전체 |

### 5.3 `ssdparams` 후반부 (202–220줄)

- 177줄 주석 `below are all calculated values`는 `tt_luns`까지만 맞음. 202줄부터는 장치 옵션을 그대로 복사한 값(ftl-geom.c:259-263)과 카운터임.
- `hot_cold_sep`, `read_reclaim_limit`, `retention_limit_sec`, `buffer_size`, `buffer_thres_pcent`는 기본값이면 모두 꺼짐. `buffer_thres_pcent`는 옵션에서는 정수 %로 받지만 0~1 소수로 바꿔 저장함 (ftl-geom.c:260).
- `retention_limit_sec`의 시간 검사는 읽기 경로의 `ssd_read_check_wear()`에서만 일어남 (ftl-datapath.c:358, 호출 위치 :420, :714). 그래서 읽히지 않는 line은 재기록 대상이 되지 않음.
- `read_cnt` / `read_hit_cnt` / `write_cnt` / `write_hit_cnt`는 호스트가 요청한 페이지 수와 버퍼 hit 수 (ftl-datapath.c:658, 669, 755, 798). 기본 경로에서도 증가함. `nand_block.read_cnt`와는 이름만 같은 다른 변수임.
- `lines_per_ru`, `total_ru_cnt`는 FDP 전용 (ftl-fdp.c:1520-1528).

### 5.4 `nand_cmd`

- `type`(USER/GC/MAP_IO), `cmd`(READ/WRITE/ERASE), `stime`(ns, **0이면 현재 시각**: ftl-media.c:190).
- `type`은 지연 계산에 쓰이지 않음. `nand_media_op()`에 전달되지 않고, `MAP_IO` 읽기를 `read_cnt`에서 빼는 데만 쓰임 (ftl-media.c:212).
- 호스트 연산은 `req->stime`을 넘김 (ftl-datapath.c:711, 528). GC 읽기·쓰기·erase는 `stime = 0`을 넘김 (ftl-line-gc.c:530, 576, 936-937). GC 연산은 모두 `enable_gc_delay`가 켜졌을 때만 지연을 계산함.
- 모두 지역 변수로 만들어 바로 넘김. 큐에 쌓이지 않음.

### 5.5 공간 관리 (`line`, `line_mgmt`, `write_pointer`, 정책 테이블)

- line 수 = `blks_per_pl` (ftl-line-gc.c:55). `line.pos == 0`이면 victim 큐에 없다는 뜻 (ftl-line-gc.c:421).
- line 상태 이동: free → `wp.curline` → 다 채우면 `vpc == pgs_per_line`이면 full 목록, 아니면 victim 큐 (ftl-line-gc.c:138-149) → full line에 첫 invalid가 생기면 victim 큐로 이동 (:428-433) → GC 후 `mark_line_free()`로 free 목록 복귀 (:860).
- victim 큐의 우선순위는 `vpc` (ftl-line-gc.c:19-21). greedy는 큐 맨 앞을 보고, 강제 GC가 아니면서 `ipc < pgs_per_line/8`이면 회수하지 않음 (:651).
- write pointer는 ch → lun → pl → pg 순으로 진행함 (ftl-internal.h:28-51).
- GC 정책 5종이 ftl-line-gc.c:787-793에 등록됨. 이름을 모르면 greedy로 정해짐 (:810).

### 5.6 주소 변환 (`femu_mapping_ops`, `map_write_plan`)

- `page` 매핑이 구현한 함수는 `translate`, `prepare_write`, `commit_write`, `gc_relocate_commit` 4개 (ftl-map.c:123-130).
- `commit_write`: old가 매핑되어 있으면 `mark_page_invalid(old)` → `rmap[old] = INVALID` → `maptbl[lpn] = new` → `rmap[new] = lpn` (ftl-map.c:81-91).
- `dftl`은 page와 같은 함수를 쓰고 `uses_cmt = true`만 다름. 즉 캐시 비용만 추가로 계산함.
- 기본 경로의 `map_write_plan`은 항상 `{DATA, false}`.

### 5.7 `struct ssd`

- WAF 카운터: `host_write_pages` (ftl-datapath.c:754), `nand_write_pages` (:506), `gc_write_pages` (ftl-line-gc.c:557). WAF = `(nand + gc) / host` (ftl.c:176-186).
- **`ssd->to_ftl`, `to_poller`, `ftl_thread`, `dataplane_started_ptr`는 bbssd에서 쓰이지 않음** (선언: ftl.h:455-458). 실제 링과 스레드는 `FemuCtrl` 쪽 `n->to_ftl` (femu.c:1940), `n->to_poller` (femu.c:1974), `n->ftl_thread` (femu.c:2653)임.
- `ftl.h`의 함수 선언(565–591)은 대부분 초기화·검증·해제이거나 옵션 기능임. 실제 FTL 동작 함수는 `ftl-internal.h`에 선언되어 있음.

### 5.8 `ssd_init_params()`와 GC 임계값

> 노션 미반영 (10/23). 코드가 `ftl.h`가 아니라 `ftl-geom.c`·`ftl-internal.h`에 있어서, GC 흐름을 볼 때 파일별 페이지에 나눠 넣기로 함 (6절).

- 호출 경로: `bb.c:232` `ssd_init()` → `ftl.c:22` `ssd_init_params()` (ftl-geom.c:225).
- 하는 일은 세 가지: 옵션 값 복사(`n->bb_params` → `spp`), geometry 곱셈으로 파생 값 계산(:270-298, `tt_luns`까지는 :270-288), GC 임계값 계산(:300-304).
- line 관련: `blks_per_line = tt_luns × pls_per_lun`, `pgs_per_line = blks_per_line × pgs_per_blk`, `tt_lines = blks_per_pl` (:295-298).
- GC 임계값 (기본값 75%, 95%, line 256개 기준):
  - `gc_thres_lines = (int)((1 - 0.75) × 256) = 64` (:301). 배경 GC는 `free_line_cnt <= 64`일 때 (ftl-internal.h:207). 요청 하나를 처리한 뒤 `do_gc(ssd, false)`를 한 번 부름 (ftl.c:577-578).
  - `gc_thres_lines_high = bb_gc_forced_lines(n) = (int)((1 - 0.95) × 256) = 12` (:303, ftl-geom.c:16-26). 강제 GC는 `free_line_cnt <= 12`일 때 (ftl-internal.h:212). `ssd_write()`에서 조건이 풀릴 때까지 `do_gc(ssd, true)`를 반복함 (ftl-datapath.c:743-748, 페이지별 루프는 :553-560).
  - `bb_gc_forced_lines()`는 계산 결과가 0일 때, hot_cold_sep·Streams·log 계열 매핑이면 1로 올림. 기본 경로에서는 해당하지 않음.
- `enable_gc_delay`는 여기서 항상 `true`로 시작함 (:304). 호스트 제어 플래그로만 끌 수 있음 (bb.c:270-273).
- 기본 geometry 값: 8 ch × 8 LUN × 1 pl, 블록당 256 page, plane당 256 블록, 섹터 512B × 8 (femu.c:2985-2997). 따라서 `pgs_per_line = 64 × 256 = 16384`이고, greedy의 회수 기준 `pgs_per_line/8 = 2048`.

### 5.9 9.0.1에서 다시 확인한 것 (11/02, Claude Code)

`ad2d9fc71`의 `ftl.h`·`ftl.c`·`bb.c`·`nvme-io.c`·`nvme-admin.c`를 직접 읽고 확인한 내용. 노션 「코드 정리」·「IO흐름」에 반영함.

- **없어진 것**: FDP, GC 정책 테이블(greedy만 `select_victim_line`에 직접 구현, ftl.c:668-688), 매핑 방식 테이블과 `map_write_plan`(`ssd_write`가 `maptbl`/`rmap`을 직접 고침, ftl.c:829-844), 쓰기 버퍼·읽기 캐시·DFTL 캐시, WAF 카운터, `MAP_IO`, ECC 지연 모델, multi-plane 묶음(`ssd_mp_batch`), `nand_block.read_cnt`. WAF를 재려면 카운터를 직접 넣어야 함.
- **PPA 비트 폭이 다름**: pl 8, lun 8, ch 7 (ftl.h:48-53). 10.1은 pl 4, lun 7, ch 12.
- **5.7절 정정**: 9.0.1에서는 `ssd->to_ftl`, `to_poller`, `dataplane_started_ptr`, `ftl_thread`를 **실제로 씀**. FTL 스레드는 `ssd_init()` 끝에서 만들고(ftl.c:390-391), dataplane이 켜질 때까지 기다린 뒤 `n->to_ftl`/`n->to_poller` 포인터를 복사해 씀(ftl.c:953-959). 함수 이름도 `femu_ftl_thread`가 아니라 `ftl_thread`(ftl.c:944).
- **5.5절 정정**: write pointer는 ch → lun → pg 순으로만 진행함. pl은 올리지 않고 항상 0 (ftl.c:157-209, "assume # of pl_per_lun is 1" 주석 :204).
- free line이 떨어지면 명령을 거부하지 않고 `abort()` (ftl.c:193-197).
- **지연은 LUN 시간뿐임**: `ssd_advance_status`는 read/write/erase 모두 `max(stime, lun_avail) + 연산 지연`이고(ftl.c:456-525), 채널 계산은 `#if 0`이라 `next_ch_avail_time`·`ch_xfer_lat`은 지연에 반영되지 않음. `nand_cmd.type`은 쓰기 분기에서 if/else가 같은 계산이라 결과에 영향 없음 (ftl.c:490-494). PCIe·펌웨어 CPU 지연 모델도 없음.
- 쓰이지 않거나 기록만 하는 필드: `nand_block.erase_cnt`(증가만, ftl.c:614), `nand_block.wp`, `nand_page.sec`/`nsecs`(초기화와 assert만), LUN·채널 `busy`, LUN `gc_endtime`(기록만, ftl.c:663, 760), 채널 `gc_endtime`(`#if 0` 안).
- `line_mgmt`에 `victim_line_cnt`가 있음 (ftl.c:188, 571, 684). victim 큐 우선순위는 `vpc`, 작은 값이 먼저 (ftl.c:59-67).
- GC 임계값 계산은 10.1과 같음: 64 / 12 line (ftl.c:279-282, 기본값 femu.c:682-683). 강제 GC는 `ssd_write` 시작 지점에서만 검사함 (ftl.c:822-827, 10.1처럼 페이지별 루프 검사는 없음). 배경 GC는 요청을 `to_poller`에 넣은 뒤 한 번 (ftl.c:998-1000).
- GC는 valid 페이지를 호스트 쓰기와 같은 write pointer로 옮기고(ftl.c:630-666), old 페이지는 하나씩 invalid 처리하지 않고 블록 전체를 `mark_block_free`로 비움 (ftl.c:750).
- **`ftl_thread`의 `lat`은 루프 밖에서 한 번만 0으로 초기화됨** (ftl.c:949). WRITE/READ/DSM이 아닌 명령(FLUSH 등)은 `lat`을 새로 정하지 않아서 직전 요청의 지연을 그대로 씀 (ftl.c:972-989).
- `FEMU_RESET_ACCT`는 카운터를 먼저 0으로 만든 뒤 출력하므로 로그에는 항상 0/0이 찍힘 (bb.c:55-58).
- I/O 경로 (9.0.1): SQ에서 꺼냄 → `stime` 기록 (nvme-io.c:69) → `nvme_io_cmd` (:502) → READ/WRITE는 `bb_io_cmd` (bb.c:79) → `nvme_rw` (:251) → `backend_rw` (:288), DSM은 `nvme_dsm` (:296) → `to_ftl` (:81) → `ftl_thread` 분기 (ftl.c:972) → `expire_time += lat` (ftl.c:990) → `to_poller` (ftl.c:992) → 완료 힙 (nvme-io.c:153-173).
- poller와 링은 `nvme_init_poller()`가 만들고 (nvme-admin.c:234-282), `nvme_set_db_memory`에서 한 번 실행된 뒤 `dataplane_started = true` (nvme-admin.c:331-337). 기본 poller 1개 (`multipoller_enabled=0`, femu.c:624, nvme-admin.c:240).

## 6. 다음 할 일

### hot/cold 실험 (11/12)

상세 순서와 명령은 `notes/실험_hotcold.md` 4·5절.
1. 서버 `git worktree list`로 두 worktree가 모두 있는지, 두 `build-femu`에 9.0.1 빌드(스냅샷 코드 포함)가 있는지 확인
2. 게스트 준비 (ssh 키, fio·nvme-cli, 비밀번호 없는 sudo) 후 VM 종료
3. 서버 `~/FEMU`를 `ftl-test`로 두고 `git pull` → `exp-scripts/run_one.sh baseline zone80 0`으로 파일럿 1회. 스냅샷 3개가 `femu.log`에 찍히는지, 걸린 시간 확인
4. 시간을 보고 `CAP`·반복 수를 정한 뒤 `run_all.sh` (tmux 안에서)
5. `parse.py`로 CSV를 만들어 `notes/실험_hotcold.md` 6절에 정리
- KVM 권한을 받으면 sudo 없이 실행하도록 바꿈 (`RUN=./run-nosudo.sh`).

### 노션 정리 현황 (11/02)

> 10/23 현황(10.1 파일 단위 구조, 5.8절 미반영)은 11/02 개편으로 대체되어 지움. 이전 내용은 노션 백업 페이지와 git 기록(`0e3b08bff`)에 남아 있음.

- 위치: 노션 `연구실 과제 / FEMU`. 상위 페이지 맨 위에 "코드 기준: 9.0.1" 안내를 넣음.
- 10.1 기준 백업: 「코드 정리 (10.1.0 백업)」, 「IO흐름 (10.1.0 백업)」 (원본을 복제한 것).
- 「코드 정리」 (9.0.1): `femu` 아래 `bbssd`(`ftl.h`, `ftl.c`, `bb.c`), `nvme.h`, `nvme-io.c`, `nvme-admin.c`(새로 추가), `femu.c`.
  - `ftl.h`: 분류 토글 ①~⑥으로 정리함. 10.1 때의 "옵션 기능" 분류는 없앰. 5.8절 내용(`ssd_init_params`, GC 임계값)도 ③에 반영함.
  - `ftl.c`: 기능별 하위 토글 11개(GC 조건, 매핑 헬퍼, victim 큐 콜백, line·write pointer, 초기화, 주소 헬퍼, 지연 계산, 페이지 상태, GC, 읽기·쓰기·TRIM, FTL 스레드)에 줄 범위와 핵심 동작만 넣음. 상세 분석은 앞으로 채움.
  - `nvme.h`, `nvme-io.c`, `femu.c` 토글은 아직 비어 있음.
- 「IO흐름」 (9.0.1): 0절(구성요소, 시간 모델, 기본 설정, 요청 일생)을 9.0.1 줄 번호로 고침. 1~4절은 아직 비어 있음.

### 코드 분석

`ftl.h` 정리는 끝남 (9.0.1 재확인 완료). 이제 구조체 대신 실행 흐름을 읽음. 9.0.1 기준 함수로 바꿈:
- `ssd_write` (ftl.c:806-859): 강제 GC 검사 → LPN마다 old `mark_page_invalid` → `get_new_page` → `maptbl`/`rmap` 갱신 → `mark_page_valid` → `ssd_advance_write_pointer` → 지연 계산
- 목표: **같은 LPN을 두 번 쓸 때** old/new PPA, `maptbl`, `rmap`, `vpc`/`ipc`가 어떻게 바뀌는지 설명하기

이후 학습 순서 (`notes/FEMU_코드분석_가이드_검토.md` 4절을 9.0.1에 맞춤):
1. 읽기·지연: `ssd_read` (ftl.c:770) → `ssd_advance_status` (ftl.c:456)
2. 전체 I/O 경로를 스레드별로 정리 (노션 「IO흐름」 1~4절)
3. GC: 임계값 → `select_victim_line` → `do_gc` → `clean_one_block` → `mark_line_free`
4. ~~baseline 실험: fio 측정 방법을 따로 정해야 함~~ → 11/12 hot/cold 실험 설계로 정함 (`notes/실험_hotcold.md`, 위 "hot/cold 실험" 참고)
