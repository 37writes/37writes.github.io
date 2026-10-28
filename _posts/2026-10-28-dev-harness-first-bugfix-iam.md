---
title: "에이전트 하네스 첫 실전: 배포 환경에서만 실패하던 기능, 원인은 IAM 권한 누락"
date: 2026-10-28 14:15:00 +0900
categories: [개발 도구, AI 에이전트]
tags: [claude-code, aws, iam, dynamodb, ecs, cdk, troubleshooting]
description: "Deep Insight식 에이전트 하네스로 처음 처리한 실제 버그를 정리합니다. 로컬에서는 되는데 배포 환경에서만 실패한 원인(DynamoDB UpdateItem·ConditionCheckItem 권한 누락), cdk diff 미리보기와 승인, IAM 정책 시뮬레이션 검증, 그리고 하네스를 처음 써 보며 배운 점을 다룹니다."
---

> **시리즈: AI 에이전트에게 팀을 만들어 주기**
> 1. [멀티에이전트 역할 나누기: Deep Insight 쉽게 이해하기]({% post_url 2026-10-28-deep-insight-multi-agent-roles %})
> 2. [컨텍스트 엔지니어링과 하네스: 개발 작업에 가져온 7가지 원칙]({% post_url 2026-10-28-deep-insight-context-engineering-for-dev %})
> 3. [Orca와 Claude Code로 1인 개발 에이전트 팀 만들기]({% post_url 2026-10-28-orca-claude-code-dev-harness %})
> 4. **첫 실전: "기능이 안 돼요"에서 IAM 권한 누락까지** ← 지금 글

## 어떤 문제였나

[지난 글]({% post_url 2026-10-28-orca-claude-code-dev-harness %})에서 만든 구조를 처음 적용한 작업은 이 신고였습니다.

> 웹사이트에서 보고서 생성 기능이 작동하지 않아요.

상황은 이랬습니다.

- 사내 웹 서비스입니다. 사용자가 조건을 넣으면 서버가 자료를 모아 AI로 요약 보고서를 만듭니다.
- 서버는 AWS ECS(Fargate)에서 돌고, 데이터는 DynamoDB에 저장합니다. 인프라는 AWS CDK로 관리합니다.
- **로컬에서 끝까지 돌려 본 테스트(e2e)는 통과**했습니다. 그런데 배포한 사이트에서만 실패했습니다.

이 글에서는 하네스 절차에 따라 이 문제를 진단하고 고친 과정을 단계별로 정리합니다. (서비스 이름, 리소스 이름, 계정 정보는 예시 값으로 바꿨습니다.)

## 1단계: 분류 (Coordinator)

먼저 [위험도 등급]({% post_url 2026-10-28-orca-claude-code-dev-harness %})으로 분류합니다.

- 원인을 찾는 단계는 로그를 읽기만 하므로 바로 진행해도 됩니다.
- 고치는 단계는 IAM 권한을 바꾸고 배포까지 해야 할 가능성이 높습니다. 그래서 **T2**입니다. 실행 전에 계획을 승인받고, 적용 전에 읽기 전용 미리보기를 먼저 해야 합니다.

## 2단계: 읽기 전용 진단

서버 로그(CloudWatch Logs)에서 최근 며칠간의 기록을 확인했습니다. 보고서 요청 두 건이 모두 같은 모양으로 실패하고 있었습니다.

```json
{"level":"info","msg":"report_created","report_id":"01J..."}
{"level":"error","msg":"job_failed","report_id":"01J...","error":"store:auth","detail":"Service authentication failed"}
```

요청이 들어온 지 **0.02초 만에** 실패합니다. AI를 부르기도 전에, 데이터를 저장하는 첫 단계에서 막힌 것입니다.

