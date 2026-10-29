---
title: "Orca와 Claude Code로 1인 개발 에이전트 팀 만들기: 역할, 위험도 등급, 작업 카드"
date: 2026-10-28 14:10:00 +0900
categories: [개발 도구, AI 에이전트]
tags: [claude-code, orca, multi-agent, git-worktree, harness-engineering]
description: "AWS Deep Insight의 역할 구조를 Orca IDE의 오케스트레이션 기능과 Claude Code 위에 옮긴 방법을 정리합니다. 역할 매핑, T0~T2 위험도 등급, 작업 카드와 보고 양식, CLAUDE.md·스킬·훅 중 규칙을 어디에 둘지까지 다룹니다."
---

> **시리즈: AI 에이전트에게 팀을 만들어 주기**
> 1. [멀티에이전트 역할 나누기: Deep Insight 쉽게 이해하기]({% post_url 2026-10-28-deep-insight-multi-agent-roles %})
> 2. [컨텍스트 엔지니어링과 하네스: 개발 작업에 가져온 7가지 원칙]({% post_url 2026-10-28-deep-insight-context-engineering-for-dev %})
> 3. **Orca와 Claude Code로 1인 개발 에이전트 팀 만들기** ← 지금 글
> 4. [첫 실전: "기능이 안 돼요"에서 IAM 권한 누락까지]({% post_url 2026-10-28-dev-harness-first-bugfix-iam %})

## 들어가며

앞의 두 글에서 Deep Insight의 역할 구조와 컨텍스트·하네스 원칙을 정리했습니다. 이번 글은 그것을 **실제 개발 환경에 옮긴 결과물**입니다.

제가 쓰는 도구는 두 가지입니다.

- **Claude Code**: 터미널에서 동작하는 코딩 에이전트입니다. 이 구조에서 사용자와 대화하는 세션이 됩니다.
- **Orca**: 여러 코딩 에이전트(Claude Code, Codex 등)를 작업 폴더별로 띄우고 관리하는 데스크톱 앱입니다. 에이전트끼리 일을 맡기고 결과를 받는 **오케스트레이션** 명령을 제공합니다.

<figure class="diagram">
{% include figures/orca-claude-code-dev-harness/who-does-what.svg %}
<figcaption>대화 세션 하나가 지휘를 맡고, 구현과 검증은 각자 worktree를 가진 워커가 합니다.</figcaption>
</figure>

## Orca를 이해하는 데 필요한 개념

### git worktree: 같은 저장소, 다른 작업 폴더

에이전트 여러 개가 **같은 폴더**에서 동시에 파일을 고치면 서로 덮어씁니다. 그래서 Orca는 에이전트마다 **git worktree**를 만들어 줍니다.

worktree는 하나의 git 저장소에서 여러 개의 작업 폴더를 꺼내 쓰는 기능입니다. 폴더마다 다른 브랜치를 체크아웃할 수 있고, 커밋 기록은 공유합니다. 저장소를 여러 번 clone하는 것과 비슷하지만 훨씬 가볍습니다.

```sh
git worktree add ../fix-login -b fix-login   # 새 작업 폴더 + 새 브랜치
git worktree list                             # 작업 폴더 목록
git worktree remove ../fix-login              # 다 쓰면 삭제
```

Orca는 이 과정을 대신 해 주고, 폴더마다 무작위 이름(예: `eelgrass`, `sheepshead`)을 붙입니다.

### Run, Task, Worker

Orca 오케스트레이션의 기본 단위는 세 가지입니다.

| 개념 | 뜻 | 명령 예 |
|---|---|---|
| **Run** | 이번 작업 묶음의 목표와 메시지함 | `orca orchestration run-create --objective "..."` |
| **Task** | Run 안의 작업 하나. 다른 Task에 의존하게 할 수 있습니다 | `task-create`, `task-list`, `task-update` |
| **Worker** | Task를 맡아 자기 worktree에서 일하는 에이전트 | `worker-start`, `worker-release` |

워커는 일이 끝나면 `worker_done`, 막히면 `escalation`, 궁금하면 `question` 메시지를 보냅니다. 지휘하는 세션은 `orca orchestration check --wait`로 이 메시지를 기다립니다. 실패한 단계만 다시 돌릴 때는 `worker-start --retry-of`를 씁니다.

