---
title: "최소 권한 CDK 첫 배포에서 막힌 곳: 태그 액션 함정과 CloudTrail로 권한 좁히기"
date: 2026-11-05 10:35:00 +0900
categories: [AWS, 배포]
tags: [aws, cdk, iam, cloudformation, cloudtrail, agentcore, least-privilege, troubleshooting]
description: "실행 역할을 좁힌 CDK 첫 배포가 simulate를 통과하고도 두 번 실패한 이야기입니다. 와일드카드가 놓친 sqs:TagQueue, CreateGateway의 태그 권한 검사, 실패 뒤 남은 빈 시크릿 정리, 정책 판 관리, 배포 뒤 CloudTrail로 권한을 좁힌 과정을 정리합니다."
---

> **시리즈: 관리자 권한 없이 CDK 배포하기**
> 1. [CDK 배포 역할에서 AdministratorAccess 빼기: 전용 bootstrap, 실행 정책, 권한 경계 두 개]({% post_url 2026-11-05-cdk-least-privilege-bootstrap %})
> 2. **최소 권한 CDK 첫 배포에서 막힌 곳: 태그 액션 함정과 CloudTrail로 권한 좁히기** ← 지금 글

## simulate는 통과했는데 배포가 거부됐다

이 배포에서는 CDK가 쓰는 CloudFormation 실행 역할에서 `AdministratorAccess`를 뺐습니다. 계정에 이미 있던 공유 `CDKToolkit`의 실행 역할이 관리자 권한이라, 이 프로젝트만 쓰는 전용 준비(bootstrap) 스택을 따로 만들고 권한을 세 겹으로 묶었습니다. 전용 bootstrap과 두 권한 경계를 어떻게 구성했는지는 1편 [CDK 배포 역할에서 AdministratorAccess 빼기: 전용 bootstrap, 실행 정책, 권한 경계 두 개]({% post_url 2026-11-05-cdk-least-privilege-bootstrap %})에서 다뤘습니다. 이 글에 필요한 것은 아래 세 가지뿐입니다.

- **실행 정책**: CloudFormation 실행 역할이 할 수 있는 일
- **실행 역할 경계**: 실행 정책을 넓혀도 넘을 수 없는 선
- **앱 역할 경계**: CDK가 만드는 앱 역할들이 넘을 수 없는 선 (IAM 액션 없음)

실행 역할이 실제로 갖는 권한은 실행 정책과 실행 역할 경계의 **교집합**입니다. 배포 전에는 두 정책을 **함께** 넣은 `simulate-custom-policy`로 기대표 170행을 돌렸고, 기대와 다른 결과는 0건이었습니다. 다른 모델에게 맡긴 검증도 합격이었습니다.

그런데 첫 배포는 두 번 실패했습니다. 이 글은 그 두 번의 실패와, 배포가 끝난 뒤 CloudTrail로 "실제로 부른 권한"을 확인해 정책을 오히려 좁힌 과정을 정리합니다. 실행 역할을 좁힌 CDK(또는 CloudFormation)로 첫 배포를 하다가 `AccessDenied`나 `ROLLBACK_COMPLETE`를 만난 분께 도움이 되면 좋겠습니다.

(사내 프로젝트의 배포 기록이 원료라서 계정 ID, 스택·역할·자원 이름, 태그 값, 시각은 모두 예시 값으로 바꿨습니다. 정책과 코드도 개념을 보여 주는 최소 예시로 새로 썼습니다.)