`detail`의 "authentication failed"만 보면 로그인 문제처럼 보입니다. 하지만 코드를 확인해 보니 이 오류는 **DynamoDB가 권한 거부(AccessDenied)를 돌려줄 때** 붙이는 이름이었습니다. 사용자 인증이 아니라 서버 역할의 **권한(authorization)** 문제입니다. 오류 메시지가 실제 원인과 다른 말을 하고 있었던 셈입니다.

## 원인: 코드가 쓰는 명령과 IAM 권한이 달랐다

서버 코드가 DynamoDB에 보내는 명령과, 서버 역할(ECS 태스크 역할)에 허용된 IAM 권한을 나란히 놓아 봤습니다.

| 코드에서 쓰는 명령 (AWS SDK) | 필요한 IAM 권한 | 역할에 허용됐나 |
|---|---|---|
| `GetCommand` | `dynamodb:GetItem` | ✅ |
| `PutCommand` | `dynamodb:PutItem` | ✅ |
| `QueryCommand` | `dynamodb:Query` | ✅ |
| `UpdateCommand` | `dynamodb:UpdateItem` | ❌ |
| `TransactWriteCommand` | 트랜잭션 안의 각 작업 권한 (`PutItem`, `UpdateItem`, 조건 검사가 있으면 `ConditionCheckItem`) | ❌ (일부) |

새 기능을 만들면서 `UpdateCommand`와 `TransactWriteCommand`를 쓰기 시작했는데, 인프라 코드의 권한 목록은 예전 그대로였습니다.

`TransactWriteCommand`는 함정이 하나 있습니다. **`TransactWriteItems`라는 IAM 권한은 따로 없습니다.** 트랜잭션 안에 들어 있는 작업 하나하나(Put, Update, Delete, 조건 검사)의 권한이 각각 있어야 합니다. 조건만 확인하는 항목이 있다면 `dynamodb:ConditionCheckItem`도 필요합니다.

### 왜 로컬에서는 통과했나

로컬 e2e 테스트는 **관리자 권한 키**로 돌렸습니다. 관리자 키는 모든 권한이 있으니 권한이 빠져도 드러나지 않습니다. 실제 서버는 최소 권한만 받은 역할로 돌기 때문에 거기서 처음 막힌 것입니다.

> 로컬 테스트를 강한 권한으로 돌리면, 테스트 통과가 "배포 환경에서도 된다"는 뜻이 아닙니다.

## 3단계: 계획 (Planner)

계획 파일을 썼습니다. 단계마다 담당과 완료 조건이 있습니다.

```markdown
# Plan 0001 — 배포 환경 보고서 생성 실패 수정 (store:auth)

Tier: T2 (IAM 변경 + 배포)     Status: approved-pending
Approved by user: no

## Goal
배포 사이트에서 만든 보고서가 실패하지 않고 끝까지 완료된다.

## Steps
- [x] S1 — 태스크 역할에 dynamodb:UpdateItem, ConditionCheckItem 추가 — Coordinator — 타입 검사 + 인프라 테스트 통과
- [ ] S2 — 읽기 전용 diff로 IAM 정책 변경만 있는지 확인 — Supervisor — 사용자가 diff 확인
- [ ] S3 — 배포 — Supervisor — ECS 롤아웃 완료
- [ ] S4 — 실제 보고서 1건 생성 후 로그에서 성공 확인 — 사용자 + Coordinator
- [ ] S5 — STATE.md, 계획 파일 갱신 — Tracker
```

S1은 인프라 코드에 두 줄을 추가하는 작은 수정이라 워커를 띄우지 않고 Coordinator가 직접 했습니다.

