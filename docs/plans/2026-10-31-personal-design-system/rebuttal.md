# S0 기획 반박 — 개인 디자인 시스템

- 검토일: 2026-10-31
- 검토자: Codex, 실행 모델 **`global.openai.gpt-6-astra`**
- 모델 확인: 실행 중 `orca orchestration worker-show --dispatch ctx_90e70fce4ba1 --json`의 `projection.provider.model`
- Task: `task_b7c0b422227f` / Dispatch: `ctx_90e70fce4ba1`
- 대상: `docs/plans/2026-10-31-personal-design-system.md` 미커밋 초안
- 방법: 기획·kit 원본·프로젝트 CSS·Chirpy 7.6.0 gem 정적 대조, 설치된 Sass 컴파일러 확인, 브라우저 없는 Node VM 모드 로직 확인. 브라우저·배포·전체 Jekyll 빌드는 실행하지 않았다.

아래 `G/`는 `/Users/jeongjaehun/Documents/dev/tech-blog/vendor/bundle/ruby/3.4.0/gems/jekyll-theme-chirpy-7.6.0/`, `K/`는 `/Users/jeongjaehun/Documents/dev/37writes-claude-kit/skills/design/`를 뜻한다. 프로젝트 경로는 이 worktree 기준이다.

## 판단

**방향은 타당하지만, 아래 세 반례를 완료 조건에 반영한 뒤 구현하는 편이 낫다.** 토큰 원본과 프로젝트 매핑을 분리하고 기존 기능의 접근성을 보강하는 것은 사용자 문제를 해결한다. 다만 “해시가 같은 paper 색 + 현재 화면 통과”만으로 “다음 작업에도 같은 규칙을 쓰는 개인 AI 디자이너”가 완성되지는 않는다. 기존 부품의 동작·상태 계약, 실제 토큰 소비 위치, 허용한 예외를 프로필에 남기고 다음 변경에 재사용할 수 있어야 한다.

이 문서는 아직 없는 구현의 결함을 확정하는 리뷰가 아니다. 확인된 원본 동작을 바탕으로, 현재 기획의 합격 조건이 놓칠 수 있는 실패 경로를 제시한다.

## 중요한 반례 — 최대 3개

### 1. 사이드바를 Escape로 한 번 닫는 검사는 통과하지만, 다시 열기·폭 전환에서 상태가 어긋난다

**근거**

- 기획 29·43·56행은 disclosure 보강과 visibility 전환을 정하지만, 기존 토글과 새 어댑터 중 누가 열림 상태를 변경하는지는 정하지 않았다.
- `G/assets/js/dist/commons.min.js:4`의 `class Qn`은 내부 변수 `Xn._`를 반전한 뒤 **세 곳**을 갱신한다: `body[sidebar-display]`, `#sidebar.z-2`, `#mask.d-none`. 같은 줄의 `Un.onclick=Kn.onclick=()=>Qn.toggle()`이 트리거와 마스크를 연결한다. `home/post/page/misc/categories` 번들에도 같은 동작이 포함돼 있다.
- `G/_sass/layout/_sidebar.scss:30`은 849px 이하에서만 사이드바를 이동시키고, 340행은 같은 상태 속성으로 본문도 이동시킨다. `G/_sass/abstracts/_mixins.scss:74`의 이동 시간은 0.4초다.
- `G/_includes/js-selector.html:65`의 페이지 번들은 `defer`다. `G/_includes/head.html:136`의 metadata-hook에서 즉시 실행하는 코드는 본문 요소가 파싱되기 전이므로, 모드 초기화와 메뉴 초기화를 같은 시점으로 취급할 수 없다.

**실패 경로**

어댑터가 Escape에서 `sidebar-display`만 지우면 화면 닫힘·초점 복귀 검사는 통과할 수 있다. 그러나 내부 값은 여전히 열림이어서 다음 트리거 클릭이 다시 닫힘 처리를 하고, 마스크나 z-index도 남을 수 있다. 속성 대신 새 토글 핸들러를 하나 더 붙이면 기존 클릭과 이중 실행될 수 있다. 0.4초 뒤 visibility만 숨기는 방법은 닫히는 동안 링크를 Tab 순서에 남긴다. 열린 채 849→851→849px로 바꾸는 순서도 각 폭의 새 페이지 캡처로는 검증되지 않는다.

