---
title: "git commit-msg 훅으로 커밋 메시지 형식 강제하기: 동작 원리와 주의할 점"
date: 2026-10-14 15:00:00 +0900
categories: [개발 도구, Git]
tags: [git, git-hooks, commit-msg, conventional-commits, shell]
description: "git commit-msg 훅이 커밋 메시지를 검사하는 원리를 정리합니다. 훅의 입력과 종료 코드, 주석 줄 처리, Merge·fixup 예외, 최소 예시 스크립트, --no-verify와 팀 공유 방법까지 다룹니다."
---

## 어떤 문제였나

개인 프로젝트에 커밋 규칙을 적용하는 도구([37writes-claude-kit](https://github.com/37writes/37writes-claude-kit), Claude Code 플러그인)를 설치했더니, 어느 순간부터 `type(scope): 요약` 형식이 아닌 커밋이 전부 거부되기 시작했습니다.

```text
$ git commit -m "버그 고침"
✖ 형식: type(scope): 요약
```

어디서 막는 건지 찾아보니 범인은 `.git/hooks/commit-msg`라는 짧은 셸 스크립트 하나였습니다. 이 글에서는 git이 이 훅을 언제, 어떻게 실행하는지, 그리고 직접 만들 때 빠지기 쉬운 함정을 정리합니다.

<figure class="diagram">
{% include figures/git-commit-msg-hook/hook-flow.svg %}
<figcaption>훅은 메시지 파일 경로를 받아 종료 코드 하나로 커밋을 통과시키거나 멈춥니다.</figcaption>
</figure>

## 훅은 "정해진 이름의 실행 파일"입니다

git 훅에는 특별한 등록 절차가 없습니다. git은 특정 시점마다 `.git/hooks/<훅 이름>` 파일을 찾아보고, 파일이 있고 **실행 권한**이 있으면 실행합니다.

- 언어는 상관없습니다. shebang(`#!/bin/sh`, `#!/usr/bin/env python3` 등)만 맞으면 됩니다.
- `git init`을 하면 `.git/hooks/`에 `commit-msg.sample` 같은 예제가 들어 있습니다. `.sample`을 떼고 실행 권한을 주면 바로 동작합니다.
- `core.hooksPath` 설정이 있으면 `.git/hooks` 대신 그 디렉터리를 봅니다. 뒤에서 팀 공유 방법으로 다시 다룹니다.

## commit-msg 훅의 계약

commit-msg 훅은 커밋 메시지가 확정된 직후, 실제 커밋 객체가 만들어지기 전에 실행됩니다. 훅과 git 사이의 약속은 단순합니다.

| 항목 | 내용 |
|---|---|
| 입력 | 첫 번째 인자 `$1` = 커밋 메시지가 담긴 파일 경로 (보통 `.git/COMMIT_EDITMSG`) |
| 출력 | 종료 코드. `0`이면 커밋 진행, 0이 아니면 커밋 중단 |
| 메시지 | 훅이 stderr로 출력한 내용이 사용자 터미널에 그대로 보입니다 |

메시지가 인자로 직접 오는 게 아니라 **파일 경로**로 온다는 점이 중요합니다. 그래서 훅은 이 파일을 읽어서 검사할 수도 있고, **수정**할 수도 있습니다. 예를 들어 브랜치 이름에서 이슈 번호를 뽑아 메시지 끝에 붙이는 훅을 만들면, 수정된 내용이 최종 커밋 메시지가 됩니다.

## 형식 검사 훅이 하는 일

커밋 형식을 검사하는 훅은 대체로 아래 네 단계로 동작합니다.

### 1. 주석과 빈 줄을 걸러내고 첫 줄만 본다

`git commit`을 에디터로 작성하면 git은 메시지 파일에 이런 안내 주석을 넣습니다.

```text
# Please enter the commit message for your changes. Lines starting
# with '#' will be ignored, and an empty message aborts the commit.
```

이 주석 줄은 최종 커밋에서는 빠지지만, **주석 정리는 commit-msg 훅이 실행된 다음에 일어납니다.** 즉 훅은 주석이 포함된 원본 파일을 받습니다. 그래서 훅에서 `#`으로 시작하는 줄과 빈 줄을 직접 걸러낸 뒤 첫 줄(제목)을 꺼내야 합니다.

### 2. git이 자동으로 만든 메시지는 통과시킨다

`Merge branch ...`, `Revert "..."`처럼 git이 만들어 주는 메시지나, `git commit --fixup`이 만드는 `fixup! ...`, `squash! ...`, `amend! ...` 메시지까지 막으면 머지나 `rebase --autosquash`를 쓸 수 없게 됩니다. 이런 접두어로 시작하면 검사 없이 `exit 0` 합니다.

### 3. 정규식으로 형식을 검사한다

Conventional Commits 스타일이라면 정규식은 대략 이렇습니다.

```text
^(feat|fix|docs|style|refactor|test|chore|perf|build|ci)(\([A-Za-z0-9._/-]+\))?!?: .+
```

- `(feat|fix|...)`: type은 허용 목록 중 하나
- `(\([A-Za-z0-9._/-]+\))?`: `(scope)`는 선택
- `!?`: breaking change 표시 (예: `feat(api)!: 응답 형식 변경`)
- `: .+`: 콜론, 공백, 그리고 한 글자 이상의 요약

### 4. 실패하면 안내문을 출력하고 exit 1

그냥 거부만 하면 사용자는 무엇이 틀렸는지 모릅니다. 올바른 형식과 예시를 stderr로 보여 주고 0이 아닌 값으로 종료합니다.

## 최소 예시

위 내용을 최소한으로 줄인 commit-msg 훅입니다.

```sh
#!/bin/sh
msg_file="$1"

# 1. 주석·빈 줄을 제외한 첫 줄
first=$(grep -v '^#' "$msg_file" | sed '/^[[:space:]]*$/d' | head -n 1)

# 2. git 자동 메시지는 통과
case "$first" in
  Merge*|Revert*|"fixup! "*|"squash! "*|"amend! "*) exit 0 ;;
esac

# 3. 형식 검사
if printf '%s\n' "$first" | grep -Eq '^(feat|fix|docs|refactor|test|chore)(\([A-Za-z0-9._/-]+\))?!?: .+'; then
  exit 0
fi

# 4. 실패 안내
cat >&2 <<'EOF'
✖ 커밋 메시지 형식이 맞지 않습니다.
  형식: type(scope): 요약
  예시: fix(api): 응답 지연 오류 수정
EOF
exit 1
```

설치하고 시험해 보면 다음과 같습니다.

```sh
chmod +x .git/hooks/commit-msg

git commit -m "아무거나"            # ✖ 거부
git commit -m "fix(api): 오류 수정"  # 통과
git commit -m "feat!: 설정 파일 형식 변경"  # 통과 (scope 생략, breaking change)
```

## 주의할 점

### 실행 권한이 없으면 조용히 무시된다

파일을 만들어 놓고 "훅이 안 돈다"면 가장 먼저 권한을 확인합니다.

```sh
ls -l .git/hooks/commit-msg
# -rw-r--r--  ...  ← x 비트가 없으면 실행되지 않음
```

최근 git은 `hint: The '.git/hooks/commit-msg' hook was ignored because it's not set as executable.` 같은 힌트를 띄워 주기도 하지만, 에러로 멈추지는 않습니다.

### 첫 줄만 검사한다

위 예시는 제목 줄만 봅니다. 본문이나 `Co-Authored-By:`, `Signed-off-by:` 같은 trailer는 자유롭게 쓸 수 있습니다. 본문 규칙(예: 제목과 본문 사이 빈 줄)까지 검사하고 싶다면 별도로 추가해야 합니다.

### `grep -E`의 `\(`는 리터럴 괄호다

확장 정규식에서 `( )`는 그룹이고, `\( \)`는 문자 그대로의 괄호입니다. scope 부분 `(\([A-Za-z0-9._/-]+\))?`은 "리터럴 괄호로 감싼 scope 전체를 하나의 그룹으로 묶어 선택 사항으로 만든다"는 뜻이라 처음 보면 헷갈리기 쉽습니다.

### `echo` 대신 `printf '%s\n'`

메시지가 `-n`이나 `-e`로 시작하면 셸에 따라 `echo`가 이를 옵션으로 해석해 버릴 수 있습니다. 사용자 입력을 파이프로 넘길 때는 `printf '%s\n' "$var"`가 안전합니다.

## 우회와 한계: 로컬 훅은 강제 수단이 아니다

### `--no-verify`로 건너뛸 수 있다

```sh
git commit --no-verify -m "급한 수정"   # 또는 -n
```

`--no-verify`는 pre-commit 훅과 commit-msg 훅을 모두 건너뜁니다. 훅은 언제든 끌 수 있다는 뜻입니다.

### 훅은 clone으로 전파되지 않는다

`.git/` 디렉터리는 버전 관리 대상이 아닙니다. 내 컴퓨터의 `.git/hooks/commit-msg`는 push해도 원격에 올라가지 않고, 다른 사람이 clone해도 받을 수 없습니다.

팀 전체에 같은 훅을 쓰게 하고 싶다면 방법은 대략 세 가지입니다.

1. **`core.hooksPath`로 레포 안의 폴더를 가리키기**

   ```sh
   mkdir .githooks
   mv .git/hooks/commit-msg .githooks/
   git config core.hooksPath .githooks
   ```

   `.githooks/`는 레포에 커밋되므로 공유됩니다. 다만 `git config` 설정 자체는 공유되지 않기 때문에, 각자 clone 후 한 번 실행해야 합니다 (README나 셋업 스크립트에 넣어 둡니다).

2. **husky 같은 도구 사용**: 패키지 설치 단계에서 훅 설정을 자동으로 해 줍니다. Node.js 프로젝트라면 가장 손이 덜 갑니다.

3. **서버나 CI에서 검사**: PR의 커밋 메시지를 CI에서 검사하면 `--no-verify`로도 우회할 수 없습니다. 진짜 "강제"가 필요하다면 이쪽입니다.

## 정리

- git 훅은 `.git/hooks/`에 있는 **정해진 이름의 실행 파일**입니다. 실행 권한이 없으면 무시됩니다.
- commit-msg 훅은 **메시지 파일 경로를 `$1`로 받고**, 종료 코드로 커밋 진행 여부를 결정합니다. 파일을 수정해 메시지를 바꿀 수도 있습니다.
- 훅이 받는 파일에는 **주석 줄이 그대로** 들어 있으므로 직접 걸러야 하고, Merge·Revert·fixup 같은 자동 메시지는 예외로 두어야 합니다.
- 로컬 훅은 `--no-verify`로 우회되고 clone으로 전파되지 않습니다. **실수 방지용**으로 쓰고, 강제가 필요하면 `core.hooksPath` 공유나 CI 검사를 함께 씁니다.

더 자세한 훅 목록과 각 훅의 인자는 `git help hooks`(githooks 공식 문서)에서 확인할 수 있습니다.

이 글에서 다룬 훅의 전체 코드는 [37writes-claude-kit의 `githooks/commit-msg`](https://github.com/37writes/37writes-claude-kit/blob/main/githooks/commit-msg)에서 볼 수 있습니다.
