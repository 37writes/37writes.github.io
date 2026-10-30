---
title: 블로그 UI를 개인 디자인 시스템(kit paper 테마)으로 정돈
date: 2026-10-31
status: in-progress
tier: T2
---

# 블로그 UI를 개인 디자인 시스템(kit paper 테마)으로 정돈

## 목표
사용자는 디자이너가 아니므로 kit:design의 공통 규칙(위계·간격·버튼·메뉴·접근성)과 개인 테마를 이 블로그에도 그대로 적용해, 다른 프로젝트와 같은 사람이 만든 것처럼 보이게 한다.
지금의 종이색·세리프 본문 개성은 유지하고, 원본 테마 CSS와 프로젝트 매핑을 분리해 나중에 외관만 교체할 수 있게 한다. 모바일 메뉴·검색·모드 버튼·목차가 깨지지 않게 한다.

## 범위
- **포함**: kit design 시스템 1.0.0 자산(core·neutral·paper) 원본 그대로 복사, Chirpy 변수 매핑, 모드 연결 어댑터, 공통 부품 규칙(44px 조작영역·초점 표시·모바일 사이드바 disclosure·목차/경로 표시), 디자인 프로필 `docs/design-system.md`, 프로젝트 프로필 `CLAUDE.md`, 해시·경로 검사 도구, ego 전후 검증, 승인 후 main push(Pages 배포)와 배포 화면 확인
- **제외**: 글 본문·발행일·URL·새 글 (요청 범위 밖), Chirpy 레이아웃 포크·프레임워크 이관 (요청 금지), viewport meta의 `user-scalable=no` (Chirpy `head.html` 소유라 포크가 필요, 남은 일로 보고), AWS·시크릿·데이터

## 현재 화면에서 찾은 문제 (전 캡처 d8615cc, ego 실측)
1. 모바일(<850px) 닫힌 사이드바의 링크 8개가 화면 밖에서 Tab 순서에 남는다. 트리거에 `aria-expanded`/`aria-controls`가 없고 Escape로 닫히지 않으며 초점이 이동하지 않는다.
2. 주요 조작영역이 44px 미만: 상단 메뉴·검색 46×38, 모드 버튼 28×28, 사이드바 메뉴 42px 높이, 코드 복사 32×32, 공유 버튼 22×31, 검색 입력 30px 높이.
3. 초점 표시가 Bootstrap 파란 반투명 그림자(`rgba(13,110,253,.25)`)이거나 없음(검색 입력). 종이 바탕에서 거의 안 보인다.
4. 데스크톱 목차가 긴 한글 제목을 `…`로 자른다. 상단 경로 표시는 긴 제목에서 두 줄로 넘쳐 상단 구분선에 닿는다.
5. 320px 글 제목(2rem)이 7줄로 꺾인다.

## 설계
- 신규: `_sass/kit/core.css`, `_sass/kit/themes/neutral.css`, `_sass/kit/themes/paper.css` — kit `skills/design/assets/`에서 내용 그대로 복사 (Sass가 plain CSS를 `@use`로 묶어 CSS 한 파일로 나간다)
- 신규: `_sass/kit/SHA256SUMS` — 원본 해시 (kit 0.16.0 커밋 `06401de`)
- 신규: `_sass/_theme-map.scss` — Chirpy 변수 → `--kit-*` 연결과 프로젝트 예외만. 색 값을 다시 적지 않는다
- 신규: `_includes/kit-theme-adapter.html` — (head 즉시) `data-kit-theme="paper"` 지정, `data-bs-theme` → `data-kit-mode` 미러(MutationObserver). (DOMContentLoaded 뒤) 모바일 사이드바 보강: 열림 상태는 Chirpy가 소유(`body[sidebar-display]`)하고 어댑터는 관찰만 한다 → `aria-expanded`/`aria-controls`, 닫힘이면 `#sidebar.inert`, 열 때 첫 링크로 초점·닫을 때 트리거로 복귀, Escape와 850px 이상 전환은 `#mask.click()`(Chirpy 토글 경로)로 닫는다
- 변경: `_includes/metadata-hook.html` — 어댑터 include (폰트 로딩은 그대로)
- 변경: `assets/css/jekyll-theme-chirpy.scss` — 기존 `--paper/--ink` 블록을 매핑으로 대체, 부품 규칙 추가
- 신규: `tools/design-check.sh` — 원본 해시 일치, 빌드 산출물에 kit 로컬 경로 없음 확인
- 신규: `docs/design-system.md`, `CLAUDE.md`(프로필), `_config.yml` exclude에 `CLAUDE.md`·`AGENTS.md` 추가

