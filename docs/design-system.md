# 디자인 프로필

이 블로그(Jekyll + jekyll-theme-chirpy 7.6.0)가 쓰는 개인 디자인 시스템의 연결 기록이다.
화면을 고칠 때는 여기 적힌 토큰·규칙·예외만 쓰고, 새 예외가 생기면 이 문서에 이유와 같이 적는다.

## 시스템과 테마
- 디자인 시스템: 37writes kit design **1.0.0**, 공통 규칙(위계·간격·버튼·메뉴·초점·접근성) + 프로젝트별 테마
- 테마: **paper** (미색 종이 + 세리프 본문 + 강조색 하나). 상태: **기존 외관 유지(사용자 미확정)** — kit paper가 이 블로그 색에서 나왔으므로 새 추천값이 아니라 기존 외관의 연장이다
- 모드: light / dark / system (Chirpy 모드 버튼)

## 원본 자산
- 출처: 37writes-claude-kit `skills/design/assets/` — kit 플러그인 0.16.0, 저장소 커밋 `fdc2663`, 자산 마지막 변경 `c6c832f`
- 복사 위치: `_sass/kit/core.css`, `_sass/kit/themes/neutral.css`, `_sass/kit/themes/paper.css` (내용 그대로, 수정 금지)
- 해시(SHA-256): `_sass/kit/SHA256SUMS`

  | 파일 | SHA-256 |
  |---|---|
  | `core.css` | `49e31837d2374212af4c985142c9ffaa4300de74d41ad6aa00aadbc080ef79a1` |
  | `themes/neutral.css` | `ae73a6ee5ef7e5e5b9b397f82097b81b2069f205879ffd2f1024153d06e300a3` |
  | `themes/paper.css` | `88607aca5f225e862dcf6b6a09eb080ba347f23c2d36ddada80170d4b2a3f0dc` |

- 갱신: kit 자산을 다시 그대로 복사하고 `SHA256SUMS`와 이 표를 같이 바꾼다. 원본을 고쳐서 맞추지 않는다

## 매핑
| 파일 | 하는 일 |
|---|---|
| `assets/css/jekyll-theme-chirpy.scss` | 진입점. Chirpy Sass 변수(`$topbar-height`, `$font-family-base/heading`) 설정, kit 원본 `@use`, 부품 규칙 |
| `_sass/_theme-map.scss` | Chirpy CSS 변수(`--main-bg`, `--link-color` …) → `--kit-*` 연결과 UI 글꼴 예외. 색 값을 쓰지 않는다 |
| `_includes/kit-theme-adapter.html` | `data-kit-theme="paper"` 지정, `data-bs-theme` → `data-kit-mode` 미러, 모바일 사이드바 접근성(aria·inert·초점·Escape), 모드 선택 뒤 초점 복귀 |
| `_includes/metadata-hook.html` | 본문 웹폰트 로드와 어댑터 include (Chirpy가 head 끝에 넣는 자리) |

- 색·읽기 글꼴·부품 반경·그림자는 `--kit-*` 토큰만 쓴다. 예외로 다크 구문 강조 3색(`#c48ab8`, `#cf8f62`, `.gp` muted)은 Chirpy 기본이 새 코드 바탕에서 4.5:1 미만이라 진입점에 값으로 둔다 (`#302c26` 기준 5.07·5.12·6.86:1)
- Chirpy 레이아웃(`_layouts`, `_includes/head.html` 등)은 덮어쓰지 않는다. Chirpy 업데이트를 그대로 받기 위해서다

### 허용한 예외
| 예외 | 이유 |
|---|---|
| UI 글꼴 = 시스템 고딕 스택 (`-apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", "Malgun Gothic", sans-serif`) | Noto Sans KR를 받지 않으므로 kit 1순위를 쓰면 설치 여부에 따라 메뉴 글꼴이 갈린다. 테마를 바꿔도 유지 |
| 상단 바 3.5rem (Chirpy 기본 3rem) | 44px 검색창·버튼이 48px 바에 꽉 찼다. `$topbar-height` 하나로 목차 바·`scroll-margin-top`·팝업 위치가 같이 바뀐다 |
| 검색 입력 42px | 검색창 테두리 1px×2 안을 다 채운 값. 테두리 포함 44px |
| 44px 미만 허용: 본문 인라인 링크, 글 메타의 카테고리, 태그 목록, 데스크톱(≥1200) 목차 항목, 라이선스 링크 | 문장·목록 속 링크이고 간격으로 구분된다 |
| 576px 미만 코드 블록 직각 | Chirpy가 이 폭에서 코드 블록을 화면 끝까지 붙여 반경이 화면 모서리에서 잘린다 |
| 경로 표시(breadcrumb) 한 줄 말줄임 | 바로 아래 h1에 전체 제목이 보인다. 목차는 자르지 않고 줄바꿈 |
| viewport `user-scalable=no` 그대로 | Chirpy `head.html` 소유라 포크가 필요하다. 접근성 미해결 항목으로 남긴다 |

## 글꼴
| 용도 | 토큰 | 실제 글꼴 | 로드 |
|---|---|---|---|
| 본문·제목·사이트 제목 | `--kit-font-reading-family` (Chirpy `$font-family-base/heading`도 이 토큰) | Noto Serif KR 400/700 | Google Fonts, `metadata-hook.html`, `display=swap`. 대체 AppleMyungjo, Batang |
| 메뉴·메타·표·검색·코드 머리 | `--kit-font-ui` (프로젝트 예외) | Apple SD Gothic Neo / SF (macOS) | 시스템 |
| 코드 | `--kit-font-mono` | Menlo (macOS) | 시스템 |

