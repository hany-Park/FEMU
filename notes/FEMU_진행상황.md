# FEMU 코드 분석 진행 상황 (인수인계용)

작성: 2026-10-22 · 갱신: 2026-10-23 (`ftl.h` 구조체 정리 완료, 5·6절) · 이 문서만 읽어도 지금까지의 진행 상황을 따라올 수 있도록 정리한 것임.

## 1. 목적과 작업 방식

- 목적: FEMU BlackBox SSD(BBSSD) FTL 코드를 이해하고 발표를 준비함. 지금은 **코드 이해 단계**이고, 코드 수정·빌드·실험은 하지 않음.
- 선임이 요구한 발표 질문 5개: ① I/O 요청 전체 흐름 ② latency 계산 ③ bandwidth 계산 ④ WAF 계산 ⑤ GC·Deadline(요청 큐) 재설계.
- 설명 방식: 한국어, 파일 경로와 줄 번호를 근거로 들 것, 코드로 확인한 사실과 추정을 구분할 것.
- 분석 범위: 기본 경로만 봄. `femu_mode=1`, 단일 namespace, `mapping=page`, `gc_policy=greedy`이고, FDP·Streams·쓰기 버퍼·읽기 캐시·추가 타이밍 옵션은 꺼진 상태 기준.

## 2. 코드 기준 (중요)

- 저장소: `github.com/hany-Park/FEMU` (MoatLab/FEMU의 fork), 로컬 경로 `/home/saram/FEMU` (WSL2, Ubuntu-22.04)
- 브랜치: `ftl-test`, 커밋 **`601ddfe21` (2026-10-07)**. master와 같고, GitHub에도 push됨.
- 빌드: `build-femu/qemu-system-x86_64`는 이 커밋으로 다시 빌드됨 (10/08).
- **예전 코드와 구조가 다름.** 예전엔 BBSSD FTL이 `bbssd/ftl.c` 한 파일이었지만, 최신 master는 여러 파일로 나뉨. 예전 기준 자료(파일 하나짜리 `ftl.c`)는 위치가 맞지 않음.

| 파일 (hw/femu/ 기준) | 내용 |
|---|---|
| `bbssd/ftl.h` | 자료구조 정의 |
| `bbssd/ftl-internal.h` | 내부 함수 선언, `should_gc()` 등 inline 함수 |
| `bbssd/ftl.c` | `bb_ftl_process_req()` 요청 분기, 배경 GC 호출, `ssd_waf_x1000()` |
| `bbssd/ftl-datapath.c` | `ssd_read()`, `ssd_write()`, `ssd_program_lpn()`, 강제 GC 호출 |
| `bbssd/ftl-line-gc.c` | line, write pointer, GC(`do_gc`, `reclaim_line`), 희생 정책 5종 |
| `bbssd/ftl-media.c` | `ssd_advance_status()` (지연 계산 입구) |
| `nand/nand-media.c` | `nand_media_op()` (실제 지연 계산) |
| `bbssd/ftl-map.c` | `maptbl`/`rmap`, 기본 page 매핑 |
| `bbssd/ftl-geom.c` | `ssd_init_params()` (스크립트 값 → `ssdparams`) |
| `nvme-io.c` | SQ 처리(`nvme_process_sq_io`), 완료 처리(`nvme_process_cq_cpl`) |
| `femu.c` | FTL 스레드(`femu_ftl_thread`), 장치 옵션 정의 |
| `docs/design/ftl.md` | BBSSD FTL 공식 설계 문서 |

## 3. 지금까지의 경과

1. **exp5 실험 (9월, 종료)**: 예전 코드에 직접 넣은 WAF 카운터로 GC 임계값 60~80%를 비교함. 결과는 이미 정리했고 **앞으로 쓰지 않음**. 예전 카운터 코드는 로컬 `backup/ftl-test-stats` 브랜치에만 남아 있음.
2. **코드를 최신 master로 교체 (10/08)**.
3. **코드 분석 가이드 개정 (10/08~09)**: 최신 master 기준으로 다시 씀. 파일은 `notes/FEMU_코드분석_가이드_master.pdf` (A4, 11쪽).
4. **Codex의 가이드 검토 (10/10)**: `notes/FEMU_코드분석_가이드_검토.md`. 아래 4절의 정정 사항을 지적함.
5. **Codex와 `ftl.h` 분석 (10/15)**: NAND 계층 구조체까지 진행함 (5절).
6. **Claude Code와 `ftl.h` 나머지 정리 (10/22~23)**: `ssdparams` 후반부부터 `struct ssd`까지, 그리고 `ssd_init_params()`와 GC 임계값 계산을 정리함 (5절). `struct ppa`는 노션에 따로 정리되어 있음. 노션 반영 현황은 6절 참고.

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

## 6. 다음 할 일

### 노션 정리 현황 (10/23)

- 노션은 **소스 파일 단위**로 나뉨: `femu` 아래 `docs`, `bbssd`(`ftl.h`, `ftl-internal.h`, `bb.c`, `ftl.c`, `ftl-cache.c`, `ftl-datapath.c`), `nvme.h`, `nvme-io.c`, `femu.c`.
- `ftl.h` 페이지: 5.2~5.7절 내용은 다른 세션에서 반영함.
- 아직 반영하지 않은 것: 5.8절 (`ssd_init_params()`, GC 임계값). GC 흐름을 볼 때 이렇게 나눠 넣을 예정:
  - `ssd_init_params()`, `bb_gc_forced_lines()` → 새 `ftl-geom.c` 페이지
  - `should_gc()`, `should_gc_high()` → `ftl-internal.h` 페이지
  - 배경 GC, 강제 GC 호출 → `ftl.c`, `ftl-datapath.c` 페이지
- `ftl.h` 페이지의 `gc_thres_*` 항목에는 위 위치를 가리키는 메모만 남겨 두기로 함.

### 코드 분석

`ftl.h` 정리는 끝남. 이제 구조체 대신 실행 흐름을 읽음:
- `ssd_write` → `ssd_program_lpn` → `femu_map_page_commit_write`
- 목표: **같은 LPN을 두 번 쓸 때** old/new PPA, `maptbl`, `rmap`, `vpc`/`ipc`가 어떻게 바뀌는지 설명하기

이후 학습 순서 (`notes/FEMU_코드분석_가이드_검토.md` 4절):
1. 읽기·지연: `ssd_read` → `ssd_advance_status` → `nand_media_op`
2. 전체 I/O 경로를 스레드별로 정리
3. GC: 임계값 → greedy 선택 → `reclaim_line`
4. `docs/guides/measuring.md` 기준 baseline 실험