## 결정 & 이유
- **테마: paper, 공통 규칙 + 프로젝트별 테마** → 사용자 추가 답이 없어 기본 가정. kit paper가 이 블로그 색에서 나왔고 TTC(neutral 업무용)와 위계·부품 규칙만 공유한다. 임시 추천값이 아니라 기존 외관의 연장이므로 프로필에 "기존 외관 유지(사용자 미확정)"으로 적는다.
- **색: kit paper 값을 그대로 쓴다 (예외 없음)** → 같은 테마는 원본 값이 같아야 한다. 차이는 작고 모든 쌍이 기존 이상이거나 기준 통과: 보조 `#6a645a→#625d53`(5.25→5.86:1), 강조 `#a8431f→#a13d1c`(5.39→5.88), 기능선 `#8c8477→#81796c`(3.31→3.85), 다크 글자 `#e8e1d3→#eee7dc`(14.14), 다크 보조 `#a39a8b→#c0b5a3`(6.24→8.58), 다크 강조 `#e08a5f→#efac84`(6.59→9.02), 다크 기능선 3.86→5.11. 코드 바탕은 `--kit-surface-alt`(라이트 동일 `#ece6da`, 다크 `#26231f→#302c26`), 코드 주석은 `--kit-muted`(라이트 5.26, 다크 6.86). 다크 구문 색은 새 바탕에서 다시 잰다.
- **글꼴**: 본문·제목은 기존 Noto Serif KR(Google Fonts 400/700, display=swap) 로딩 유지, family는 `--kit-font-reading-family`(fallback이 `Apple SD Gothic Neo`→`AppleMyungjo, Batang`으로 세리프 유지). Chirpy Sass의 `$font-family-base/heading`(본문·제목·팝업·`--wc-stm-font-family`)과 사이트 제목 직접 선언까지 모두 이 토큰으로 바꿔 테마 교체 때 일부만 남지 않게 한다 (반박 2). UI 글꼴은 **프로젝트 예외**로 `--kit-font-ui`를 기존 시스템 스택(-apple-system…)으로 덮는다 → Noto Sans KR를 로드하지 않는 블로그에서 설치 여부에 따라 UI 글꼴이 갈리는 것을 막고 추가 다운로드를 피한다. 코드 글꼴은 kit `--kit-font-mono`를 쓰고, ego에서 실제 사용 글꼴(CDP `CSS.getPlatformFontsForNode`)이 전과 다르면 예외로 기존 스택을 유지한다.
- **테마 교체 범위**: 색·읽기 글꼴·부품 반경(`--kit-radius-control`)·떠 있는 메뉴 그림자. 간격·크기·UI 글꼴(프로젝트 예외)은 테마와 무관하게 고정. 검증은 ego에서 `data-kit-theme`를 지워 neutral로 바꿔 보고 홈 제목·h1/h2/본문·사이트 제목·검색 결과·목차·코드의 계산된 family/색을 대조한다 (제품에 남기지 않음, 반박 2).
- **모서리**: kit 시스템은 paper도 같은 부품 위계(부품 10px)를 쓴다. 검색창·모드 메뉴·코드 블록·복사/공유 버튼은 `--kit-radius-control`, 홈 목록·사이드바 메뉴는 지금처럼 선과 여백 위계(반경 없음).
- **자산 위치: `_sass/kit/` + Sass `@use`** → 요청 하나로 묶이고 순서가 고정된다. 원본은 해시로 검사하고, 외관 교체는 `@use 'kit/themes/<테마>'`와 어댑터의 테마 값 두 곳.
- **모드: Chirpy `data-bs-theme`가 유일한 원본** → Chirpy는 시스템 모드에서도 해석된 light/dark를 속성에 적으므로 어댑터는 미러만 한다. localStorage·팔레트 복제 없음. JS가 없으면 테마 속성이 없어 neutral로 보이는 한계는 Chirpy 모드 자체가 JS에 의존하므로 수용, 프로필에 기록.
- **44px 대상**: 상단 버튼·검색 입력·취소, 사이드바 메뉴·모드 버튼·모드 메뉴 항목, 페이지 이동, 코드 복사, 공유, 모바일 목차 버튼, 맨 위로. **예외**: 본문 인라인 링크, 글 메타의 카테고리, 태그 목록, 데스크톱(≥1200, 가는 포인터) 목차 항목, 라이선스 링크 → 문장 속 링크·목록이며 간격으로 구분.
- **경로 표시(breadcrumb) 한 줄 말줄임** → 바로 아래 h1에 전체 제목이 보이므로 핵심 제목 자르기가 아니다. 목차는 자르지 않고 줄바꿈.
- **사이드바 닫힘은 `inert`(JS) — visibility 지연 안 씀** → 반박 1 수용. visibility 지연은 닫히는 0.4초 동안 링크가 Tab에 남고, 어댑터가 속성을 직접 지우면 Chirpy 내부 값과 어긋난다. `inert`는 즉시 상호작용만 막고 슬라이드는 그대로 보인다. JS가 없으면 전과 같다(메뉴 자체가 JS로 열림).
- **코드 복사 버튼**: 44×44, 코드 머리는 고정 36px 대신 `min-height: 44px`, hover는 `--kit-surface`·아이콘 `--kit-text`(Chirpy 기본 회색 37%+흰 아이콘은 라이트 1.81:1), `button:focus{outline:none}`을 `:focus-visible` 규칙으로 덮는다 (반박 3).

