# S6 독립 검증 보고서

실행: **Codex / `global.openai.gpt-6-astra`** (Orca `worker-show --dispatch ctx_693c33a4c570 --json`의 `projection.provider.model` 확인). 2026-10-31 KST.
Task `task_192e55eca054`, Dispatch `ctx_693c33a4c570`.

대상 HEAD `79770489afa12003d99f96637ed489ab29a804c6`, base `d8615cc5b4ca25883c633e0baacf1a58e9928b04`, 브랜치 `37writes/personal-design-system`.
작성자의 S2~S5 통과 기록을 증거로 사용하지 않고 빌드·검사·실조작을 다시 수행했다. 기획서의 결정과 디자인 프로필을 기준으로 검사했다. 이 보고서 외 추적 파일 수정·커밋·push·배포는 하지 않았다.

## 1. 재실행한 검사

Ruby 명령의 공통 환경:

```sh
export PATH=/opt/homebrew/opt/ruby/bin:$PATH BUNDLE_PATH=/Users/jeongjaehun/Documents/dev/tech-blog/vendor/bundle
```

| 검사 | 실행 명령 | 출력 요약 | exit code |
|---|---|---|---:|
| production 빌드 | `JEKYLL_ENV=production bundle exec jekyll b -d /tmp/tb-s6` | `done in 1.812 seconds`, 오류·경고 없음 | 0 |
| 내부 링크 | `bundle exec htmlproofer /tmp/tb-s6 --disable-external --ignore-urls "/^http:\/\/127.0.0.1/,/^http:\/\/0.0.0.0/,/^http:\/\/localhost/"` | 58 HTML 파일, 내부 링크 186개, 10개 파일의 hash 검사, `finished successfully` | 0 |
| 프로젝트 디자인 검사 | `sh tools/design-check.sh /tmp/tb-s6` | core·neutral·paper 모두 OK, `design-check: OK` | 0 |
| kit 원본 직접 해시 | `shasum -a 256 /Users/jeongjaehun/Documents/dev/37writes-claude-kit/skills/design/assets/core.css /Users/jeongjaehun/Documents/dev/37writes-claude-kit/skills/design/assets/themes/*.css` | 아래 3개 해시, manifest와 일치 | 0 |
| 원본·manifest·복사본 직접 비교 | 아래 Python 비교 | 파일 3개 모두 `source=manifest=copy True` | 0 |
| 배포 제외·절대경로 독립 검사 | 아래 Python 산출물 검사 | `excluded path violations: [] local path files: []` | 0 |

빌드 로그 `/tmp/tb-s6-work/build.log`, 링크 로그 `/tmp/tb-s6-work/links.log`.

| 파일 | 원본 = `_sass/kit/SHA256SUMS` = 복사본 SHA-256 |
|---|---|
| core.css | `49e31837d2374212af4c985142c9ffaa4300de74d41ad6aa00aadbc080ef79a1` |
| themes/neutral.css | `ae73a6ee5ef7e5e5b9b397f82097b81b2069f205879ffd2f1024153d06e300a3` |
| themes/paper.css | `88607aca5f225e862dcf6b6a09eb080ba347f23c2d36ddada80170d4b2a3f0dc` |

직접 비교(실행한 `python3 - <<'PY'` 본문):

```python
from pathlib import Path
import hashlib
base = Path('/Users/jeongjaehun/Documents/dev/37writes-claude-kit/skills/design/assets')
for row in Path('_sass/kit/SHA256SUMS').read_text().splitlines():
    if row.startswith('#') or not row.strip():
        continue
    digest, name = row.split()
    actual = hashlib.sha256((base / name).read_bytes()).hexdigest()
    copy = hashlib.sha256((Path('_sass/kit') / name).read_bytes()).hexdigest()
    print(name, 'source=manifest=copy', digest == actual == copy)
    assert digest == actual == copy
```

산출물 검사(실행한 `python3 - <<'PY'` 본문, 확장자에 제한 없이 파일의 바이트 검사):

