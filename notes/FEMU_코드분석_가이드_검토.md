# FEMU 코드 분석 가이드 검토

검토일: 2026-10-10  
대상: `FEMU_코드분석_가이드_master.pdf` 전체 11쪽  
대조 기준: 현재 체크아웃 `601ddfe21` — PDF에 적힌 기준 커밋과 일치

**판정: 기본 BBSSD 코드 학습 순서로 사용해도 좋다. 다만 Deadline 구현 제안과 실험 해석은 아래 보완을 적용해야 한다.** FTL 파일 분리, 주요 함수 위치, 기본 I/O 경로, GC 정책 5종, line 단위 회수, WAF 카운터는 실제 코드와 대체로 일치한다. 코드가 다른 버전이라서 못 따라가는 가이드는 아니다.

검토는 소스·저장소 문서·실행 스크립트의 정적 대조로 수행했다. VM 실행, fio 실험, 빌드 또는 성능 검증은 수행하지 않았다. 원본 PDF와 실행 스크립트는 수정하지 않았다.

## 1. 먼저 고칠 내용

### [중요] 7쪽: FIFO 링을 pqueue로 단순 교체하면 안 된다

`to_ftl[i]`는 poller와 FTL 스레드 사이의 전달 수단이다. 현재 링은 `FEMU_RING_TYPE_MP_SC`로 생성된다. 반면 `lib/pqueue.c`의 삽입·삭제는 내부 동기화 없이 힙 배열과 크기를 수정한다. 같은 pqueue를 poller와 FTL 스레드가 동시에 쓰도록 단순 치환하면 경쟁 상태가 생긴다.

권장 제안은 다음과 같다.

```text
poller → 기존 to_ftl[i] 링 → FTL 스레드가 소유하는 대기 힙
                            → deadline 기준 선택 → FTL 처리
                            → 기존 to_poller[i] → 완료 시각 힙
```

이는 구현이 끝난 설계가 아니라 안전한 출발점이다. 추가로 정할 것은 다음과 같다.

- deadline의 출처: 예를 들어 요청 도착 시각 + 실험에서 정한 목표 지연. 기존 `expire_time`은 모델이 계산한 완료 예정 시각으로, 서비스 목표 deadline과 다르다.
- 여러 요청을 힙에 모으는 범위와 처리 예산. 한 요청을 넣자마자 꺼내면 재정렬 효과가 거의 없다.
- FLUSH, FUA, 같은 LBA에 대한 요청 등 데이터 의미와 의존성을 어떻게 유지할지.
- 큐 삭제·컨트롤러 리셋 때 대기 힙의 요청을 어떻게 정리할지.
- 스케줄러에서 기다린 시간을 지연 모델과 측정에 어떻게 반영할지. `stime`과 `expire_time`의 의미를 명시해야 한다.

기본 경로에서는 실제 payload 복사가 FTL 도착 전에 끝난다. 따라서 이 위치의 EDF는 우선 **FTL의 매핑·NAND 타이밍 처리 순서를 바꾸는 실험**으로 범위를 정의해야 한다. 데이터 이동까지 포함한 전체 I/O 스케줄링을 구현했다는 주장은 별도 검증이 필요하다.

근거: [링 생성](../hw/femu/nvme-admin.c:371), [pqueue 삽입](../hw/femu/lib/pqueue.c:136), [FTL 루프](../hw/femu/femu.c:1881), [payload 복사](../hw/femu/nvme-io.c:977).

### [정확성] 7쪽: “FTL 처리 순서는 FIFO”의 범위를 한정해야 한다

각 `to_ftl[i]` 링 내부에서는 FIFO다. 하지만 여러 poller가 있으면 FTL 스레드는 poller 인덱스 순으로 돌며 비어 있지 않은 링에서 요청 하나씩 꺼낸다. 모든 요청을 도착 시각으로 합친 전역 FIFO는 아니다. 완료 힙도 poller별이다.

발표 문장은 “각 전달 링은 FIFO이며, 여러 링은 순회 처리한다. 각 poller의 완료 큐는 `expire_time`으로 정렬한다”가 정확하다. 기본 `multipoller_enabled=0` 경로와 다중 poller 경로를 구분하면 된다.

근거: [링 순회](../hw/femu/femu.c:1923), [poller별 완료 힙](../hw/femu/nvme-io.c:420), [기본 설정](../hw/femu/femu.c:2871).

### [정확성] 1–2쪽: 도착 시각 기록은 데이터 복사보다 먼저다

PDF는 2단계 데이터 복사 뒤 3단계에서 `stime`을 기록한다고 설명하지만, 실제 코드는 요청을 준비할 때 먼저 기록한다.

```text
SQ 명령 읽기 → stime = expire_time = now
→ nvme_io_cmd → bb_io_cmd → nvme_rw → backend_rw
→ to_ftl → FTL 지연 계산 → expire_time += lat → 완료 처리
```

이 차이는 지연의 기준점을 설명할 때 중요하다. 또한 “데이터 저장 끝”은 기본 모델의 RAM 백엔드 복사가 끝났다는 뜻이며, NAND 지연 모델상 프로그램 완료나 게스트가 완료를 받았다는 뜻은 아니다.