**확인 방법 / 추가할 합격 조건**

1. 위 번들의 `sidebar-display` 주변 코드를 확인해 기존 토글의 상태 소유권을 보존한다. 어댑터는 DOM 준비 후 초기화하고, 닫기 요청은 기존 토글 경로를 이용하는 등 한 경로로 통일한다.
2. 구현 후 같은 페이지에서 `열기 → Escape → 즉시 Tab → 다시 열기 → 마스크로 닫기 → 다시 열기 → 항목 선택`을 연속 수행한다. 매번 세 상태와 `aria-expanded`, 실제 초점 위치를 확인한다. 모드 dropdown이 열린 상태의 Escape 우선순위도 확인한다.
3. 메뉴 안에 초점을 둔 채 849→851→849px를 왕복한다. 숨은 트리거로 초점을 보내지 않고 마스크가 본문을 막지 않아야 한다. 시각적 닫힘 애니메이션과 상호작용 차단 시점을 분리한다면 `inert` 같은 처리가 데스크톱 복귀 때도 해제되는지 확인한다.

정적 검토로 내부 상태·초기화 순서·전환 시간은 확인했다. 위 UI 시퀀스의 실제 결과는 구현 후 검증 대상이다.

### 2. paper 화면과 해시가 모두 통과해도, 테마 교체 때 글꼴·부품 외관이 이전 값에 남는다

**근거**

- 기획 38·39행은 본문 family를 토큰에 연결하고 두 곳 변경으로 외관을 교체한다고 하지만, 실제 적용 선택자와 교체 후 검증 조건이 없다. S5는 paper의 모드·폭 검사에 집중한다.
- 현재 `assets/css/jekyll-theme-chirpy.scss:4`는 본문·제목 family를 Sass 설정에 직접 넣는다. 150행의 사이트 제목은 별도 직접 선언이다. `G/_sass/base/_base.scss:51`, `G/_sass/abstracts/_placeholders.scss:7` 및 `G/_sass/components/_popups.scss:35` 등에도 Sass family 소비 지점이 있다.
- `K/assets/core.css:18`·35·37의 글꼴/읽기/버튼 규칙은 `.kit-*`를 붙인 요소에만 적용된다. 원본을 포함하는 것만으로 Chirpy DOM에는 적용되지 않는다.
- 현재 프로젝트에는 `border-radius: 0`·`3px`, 고정 간격·크기가 남아 있다. neutral의 `--kit-radius-control` 등은 이 선언을 자동 변경하지 않는다. `K/references/system.md`도 자산이 완성된 부품 라이브러리가 아니라고 명시한다.

**실패 경로**

본문에서만 `--kit-font-reading-family`를 적용하고 사이트 제목이나 팝업의 Sass family를 놓쳐도 paper에서는 같은 Noto Serif KR여서 눈에 띄지 않는다. 이후 neutral이나 다른 읽기 글꼴을 선택하면 일부 영역만 바뀐다. UI·코드의 프로젝트 예외를 이유 없이 고정하면 사용자가 기대하는 “개인 글꼴 교체”의 범위도 모호해진다.

**확인 방법 / 추가할 합격 조건**

- 우선 `rg -n 'font-family|border-radius|--ui-font|--mono-font' assets/css/jekyll-theme-chirpy.scss`와 gem의 위 소비 지점을 대조한다. 프로필에 각 역할의 소비 선택자와 테마 변경 때 고정되는 예외를 명시한다.
- 구현 검증용으로 paper→neutral→paper를 왕복하거나 읽기 family 토큰만 임시 교체한다. 홈 제목·글 h1/h2/본문·사이트 제목·검색 결과·목차·코드의 계산된 family를 확인한다. 임시 변경은 제품에 남기지 않는다.
- “CSS 테마 교체”를 색·읽기 글꼴에 한정할지, 모서리·그림자까지 포함할지 적는다. UI 시스템 스택 유지와 코드 스택 예외는 합리적일 수 있지만 교체 범위에서 명시해야 한다.