## Deep Insight 역할을 Orca에 매핑하기

Deep Insight의 역할을 제 환경에 대응시키면 이렇습니다.

| 역할 | 누가 맡나 | 산출물 | 모델(정한 기준) |
|---|---|---|---|
| **Coordinator** | 제가 대화하는 Claude Code 세션 | 간단한 일은 직접 처리, 나머지는 계획으로 | Haiku 또는 Sonnet |
| **Planner** | 같은 세션(큰 계획은 깊게 생각하는 모델로) | `docs/plans/NNNN-<주제>.md` 체크리스트 | Opus |
| **Plan Reviewer** | **나(사람)** | 승인 또는 수정 요청 | – |
| **Supervisor** | 같은 세션 | Orca Run/Task 생성, 워커 배정, 병합 | Sonnet |
| **Coder** | Orca 워커(자기 worktree) | 코드 변경 + 커밋 | Claude, Codex 등에 분산 |
| **Validator** | Orca 워커(**Coder와 다른 에이전트**) | 테스트·타입 검사 재실행, 변경 범위·시크릿 점검 | Coder와 다른 모델 |
| **Reporter** | Orca 워커 또는 세션 | 상태 문서, 결정 기록(ADR) 갱신 | – |
| **Tracker** | 세션 | 계획 파일 `[ ]` → `[x]`, `STATE.md` 반영 | Haiku |

원문은 Tracker에 Sonnet을 쓰지만, 저는 체크박스를 바꾸는 단순한 일이라 Haiku를 기준으로 정했습니다. 다만 실제로는 대화 세션이 Coordinator, Planner, Supervisor, Tracker를 번갈아 맡기 때문에, 역할별 모델은 "따로 띄울 때 쓸 기준"에 가깝습니다.

그림으로 보면 이렇습니다.

```text
나 ── 요청
 │
[Coordinator] 대화 세션. 작은 일은 바로 처리
 │
[Planner] docs/plans/NNNN-*.md 작성
 │
[Plan Reviewer] 나: 승인 / 수정
 │
[Supervisor] orca orchestration run-create → worker-start → check --wait
 ├─▶ [Coder 워커]     자기 worktree에서 구현 → worker_done 보고
 ├─▶ [Validator 워커] 다른 에이전트가 재검증 → worker_done 보고
 └─▶ [Reporter]       문서 갱신
 │
[Tracker] 계획 체크박스, STATE.md 갱신
```

| Deep Insight 요소 | Orca에서 |
|---|---|
| 에이전트별 독립 컨텍스트 | `worker-start`가 워커마다 새 worktree와 새 세션을 만듭니다 |
| `full_plan` 체크리스트 | `docs/plans/*.md`와 Orca Task |
| 완료 신호와 짧은 요약 | `worker_done` 메시지(정해진 양식) |
| 사람에게 묻기 | 워커의 `question`을 세션이 받아 저에게 묻고 `reply`로 전달 |
| 부분 재실행 | `worker-start --retry-of` |

## 위험도 등급: 절차의 무게를 나누기

[지난 글]({% post_url 2026-10-28-deep-insight-context-engineering-for-dev %})에서 말한 대로, 모든 작업에 같은 절차를 쓰면 느려집니다. 그래서 작업을 세 등급으로 나눴습니다.

| 등급 | 예 | 절차 |
|---|---|---|
| **T0** | 질문, 문서 오타, 20줄 미만의 파일 하나 수정 | 바로 처리. 계획도 워커도 없음 |
| **T1** | 기능 추가, 버그 수정, 리팩터링, 테스트 | 계획 카드 + Coder + **독립 Validator** |
| **T2** | 배포, push, AWS·IAM·시크릿 변경, 확정된 설계 변경, 데이터 삭제 | T1 + **실행 전에 내가 계획을 승인**. 먼저 읽기 전용 미리보기(`diff`, dry-run) |

애매하면 높은 등급으로 분류합니다. 이 등급표 덕분에 Coordinator는 매번 "이건 물어봐야 하나?"를 고민하지 않고 표를 보고 판단합니다.