근거: [시각 기록과 명령 호출](../hw/femu/nvme-io.c:246).

### [보완] 5–6쪽: GC 임계값 충족과 실제 회수 성공을 구분해야 한다

`should_gc()`가 참이면 배경 GC를 **시도**한다. 기본 greedy 정책은 후보가 없거나, 후보 line의 무효 페이지가 `pgs_per_line / 8`보다 적으면 회수하지 않는다. 강제 GC는 이 무효 페이지 비율 조건을 생략하지만 후보가 없거나 회수 공간이 부족하면 진행하지 못할 수 있다.

`gc_thres_pcent=75`는 free line이 75% 남았다는 뜻이 아니다. `gc_thres_lines = (1 - 0.75) × 전체 line 수`이므로 기본 256 lines에서는 free lines가 64 이하일 때 배경 GC 조건에 들어간다.

또한 강제 GC 검사는 `ssd_write()` 시작뿐 아니라 직접 쓰기 경로의 **페이지별 루프**와 버퍼 destage에도 있다. PDF에 helper 위치는 있지만 호출 범위가 충분히 설명되지 않았다. 요청 시작 지점만 수정해서 GC를 분할했다고 판단하면 안 된다.

지연도 구분해야 한다. 기본 GC는 NAND 시간만큼 sleep하는 방식이 아니라 매핑·상태를 갱신하고 NAND 자원의 다음 가용 시각을 전진시킨다. 그 자원을 쓰는 후속 연산의 모델 지연이 늘어난다. 여기에 FTL 스레드가 GC 코드를 실행하는 실제 CPU 시간도 생긴다.

근거: [임계값 계산](../hw/femu/bbssd/ftl-geom.c:300), [greedy 후보 조건](../hw/femu/bbssd/ftl-line-gc.c:641), [페이지별 강제 GC 검사](../hw/femu/bbssd/ftl-datapath.c:833), [GC 읽기 타이밍](../hw/femu/bbssd/ftl-line-gc.c:523).

### [측정] 6·10쪽: 누적 WAF와 실험 구간 WAF를 구분해야 한다

PDF의 식 자체는 맞다. 다만 10쪽 명령은 누적 WAF × 1000만 읽는다. 6쪽의 “전후 값의 차이”는 WAF 비율의 차이가 아니라 **각 원시 카운터의 차이**여야 한다.

```text
실험 WAF = (Δnand_write_pages + Δgc_write_pages) / Δhost_write_pages
```

`Δhost_write_pages=0`이면 이 구간의 쓰기 WAF를 계산할 수 없다. raw 카운터를 읽는 명령은 다음과 같다. 게스트에서 대상 FEMU 컨트롤러 이름을 확인한 뒤 사용한다.

```sh
sudo nvme get-log /dev/nvme0 --log-id=0xc0 --log-len=512 -b |
    od -An -t u8 -j 8 -N 24 -w24
# 순서: host_write_pages, gc_write_pages, nand_write_pages
```

C0h는 컨트롤러의 관련 namespace 카운터를 합산하므로 첫 실험은 단일 BBSSD namespace로 제한하면 해석이 쉽다. 쓰기 버퍼를 켜면 측정 종료 시 destage/flush 포함 여부도 고정해야 한다.

GC 비교 실험은 초기 상태, 사전 채움, 랜덤 덮어쓰기, 블록 크기, queue depth, 작업 범위, 실행 시간과 반복 횟수를 맞춰야 한다. 빈 SSD에 짧게 쓴 결과만으로 정책을 평가하면 GC를 충분히 관찰하지 못할 수 있다. 평균 지연 외에 p99/p99.9, WAF, 처리량을 함께 본다. Deadline 실험은 deadline miss 비율을 추가한다.

근거: [측정 가이드](../hw/femu/docs/guides/measuring.md:31), [C0h 계산](../hw/femu/nvme-admin.c:2090), [재현 가능한 실험 조건](../hw/femu/docs/guides/measuring.md:212).

## 2. 설명을 조금 더 정확하게 할 부분