```ts
taskRole.addToPrincipalPolicy(
  new iam.PolicyStatement({
    actions: [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:Query",
      // UpdateCommand, TransactWriteCommand용
      "dynamodb:UpdateItem",
      "dynamodb:ConditionCheckItem",
    ],
    resources: [tableArn, `${tableArn}/index/*`],
  }),
);
```

## 4단계: 읽기 전용 미리보기

T2 작업은 적용 전에 무엇이 바뀌는지 먼저 봅니다. 배포 스크립트에 `cdk diff`만 실행하고 끝나는 `--diff` 모드를 추가해 두었습니다.

```sh
./deploy.sh --diff     # 내부적으로 npx cdk diff. 아무것도 바꾸지 않음
```

결과는 예상대로였습니다.

```text
[~] AWS::IAM::Policy  TaskRole/DefaultPolicy
      [+] "dynamodb:UpdateItem"
      [+] "dynamodb:ConditionCheckItem"
[~] AWS::ECS::TaskDefinition  replace   (새 컨테이너 이미지)
[~] AWS::ECS::Service                   (새 태스크 정의로 교체)
```

IAM 정책에 권한 2개가 추가되고, 그사이 쌓인 코드 변경으로 컨테이너 이미지가 새로 바뀌는 것 외에는 변화가 없었습니다. 이 diff와 함께 계획을 보여 주고 승인을 요청했습니다. 롤백 방법(추가한 권한을 지우고 다시 배포)도 같이 적었습니다.

## 5단계: 승인과 배포

제가 승인한 뒤 배포했습니다. 이 과정에서 Claude Code의 자동 모드가 "확인 없이 인프라를 적용하는 명령"으로 보고 배포 명령을 막은 적이 있습니다. 그때는 우회하지 않고 명령을 보여 주기만 했고, 제가 세션에서 `!`를 붙여 직접 실행했습니다. 그다음부터는 `--diff`로 먼저 보여 주고 승인받은 뒤 `--deploy`를 실행하는 순서를 지키고 있습니다.

## 6단계: 검증 — 권한을 실제로 시뮬레이션하기

배포가 끝났다고 고쳐진 것은 아닙니다. 로그에는 **첫 번째로 막힌 권한**만 찍힙니다. DynamoDB 다음 단계에서 S3나 Bedrock 권한이 또 막혀 있을 수 있습니다.

그래서 보고서 작업이 쓰는 모든 AWS 권한을 **IAM 정책 시뮬레이터**로 한 번에 확인했습니다. 실제로 호출하지 않고 "이 역할로 이 작업을 하면 허용되는가"만 묻는 읽기 전용 명령입니다.

```sh
ROLE_ARN=arn:aws:iam::123456789012:role/MyApiTaskRole

aws iam simulate-principal-policy \
  --policy-source-arn "$ROLE_ARN" \
  --action-names dynamodb:GetItem dynamodb:PutItem dynamodb:Query \
                 dynamodb:UpdateItem dynamodb:ConditionCheckItem \
  --resource-arns arn:aws:dynamodb:ap-northeast-2:123456789012:table/my-table \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text
```

```text
dynamodb:GetItem             allowed
dynamodb:PutItem             allowed
dynamodb:Query               allowed
dynamodb:UpdateItem          allowed
dynamodb:ConditionCheckItem  allowed
```

같은 방법으로 S3(`GetObject`, `PutObject`), Bedrock(`InvokeModel`) 등 작업이 쓰는 나머지 권한도 모두 `allowed`인 것을 확인했습니다.

시뮬레이션은 권한만 확인합니다. 실제로 끝까지 도는지는 로그인한 사용자가 보고서를 만들어 봐야 압니다. 테스트 사용자를 에이전트가 직접 만드는 것은 인증 시스템(Cognito)을 건드리는 일이라 하지 않고, 제가 사이트에서 직접 확인하기로 했습니다.

## 7단계: 기록 (Tracker)

계획 파일의 체크박스를 갱신하고, 결과 기록에 "배포 완료, IAM 시뮬레이션 결과 모두 허용, 실제 요청 확인 대기"를 덧붙였습니다. `STATE.md`의 다음 할 일에는 "사이트에서 보고서 1건 생성 후 로그에서 성공 확인"을 적었습니다. 다음 날 세션이 새로 시작돼도 이 두 파일만 읽으면 어디까지 했는지 알 수 있습니다.

## 그다음: 테스트는 통과했지만 사람이 이해하지 못했다

다음 날 사이트에서 직접 보고서를 만들어 봤습니다. 기능은 동작했지만 새로운 문제가 보였습니다.

- 보고서 문장 끝에 `[근거 f_b4bb...]` 같은 **내부 ID**가 그대로 붙어 있었습니다. 사용자에게는 의미 없는 기호입니다.
- 요약 문장이 "정리했다"고는 하는데 **무슨 말인지 알 수 없었습니다.**
- 첫 시도는 "실패"로 나오고, 다시 시도하니 성공했습니다. 로그로 확인했지만 원인을 확정하지는 못했습니다. 권한 수정 배포가 끝나기 전에 시도했을 가능성이 가장 높아 보입니다.

앞의 두 개는 코드 테스트로는 잡을 수 없는 문제입니다. 근거 표시는 ①②처럼 번호 칩으로 바꾸고, 누르면 아래 출처 목록의 원문 문장으로 이동하게 했습니다. 요약은 AI에게 주는 지시를 고쳐 "누가, 언제, 무엇을 했고, 왜 중요한지"를 쉬운 한 문장으로 쓰게 하고, 내부 용어는 쓰지 못하게 했습니다.

## 하네스를 처음 써 보고 배운 점

**잘 된 점**

- **멈춰야 할 곳에서 멈췄습니다.** 등급표 덕분에 IAM 변경과 배포 전에 항상 diff와 승인 요청이 나왔습니다. 예전에는 이 확인이 그날 대화 흐름에 따라 빠지기도 했습니다.
- **"배포 완료"에서 끝내지 않았습니다.** 계획에 완료 조건(S4)을 적어 두니, 권한 시뮬레이션과 실제 요청 확인까지 이어졌습니다.
- **이어서 하기가 쉬웠습니다.** 대화가 길어져 요약되고 다음 날 다시 시작해도 계획 파일과 `STATE.md`만 읽고 바로 이어갔습니다.

**아쉬운 점**

- **이번 작업은 워커 없이 끝났습니다.** 수정이 작아서 Coordinator가 직접 고쳤고, 독립 Validator 워커도 띄우지 않았습니다. 검증은 인프라 테스트, diff, 권한 시뮬레이션으로 대신했습니다. 등급표로는 T2지만 코드 변경은 T0 수준이라, "변경 규모"와 "영향 범위"를 따로 보는 기준이 필요해 보입니다.
- **로컬 테스트 권한이 너무 셌습니다.** 관리자 키 대신 실제 서버 역할과 같은 권한으로 로컬 테스트를 돌렸다면 배포 전에 잡았을 문제입니다.
- **오류 메시지가 원인을 가렸습니다.** 권한 거부를 "authentication failed"로 바꿔 보여 주는 코드 때문에 처음에는 로그인 문제로 보였습니다. 오류를 감쌀 때는 원래 오류 이름(AccessDenied)을 함께 남기는 것이 좋습니다.

## 정리

- 배포 환경에서만 실패하던 원인은 **새로 쓰기 시작한 DynamoDB 명령(`UpdateItem`, 트랜잭션의 `ConditionCheckItem`)이 서버 역할의 IAM 권한에 없던 것**이었습니다.
- `TransactWriteItems`는 별도 권한이 없고, **트랜잭션 안의 작업마다 권한**이 필요합니다.
- 로컬 테스트를 관리자 권한으로 돌리면 권한 누락이 가려집니다.
- 하네스 절차(분류 → 읽기 전용 진단 → 계획 → diff 미리보기 → 승인 → 배포 → 권한 시뮬레이션 → 기록)는 작은 수정에서도 "멈출 곳에서 멈추고, 끝까지 확인하는" 데 효과가 있었습니다.
- 테스트가 통과해도 사람이 이해하지 못하면 끝난 것이 아닙니다. 마지막 확인은 실제 사용자의 눈입니다.