## 기획 반박
- 검토자: Codex 워커, 모델 `global.openai.gpt-6-astra` (`worker-show` `projection.provider.model`), Task `task_b7c0b422227f` / Dispatch `ctx_90e70fce4ba1`, 보고서 `docs/plans/2026-10-31-personal-design-system/rebuttal.md`
- 반례 1 (사이드바 상태 소유권·재열기·폭 왕복) — **수용**. 상태는 Chirpy `Qn.toggle`만 바꾸고 어댑터는 관찰·`#mask.click()`만 쓴다. visibility 지연 대신 `inert`. S5에 `열기 → Escape → Tab → 다시 열기 → 마스크 닫기 → 다시 열기 → 항목 선택` 연속 시퀀스와 열린 채 849→851→849 왕복, 모드 메뉴가 열린 상태의 Escape 우선순위를 넣는다.
- 반례 2 (테마 교체 때 글꼴·부품 연결 누락) — **수용**. Sass 글꼴 변수와 사이트 제목까지 토큰 연결, 교체 범위 명시, ego neutral 왕복 검사 추가.
- 반례 3 (복사 버튼 hover 1.81:1·머리 높이·focus 충돌) — **수용**. 코드 글 `_posts/2026-10-14-codecommit-git-push-403.md`에서 기본/hover/focus/복사 후 상태와 320px hit target을 확인한다.
- "더 작은 해법"의 호환 별칭(`--paper`·`--ink`) — **기각**. 글 본문에 `var(--...)` 사용이 없고(`grep -rn 'var(--' _posts _tabs` 0건) 도표 선택자는 이 SCSS 안에만 있어 한 번에 바꾼다. 이름이 두 벌이면 다음 변경에서 어느 쪽을 쓸지 갈린다.
- viewport `user-scalable=no`를 metadata-hook에서 조정하는 대안 — **보류(범위 밖 유지)**. JS로 meta를 바꾸는 것은 브라우저별 효력이 불확실하고 Chirpy `head.html` 소유다. 제외를 접근성 완료로 쓰지 않고 남은 일에 둔다.
- 추가 breakpoint 768/1400/1650 — 768은 기존 매트릭스에 있음, 1400/1650은 사이드바 폭·패널 폭만 바뀌어 이번 부품 규칙과 무관 → 1280과 1440 한 번만 확인.