```python
from pathlib import Path
import re
p = Path('/tmp/tb-s6')
bad = [str(f.relative_to(p)) for f in p.rglob('*')
       if f.name in ['CLAUDE.md', 'AGENTS.md'] or f.relative_to(p).parts[0] == 'docs']
leaked = [str(f.relative_to(p)) for f in p.rglob('*') if f.is_file()
          and re.search(rb'/Users/|file://|claude-kit/skills/', f.read_bytes())]
print('excluded path violations:', bad, 'local path files:', leaked)
assert not bad and not leaked
```

`CLAUDE.md`, `AGENTS.md`, `docs/`가 빌드에 없으며, `/Users/`, `file://`, `claude-kit/skills/` 유출도 없다. 외부 링크의 유효성은 htmlproofer 옵션상 검사하지 않았다.

## 2. 변경 범위

- `git rev-parse HEAD` → 지정된 HEAD, exit 0. 시작 시 `git status --short` → 출력 없음, exit 0.
- `git diff --stat d8615cc5b4ca25883c633e0baacf1a58e9928b04...HEAD` → **22 files changed, 879 insertions(+), 140 deletions(-)**, exit 0.
- `git diff --stat d8615cc5b4ca25883c633e0baacf1a58e9928b04...HEAD -- _posts _tabs` → **출력 없음(변경 0)**, exit 0. 해당 경로의 본문·발행일·URL 변경 없음.
- `_config.yml` diff는 `exclude`의 `CLAUDE.md`·`AGENTS.md` 추가 2줄뿐. `metadata-hook.html`은 어댑터 include와 설명 추가이며 기존 폰트 링크 유지.
- 변경 파일 구성: 프로젝트 프로필 1, 설정 1, include 2, Sass/kit 5, CSS 진입점 1, 기준 PNG 8, 디자인 문서 1, 기획·반박 문서 2, 검사 도구 1 = 22. 요청 범위 안이다.
- `_layouts`, `head.html`, 글·탭·발행 경로 변경 없음. 모드 상태를 Chirpy에서 읽는 어댑터와 토큰 매핑, 조작 크기·초점 규칙을 직접 읽었다.

## 3. 시크릿 검사

실행 파이프:

```sh
git diff d8615cc5b4ca25883c633e0baacf1a58e9928b04...HEAD | grep -nE 'AKIA|secret|api[_-]?key|BEGIN .*PRIVATE'
```

Python subprocess로 위 두 프로세스를 연결하고 반환 코드를 개별 확인했다. **git exit 0, grep exit 1, 일치 0줄**이다. grep 1은 일치 없음이며 검사 실패가 아니다. 시크릿 값은 출력하지 않았다. 이는 지정된 패턴 검사이며 모든 종류의 비밀값 부재를 증명하는 것은 아니다.

## 4. 독립 실패 시나리오

### 환경·공통 제약

- `ego-browser skill` 안내를 끝줄 `[ego-browser:skill] end of guide v2.1.0`까지 읽었다. ego lite 0.6.1.13만 사용, upgrade·다른 브라우저·Playwright·headless·shot.py 사용 없음.
- TaskSpace **11**. `v1`이 존재하지 않았고 현재 SDK는 생성된 managed Page의 이름 변경을 지원하지 않았다. 지휘자에게 `ask`로 문의해 **“p2 사용하세요. p1은 작성자 Page이므로 건드리지 말고 … p2의 뷰포트·에뮬레이션을 원래대로”**라는 답을 받은 뒤 **p2** 사용. p1은 조작하지 않았다.
- 직접 빌드한 `/tmp/tb-s6`에서 `python3 -m http.server 4103 --bind 127.0.0.1` 실행. 원본 비교 보조 1회만 기존 4101 사용. 4101·4102 서버는 변경하지 않았다.
- 모든 브라우저 스크립트는 `/tmp/tb-s6-work/` 파일로 작성해 `ego-browser nodejs < 파일` 실행. 각 실행의 `try/finally` 안에 뷰포트·터치·OS 모드 설정과 `resetViewport(page)`를 묶었다. localStorage 직접 수정/삭제 없음. UI로 선택한 모드는 시나리오 1 끝에서 원래 시스템 선택으로 되돌렸다.
- 아래 시나리오는 기존 단독 버튼·폭 매트릭스 반복이 아니라 **낮은 화면 높이+스크롤+페이지 이동**, **열린 dialog+태블릿 폭 전환+앵커**, **빈 검색→재검색+검색 중 폭 변경+글 이동+시스템 모드** 조합을 선택했다.
- 에뮬레이션 결과다. **iOS Safari·가상 키보드·실기기 터치는 모두 미확인**. 시나리오 3의 검색 열기만 CDP touchStart/touchEnd 실제 입력을 보냈고, 나머지는 ego 포인터 클릭·키보드·wheel 조작이다. maxTouchPoints/coarse 측정만으로 실기기 터치 성공이라고 해석하지 않았다.