<figure class="diagram">
{% include figures/cdk-least-privilege-first-deploy/sim-vs-deploy.svg %}
<figcaption>Create 허용만으로는 충분하지 않았습니다. SQS와 S3는 태그 액션 행이, Gateway는 만들 때 평가되는 gateway/* 자원에 대한 태그 행이 기대표에 없었습니다.</figcaption>
</figure>

## 배포 순서: 스택 넷으로 나눴다

앱은 CDK 스택 네 개입니다. 배포 명령은 사람이 직접 실행했고, 이 순서로 하나씩 올렸습니다.

| 순서 | 스택 | 담는 것 |
|---|---|---|
| 1 | `MyProjIam` | 앱 역할과 정책 |
| 2 | `MyProjData` | S3 버킷, SQS 큐, 시크릿 |
| 3 | `MyProjTools` | Lambda 함수, 로그 그룹 |
| 4 | `MyProjAgent` | AgentCore Gateway 등 에이전트 자원 |

이렇게 나눈 이유는 되돌리기입니다. 데이터 스택만 남기고 도구·에이전트 스택을 지울 수 있고, IAM 변경은 따로 미리 볼 수 있습니다. 첫 배포가 중간에 실패해도 실패한 스택 하나만 다시 보면 됩니다. 이번에도 이 덕을 봤습니다.

`MyProjIam`은 바로 성공했습니다. 만들어진 앱 역할 11개에 모두 앱 경계가 붙어 있는지, 개발자 사용자에게 붙은 정책이 그대로인지 확인하고 다음으로 넘어갔습니다. 문제는 두 번째 스택부터였습니다.

## 첫 번째 실패: 와일드카드가 액션 이름을 못 잡았다

`MyProjData` 첫 배포에서 SQS 데드레터 큐(DLQ)를 만드는 단계가 실패했습니다. 아래는 `cdk deploy` 출력에 나온 스택 이벤트입니다. 이름·ARN을 예시 값으로 바꾸고 줄을 나눴습니다(요청 ID 등 일부 생략).

```text
MyProjData | CREATE_FAILED | AWS::SQS::Queue | JobsDlq (JobsDlq1A2B3C4D)
Resource handler returned message: "Encountered a permissions error performing a tagging operation,
please add required tag permissions. See https://repost.aws/knowledge-center/cloudformation-tagging-permission-error
for how to resolve. Resource handler returned message: "User: arn:aws:sts::123456789012:assumed-role/cdk-myproj1-cfn-exec-role-123456789012-ap-northeast-2/AWSCloudFormation
is not authorized to perform: sqs:tagqueue on resource: arn:aws:sqs:ap-northeast-2:123456789012:myproj-jobs-dlq.fifo
because no identity-based policy allows the sqs:tagqueue action (Service: Sqs, Status Code: 403, Request ID: …) …""
(RequestToken: …, HandlerErrorCode: UnauthorizedTaggingOperation)
```

스택은 `ROLLBACK_COMPLETE`로 되돌려졌습니다. 큐를 만드는 권한은 있었는데, 만든 큐에 **태그를 다는** 권한이 없었습니다.

실행 정책과 실행 역할 경계에는 SQS 태그 액션을 똑같이 이렇게 써 두었습니다.

```json
"Action": ["sqs:CreateQueue", "sqs:DeleteQueue", "sqs:*QueueAttributes", "sqs:GetQueueUrl", "sqs:*Queue*Tag*"]
```

관리형 정책은 공백을 빼고 6,144자를 넘을 수 없습니다 ([IAM 할당량](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_iam-quotas.html)). 두 정책이 이 한도에 가까워서 액션을 와일드카드로 묶어 두었는데, `*Queue*Tag*`는 "Queue가 나오고 **그 뒤에** Tag가 나오는 이름"만 맞습니다. SQS의 태그 액션 셋에 대 보면 이렇습니다.

| 액션 | `sqs:*Queue*Tag*`에 맞나 | 이유 |
|---|---|---|
| `ListQueueTags` | ✓ 맞음 | List**Queue**+**Tag**s |
| `TagQueue` | ✗ 안 맞음 | Tag가 Queue **앞**에 있다 |
| `UntagQueue` | ✗ 안 맞음 | tag가 Queue **앞**에 있다 |

정작 CloudFormation이 큐를 만들 때 쓰는 `TagQueue`는 빠져 있었습니다. 두 정책 모두 정확한 액션 이름으로 바꿨습니다.

```json
"Action": [
  "sqs:CreateQueue", "sqs:DeleteQueue", "sqs:*QueueAttributes", "sqs:GetQueueUrl",
  "sqs:TagQueue", "sqs:UntagQueue", "sqs:ListQueueTags"
]
```

오류에는 `sqs:tagqueue`처럼 소문자로 나와 있습니다. IAM 액션 이름은 대소문자를 구분하지 않으므로 `sqs:TagQueue`와 같은 액션입니다.

### simulate는 왜 못 잡았나

답은 단순합니다. **기대표에 `sqs:TagQueue` 행이 없었습니다.** simulate는 넣어 준 액션과 자원 조합만 평가합니다. 표에 `sqs:CreateQueue`가 있었고 그건 허용으로 통과했지만, "큐를 만들면 태그도 단다"는 사실은 표 바깥에 있었습니다.

그래서 기대표에 `sqs:TagQueue` 허용 행을 넣었습니다. 다른 스택에서 태그를 다는 액션(Lambda, CloudWatch Logs, Secrets Manager, AgentCore)도 실행 역할로 simulate해 허용을 확인했습니다. 그리고 실행 정책과 실행 역할 경계를 함께 새 판(v2)으로 올렸고, 재배포는 성공했습니다. 한쪽만 고치면 교집합에서 다시 막히기 때문입니다. (이때 AgentCore 태그 액션도 허용으로 나왔지만, **이름 ARN으로만** 검사했다는 것이 다음 실패에서 드러납니다.)

와일드카드를 쓴다면, 그 패턴에 **맞아야 할 액션 이름을 하나씩 대 보는** 행을 기대표에 넣어 두는 것이 좋습니다. 패턴을 쓴 사람의 머릿속 목록과 서비스의 실제 액션 목록은 다를 수 있습니다.

### 실패 뒤에 남은 것: 빈 시크릿 셋

롤백은 끝났지만 깨끗하지는 않았습니다. 데이터 스택에는 Secrets Manager 시크릿 셋이 있었고, 값은 배포 뒤 사람이 직접 넣기로 해서 **값 없이** 만들었습니다. L2 `Secret`은 값을 주지 않으면 임의 값을 생성하므로, 값 속성이 없는 L1 `CfnSecret`을 썼습니다. 그리고 `RemovalPolicy.RETAIN`을 걸어 두었습니다. CloudFormation이 시크릿을 지울 때는 복구 기간 없이 바로 지우기 때문에, 스택을 지워도 시크릿은 남기고 사람이 따로 정리하려는 의도였습니다.

```ts
const apiKey = new secretsmanager.CfnSecret(this, 'ApiKeyA', {
  name: 'myproj/api-key-a',          // 값(SecretString)은 넣지 않는다
});
apiKey.applyRemovalPolicy(cdk.RemovalPolicy.RETAIN);
```

`RETAIN`은 롤백 때도 지켜집니다. 시크릿 셋은 `DELETE_SKIPPED`로 남았고, 다음 배포는 **같은 이름의 시크릿을 다시 만들려다** 실패하게 됩니다. 예약 삭제(`--recovery-window-in-days`)도 답이 아닙니다. 복구 기간 동안은 이름이 계속 묶여 있어서 그 사이에는 다시 배포할 수 없습니다.

복구 기간 없는 삭제는 되돌릴 수 없습니다. 그래서 확인을 먼저 하고, 쓰기는 마지막에 했습니다. 다음은 당시 정리 과정을 바탕으로 버전 조회와 삭제 완료 확인을 보완한 권장 절차입니다. 시크릿 값은 어느 단계에서도 읽지 않습니다.

1. **실패 스택이 남긴 것을 확인합니다(읽기).** 스택 이벤트에서 `DELETE_SKIPPED`로 남은 시크릿의 ARN을 적어 둡니다. 정리할 대상은 이 목록뿐입니다.

   ```sh
   aws cloudformation describe-stack-events --stack-name MyProjData \
     --region ap-northeast-2 --profile ops \
     --query "StackEvents[?ResourceStatus=='DELETE_SKIPPED'].[LogicalResourceId,PhysicalResourceId]" \
     --output text
   ```

2. **버전이 정말 하나도 없는지 확인합니다(읽기).** `describe-secret`의 `VersionIdsToStages`는 스테이징 레이블이 붙은 버전만 보여 줍니다. 레이블이 모두 떨어진(deprecated) 버전은 빠질 수 있어서, 이것이 비어 있다고 버전이 없다고 단정하지 않습니다. `list-secret-version-ids --include-deprecated`로 전체 목록을 봅니다 ([ListSecretVersionIds](https://docs.aws.amazon.com/secretsmanager/latest/apireference/API_ListSecretVersionIds.html)).

   ```sh
   aws secretsmanager list-secret-version-ids \
     --secret-id arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:myproj/api-key-a-AbCdEf \
     --include-deprecated --region ap-northeast-2 --profile ops --output json
   # "Versions": [] 이고 응답에 "NextToken"이 없어야 한다
   ```

   이 명령은 페이지를 직접 이어 조회해야 합니다. 응답에 `NextToken`이 있으면 같은 시크릿 ARN과 `--include-deprecated`를 유지한 채 `--next-token '<응답의 NextToken>'`으로 다음 페이지를 확인하거나, 끝까지 확인하기 전에는 여기서 삭제하지 않고 멈춥니다. 빈 페이지에도 `NextToken`이 올 수 있으므로 `Versions: []` 하나만 보고 판단하지 않습니다. 모든 조회가 성공하고, 모든 페이지의 `Versions`가 비어 있고, 마지막 응답에 `NextToken`이 없을 때만 현재 버전 0개로 봅니다. 버전이 하나라도 있거나 조회가 실패하면 삭제하지 않습니다. 이 조회에는 `secretsmanager:ListSecretVersionIds` 권한이 따로 필요합니다. 그리고 "지금 버전이 0개"는 과거에 값이 없었다는 증명이 아니므로, 1번 목록과 대조해 **이번 실패에서 만들어진 미사용 시크릿**인지도 함께 봅니다.

3. **실패 스택 기록을 지웁니다(쓰기).** `ROLLBACK_COMPLETE` 스택은 그대로 다시 배포할 수 없습니다. 지우고, 삭제가 끝날 때까지 기다립니다.

   ```sh
   aws cloudformation delete-stack --stack-name MyProjData --region ap-northeast-2 --profile ops
   aws cloudformation wait stack-delete-complete --stack-name MyProjData --region ap-northeast-2 --profile ops
   ```

   기다리기가 실패하면(삭제 실패나 시간 초과) 다음 단계로 넘어가지 않고 스택 이벤트부터 다시 봅니다.

4. **2번에서 버전 0개를 확인한 시크릿만 복구 기간 없이 지웁니다(쓰기).** 값이 하나라도 있으면 지우지 않고, `cdk import`로 스택에 다시 넣는 쪽을 검토합니다.

   ```sh
   aws secretsmanager delete-secret \
     --secret-id arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:myproj/api-key-a-AbCdEf \
     --force-delete-without-recovery --region ap-northeast-2 --profile ops
   ```

5. **이름을 다시 쓸 수 있게 된 뒤 재배포합니다.** 복구 기간 없는 삭제도 실제 삭제는 비동기라, 명령이 돌아온 직후에 같은 이름을 만들면 실패할 수 있습니다 ([DeleteSecret](https://docs.aws.amazon.com/secretsmanager/latest/apireference/API_DeleteSecret.html)). `describe-secret`이 `ResourceNotFoundException`을 낼 때까지 간격을 두고 확인한 뒤 다시 배포합니다. 지운 SQS 큐와 같은 이름을 다시 만드는 경우라면 삭제 뒤 60초를 기다려야 한다는 제한도 있습니다 ([CreateQueue](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/APIReference/API_CreateQueue.html)).

이 쓰기(3·4번)는 CloudFormation 실행 역할이 아니라 **별도 권한을 가진 운영 주체**(위 예시의 `ops` 프로필)가 했습니다. 실행 역할 경계는 복구 기간 없는 시크릿 삭제를 명시적으로 거부하도록 만들어 두었기 때문입니다. 배포 역할이 시크릿을 되돌릴 수 없게 지우는 일은 막고, 그 판단은 사람이 내리게 한 것입니다.

배포 계획서에는 미리 "실패 상태 정리표"를 만들어 두었습니다. `ROLLBACK_COMPLETE`, `ROLLBACK_FAILED`, `UPDATE_ROLLBACK_FAILED`, `DELETE_FAILED`처럼 상태마다 무엇이 남고, 무엇을 읽기 전용으로 확인하고, 어떻게 지우는지 적은 표입니다. 이 경우는 표에 없었기 때문에 이번에 한 줄을 추가했습니다.

| 실패 상태 | 남는 것 | 읽기 전용 확인 | 정리 (별도 운영 주체) |
|---|---|---|---|
| 데이터 스택 첫 배포 실패(`ROLLBACK_COMPLETE`), `RETAIN` 시크릿이 `DELETE_SKIPPED` | 스택 기록, 값 없는 시크릿. 같은 이름으로 다시 만들 수 없다 | 스택 이벤트의 `DELETE_SKIPPED` ARN, `list-secret-version-ids --include-deprecated`로 모든 페이지의 `Versions`가 비고 마지막 응답에 `NextToken`이 없는지. 조회 실패면 멈춤. 값은 읽지 않음 | `delete-stack` 후 삭제 완료 대기. 이번 실패에서 만든 버전 0개 시크릿만 `--force-delete-without-recovery`, 이름이 풀린 뒤 재배포. 값이 있으면 `cdk import` 검토 |

## 두 번째 실패: CreateGateway의 태그 권한 검사에서 막혔다

데이터·도구 스택이 올라가고, 마지막 `MyProjAgent`에서 다시 막혔습니다. 이 스택에는 Amazon Bedrock AgentCore Gateway가 있습니다. Gateway는 Lambda 같은 도구를 에이전트가 MCP로 부를 수 있게 묶어 주는 AgentCore 자원입니다. (AgentCore가 무엇인지는 [AWS로 AI 에이전트 만들기 전에 알아야 할 서비스 지도]({% post_url 2026-11-01-aws-ai-agent-services-map %})에 정리했습니다.) [서비스 권한 참조](https://docs.aws.amazon.com/service-authorization/latest/reference/list_bedrock-agentcore.html)를 보면 `CreateGateway`에는 자원 유형이 없고, 요청 태그 조건(`aws:RequestTag`)을 쓸 수 있습니다.

이번에도 `cdk deploy` 출력의 스택 이벤트입니다. 이름·ARN을 예시 값으로 바꾸고 줄을 나눴습니다(요청 ID 등 일부 생략).

```text
MyProjAgent | CREATE_FAILED | AWS::BedrockAgentCore::Gateway | ToolsGateway
Resource handler returned message: "User: arn:aws:sts::123456789012:assumed-role/cdk-myproj1-cfn-exec-role-123456789012-ap-northeast-2/AWSCloudFormation
is not authorized to perform: bedrock-agentcore:TagResource on resource: arn:aws:bedrock-agentcore:ap-northeast-2:123456789012:gateway/*
because no identity-based policy allows the bedrock-agentcore:TagResource action
(Service: BedrockAgentCoreControl, Status Code: 403, Request ID: …) …"
(RequestToken: …, HandlerErrorCode: AccessDenied)
```

눈여겨볼 곳은 자원 ARN의 끝, `gateway/*`입니다. 아직 만들어지지 않아 ID가 없는 Gateway를 대상으로 `TagResource`를 확인받고 있습니다.

<figure class="diagram">
{% include figures/cdk-least-privilege-first-deploy/tagged-create.svg %}
<figcaption>이번 Gateway 생성에서 문제와 관련된 권한만 표시했습니다. 생성 권한은 허용됐지만 gateway/*를 대상으로 한 태그 권한이 빠져 실패했습니다.</figcaption>
</figure>

실행 정책과 실행 역할 경계의 AgentCore 부분은 각각 두 문장으로 나뉘어 있었습니다.

- **만들기 문장**: `CreateGateway` 같은 만들기 액션. 자원 유형이 없으므로 `Resource: "*"`로 두고, 대신 리전(`aws:RequestedRegion`)과 요청 태그(`aws:RequestTag/project`·`phase`) 조건으로 묶었습니다.
- **관리 문장**: 만든 뒤에 고치고 지우는 액션. 이름 접두사가 붙은 ARN(`gateway/myproj-tools-*`)으로 묶었고, `TagResource`는 여기에만 있었습니다.

`TagResource`를 "이미 있는 자원에 태그를 붙이는 일"로만 생각해서 관리 문장에 넣었던 것입니다. 기대표에도 `TagResource` 행은 있었지만, 자원은 이름이 정해진 Gateway ARN이었습니다. 그런데 이번 Gateway 생성에서는 `TagResource`가 이름 ARN이 아니라 ID 미정의 `gateway/*`를 대상으로 평가됐고, 관리 문장의 `gateway/myproj-tools-*`에는 맞지 않았습니다. 기대표에 없던 것은 액션이 아니라 **이 액션과 이 자원의 조합**이었습니다.

다른 서비스의 만들기 액션도 이렇게 평가된다고 일반화하지는 않습니다. 자원 유형이 있는지, 태그 권한이 어떤 자원으로 평가되는지는 서비스마다 권한 참조와 실제 오류로 따로 확인해야 합니다.

### 이번 Gateway는 태그를 빼서 피할 수 없었다

처음 떠오른 생각은 "Gateway에서 태그를 빼면 되지 않나"였습니다. 이번에는 통하지 않았습니다. CloudFormation은 템플릿에 쓴 태그와 별개로 `aws:cloudformation:stack-name`, `aws:cloudformation:stack-id`, `aws:cloudformation:logical-id` 스택 태그를 스스로 만듭니다. 이 스택 태그가 자원에 전달되는지는 자원 유형마다 다릅니다 ([CloudFormation 자원 태그](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-properties-resource-tags.html)). 배포 뒤 CloudTrail을 보니 Gateway 만들기 요청에는 이 셋이 실려 있었습니다. 그래서 이 Gateway는 내 태그만 빼서는 요청에서 태그가 사라지지 않았습니다.

### 고친 방법: 만들기 문장에 TagResource를 넣는다

`TagResource`를 `Resource: "*"`로 조건 없이 허용하는 방법도 있지만, 그러면 아무 AgentCore 자원에나 태그를 달 수 있게 됩니다. 그래서 이미 리전·요청 태그 조건이 걸린 **만들기 문장에** `TagResource`를 넣었습니다. 실행 정책과 실행 역할 경계 양쪽에 같은 변경을 했습니다.

```json
{
  "Sid": "AgentCoreCreateTagged",
  "Effect": "Allow",
  "Action": [
    "bedrock-agentcore:CreateGateway",
    "bedrock-agentcore:TagResource"
  ],
  "Resource": "*",
  "Condition": {
    "StringEquals": {
      "aws:RequestedRegion": "ap-northeast-2",
      "aws:RequestTag/project": "myproj",
      "aws:RequestTag/phase": "pilot"
    }
  }
}
```

이 문장도 정책을 넓히는 변경입니다. `Resource: "*"`와 요청 태그 조건은 "만들 때만" 쓰이는 허용이 아니어서, `project=myproj`, `phase=pilot` 태그를 싣는 요청이면 이름이 다른 기존 자원에도 태그를 달 수 있기 때문입니다. 그래서 바로 적용하지 않고, 이 차이를 설명한 뒤 승인을 받고 올렸습니다. 기대표에는 `gateway/*`에 대한 `TagResource` 허용 행과, 다른 `project` 태그로는 거부되는 행을 함께 넣었습니다. 그다음 두 정책의 새 판을 올리고, 실패한 `MyProjAgent` 스택 기록을 지운 뒤 재배포해 성공했습니다.

### 원인을 찾을 때 본 것

- **CloudTrail의 거부 이벤트에는 `errorMessage`가 비어 있었습니다.** 어떤 액션이 어떤 자원에서 막혔는지는 CloudTrail보다 CloudFormation 스택 이벤트의 메시지에서 먼저 보였습니다.
- **오류 문구는 실행 정책의 허용 누락을 가리켰습니다.** `because no identity-based policy allows`는 허용하는 자격 증명 기반 정책이 없다는 뜻입니다. 다만 여러 종류의 정책이 함께 거부하면 AWS는 그중 한 종류만 메시지에 넣습니다 ([접근 거부 오류 메시지](https://docs.aws.amazon.com/IAM/latest/UserGuide/troubleshoot_access-denied.html)). 이 문구만으로 경계나 SCP의 영향까지 배제할 수는 없습니다. 실제로 이번 두 번의 실패는 실행 정책과 실행 역할 경계에 같은 허용 누락이 있었고, 둘을 함께 고쳤습니다.
- 이전 시범 단계에서도 다른 AgentCore 자원(`harness/*`)을 만들 때 `TagResource` 거부를 본 적이 있습니다. 같은 원인이었을 것으로 보지만, 따로 다시 확인하지는 않은 **추정**입니다.

## 조용히 우회된 거부: S3 버킷

배포가 끝난 뒤 CloudTrail을 보다가 하나 더 찾았습니다. S3 버킷은 배포에 성공했는데, CloudTrail에는 거부가 남아 있었습니다. 이번 배포에서 관찰한 흐름은 이랬습니다.

1. CloudFormation이 태그를 실은 `CreateBucket`을 보냄 → `s3:TagResource`로 거부
2. CloudFormation이 태그 없이 버킷을 만듦 → 성공
3. `PutBucketTagging`으로 태그를 따로 달음 → 성공

SQS와 AgentCore는 태그 권한이 없으면 실패했지만, 이번 S3 버킷은 다른 경로로 만들어졌습니다. 이것은 이번 배포에서 본 핸들러 동작이고, 모든 핸들러·설정에서 같은 우회가 보장되는 것은 아닙니다. 다만 같은 "태그 권한 없음"이 실패가 되기도 하고 조용한 우회가 되기도 한다는 점, 그리고 배포 성공만 보면 이런 거부가 보이지 않는다는 점은 기억해 둘 만합니다.

## 정책 판(version) 관리: 다섯 칸과 6,144자

실행 정책과 실행 역할 경계는 고객 관리형 정책이라 고칠 때마다 새 판이 생깁니다. 이번 배포에서만 v1에서 v4까지 쌓였습니다. 관리형 정책은 판을 **최대 다섯 개**까지 보관하고, 다섯 개가 다 찬 상태에서 CLI로 새 판을 만들려면 먼저 하나를 지워야 합니다 ([IAM 정책 버전 관리](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_managed-versioning.html)). 기본(default) 판은 지울 수 없습니다.

v5를 올릴 때는 v1–v4 네 개라 공간이 있었지만, 다음 변경을 위한 여유를 남기려고 기본 판이 아닌 v1을 미리 지웠습니다. 아래 `v1`·`v4`는 그때 목록으로 확인한 예시 값입니다. 경계 정책(`MyProjCdkBoundary`)도 같은 명령으로 함께 올립니다.

```sh
POLICY_ARN=arn:aws:iam::123456789012:policy/MyProjCdkExec

aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
  --query 'Versions[].[VersionId,IsDefaultVersion]' --output text   # 지금 판과 기본 판 확인

aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id v1
aws iam create-policy-version --policy-arn "$POLICY_ARN" \
  --policy-document "$(cat policies/MyProjCdkExec.json)" --set-as-default

# 되돌리기: 기록해 둔 이전 기본 판으로
aws iam set-default-policy-version --policy-arn "$POLICY_ARN" --version-id v4
```

이때 지킨 규칙이 둘 있습니다.

- **두 정책을 같은 변경 묶음으로 함께 갱신하고, 각 정책의 이전 기본 판을 기록합니다.** 실제 권한은 두 정책의 교집합입니다. 한쪽만 넓히면 다른 쪽에 막혀 배포가 또 실패하고, 어느 쪽이 문제인지 헷갈립니다. 두 정책의 판 번호가 같아야 하는 것은 아닙니다. 되돌릴 때 각 정책을 어느 판으로 돌릴지 알 수 있으면 됩니다.
- **판을 만들기 전에 크기를 잽니다.** 문장을 하나 더할 때마다 6,144자 한도에 가까워집니다. 최종 판은 실행 정책 6,068자, 경계 6,106자였습니다. 한도를 넘으면 `create-policy-version`이 실패하므로, 정책을 만드는 스크립트에서 공백을 뺀 길이를 먼저 확인했습니다.

  ```sh
  tr -d '[:space:]' < policies/MyProjCdkExec.json | wc -c   # 공백 제외 길이 (6,144 이하)
  ```

  `wc -c`는 바이트 수를 셉니다. 정책이 ASCII 문자만으로 되어 있어 글자 수와 같습니다.

처음 와일드카드를 쓴 이유가 이 한도였다는 점을 생각하면, 크기 한도와 정확한 액션 이름 사이에서 계속 줄다리기를 하게 됩니다. 와일드카드로 줄이려면 그 패턴이 무엇을 잡는지 기대표로 확인해야 합니다.

## 배포 뒤 CloudTrail로 "실제로 부른 것"을 확인했다

네 스택이 모두 올라간 뒤, 첫 배포를 시작한 시각부터 서울 리전 CloudTrail에서 **우리 실행 역할이 부른 이벤트**를 모았습니다. 읽기 전용 작업입니다.

아래는 지정한 기간의 관리 이벤트를 서비스(이벤트 소스)별로 조회하고, `sessionIssuer`의 **전체 역할 ARN이 일치하는 것만** 고르는 예시입니다. 몇 가지 한계가 있습니다 ([LookupEvents](https://docs.aws.amazon.com/awscloudtrail/latest/APIReference/API_LookupEvents.html)).

- 최근 90일만 조회할 수 있고, 관리 이벤트만 나옵니다. 데이터 이벤트는 포함되지 않습니다.
- 조회 조건은 하나만 받으므로 이벤트 소스마다 따로 조회합니다.
- 조회는 계정·리전당 초당 2회로 제한됩니다. 페이지 사이에 간격을 두고, 제한에 걸리면 재시도하게 합니다.

```python
import json
import os
import time
from datetime import datetime

import boto3
from botocore.config import Config

# 입력: 실행 역할의 전체 ARN, 자신의 배포 시작·종료 시각(UTC, ISO 8601)
ROLE_ARN = os.environ["EXEC_ROLE_ARN"]        # arn:aws:iam::123456789012:role/cdk-myproj1-cfn-exec-role-...
START = datetime.fromisoformat(os.environ["DEPLOY_START_UTC"])   # 예: 2026-01-01T00:00:00+00:00
END = datetime.fromisoformat(os.environ["DEPLOY_END_UTC"])
SOURCES = ["sqs.amazonaws.com", "s3.amazonaws.com", "lambda.amazonaws.com",
           "logs.amazonaws.com", "secretsmanager.amazonaws.com",
           "bedrock-agentcore.amazonaws.com"]

ct = boto3.client("cloudtrail", region_name="ap-northeast-2",
                  config=Config(retries={"mode": "adaptive", "max_attempts": 10}))
for source in SOURCES:
    pages = ct.get_paginator("lookup_events").paginate(
        LookupAttributes=[{"AttributeKey": "EventSource", "AttributeValue": source}],
        StartTime=START, EndTime=END,
    )
    for page in pages:
        for e in page["Events"]:
            ev = json.loads(e["CloudTrailEvent"])
            issuer = ev.get("userIdentity", {}).get("sessionContext", {}) \
                       .get("sessionIssuer", {}).get("arn", "")
            if issuer != ROLE_ARN:
                continue
            print(ev["eventTime"], ev["eventSource"], ev["eventName"],
                  ev.get("errorCode", "-"), ev.get("errorMessage", "-"))
        time.sleep(0.5)   # 초당 2회 제한
```

이 출력으로 거부와 호출 목록을 봤습니다. 요청에 어떤 태그가 실렸는지는 필요한 이벤트 몇 개만 골라, 그 이벤트의 `requestParameters`에서 태그 필드만 따로 확인했습니다. 요청 전체를 한꺼번에 출력하지는 않습니다.

IAM 관리 이벤트는 서울이 아니라 `us-east-1`에 기록됩니다. IAM 호출까지 보려면 `us-east-1`에서 `EventSource=iam.amazonaws.com`으로 따로 조회해야 합니다. 다른 전역 서비스와 STS는 사용한 엔드포인트에 따라 기록되는 리전이 다르므로 따로 확인합니다 ([CloudTrail 전역 서비스 이벤트](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-concepts.html#cloudtrail-concepts-global-service-events)).

### 거부 목록

우리 실행 역할의 거부는 이것뿐이었습니다.

| 거부 | 배포 영향 |
|---|---|
| `sqs:TagQueue` | 첫 번째 실패 (고침) |
| 태그를 단 `CreateGateway` (`TagResource`) | 두 번째 실패 (고침) |
| `s3:TagResource` (태그를 실은 `CreateBucket`) | 없음. 이번에는 태그 없이 만든 뒤 `PutBucketTagging`으로 우회 |
| `lambda:GetAccountSettings` | 없음. CloudFormation이 만든 뒤 읽는 호출 |
| `logs:DescribeIndexPolicies`, `logs:DescribeResourcePolicies` | 없음 |
| S3 `GetBucket*` 일부 | 없음 |

배포에 영향이 없는 거부까지 허용해 줄 이유는 없으므로 그대로 두었습니다. 다만 기록은 남겼습니다. 다음에 누군가 CloudTrail을 보다 "거부가 있는데 괜찮은가"를 다시 조사하지 않도록요.

실행 역할 말고 **앱 역할**의 거부도 하나 보였습니다. 에이전트 런타임의 실행 역할이 자기 로그 그룹에 `logs:PutResourcePolicy`를 시도해 거부됐습니다. 자원 상태는 READY였습니다. 다음 단계에서 실제로 로그가 쌓이는지 확인할 일로 남겼습니다.

### 미리 넓게 줬던 권한을 좁혔다

이번 확인의 진짜 수확은 거부가 아니라 **허용된 호출 목록**이었습니다. 처음 정책을 쓸 때는 문서와 서비스 스키마를 기준으로, 필요할지 모르는 권한을 조금 넓게 주었습니다. CloudTrail을 보니 그중 일부는 더 좁힐 수 있었습니다.

1. **런타임 만들기 요청에 우리 태그가 실려 있었다.** AgentCore의 다른 자원이 런타임(`CreateAgentRuntime`)을 대신 만들 때, 요청에 `project`·`phase` 태그가 함께 실렸습니다. 처음에는 태그가 실릴지 몰라 이 액션을 리전 조건만으로 허용했었습니다. 서비스 권한 참조에서 `CreateAgentRuntime`도 요청 태그 조건을 지원하는 것을 확인하고, 태그 조건이 있는 만들기 문장으로 옮겼습니다.
2. **`CreateAgentRuntimeEndpoint`는 한 번도 불리지 않았다.** 이번 구성에서는 엔드포인트를 따로 만들 일이 없어서 정책에서 뺐습니다. **실제로 뺀 권한은 이것 하나입니다.** 나중에 필요해지면 런타임 ARN 범위로 다시 넣기로 기록해 두었습니다.
3. **끄기로 한 Memory 기능은 호출 0건이었다.** 실행 정책과 경계에서 Memory 액션을 무조건 거부하고 있었는데, 우리 역할이 Memory 액션을 부른 적이 없으니 이 거부가 배포를 막지 않는다는 것이 확인됐습니다.
4. **시크릿의 CloudFormation 핸들러는 `CreateSecret`·`DescribeSecret`만 불렀다.** `GetSecretValue`·`UpdateSecret`은 0건이었습니다. 실행 역할에 값을 읽는 권한 없이도 시크릿을 만들 수 있다는 뜻입니다. 현재 실행 정책과 경계에는 `UpdateSecret`·`GetSecretValue` 허용이 없습니다. 태그나 설명을 바꾸는 **갱신** 때 `UpdateSecret`이 필요한지는 아직 확인하지 않았으므로, 첫 갱신에서 필요한 액션을 확인하고 필요하면 범위를 정해 추가할 일로 남겼습니다.

3번과 4번에서 배운 점이 있습니다. CloudFormation 자원 스키마에는 핸들러(create·read·update·delete·list)별 권한 목록이 있습니다([자원 유형 스키마](https://docs.aws.amazon.com/cloudformation-cli/latest/userguide/resource-type-schema.html)). 이 목록은 핸들러가 필요로 할 수 있는 권한이라 출발점으로 쓰기 좋지만, 모든 설정에서 각 권한을 항상 쓴다는 뜻은 아닙니다. 시크릿 create 핸들러의 목록에는 `GetSecretValue`가 있지만 이번 생성에서는 부르지 않았고, Memory를 끈 자원의 스키마에도 Memory 액션이 있습니다.

그래서 순서를 이렇게 정리했습니다.

1. 처음에는 문서와 스키마를 기준으로 **조금 넓게** 줍니다. 단, 무엇을 왜 넓게 줬는지 적어 둡니다.
2. 실제 배포를 한 번 끝냅니다.
3. CloudTrail에서 **실제로 부른 것**을 봅니다. 첫 생성에서 부르지 않은 권한은 바로 빼지 않고 **제거 후보**로 둡니다. 첫 생성만 보면 갱신·삭제·롤백·교체에서만 쓰는 권한은 모두 0건으로 보이고, 조회에 잡히지 않는 데이터 이벤트도 있기 때문입니다.
4. 갱신·삭제·롤백 생명주기에서 필요한지 확인한 뒤, 쓰지 않을 기능의 권한만 빼고, 요청에 실제로 실린 값(태그 등)으로 조건을 좁힙니다.

## 실제 실행 역할로 simulate를 다시 돌렸다

좁힌 정책을 올리기 전과 후에 한 번 더 확인했습니다. 이때는 원문 JSON이 아니라 **계정에 적용된 정책**을 봐야 합니다. 판을 여러 번 바꾸다 보면 "저장소의 파일"과 "계정의 기본 판"이 어긋날 수 있기 때문입니다.

simulate API는 두 가지입니다.

```sh
# 원문 기준: 정책 파일과 경계 파일을 직접 넣는다
aws iam simulate-custom-policy \
  --policy-input-list "$(cat policies/MyProjCdkExec.json)" \
  --permissions-boundary-policy-input-list "$(cat policies/MyProjCdkBoundary.json)" \
  --action-names sqs:TagQueue \
  --resource-arns arn:aws:sqs:ap-northeast-2:123456789012:myproj-jobs-dlq.fifo \
  --query 'EvaluationResults[].EvalDecision'

# 계정 기준: 역할에 붙은 정책의 기본 판과 역할의 경계로 평가한다
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::123456789012:role/cdk-myproj1-cfn-exec-role-123456789012-ap-northeast-2 \
  --action-names sqs:TagQueue \
  --resource-arns arn:aws:sqs:ap-northeast-2:123456789012:myproj-jobs-dlq.fifo \
  --query 'EvaluationResults[].EvalDecision'
```

두 번째 방식도 역할을 실제로 맡아 API를 부르는 것은 아닙니다. 계정에 붙은 정책을 평가할 뿐이고, 요청 문맥은 직접 넣어야 합니다. 이 SQS 예시에는 조건이 없지만, AgentCore `TagResource`를 검사할 때는 `aws:RequestedRegion`, `aws:RequestTag/project`, `aws:RequestTag/phase`를 `--context-entries`로 함께 넣고, 결과의 `MissingContextValues`도 확인합니다. 문맥을 빠뜨리면 조건 문장이 맞지 않아 허용돼야 할 행이 거부로 나옵니다.

CLI로 쓰면 이런 모양입니다. 검사 스크립트는 같은 문맥을 SDK로 넣었고, 아래는 그 행을 CLI 형식으로 옮긴 예시입니다.

```sh
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::123456789012:role/cdk-myproj1-cfn-exec-role-123456789012-ap-northeast-2 \
  --action-names bedrock-agentcore:TagResource \
  --resource-arns 'arn:aws:bedrock-agentcore:ap-northeast-2:123456789012:gateway/*' \
  --context-entries \
    ContextKeyName=aws:RequestedRegion,ContextKeyValues=ap-northeast-2,ContextKeyType=string \
    ContextKeyName=aws:RequestTag/project,ContextKeyValues=myproj,ContextKeyType=string \
    ContextKeyName=aws:RequestTag/phase,ContextKeyValues=pilot,ContextKeyType=string \
  --query 'EvaluationResults[].[EvalDecision,MissingContextValues]'
```

`gateway/*`는 셸이 펼치지 않게 따옴표로 감쌉니다. `--query`에 `MissingContextValues`를 넣어야 빠진 문맥 키가 함께 보입니다.

검사 스크립트에 환경 변수 하나로 두 번째 방식을 고르는 모드를 추가해, 같은 기대표를 실제 실행 역할 ARN으로 돌릴 수 있게 했습니다. 이 역할 모드는 전체 기대표 중 **실행 역할 행 130개만** 검사합니다. 원문 모드는 앱 역할·사용자 정책 표까지 포함해 176행입니다.

| 시점 | 방식 | 결과 |
|---|---|---|
| 좁히기 전 (계정은 v4) | 계정 기준 (실행 역할 130행) | 130건 중 128건 기대 일치. 다른 2건은 기대표가 이미 좁힌 판 기준이라서 |
| 좁힌 원문 | 원문 기준 (전체 176행) | 176건 모두 기대 일치, `validate-policy` 발견 0건 |
| v5 적용 뒤 | 계정 기준 (실행 역할 130행) | 130건 모두 기대 일치 |

128건에서 멈춘 2건이 오히려 쓸모 있었습니다. "계정에는 아직 이전 판이 적용돼 있다"는 사실을 숫자로 보여 줬기 때문입니다. v5를 올린 뒤 같은 명령이 130건 모두 일치하는 것으로 적용을 확인했습니다.

## 배포 뒤 완료 대조

마지막으로 처음에 세운 완료 조건을 하나씩 읽기 전용으로 대조했습니다.

- 전용 준비 스택이 `CREATE_COMPLETE`다.
- 실행 역할에 붙은 관리형 정책은 실행 정책 하나뿐이고, 인라인 정책이 없고, 실행 역할 경계가 붙어 있다. `AdministratorAccess`는 없다.
- 계정의 공유 `CDKToolkit` 스택은 상태와 마지막 갱신 시각이 배포 전 기록과 같다. 건드리지 않았다.
- 개발자 사용자는 CDK 준비 역할 넷(lookup·deploy·file-publishing·image-publishing)에 대해 `sts:AssumeRole`·`sts:TagSession`이 모두 `implicitDeny`다. 사람이 쓰는 자격 증명으로는 배포 역할을 맡을 수 없다.
- 앱 역할 11개 모두 앱 경계가 붙어 있다.

## 남은 일

- 앱 런타임 역할의 `logs:PutResourcePolicy` 거부: 로그가 실제로 쌓이는지 다음 단계에서 확인
- 시크릿 갱신 때 `UpdateSecret`이 필요한지: 지금은 허용하지 않음. 첫 갱신 때 확인하고 필요하면 범위를 정해 추가
- 첫 생성에서 0건이었던 다른 권한들: 갱신·삭제·롤백을 한 번씩 겪은 뒤 제거 후보를 다시 검토

이전에 [에이전트 하네스 첫 실전: 배포 환경에서만 실패하던 기능, 원인은 IAM 권한 누락]({% post_url 2026-10-28-dev-harness-first-bugfix-iam %})에서도 비슷한 결론을 냈습니다. 로컬과 배포 환경의 권한은 다르고, 그 차이는 실제 환경에서만 드러납니다. 스택이 실패한 뒤 고착되는 다른 사례는 [Amplify Hosting + Fargate 배포에서 실제로 부딪힌 함정 12가지와 해결]({% post_url 2026-10-29-solo-dev-aws-deploy-pitfalls %})에 정리했습니다.

## 정리

- **simulate 통과는 배포 성공이 아닙니다.** simulate는 기대표에 적은 액션·자원 조합만 평가합니다. SQS는 `TagQueue` 행이 없었고, Gateway는 `TagResource` 행은 있었지만 만들 때 평가되는 `gateway/*` 조합이 없었습니다.
- **와일드카드는 맞아야 할 이름을 대 봐야 합니다.** `sqs:*Queue*Tag*`는 `ListQueueTags`만 잡고 `TagQueue`·`UntagQueue`를 놓쳤습니다.
- **정책과 경계는 함께 고칩니다.** 실제 권한은 교집합이고, 이번 두 실패 모두 두 정책에 같은 누락이 있었습니다. "no identity-based policy allows" 문구만으로 경계·SCP를 배제할 수는 없습니다.
- **이번 Gateway 생성에서는 `TagResource`가 `gateway/*`로 평가됐습니다.** Gateway에는 CloudFormation 스택 태그도 실려 내 태그만 빼서는 피할 수 없었습니다. 조건이 걸린 만들기 문장에 `TagResource`를 넣었습니다. 다른 서비스는 권한 참조와 실제 오류로 따로 확인합니다.
- **같은 태그 거부가 서비스마다 다르게 나타났습니다.** SQS·AgentCore는 롤백됐고, 이번 S3 버킷은 조용히 우회됐습니다.
- **`RETAIN` 자원은 롤백 뒤에도 남습니다.** 실패 스택 기록을 지우고, `list-secret-version-ids --include-deprecated`의 모든 페이지에서 버전 0개(마지막 응답에 `NextToken` 없음)와 이번 실패에서 만든 시크릿인지 확인한 뒤에만 별도 운영 주체가 즉시 삭제합니다. 이름이 풀린 뒤 재배포합니다.
- **배포 뒤 CloudTrail은 권한을 좁히는 재료입니다.** 다만 첫 생성에서 부르지 않은 권한은 제거 후보일 뿐이고, 갱신·삭제·롤백까지 확인한 뒤 뺍니다. 스키마의 핸들러 권한 목록은 출발점이지 "항상 부른다"는 뜻이 아닙니다.
- **첫 배포는 실패를 전제로 준비합니다.** 스택을 작게 나누고, 상태별 실패 정리표를 미리 써 두고, 정책 판과 크기 한도를 매번 확인합니다.