- **4쪽 latency 식:** 기본 옵션에서 단일 NAND 연산의 식으로는 맞다. `완료 = max(도착, LUN 가용) + 연산 지연`, `연산 latency = 완료 - 도착`을 구분해서 설명한다. 다중 페이지 요청은 페이지별 latency의 최대값을 사용한다. fio의 관측 지연은 게스트·호스트 실행과 완료 전달 비용도 포함하므로 `reqlat`과 항상 같지는 않다. [근거](../hw/femu/nvme-io.c:514)
- **4쪽 bandwidth:** 기본 모델 설명으로는 유용하지만 “지연만으로 대역폭이 정해진다”는 단정은 줄인다. LUN 병렬성, 요청 크기·QD, 채널 모델, PCIe 모델, 선택적 `fw_cpu_ns`, 실제 에뮬레이터 실행 속도가 함께 영향을 준다. `fw_cpu_ns`는 PDF에 빠져 있다. [근거](../hw/femu/nvme-io.c:473)
- **5쪽 out-of-place update:** write pointer만 보면 부족하다. `ssd_program_lpn()`에서 `prepare_write`와 `commit_write`를 따라 `femu_map_page_commit_write()`까지 읽어야 이전 페이지 invalidation, 새 L2P, 역매핑 갱신이 연결된다. [근거](../hw/femu/bbssd/ftl-map.c:84)
- **6쪽 GC의 “실제로 옮긴다”:** 기본 모델은 payload를 LBA 기준 RAM 백엔드에 두고, GC에서는 PPA 매핑·페이지 상태·카운터·타이밍을 갱신한다. `gc_write_page()`가 NAND 데이터 바이트를 복사하는 함수라고 이해하면 안 된다. [근거](../hw/femu/bbssd/ftl-line-gc.c:595)
- **7쪽 hot/cold:** 현재 구현이 있다는 설명은 맞지만, 기본 page 매핑의 분류는 기존 매핑이 있는 덮어쓰기를 hot으로 보는 간단한 방식이다. 접근 빈도를 정밀하게 추정하는 정책과는 구분해야 하며, 이 분류 자체를 개선하는 것도 연구 주제가 될 수 있다. [근거](../hw/femu/bbssd/ftl-map.c:58)
- **9쪽 “3일”:** 구조 파악 목표로 삼되, 전체 구조체 통독·모든 정책 이해·실험까지 완료하는 기한으로 받아들이지 않는다. 날짜보다 아래 단계별 산출물을 기준으로 진행하는 편이 낫다.

## 3. 실행 스크립트 확인 결과

8쪽의 “build-femu 사본이 다르다”는 설명은 현재도 사실이다.

| 설정 | 현재 원본 `hw/femu/scripts/run-blackbox.sh` | `build-femu/run-blackbox.sh` 사본 |
| --- | ---: | ---: |
| `blks_per_pl` | 256 | 64 |
| `ssd_size` | 12288 | 2048 |
| `gc_thres_pcent` | 75 | 80 |
| `gc_thres_pcent_high` | 95 | 95 |

두 구성은 용량과 여유 공간 비율, GC 발생 조건이 다르므로 실험 수치를 바로 비교하면 안 된다. 사본에 의도적으로 작은 용량을 설정했을 가능성도 있으므로 “오래된 사본이니 무조건 덮어쓰기”보다는 **학습에 쓸 설정을 선택하고 기록**하는 것이 먼저다. 복사하면 새 기본 용량으로 바뀐다는 점도 반영해야 한다.

`femu-scripts`가 `hw/femu/scripts`를 가리키는 심볼릭 링크이고, 복사 스크립트가 `../femu-scripts`를 사용하는 것도 확인했다. 실행 바이너리는 존재하지만 현재 소스와 정확히 일치하는 빌드인지는 확인하지 않았다. 실험 전에는 해당 소스로 빌드를 맞추는 단계가 필요하다.

근거: [원본](../hw/femu/scripts/run-blackbox.sh:12), [사본](../build-femu/run-blackbox.sh:10).

## 4. 권장 학습 순서와 완료 기준

처음에는 `femu_mode=1`, 단일 namespace, `mapping=page`, `gc_policy=greedy`, FDP·Streams·쓰기 버퍼·읽기 캐시·추가 타이밍 옵션이 꺼진 범위로 고정한다.

| 순서 | 읽을 내용 | 다음 단계로 넘어갈 기준 |
| --- | --- | --- |
| 1 | `docs/design/ftl.md`의 구조 설명, `ftl.h`의 ppa·ssdparams·ssd·line·write_pointer | NAND 계층과 LPN→PPA를 그림으로 설명한다. 헤더 전체를 외울 필요는 없다. |
| 2 | `ssd_write` → `ssd_program_lpn` → page mapping의 prepare/commit → write pointer 갱신 | 같은 LPN을 두 번 쓸 때 old PPA, new PPA, maptbl, rmap, vpc/ipc 변화를 설명한다. |
| 3 | `ssd_read` → `ssd_advance_status` → `nand_media_op` | 같은 LUN과 서로 다른 LUN에 두 페이지를 쓸 때 완료 시각을 손으로 계산한다. |
| 4 | `nvme_process_sq_io` → `bb_io_cmd`/`nvme_rw` → `femu_ftl_thread` → `bb_ftl_process_req` → `nvme_process_cq_cpl` | payload 복사, 모델 상태 변경, 게스트 완료 통보를 구분하고 각 스레드를 표시한다. |
| 5 | GC 임계값 → greedy 선택 → `reclaim_line` → 페이지 이동·소거 | GC 한 번의 유효 페이지 이동 수와 WAF 분자 증가량을 설명한다. |
| 6 | `docs/guides/measuring.md`, 동일 조건의 baseline 실험 | 구간 WAF·처리량·tail latency를 재현한다. 그 후 다른 GC 정책과 Deadline 설계를 검토한다. |

PDF의 전체 방향은 유지하되, 처음부터 5개 GC 정책과 확장 기능을 모두 읽기보다 **기본 쓰기 한 건과 덮어쓰기 한 건을 끝까지 설명할 수 있는지**를 먼저 확인하면 학습 부담이 줄어든다.