### 시나리오 1 — 짧은 가로 화면에서 메뉴 하단 도달·모드 선택·탭 이동

**선택 이유:** 폭만 검사하면 높이 360px에서 모드 버튼이 잘리는 상황을 놓칠 수 있다. 메뉴 스크롤 후 모드를 고르고 다른 문서로 이동해도 상태와 닫힌 메뉴의 inert가 유지돼야 한다.

재현:

```sh
ego-browser nodejs < /tmp/tb-s6-work/scenario-1.mjs
```

**exit 0**, 로그 `/tmp/tb-s6-work/scenario-1.log`.
절차: 780×360 touch/light OS → 홈에서 Sidebar 열기 → 메뉴 안 wheel 450 → 모드 메뉴 다크 선택 → 정보 링크로 이동 → 메뉴를 다시 열고 시스템 선택 → Escape.

실측·결과:

- `innerWidth=780`, `innerHeight=360`, `maxTouchPoints=1`, `pointer:coarse=true`.
- 사이드바 `clientHeight=360`, `scrollHeight=592`, 스크롤 뒤 `scrollTop=232`; 모드 버튼 y=284, 44×44로 화면 내 도달. 모드 팝업 3개 항목도 스크롤 영역 안에서 보임.
- 다크 선택 뒤 `data-bs-theme=data-kit-mode=dark`, 배경 `rgb(28,26,23)`, focus=`mode-toggle`.
- `/about/`로 실제 이동 후 dark 유지, sidebar inert=true, document scrollWidth=780. 제목 family=`"Noto Serif KR", AppleMyungjo, Batang, serif`.
- 시스템 선택·닫기 뒤 light, 배경 `rgb(246,242,234)`, focus=`sidebar-trigger`, inert=true.
- 열린 사이드바의 scrollWidth=1040은 본문이 260px 이동하는 Chirpy 기존 동작이다. `/tmp/tb-s6-work/14-offcanvas-compare.mjs`(exit 0, `14.log`)로 4101/4103 모두 `matrix(1,0,0,1,260,0)`·1040임을 대조했으므로 새로운 가로 넘침 결함으로 세지 않았다. 닫힌 상태는 780으로 복귀한다.

캡처(직접 열어 확인): `/tmp/tb-s6-work/landscape-mode-open.png`, `/tmp/tb-s6-work/s1-dark-menu.png`, `/tmp/tb-s6-work/s1-about-dark.png`. **기능 통과**.
미검증: 실제 손가락 swipe, 브라우저 주소창 접힘, 실제 가로 회전·화면 노치.

### 시나리오 2 — 열린 목차를 태블릿의 넓은 표시로 전환한 뒤 복귀

**선택 이유:** 1200px 양쪽을 각각 로드하는 것만으로는 열린 dialog의 backdrop/scroll lock 잔류를 놓친다. 넓은 태블릿은 viewport가 데스크톱 크기여도 pointer가 coarse일 수 있다.

재현:

```sh
ego-browser nodejs < /tmp/tb-s6-work/scenario-2.mjs
ego-browser nodejs < /tmp/tb-s6-work/scenario-2-final.mjs
```