## 계획 파일과 작업 카드

### 계획 파일

Planner는 템플릿을 복사해 계획을 씁니다. 단계마다 **담당**과 **확인할 수 있는 완료 조건**을 적는 것이 핵심입니다.

```markdown
# Plan NNNN — <제목>

Tier: T0 | T1 | T2     Status: draft | approved | running | done
Approved by user: no (승인하면 날짜)

## Goal (한 문장, 사용자가 보게 될 결과)
## Context (사실만. 관련 파일, STATE, ADR 링크)

## Steps
- [ ] S1 — … — Coder/codex — `pnpm test` 통과, 변경은 <경로> 안에서만
- [ ] S2 — … — Validator/claude — S1 검사 독립 재실행, 시크릿·범위 점검
- [ ] S3 — … — Reporter — STATE.md 갱신

## Out of scope / forbidden (워커가 건드리면 안 되는 것)
## Risks and approvals needed (AWS 변경, push, 배포 등)
## Result log (Tracker가 단계별 결과를 덧붙임)
```

계획이 파일로 남아 있으니 대화가 끊겨도 다음 세션이 파일을 읽고 이어갈 수 있습니다.

### 작업 카드

워커에게는 대화 내용 전체가 아니라 **작업 카드**만 줍니다.

- 목표
- 건드려도 되는 파일·폴더
- 완료를 확인할 명령(예: `pnpm test`)
- 금지 사항: push, 배포, AWS 쓰기, 시크릿 출력
- 보고 양식

### 보고 양식

워커는 끝날 때 150단어 이내로 이렇게 보고합니다. 긴 출력은 파일로 남기고 경로만 적습니다.

```text
STATUS: SUCCESS | PARTIAL | ERROR
DONE: <끝낸 계획 단계 id>
CHANGED: <바뀐 파일 경로>
CHECKS: <실행한 명령 → 결과>
NOT DONE / RISKS: <남은 일, 위험>
```

양식이 고정돼 있어서 Supervisor는 `STATUS`와 `CHECKS`만 보고도 다음 행동을 정할 수 있습니다. 그래도 Coder의 보고를 그대로 믿지는 않습니다. Validator가 같은 검사를 **처음부터 다시** 돌리고, 숫자는 베끼지 않고 다시 계산합니다.

## 규칙을 어디에 둘 것인가

구조를 만들면서 가장 헷갈렸던 질문은 "이 규칙을 어디에 써 둬야 하나"였습니다. Claude Code에는 지침을 두는 곳이 여러 군데 있고, 각각 성격이 다릅니다.

| 위치 | 언제 읽히나 | 성격 | 이 구조에서 둔 것 |
|---|---|---|---|
| `~/.claude/CLAUDE.md` | 이 컴퓨터의 **모든 프로젝트**, 매 세션 | 개인 공통 규칙 | (나중에) 모든 프로젝트 공통 원칙 |
| `<프로젝트>/CLAUDE.md` | 그 프로젝트, 매 세션 | 프로젝트 규칙과 맥락 | 역할 요약, 등급표 요약 (짧게) |
| 스킬 `.claude/skills/<이름>/SKILL.md` | **필요할 때만** | 절차서 | 계획·실행·검증의 상세 절차 |
| 서브에이전트 `.claude/agents/` | 세션 안에서 호출될 때 | 역할별 모델·도구 제한 | 가벼운 역할(Planner, Tracker) 후보 |
| 훅·권한 `.claude/settings.json` | 도구 실행 시점 | **코드로 강제** | "승인 없이 배포 금지" 같은 절대 규칙 |
| `AGENTS.md` | Codex 등 다른 에이전트 | 다른 에이전트용 규칙 | 워커가 지킬 규칙과 보고 양식 |

몇 가지 기준을 세웠습니다.