이 반례는 모든 요소를 `.kit-*`로 바꾸라는 요구가 아니다. 기존 Chirpy 선택자를 유지하면서 필요한 토큰을 연결하고, 한 번의 교체 시험으로 빠진 연결을 찾자는 제안이다.

### 3. 코드 복사 버튼이 44px이어도 hover 아이콘이 흐리고, 부모 높이와 초점 표시가 충돌할 수 있다

**근거**

- 기획 37·41·56행은 구문색 대비와 버튼 크기를 다루지만 복사 버튼의 기본/hover/복사 성공/focus 상태는 구체화하지 않았다.
- `G/_sass/base/_syntax.scss:247`은 복사 전 hover 배경을 `rgb(128 128 128 / 37%)`, 아이콘을 흰색으로 바꾼다. 코드 배경은 `G/_sass/abstracts/_placeholders.scss:148`의 `--highlight-bg-color`이고, 현재 프로젝트 97행은 `--paper-deep`에 연결한다. paper 라이트의 대응 값은 `#ece6da`다.
- 이 색을 합성하면 약 `rgb(196.04, 192.26, 184.70)`이고 흰 아이콘 대비는 **약 1.81:1**이다. 기본 상태나 다크 화면만 보면 놓친다.
- `G/_sass/base/_syntax.scss:183`의 코드 머리는 고정 높이이고, `G/_sass/abstracts/_variables.scss:22`는 이를 `2.25rem`으로 정한다. 기본 16px 기준 36px이므로 버튼만 44px로 키우면 위아래로 넘친다. 243행의 `button:focus { outline: none; }`도 새 focus-visible 규칙과 특이성 대조가 필요하다.

**확인 방법 / 추가할 합격 조건**

- `_posts/2026-10-14-codecommit-git-push-403.md:55`부터 실제 코드 블록이 있으므로 이 글을 검증 대상으로 고정한다.
- 라이트에서 복사 전 hover, 키보드 focus, 복사 성공 후 상태를 각각 확인한다. 아이콘은 실제 배경에서 3:1 이상이어야 한다.
- 버튼 크기뿐 아니라 부모 머리 높이, 첫 코드 줄과의 겹침, 초점 외곽선의 노출을 확인한다. 320px 및 글자 확대에서 버튼의 실제 hit target도 확인한다.
- 기존 hover/focus 규칙을 의도적으로 덮고, 머리는 내용에 맞춰 확장되게 한다. 색·크기 측정 통과만으로 이 부품의 완료를 판정하지 않는다.

대비 1.81:1은 정적 색 합성으로 계산했다. 구현 후 최종 cascade와 실제 겹침 여부는 아직 검증하지 않았다.

## 더 작은 해법

자산 vendoring·얇은 매핑·프로필은 그대로 유지하되, 새 공통 부품 체계를 만들 필요는 없다. 먼저 기존 paper 변수 소비 지점을 보존한 채 kit 토큰에 연결하고, 기존 Chirpy 버튼·사이드바·목차에 필요한 동작과 상태만 보강하면 된다. 의미 매핑에 `--paper`·`--ink` 같은 호환 별칭을 두면 도표 선택자를 전부 바꾸는 위험도 줄인다.

`kit-theme-adapter` 안에서도 첫 화면 모드 동기화와 DOM 준비 후 메뉴 보강을 분리한다. 팔레트·저장소·메뉴 열림 상태를 새로 복제하지 않는다. 테마 교체는 검증용 왕복 한 번으로 계약을 확인하고, 새 테마의 본격 지원이나 범용 컴포넌트 추출은 별도 요구가 있을 때 한다.

폭별 조합을 무작정 늘리기보다 기존 S5에 위 세 상태 시퀀스와 폰트 실패·글자 확대를 명시적으로 넣는 편이 효율적이다. 배포 승인은 원래 기획 절차대로 별도로 남긴다.

## 가정 확인 결과