**각 exit 0**, 로그 `scenario-2.log`, `scenario-2-final.log`(모두 `/tmp/tb-s6-work/`).
절차: 긴 제목 글을 1199×700 touch/dark로 로드 → 스크롤 → 목차 팝업 열기 → 열린 채 1201로 넓힘 → 오른쪽 목차 ‘정리’ 선택 → 1199로 복귀 → 목차를 다시 열고 ‘정리’ 선택.

실측·결과:

- 모든 행 `innerHeight=700`, `maxTouchPoints=1`, `pointer:coarse=true`; 실제 innerWidth는 각각 1199/1201/1199.
- 1199 열린 상태: dialogOpen=true, body overflow=hidden, 닫기 버튼 44×44.
- 1201 전환: dialogOpen=false, overflow=visible, document scrollWidth=1201. backdrop 잔류로 본문을 막지 않음.
- 오른쪽 목차 링크 클릭으로 hash=`#정리`, 제목이 화면 안에 도달. 복귀 후 재선택도 dialogOpen=false, overflow=visible, 제목 y=56.24px로 상단 목차 바 아래에 노출.
- 종이 dark 배경 `rgb(28,26,23)`, 제목 세리프 family 유지.
- **낮음 1건:** 1201/coarse에서 목차 한 줄 항목 hit box가 **184.25×29.80px**, 인접 항목 y=75.20/104.99로 연속. 기획의 ‘≥1200, 가는 포인터’ 예외보다 넓게 작은 목차가 적용된다(5절).

캡처(직접 확인): `/tmp/tb-s6-work/s2-open-1201.png`, `/tmp/tb-s6-work/s2-anchor-1201.png`, `/tmp/tb-s6-work/s2-return-1199.png`.
미검증: 실기기 회전 이벤트, touch 오탭 확률. 앵커·dialog 기능은 통과했지만 44px 정책은 위 1건을 남긴다.

### 시나리오 3 — 빈 검색 복구 후 화면 폭 변경·도표 글 이동·시스템 전환

**선택 이유:** 검색을 취소하는 단독 검사와 달리 검색 상태를 가진 채 폭을 바꿔 결과 링크로 이동하면 상태/레이아웃 잔류를 발견할 수 있다. 이동한 도표 글에서도 OS 모드 미러가 작동해야 한다.

재현:

```sh
ego-browser nodejs < /tmp/tb-s6-work/scenario-3.mjs
ego-browser nodejs < /tmp/tb-s6-work/13-final-visual.mjs
```

**각 exit 0**, 로그 `/tmp/tb-s6-work/scenario-3.log`, `/tmp/tb-s6-work/13.log`.
절차: 320×640 touch/dark → 검색 트리거 중심에 CDP touchStart/touchEnd → 없는 검색어 입력 → ‘검색 결과가 없습니다’ 확인 → CERTIFICATE로 바꿈 → 검색 결과를 유지한 채 575px → 인증서 글 링크 클릭 → 첫 도표로 스크롤 → 새로고침 없이 OS light 전환.

실측·결과:

- 실제 innerWidth=320→575, innerHeight=640, maxTouchPoints=1, pointer:coarse=true. document scrollWidth도 각각 320/575.
- 없는 검색어 결과 0개 → CERTIFICATE 결과 2개 → `/posts/aws-cli-certificate-verify-failed/` 이동 성공. 이동 후 검색 결과 DOM 0개.
- 575에서 `.diagram-narrow` 폭 360px, 최소 SVG 글자 실효 크기 14.625px(viewBox 대비 축척 반영).
- dark: body `rgb(28,26,23)`, SVG 기본 fill `rgb(238,231,220)`.
- OS light 전환 후: body·목차 바 모두 `rgb(246,242,234)`, SVG 기본 fill `rgb(38,36,31)`, mode=light. 세리프 family는 유지.
- 전환 애니메이션 중 캡처의 목차 바가 어둡게 남은 것을 확인하여 `13-final-visual.mjs`에서 모든 animation.finished 후 다시 캡처했다. 안정 상태에는 정상 종이색이다.