## 엣지 케이스 & 리스크
- Sass가 `.css`를 `@use`로 못 읽으면 → S1에서 빌드로 먼저 확인, 안 되면 `assets/css/kit/`에 그대로 두고 `<link>`로 로드
- 사이드바가 열린 채 850px 이상으로 넓어지면 Chirpy는 마스크(z-1, 전체 화면)를 남겨 본문을 막는다 → 어댑터가 넓어질 때 Chirpy 경로로 닫는다. 849→851→849 왕복으로 확인
- 어댑터가 Chirpy 스크립트보다 먼저 돌면 모드가 비어 보임 → metadata-hook은 head 끝(theme.min.js 뒤)
- 검색 결과 화면·모드 메뉴(Bootstrap dropdown) 키보드 동작이 CSS 변경으로 깨짐 → 실조작 검증
- 도표 SVG 색이 변수 이름 변경으로 깨짐 → 도표 글 라이트/다크 캡처

## 작업 단계
- [x] S0. 기획 반박 — Codex 워커 — 보고서 `docs/plans/2026-10-31-personal-design-system/rebuttal.md`, 반례별 수용/기각 기록
  - 결과: 반례 3개 모두 수용(사이드바 inert·Chirpy 경로로 닫기, 글꼴 Sass 변수 토큰화·neutral 왕복 검사, 복사 버튼 상태·머리 높이). Sass plain CSS `@use`는 검토자가 컴파일로 확인
- [ ] S1. kit 자산 복사·해시·검사 도구 — 나(Claude) — `tools/design-check.sh` 통과, production 빌드 성공, 화면 변화 없음
- [ ] S2. 테마 매핑·모드 어댑터·글꼴 토큰 — 나 — light/dark/system에서 `--main-bg` 등이 kit 값, 모드 전환 즉시 반영
- [ ] S3. 공통 부품 규칙(44px·초점·사이드바 disclosure·목차·경로·제목) — 나 — ego 측정에서 대상 조작영역 44px 이상, 닫힌 사이드바 Tab 제외, Escape 닫힘·초점 복귀
- [ ] S4. 프로필 문서 `docs/design-system.md`·`CLAUDE.md`·exclude — 나 — 빌드 산출물에 CLAUDE.md 없음
- [ ] S5. ego 전후 검증 매트릭스 — 나 — 320/360/390/430/768/1280/1440 + 575/576/577·849/850/851·1199/1200/1201, light/dark/system, 실제 innerWidth·touch 기록, 사이드바 연속 시퀀스·폭 왕복, 복사 버튼 상태, neutral 교체 왕복, 전후 캡처 직접 확인
- [ ] S6. 독립 검증 — Codex 워커 — 빌드·htmlproofer·design-check 재실행, 변경 범위, 직접 고른 실패 시나리오 1~3개(ego 같은 TaskSpace 다른 Page)
- [ ] S7. 배포 — 승인 후 — `git push origin <SHA>:refs/heads/main`, 그 SHA의 Pages 실행 성공 + 배포 사이트에서 홈·글·모드·검색·모바일 메뉴 확인

## 완료 기준
- https://37writes.github.io/ 홈·긴 제목 글·코드/표 글에서 종이색·세리프가 유지되고, 모바일 메뉴를 터치로 열고 닫을 수 있으며 Tab/Escape가 동작하고, 다크·시스템 모드 전환과 검색·목차가 그대로 동작한다.
- 원본 자산 해시가 프로필과 일치하고 빌드에 kit 로컬 경로가 없다.

## 승인 필요 (T2)
- 바꾸는 것: main에 이 브랜치의 디자인 커밋을 fast-forward push → GitHub Actions "Build and Deploy"가 Pages에 배포 (프로필 push 줄 없음 = push는 배포, harness "push와 배포")
- 미리보기: 로컬 production 빌드 전후 캡처, `git diff --stat origin/main...HEAD`, htmlproofer
- 롤백: `git revert <범위>` 커밋을 만들어 push (이것도 배포이므로 다시 승인), 또는 Actions에서 이전 SHA의 workflow 재실행
- 자동 배포: 정책 밖 (프로필에 자동 배포 줄 없음)

## 남은 일
- 실제 iOS Safari·가상 키보드·실기기 터치는 ego Chromium 에뮬레이션으로 증명할 수 없음 → 사용자 확인 항목