| 가정 | 이번 확인 / 남은 확인 |
|---|---|
| Sass가 plain `.css`를 `@use`로 묶는다 | **설치된 Sass로 확인.** core→neutral→paper 컴파일 결과 6,479 bytes, core·paper 값 포함, `@import` 잔류 없음. 실제 Jekyll production의 포함 위치·cascade는 S1에서 확인해야 한다. |
| Chirpy 시스템 모드도 `data-bs-theme`를 쓴다 | **7.6.0 원본 확인.** `theme.min.js:4`가 시스템 해석값을 기록하고 media change에 갱신한다. Node VM에서 시스템 light/dark 초기화 및 반대 모드 변경 모두 확인했다. 기존 프로젝트 CSS의 “시스템이면 속성이 없다” 주석은 현재 정상 JS 경로와 맞지 않는다. |
| metadata-hook이 필요한 스크립트 뒤다 | **모드에는 맞고 메뉴에는 불충분.** 동기 theme 스크립트 뒤지만 페이지 번들은 defer이고 body는 아직 파싱 전이다. |
| visibility 지연만으로 닫힌 메뉴의 탐색을 즉시 막는다 | **성립하지 않는 구간이 있다.** 지연 동안의 초점·빠른 재열기·breakpoint 왕복은 위 반례 1로 검증해야 한다. |
| Noto Serif KR/시스템 fallback이 모든 OS에서 같은 폭을 만든다 | **미확인.** 로딩 URL·400/700·swap은 확인했지만 실제 글리프/굵기 사용, 차단 시 fallback, Windows/Android 폭은 미확인이다. `document.fonts.ready`만으로 로드 성공을 판정하지 않는다. |
| kit mono가 Menlo를 잃으면 무조건 예외가 필요하다 | **미확인.** `ui-monospace`의 실제 선택은 플랫폼에 달린다. family 문자열과 실제 사용 글꼴을 구분해 판단해야 한다. |
| 44px 조작영역이면 부품이 사용 가능하다 | **불충분.** 부모 크기·가림·상태별 대비·실제 hit target도 필요하다. |
| 화면 폭 검사가 모든 전환을 덮는다 | **미확인.** 기획 목록 외에 gem breakpoint는 768/1400/1650px도 있다(`G/_sass/abstracts/_breakpoints.scss:3`). 영향 있는 전환만 골라 추가/생략 이유를 기록하고, 고정 폭 새로고침과 연속 resize를 구분한다. |
| viewport 확대 제한을 없애려면 Chirpy 전체 포크가 필요하다 | **근거가 부족하다.** `G/_includes/head.html:5`의 선언은 확인했다. 이미 계획한 metadata-hook에서 기존 meta를 조정하는 대안도 검토할 수 있다. JS 전 변경·브라우저별 효력은 별도 확인이 필요하며, 이번 제외 결정을 접근성 완료로 표현하면 안 된다. |

## 실행 증거와 한계

Sass 확인은 다음 명령으로 재현할 수 있다. 소스나 산출물 파일을 쓰지 않는다.

```sh
PATH=/opt/homebrew/opt/ruby/bin:$PATH \
BUNDLE_PATH=/Users/jeongjaehun/Documents/dev/tech-blog/vendor/bundle \
bundle exec ruby - <<'RB'
require 'sass-embedded'
root = '/Users/jeongjaehun/Documents/dev/37writes-claude-kit/skills/design/assets'
r = Sass.compile_string('@use "core"; @use "themes/neutral"; @use "themes/paper";',
                        load_paths: [root])
raise unless r.css.include?('--kit-control-min: 44px')
raise unless r.css.include?('#f6f2ea')
raise if r.css.include?('@import')
puts "PASS #{r.css.bytesize} bytes"
RB
```

모드 확인은 실제 `theme.min.js`를 Node `vm`에서 실행하고 DOM dataset·localStorage·matchMedia만 모의했다. 결과는 `system light → data-bs-theme light → media change dark`, 역방향도 동일했다. 이는 모드 알고리즘의 확인이며 브라우저 초기 페인트·MutationObserver·저장소 접근 실패·실기기 검증의 증거는 아니다.

검토 범위에서 제품 코드·기획서·kit 원본은 수정하지 않았다. 전체 빌드·htmlproofer·브라우저 접근성·실기기 결과는 주장하지 않는다. 다음 작업은 지휘자가 세 반례의 수용/기각을 기획에 기록하고, 구현 시 해당 조건을 검증하는 것이다.