캡처: `/tmp/tb-s6-work/s3-no-results.png`, `/tmp/tb-s6-work/s3-diagram-dark.png`, `/tmp/tb-s6-work/s3-diagram-light-settled.png`(도표 dark/light 직접 열어 확인). **통과**.
미검증: 실기기 가상 키보드, IME 조합 입력, 네트워크가 끊긴 검색, 다른 모든 도표의 최소 글자 크기.

### 검사 도중의 도구·가정 실패 기록

- `01-inspect.mjs`: v1 label 없음, exit 1. `03-open.mjs`: agent page release 거부, exit 1. `04-label.mjs`: managed page adopt 거부, exit 1. 이후 지휘자 승인으로 p2 사용. 제품 결함 아님.
- `scenario-2-finish.mjs`: 앵커 제목이 정확히 y≈88이어야 한다는 검사자 가정 때문에 waitForFunction timeout, exit 1. URL hash 이동은 이미 성공했다. `11-toc-position.mjs`(exit 0)로 제목이 y=160.55에 실제 노출된 것을 확인하고, `scenario-2-final.mjs`에서 화면 내 노출 조건으로 교정해 exit 0. 첫 실패를 제품 실패나 통과로 숨기지 않았다.
- `06-landscape-menu.mjs`의 초기 좌표는 사이드바 애니메이션 중간 값이므로 최종 판정에 사용하지 않았다. 후속 스크립트는 완료된 애니메이션과 실제 스크롤 도달을 확인했다.
- ego가 업데이트 가능 알림을 출력했다. 지시대로 upgrade하지 않았다.

## 5. 발견한 결함

**높음 0 / 중간 0 / 낮음 1.**

1. **낮음 — 넓은 터치 화면의 목차 크기 예외가 기획보다 넓다.**
   - 위치: `assets/css/jekyll-theme-chirpy.scss:434`(목차 줄바꿈만 재정의, coarse 크기 분기 없음), `docs/design-system.md:41`(가는 포인터 조건 누락), 기획서 `docs/plans/2026-10-31-personal-design-system.md:43`(예외를 ‘≥1200, 가는 포인터’로 제한).
   - 재현: 시나리오 2, 1201×700 / maxTouchPoints=1 / pointer:coarse=true. 오른쪽 목차 한 줄 링크 높이 29.796875px, 44px 미만. 클릭·앵커 이동은 성공한다.
   - 영향: 넓은 태블릿에서도 좁은 간격의 목차가 표시된다. 기획·문서·구현의 조건 불일치이며 기능 차단이나 새로 발생한 탐색 실패는 확인되지 않았다.
   - 제안: coarse 환경에 44px 목차 행을 적용하거나, 의도한 예외가 폭 기준이라면 기획·프로필의 조건을 합의해 일치시킨다. 읽기 전용 범위라 수정하지 않았다.

별도 기존 한계: `user-scalable=no`, 실기기 확인 부재, 모든 도표의 작은 글자 문제는 승인된 범위 밖/기존 미확인 항목으로 유지한다. 이번 검사로 해결됐다고 하지 않는다.

## 6. 결론 및 정리

**배포 전 막아야 할 기능 결함은 발견하지 못했다. 낮음 1건(넓은 터치 화면 목차 크기 정책 불일치)은 남아 있다.**

이 결론은 지정 HEAD의 로컬 production 빌드에 한정되며 배포 성공·실기기 성공을 뜻하지 않는다. 빌드·내부 링크·원본 해시·산출물 경로·변경 범위·지정 시크릿 패턴 검사는 통과했다.

- p2의 viewport/touch/media override는 각 스크립트 `finally`에서 초기화했다. 공유 TaskSpace 11과 p1은 유지한다.
- 검증용 4103 서버만 종료했다. 4101·4102는 종료하지 않았다.
- 최종 `git status --short`: `?? docs/plans/2026-10-31-personal-design-system/validation.md` 한 줄, exit 0. 추적 파일 변경 없음.
- 재현 스크립트·로그·캡처는 `/tmp/tb-s6-work/`, 빌드는 `/tmp/tb-s6`에 남겼다. 임시 경로 증거는 시스템 정리 시 사라질 수 있으므로 장기 보존은 지휘자 판단 사항이다.