ego에서 CDP `CSS.getPlatformFontsForNode`로 잰 실제 글꼴은 kit 적용 전후 같다.

## 화면 종류와 반응형
- 메뉴: 850px 미만은 왼쪽 사이드바가 화면 밖에 있고 상단 메뉴 버튼으로 연다(Chirpy `body[sidebar-display]`가 상태 원본). 닫힌 동안 `#sidebar`는 `inert`, 열면 첫 링크로 초점, Escape·마스크·항목 선택으로 닫히고 초점은 트리거로. 열린 채 850px 이상이 되면 닫는다. 850px 이상은 사이드바 고정
- 오른쪽 패널·목차: 1200px 이상은 오른쪽 목차, 미만은 상단 목차 바 + 팝업(닫기 44px)
- 도표: 576px 이하는 세로로 쌓은 좁은 그림(`.diagram-narrow`), 577px 이상은 넓은 그림. 세로로 긴 그림(`.diagram-tall`)은 한 장
- 코드 블록: 576px 미만은 화면 끝까지(직각), 이상은 반경 `--kit-radius-control`
- 가로 넘침: 문서는 넘치지 않는다. 표는 Chirpy `.table-wrapper`, 코드는 블록 자체가 가로 스크롤을 맡는다
- 모드 원본: Chirpy `data-bs-theme`(저장 `localStorage['theme']`, 없으면 OS). 어댑터는 `data-kit-mode`로 따라만 한다. JS가 없으면 테마 속성이 없어 neutral 값으로 보인다 (Chirpy 모드·메뉴 자체가 JS에 의존하므로 수용)

## 테마 교체
- 바꾸는 곳 두 개: 진입점의 `@use 'kit/themes/<테마>'`와 어댑터의 `data-kit-theme` 값
- 바뀌는 것: 색, 읽기 글꼴, 부품 반경, 떠 있는 메뉴 그림자. 바뀌지 않는 것: 간격, 크기(44px), UI 글꼴(예외), 레이아웃
- 확인: ego에서 `data-kit-theme`를 `neutral`로 바꿔 h1/h2/본문/사이트 제목/목차/코드/검색의 계산된 family·색이 모두 바뀌고 되돌아오는지 본다 (제품 파일은 바꾸지 않는다)

## 지원 범위와 검증
- 검사 명령
  - 빌드: `JEKYLL_ENV=production bundle exec jekyll b`
  - 링크: `bundle exec htmlproofer _site --disable-external --ignore-urls "/^http:\/\/127.0.0.1/,/^http:\/\/0.0.0.0/,/^http:\/\/localhost/"`
  - 원본·경로: `sh tools/design-check.sh [빌드 폴더]` — kit 원본 해시 일치, 산출물에 kit 토큰 있음, 로컬 절대경로 없음
- 폭: 320 / 360 / 390 / 430 / 768 / 1280 / 1440, 경계 575·576·577 / 848·849·850·851 / 1199·1200·1201
- 모드: light / dark / system (OS 전환을 새로고침 없이 따라오는지)
- 브라우저: ego lite 0.6.1.13 (Chromium 156) 뷰포트·터치 에뮬레이션. 측정마다 실제 `innerWidth`·`maxTouchPoints`·`pointer: coarse`를 기록해 설정과 대조했다
- 주요 조작: 모바일 사이드바 연속 시퀀스(열기 → Escape → Tab → 다시 열기 → 마스크 → 항목 선택), 849↔851 왕복, 모드 메뉴 키보드(Enter·화살표·Escape), 검색(입력·결과·취소), 코드 복사(hover·초점·복사 후, 320 터치), 모바일 목차(열기·닫기·Escape), neutral 교체 왕복
- 대비 (바탕 기준): 라이트 본문 13.88:1 · 보조 5.86:1 · 강조·초점 5.88:1, 다크 본문 14.14:1 · 보조 8.58:1 · 강조·초점 9.02:1, 복사 hover 아이콘 15.14:1, 복사 완료 테두리 5.45:1
- **미확인**: 실제 iOS Safari, 가상 키보드가 올라온 상태의 검색, 실기기 터치. 위 결과는 에뮬레이션이며 실기기 성공이 아니다

## 기준 화면
경로 (로컬 `bundle exec jekyll s` 또는 배포 사이트 https://37writes.github.io/ 기준)

| 화면 | 경로 | 확인할 것 |
|---|---|---|
| 홈 목록 | `/` | 목록 위계, 사이드바, 상단 검색·모드 |
| 긴 제목 글 | `/posts/deep-insight-multi-agent-roles/` | 제목 줄 수, 경로 말줄임, 목차 |
| 코드·표 글 | `/posts/codecommit-git-push-403/` | 코드 머리·복사 버튼, 표 |
| 도표 글 | `/posts/aws-cli-certificate-verify-failed/` | 넓은/좁은 도표 교체, 다크 색 |
| 소개 | `/about/` | 탭 페이지 |

캡처: `docs/design-baseline/` (kit 적용 직후 로컬 production 빌드, ego 0.6.1.13)

| 파일 | 폭·모드 |
|---|---|
| `home-390-light.png`, `home-1280-light.png`, `home-1280-dark.png` | 홈 |
| `home-390-sidebar-open.png` | 모바일 사이드바 열림 |
| `post-long-390-dark.png`, `post-long-1280-light.png` | 긴 제목 글 |
| `post-code-390-light.png` | 코드·표 글 |
| `dia-390-dark.png` | 도표 글 (좁은 그림, 다크) |
