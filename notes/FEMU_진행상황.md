# FEMU 코드 분석 진행 상황 (인수인계용)

작성: 2026-10-22 · 이 문서만 읽어도 지금까지의 진행 상황을 따라올 수 있도록 정리한 것임.

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

## 4. 가이드에서 바로잡을 점 (Codex 검토, 일부 코드로 재확인함)

- **I/O 흐름 순서**: `stime = expire_time = now`는 데이터 복사(`nvme_rw` → `backend_rw`)보다 **먼저** 기록됨 (`nvme-io.c` 246 부근). 가이드는 복사 다음으로 적어 두어서 틀림.
  정확한 순서: SQ에서 명령 읽기 → stime 기록 → `nvme_io_cmd` → `bb_io_cmd` → `nvme_rw` → `backend_rw` → `to_ftl` 링 → `femu_ftl_thread` → `bb_ftl_process_req` → `ssd_read`/`ssd_write` → `expire_time += lat` → `to_poller` 링 → `nvme_process_cq_cpl`(expire_time 순 힙) → CQ 완료.
- **FIFO 표현**: 각 `to_ftl[i]` 링 안에서는 FIFO이지만, poller가 여러 개면 FTL 스레드가 링을 돌아가며 꺼냄. 완료 힙도 poller별로 따로 있음.
- **Deadline 제안**: `to_ftl` 링(MP/SC)을 `pqueue`로 단순 교체하면 경쟁 상태가 생김. `pqueue`에는 동기화가 없음. 안전한 구조는 "링은 그대로 두고, FTL 스레드만 쓰는 대기 힙을 두어 deadline 순으로 선택"하는 것. 이때 deadline의 기준, 모으는 범위, FLUSH/FUA·같은 LBA 사이의 의존성도 정해야 함.
- **GC 임계값**: `gc_thres_lines = (1 - gc_thres_pcent/100) × 전체 line 수`. 기본값(75%, 256 lines)이면 free line이 64개 이하일 때 배경 GC를 **시도**함. greedy는 무효 페이지가 `pgs_per_line/8`보다 적으면 회수하지 않음. 강제 GC 검사는 `ssd_write()` 시작 지점뿐 아니라 페이지별 루프에도 있음.
- **WAF 측정**: C0h 로그의 WAF는 장치를 켠 뒤부터의 누적값임. 실험 구간 WAF는 원시 카운터의 차이로 계산함: `(Δnand + Δgc) / Δhost`.
- **GC의 "페이지 이동"**: 데이터 바이트를 복사하는 게 아니라 매핑·페이지 상태·카운터·타이밍만 갱신함. 실제 데이터는 LBA 기준으로 RAM 백엔드에 있음.
- **bandwidth**: "지연만으로 결정된다"는 말은 너무 단정적임. LUN 병렬성, QD, 요청 크기, 채널·PCIe 모델, `fw_cpu_ns`도 영향을 줌.

## 5. `ftl.h` 분석 진행 (10/15까지)

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

## 6. 다음 할 일

`ftl.h`의 남은 부분 (우선순위 순):
1. `struct ppa` (69): 아직 안 봤으면 짧게 확인
2. `struct ssdparams` (137) + `ssd_init_params()` (ftl-geom.c:225), `gc_thres_lines` 계산 (ftl-geom.c:300)
3. `line` / `write_pointer` / `line_mgmt` (223–262)
4. `struct nand_cmd` (271): `USER_IO`/`GC_IO`/`MAP_IO`
5. `struct ssd` (435): 기본 경로 필드만
- 건너뜀: `buffer_entry`, FDP `ru_mgmt`, `rcache`, `cmt`. `*_ops` 테이블은 "정책을 갈아끼우는 구조"라는 것만 알면 됨.

그다음에는 구조체 대신 실행 흐름을 읽음:
- `ssd_write` → `ssd_program_lpn` → `femu_map_page_commit_write`
- 목표: **같은 LPN을 두 번 쓸 때** old/new PPA, `maptbl`, `rmap`, `vpc`/`ipc`가 어떻게 바뀌는지 설명하기

이후 학습 순서 (`notes/FEMU_코드분석_가이드_검토.md` 4절):
1. 읽기·지연: `ssd_read` → `ssd_advance_status` → `nand_media_op`
2. 전체 I/O 경로를 스레드별로 정리
3. GC: 임계값 → greedy 선택 → `reclaim_line`
4. `docs/guides/measuring.md` 기준 baseline 실험