- **CLAUDE.md는 짧게** 유지합니다. 매 세션 통째로 읽히니 길면 토큰을 계속 씁니다. 자세한 절차는 스킬로 빼고, CLAUDE.md에는 "자세한 건 harness 스킬"이라는 안내만 둡니다. Deep Insight가 스킬을 필요할 때만 불러오는 것과 같은 원리입니다.
- **꼭 지켜야 하는 규칙은 훅이나 권한으로** 막습니다. CLAUDE.md나 스킬에 쓴 규칙은 지침일 뿐이라 어길 수 있습니다. 훅은 코드라서 어길 수 없습니다. 훅의 동작 원리는 [git commit-msg 훅 글]({% post_url 2026-10-14-git-commit-msg-hook %})에서 다룬 git 훅과 비슷합니다. 정해진 시점에 스크립트가 돌고, 종료 코드로 막거나 통과시킵니다.
- **Codex 같은 다른 에이전트는 CLAUDE.md를 읽지 않을 수 있습니다.** Codex는 `AGENTS.md`를 읽습니다. 그래서 워커용 규칙은 `AGENTS.md`에 따로 두고, 작업 카드에도 필요한 규칙 다섯 줄을 직접 붙여 넣습니다.
- **플러그인은 나중에** 만듭니다. 한 프로젝트에서 구조를 먼저 검증하고, 다른 프로젝트에도 쓰겠다는 확신이 들면 스킬, 에이전트, 훅을 플러그인으로 묶습니다.

최종 파일 구성은 다음과 같습니다.

```text
CLAUDE.md                          역할·등급 요약 (몇 줄)
AGENTS.md                          Codex 등 워커가 지킬 규칙과 보고 양식
.claude/skills/harness/SKILL.md    분류 → 계획 → 실행 → 보고 → 검증 → 기록 절차
docs/plans/_template.md            계획 템플릿
docs/plans/0001-*.md               실제 계획들
docs/decisions/00NN-*.md           "이 구조를 쓰기로 했다"는 결정 기록(ADR)
docs/STATE.md                      현재 상태, 다음 할 일
```

## 한계와 주의할 점

솔직하게 적어 두면 이렇습니다.

- **Orca에 Coordinator, Planner 같은 고정 역할은 없습니다.** 역할은 제가 절차서와 프롬프트로 정의한 것이고, Coordinator·Planner·Supervisor는 사실상 대화 세션 하나가 번갈아 맡습니다. 절차를 지키는지는 결국 규칙과 습관에 달려 있습니다.
- **Validator를 따로 띄우면 토큰이 더 듭니다.** 그래서 등급을 나눴습니다. 문서 작업은 생략하고, 코드는 필수, 배포는 미리보기와 승인까지 이중으로 합니다.
- **기다리는 동안에는 질문이 늦게 읽힙니다.** 세션이 `check --wait`로 워커 신호를 기다리는 동안 제가 보낸 메시지는 대기가 끝나야 처리됩니다. 대기 시간을 2~3분 단위로 짧게 끊는 것으로 조정했습니다.
- **작업 폴더 정리가 필요합니다.** 병합이 끝난 worktree와 브랜치, 실패로 남은 Task 상태가 쌓이면 무엇이 진행 중인지 헷갈립니다. 처음에는 정리를 따로 요청해야 했습니다. 병합된 worktree와 브랜치를 지우고 Task 상태를 실제와 맞추는 일은 작업 마무리 단계에 넣어 두는 것이 좋습니다.

## 정리

- Orca의 **Run, Task, Worker**와 git worktree로 에이전트마다 독립된 작업 공간과 컨텍스트를 줍니다.
- Deep Insight의 역할을 **대화 세션(Coordinator·Planner·Supervisor·Tracker) + 나(Plan Reviewer) + Orca 워커(Coder·Validator·Reporter)** 로 매핑했습니다.
- **T0~T2 위험도 등급**으로 작업마다 절차의 무게를 다르게 합니다.
- 계획은 파일로, 워커 지시는 작업 카드로, 보고는 고정 양식으로 남깁니다.
- 규칙의 위치를 나눕니다. 요약은 CLAUDE.md, 절차는 스킬, 절대 규칙은 훅·권한, 다른 에이전트용 규칙은 AGENTS.md에 둡니다.

다음 글에서는 이 구조로 처음 처리한 실제 작업을 소개합니다. 배포 환경에서만 기능이 실패하던 버그였고, 원인은 IAM 권한 누락이었습니다.
