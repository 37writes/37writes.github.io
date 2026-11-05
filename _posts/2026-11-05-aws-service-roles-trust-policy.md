---
title: "AWS 서비스가 내 권한을 쓰는 법: 서비스 역할, 서비스 연결 역할, 신뢰 정책과 confused deputy 조건"
date: 2026-11-05 14:15:00 +0900
categories: [AWS, 보안]
tags: [aws-concepts, aws, iam, service-role, service-linked-role, trust-policy, confused-deputy, agentcore, eventual-consistency]
description: "Failed creating service linked role 403과 '역할 없이 만들어진 Gateway'에서 출발해, 신뢰 정책과 권한 정책, 서비스 역할과 서비스 연결 역할(SLR)의 차이, confused deputy를 막는 aws:SourceAccount·aws:SourceArn 조건, IAM 최종 일관성을 정리합니다."
---

회사 작업에서 AI 에이전트 런타임과 도구 게이트웨이를 만들던 중이었습니다. 둘 다 Amazon Bedrock AgentCore의 기능입니다. **Runtime**은 에이전트 코드를 실행하는 환경이고, **Gateway**는 에이전트가 Lambda 함수 같은 외부 도구를 부를 수 있게 이어 주는 관문입니다. AWS 쪽 작업은 AI 에이전트(Claude Code)와 같이 했고, IAM 쓰기처럼 위험한 명령은 에이전트가 건네면 제가 관리자 프로필로 실행하는 방식이었습니다. 그 과정에서 두 장면이 기억에 남았습니다.

**첫 번째 장면.** 최소 권한만 가진 IAM 사용자로 에이전트 런타임을 처음 만들었더니 `CREATE_FAILED`가 났습니다. 사유는 이랬습니다.

```text
Failed creating service linked role ... 403
```

에이전트는 "서비스가 호출자 권한으로 서비스 연결 역할을 만들려다 막혔다"고 설명하고, 관리자가 이 한 줄로 그 역할을 직접 만들자고 했습니다.

```sh
aws iam create-service-linked-role --aws-service-name runtime-identity.bedrock-agentcore.amazonaws.com
```

되돌리기 문서에는 "런타임이 하나도 없을 때 이 역할을 지운다"는 단계도 추가됐습니다. 저는 명령을 실행했고 런타임은 만들어졌습니다. 그런데 "서비스 연결 역할이 뭔데, 왜 내가 만들어 줘야 하지?"는 모른 채였습니다.

**두 번째 장면.** 다른 작업에서 Gateway가 쓸 **서비스 역할**을 `aws iam create-role --assume-role-policy-document`(신뢰 정책 JSON 파일 지정)로 만드는 명령과 Gateway를 만드는 명령을 차례로 받았습니다. 역할 만들기 명령은 실제로는 실행되지 않았는데, Gateway는 **READY로 만들어졌습니다.** 에이전트가 확인해 보니 역할은 없었고(`NoSuchEntity`), "Gateway는 역할이 실제로 있는지 확인하지 않고 만들어졌다. 이대로면 검색할 때 역할을 쓸 수 없어 실패한다"고 했습니다. 역할을 만든 뒤에는 신뢰 정책의 `aws:SourceArn`을 `gateway/*`에서 **그 Gateway 하나의 ARN**으로 좁혔습니다. 명령 사이사이에는 "역할이 퍼지는 데 10초쯤 걸리니 잠시 뒤에" 같은 말도 있었습니다.

두 장면 모두 명령은 따라 했지만 이유는 몰랐습니다. 이 글은 그때 남은 질문에 답하려고 씁니다.

> 역할은 누가 맡는 것이고, 왜 어떤 역할은 내가 만들고 어떤 역할은 AWS가 만들며, 신뢰 정책의 그 `Condition`은 무엇을 막는가?

## 1. 역할 하나에 정책 둘: 신뢰 정책과 권한 정책

IAM 주체와 역할의 기초는 [인증 한 번에 정리: JWT, IAM(SigV4), Cognito]({% post_url 2026-11-01-auth-basics-jwt-iam-cognito %})에 정리했습니다. 여기서는 필요한 만큼만 다시 짚습니다.

[IAM 역할](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html#id_roles_terms-and-concepts)에는 비밀번호나 액세스 키 같은 장기 자격 증명이 없습니다. 누군가 역할을 **맡으면(assume)** 그 세션에서만 쓰는 **임시 자격 증명**을 받습니다. 역할을 맡을 수 있는 주체는 IAM 사용자와 역할만이 아닙니다. Lambda나 AgentCore 같은 AWS 서비스도 **서비스 주체(service principal)**라는 이름(`lambda.amazonaws.com`, `bedrock-agentcore.amazonaws.com`)으로 역할을 맡습니다. "AWS 서비스가 내 권한을 쓴다"는 말은 대부분 이 경우입니다.

역할에는 성격이 다른 정책이 두 개 붙습니다.

- **신뢰 정책(trust policy)**: "이 역할을 **누가** 맡아도 되나"를 정합니다. 역할에 반드시 붙는 **자원 기반 정책**이라 `Principal`이 있습니다. CLI에서는 역할을 만들 때 `create-role --assume-role-policy-document`로 넣고, 나중에는 `update-assume-role-policy`로 바꿉니다.
- **권한 정책(permissions policy)**: "역할을 맡은 뒤 **무엇을** 할 수 있나"를 정합니다. 자격 증명 기반 정책이라 `Principal`을 적지 않습니다. 이 정책이 붙은 역할 자신이 주체가 되고, `Effect`·`Action`·`Resource`로 허용(또는 거부)과 범위를 정합니다. 필요하면 여기에도 `Condition`을 붙일 수 있습니다.

비유하자면 신뢰 정책은 **출입증 발급 규칙**, 권한 정책은 **그 출입증으로 열 수 있는 문**입니다. 역할을 맡아도 되는지와 맡은 뒤 자원을 써도 되는지는 따로 따집니다. 신뢰 정책에서 막히면 역할을 맡지도 못합니다. 맡은 뒤의 실제 접근은 역할의 권한 정책만으로 정해지지 않습니다. [정책 평가 로직](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html)에 따르면 같은 계정 안에서는 자격 증명 기반 정책과 대상 자원의 자원 기반 정책이 허용한 것을 합쳐서 보고, 어느 쪽이든 명시적 거부가 있으면 거부가 이깁니다. 아래 예에서는 역할의 권한 정책으로 Lambda 호출을 허용합니다.

Gateway 서비스 역할의 신뢰 정책을 예시 값으로 써 보면 이렇습니다. 예시에 나오는 **ARN**(Amazon Resource Name)은 `arn:aws:<서비스>:<리전>:<계정>:<자원>` 꼴로 AWS 자원 하나를 가리키는 식별자입니다. 계정 `123456789012`, 리전 `ap-northeast-2`, Gateway ID `myproj-tools-abc123def4`는 모두 가짜 값입니다.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "bedrock-agentcore.amazonaws.com" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": { "aws:SourceAccount": "123456789012" },
        "ArnLike": {
          "aws:SourceArn": "arn:aws:bedrock-agentcore:ap-northeast-2:123456789012:gateway/myproj-tools-abc123def4"
        }
      }
    }
  ]
}
```

같은 역할의 권한 정책입니다. Gateway가 Lambda 함수 하나를 도구로 부르는 경우를 예로 들었습니다. `Principal`이 없다는 점을 위의 신뢰 정책과 비교해 보세요.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "lambda:InvokeFunction",
      "Resource": "arn:aws:lambda:ap-northeast-2:123456789012:function:MyProjSearchTool"
    }
  ]
}
```

신뢰 정책의 `Principal`에는 ARN 일부에 와일드카드(`*`)를 쓸 수 없습니다([역할 용어와 개념](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html#id_roles_terms-and-concepts)). 그래서 서비스 주체는 이름 그대로 적고, "어느 계정의 어느 자원을 위해 일할 때만"처럼 범위를 좁히는 일은 `Condition`이 맡습니다. 이 조건은 3절에서 자세히 봅니다.

<figure class="diagram">
{% include figures/aws-service-roles-trust-policy/service-assumes-role.svg %}
<figcaption>신뢰 정책(위 칸)은 서비스 주체와 SourceAccount·SourceArn 출처 꼬리표를 보고 역할을 맡길지 정하고, 권한 정책(아래 칸)은 맡은 뒤 부를 수 있는 대상을 정한다</figcaption>
</figure>

## 2. 서비스 역할과 서비스 연결 역할(SLR)

서비스가 맡는 역할에는 두 종류가 있습니다. 두 장면의 차이가 바로 여기서 나옵니다.

- **서비스 역할(service role)**: 서비스가 나 대신 일할 때 맡는 역할입니다. IAM 관리자가 **직접 만들고, 고치고, 지웁니다.** 두 번째 장면의 Gateway 역할이 이것입니다.
- **서비스 연결 역할(service-linked role, SLR)**: 서비스 역할의 한 종류지만 특정 AWS 서비스에 **연결돼 있고 그 서비스가 소유**합니다. 신뢰 정책과 권한 정책을 모두 서비스가 미리 정의하고, 관리자는 볼 수만 있고 권한은 고칠 수 없습니다. 첫 번째 장면의 역할이 이것입니다.

[서비스 연결 역할 문서](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create-service-linked-role.html)를 기준으로 차이를 표로 정리했습니다.

| | 서비스 역할 | 서비스 연결 역할(SLR) |
| --- | --- | --- |
| 정책을 누가 쓰나 | 내가 신뢰·권한 정책을 직접 작성 | 연결된 서비스가 둘 다 미리 정의 |
| 고칠 수 있나 | 만들고 고치고 지울 수 있음 | 권한은 못 고침. 설명(description)만 수정, 이름 변경 불가 |
| 이름·경로 | 내가 정함 (예: `MyProjGatewayRole`) | `role/aws-service-role/<서비스 주체>/AWSServiceRoleFor...` |
| 맡는 주체 | 신뢰 정책에 적은 주체 | 따로 정의하지 않았다면 그 서비스만 |
| 권한 경계 | 붙일 수 있음 | 붙일 수 없음 |
| 만드는 법 | `create-role` + 정책 붙이기 | 서비스가 필요할 때 만들거나 `create-service-linked-role` |
| 지우는 법 | 정책을 떼고 `delete-role` | 그 역할을 쓰는 자원을 먼저 모두 지운 뒤 `delete-service-linked-role` (비동기) |

권한 경계(permissions boundary)를 SLR에 붙일 수 없다는 점도 [문서](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html#id_roles_terms-and-concepts)에 적혀 있습니다. 서비스 역할을 서비스에 넘길 때 필요한 `iam:PassRole`과 권한 경계 이야기는 [관리자 권한 없이 CDK 배포하기 1편]({% post_url 2026-11-05-cdk-least-privilege-bootstrap %})에서 다뤘습니다. PassRole은 넘기는 역할에 경계가 있는지 검사하지 않는다는 함정이 거기 있습니다.

### "자동으로 만든다"의 함정

SLR 문서는 대부분 "서비스가 필요할 때 자동으로 만든다"고 씁니다. AgentCore도 그렇습니다. 그런데 자동이라고 해서 권한 검사가 없는 것은 아닙니다. 문서는 SLR을 만들려면 그 요청을 하는 **IAM 주체(사용자나 역할)에게 `iam:CreateServiceLinkedRole` 권한이 있어야 한다**고 적고 있습니다. 서비스가 내 요청을 처리하다 SLR을 만들 때, 그 권한을 내 쪽에서 확인한다는 뜻입니다. 첫 번째 장면의 403이 이것이었습니다.

AgentCore의 [Runtime Identity SLR](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/service-linked-roles.html)은 이렇게 정의돼 있습니다.

- 이름: `AWSServiceRoleForBedrockAgentCoreRuntimeIdentity`
- 이 역할을 맡는 서비스 주체: `runtime-identity.bedrock-agentcore.amazonaws.com`
- 권한: 워크로드 액세스 토큰을 받는 세 액션(`GetWorkloadAccessToken`, `GetWorkloadAccessTokenForJWT`, `GetWorkloadAccessTokenForUserId`)뿐
- 언제 생기나: **2025년 10월 13일 이후** Runtime을 만들거나 업데이트할 때
- 지우는 조건: AgentCore Runtime 자원을 **모두** 지운 뒤

이 SLR을 만들 수 있게 하는 권한은 문서에 이런 모양으로 나옵니다. 아래는 정책 문서 전체가 아니라 기존 정책의 `Statement` 배열에 넣을 **항목 하나**입니다. `Resource`는 경로와 이름이 그 SLR로 정해진 ARN 패턴이고(문서 원형은 계정 자리가 `*`라 내 계정으로 좁히려면 `123456789012`처럼 계정 ID를 넣습니다), `Condition`은 `iam:AWSServiceName`(서비스 주체 이름)으로 다시 좁힙니다.

```json
{
  "Effect": "Allow",
  "Action": "iam:CreateServiceLinkedRole",
  "Resource": "arn:aws:iam::*:role/aws-service-role/runtime-identity.bedrock-agentcore.amazonaws.com/AWSServiceRoleForBedrockAgentCoreRuntimeIdentity",
  "Condition": {
    "StringEquals": {
      "iam:AWSServiceName": "runtime-identity.bedrock-agentcore.amazonaws.com"
    }
  }
}
```

문서에 따르면 이 권한은 AWS 관리형 정책 `BedrockAgentCoreFullAccess`에 이미 들어 있습니다. 그 정책을 쓰면 명시적 거부나 권한 경계, 조직 정책 같은 다른 제한이 없는 한 이번과 같은 "생성 권한 누락"은 피할 수 있습니다. 정책을 직접 좁혀 쓴 최소 권한 사용자가 이 403을 만나기 쉬운 이유입니다.

서비스 주체 이름은 **추측하지 말라**고 IAM 문서가 경고합니다. 대소문자를 구분하고 서비스마다 형식이 다르기 때문입니다. AgentCore만 해도 SLR마다 주체가 다릅니다. Runtime Identity SLR은 `runtime-identity.bedrock-agentcore.amazonaws.com`, VPC 네트워크용 SLR은 `network.bedrock-agentcore.amazonaws.com`입니다. 반드시 그 서비스의 SLR 문서에서 확인합니다.

> **이름이 비슷한 다른 SLR.** AgentCore에는 `AWSServiceRoleForBedrockAgentCoreGatewayNetwork`라는 Gateway용 SLR도 있습니다. 이것은 Gateway 타깃을 관리형 사설 엔드포인트(VPC Lattice)로 연결할 때 쓰는 역할입니다. 두 번째 장면의 "Gateway 서비스 역할"(내가 만들고 Gateway가 도구를 부를 때 맡는 역할)과는 다른 것입니다.
{: .prompt-info }

### SLR 권한은 좁게 정의되는 이유

[IAM 문서](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create-service-linked-role.html#create-service-linked-role-permissions-transfer)는 SLR의 **간접 권한**을 설명합니다. SLR을 쓰는 서비스를 호출할 수 있는 사용자는, 그 서비스를 거쳐 SLR의 권한을 간접적으로 쓰게 됩니다. 그래서 SLR을 볼 때는 그 역할 자체의 권한뿐 아니라, **그 서비스를 호출할 수 있는 주체가 누구이고 어디까지인지**도 함께 확인해야 합니다. 참고로 Runtime Identity SLR의 [현재 정책](https://docs.aws.amazon.com/aws-managed-policy/latest/reference/BedrockAgentCoreRuntimeIdentityServiceRolePolicy.html)이 허용하는 것은 앞서 본 토큰 세 액션입니다.

### 있는지 확인하고, 만들고, 지우기

SLR이 이미 계정에 있는지는 읽기 명령 하나로 봅니다. 없으면 `NoSuchEntity`가 납니다.

```sh
aws iam get-role --profile dev \
  --role-name AWSServiceRoleForBedrockAgentCoreRuntimeIdentity \
  --query Role.Arn --output text
```

없으면 관리자가 만듭니다. 서비스 주체 이름은 그 서비스 문서에 적힌 값을 그대로 씁니다.

```sh
aws iam create-service-linked-role --profile admin \
  --aws-service-name runtime-identity.bedrock-agentcore.amazonaws.com
```

지우는 일은 조금 다릅니다. [DeleteServiceLinkedRole](https://docs.aws.amazon.com/IAM/latest/APIReference/API_DeleteServiceLinkedRole.html)은 바로 지우지 않고 **삭제 작업을 제출**한 뒤 `DeletionTaskId`를 돌려줍니다. 서비스가 아직 그 역할로 자원을 쓰고 있으면 작업이 실패하고, [상태 조회](https://docs.aws.amazon.com/IAM/latest/APIReference/API_GetServiceLinkedRoleDeletionStatus.html)가 `NOT_STARTED`·`IN_PROGRESS`·`SUCCEEDED`·`FAILED` 중 하나와, 실패했다면 서비스가 알려 준 이유(그 역할을 쓰는 리전과 자원)를 돌려줍니다.

```sh
# 1. 그 SLR을 쓰는 자원이 쓰던 리전 전부에서 0개인지 확인 (리전은 예시)
#    모든 조회가 오류 없이 끝나고 결과가 전부 []일 때만 2번으로 넘어갑니다.
for r in ap-northeast-2 us-east-1; do
  aws bedrock-agentcore-control list-agent-runtimes --profile dev --region "$r" \
    --query 'agentRuntimes' --output json
done

# 2. 삭제 작업 제출 → 응답의 DeletionTaskId를 변수에 담기
TASK_ID=$(aws iam delete-service-linked-role --profile admin \
  --role-name AWSServiceRoleForBedrockAgentCoreRuntimeIdentity \
  --query DeletionTaskId --output text)

# 3. 상태 확인
#    NOT_STARTED·IN_PROGRESS → 잠시 뒤 다시 조회
#    FAILED → Reason에 나온 남은 자원을 정리한 뒤 2번부터 다시
#    SUCCEEDED → 4번으로
aws iam get-service-linked-role-deletion-status --profile admin \
  --deletion-task-id "$TASK_ID"

# 4. 정말 없어졌는지 (NoSuchEntity가 나와야 함)
aws iam get-role --profile dev \
  --role-name AWSServiceRoleForBedrockAgentCoreRuntimeIdentity
```

1번에서 리전을 모두 도는 이유가 있습니다. IAM 역할은 리전마다 따로 있지 않고 계정에 하나입니다. 런타임은 리전마다 만들지만, 그 런타임들이 기대는 SLR은 계정 전체에 하나뿐입니다. AgentCore 문서도 SLR 삭제가 실패하면 그 역할을 쓰고 있는 리전을 볼 수 있다고 적고 있습니다. 한 리전만 비었다고 지우면 안 됩니다.

## 3. confused deputy와 `aws:SourceAccount`·`aws:SourceArn`

이제 두 번째 장면의 `Condition`입니다.

### 혼동된 대리인 문제

[혼동된 대리인 문제(confused deputy)](https://docs.aws.amazon.com/IAM/latest/UserGuide/confused-deputy.html)는 어떤 행동을 할 권한이 없는 주체가, 권한이 더 많은 주체(대리인)를 시켜서 그 행동을 하게 만드는 보안 문제입니다. 문서는 두 갈래로 설명합니다.

- **교차 계정형**: 외부 업체에 내 계정의 역할 ARN을 알려 줬는데, 그 업체의 다른 고객이 같은 ARN을 업체에 넣어서 업체가 내 계정을 건드리게 만드는 경우입니다. 역할 ARN은 비밀이 아니라 추측하거나 알아낼 수 있습니다. 해결은 신뢰 정책에 `sts:ExternalId` 조건을 거는 것입니다. 이 값은 고객이 지어내는 것이 아니라 외부 업체가 고객마다 **겹치지 않게** 만들어 관리하고, 역할을 맡는 요청에 늘 그 고객의 값을 넣어 보냅니다. 다른 고객은 업체가 요청에 넣는 값을 바꿀 수 없으니 내 역할을 맡을 수 없습니다.
- **교차 서비스형**: 이 글의 중심입니다. 정책이 `"Principal": {"Service": "x.amazonaws.com"}`만 믿으면, 그 서비스를 **누가, 어느 계정의 어느 자원에서** 설정했는지는 확인하지 않습니다. 문서 예시는 조건 없이 CloudTrail 서비스 주체를 믿는 S3 버킷입니다. 이 버킷은 내가 설정한 CloudTrail 로그뿐 아니라, 버킷 이름만 아는 다른 사람이 설정한 CloudTrail 로그까지 받게 됩니다.

서비스 주체는 모든 고객이 함께 쓰는 이름입니다. `bedrock-agentcore.amazonaws.com`은 내 Gateway를 위해 일할 때도, 남의 Gateway를 위해 일할 때도 같은 이름입니다. 그래서 `Principal`만으로는 "이 서비스라면 누구를 위해 일하든 맡아도 된다"는 뜻이 됩니다.

### AWS가 붙여 주는 출처 꼬리표

서비스 주체가 다른 서비스를 대신 부를 때, AWS는 "지금 어느 자원·계정·조직을 위해 일하는지"를 전역 조건 키로 요청에 넣어 줍니다. [confused deputy 문서](https://docs.aws.amazon.com/IAM/latest/UserGuide/confused-deputy.html#cross-service-confused-deputy-prevention)는 서비스 주체에 권한을 주는 곳마다 이 키를 쓰라고 권장합니다.

- **`aws:SourceArn`**: 특정 자원(특정 Gateway, 특정 CloudTrail 추적 등)을 위한 요청만 허용합니다. 데이터 형식이 ARN이므로 [문서](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_condition-keys.html#condition-keys-sourcearn)는 문자열 연산자 대신 **`ArnLike`·`ArnEquals` 같은 ARN 연산자**를 권장합니다. 원본 ARN에 계정 ID가 들어 있으면 `aws:SourceAccount`를 같이 쓰지 않아도 된다고도 적혀 있습니다.
- **`aws:SourceAccount`**: 특정 계정을 위한 요청만 허용합니다. 문자열이라 `StringEquals`를 씁니다. [민감 조건 키](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_condition-keys.html)로 분류돼 있어서, 값 일부에라도 와일드카드를 쓸 정당한 이유가 없다고 문서가 말합니다.
- 조직 단위로 묶는 `aws:SourceOrgID`, `aws:SourceOrgPaths`도 있습니다.

두 가지를 알아 둡니다.

1. 이 키들은 **서비스 주체가 직접 호출할 때만** 요청 컨텍스트에 들어갑니다. 사람이 직접 부르는 요청에는 없습니다.
2. 문서는 **모든 서비스 연동이 이 키를 쓰지는 않는다**고 적고 있습니다. 붙이기 전에 그 서비스 문서의 예시를 확인합니다.

### 같은 조건이 두 종류의 정책에 나온다

이번 작업에서 이 조건 키를 두 곳에서 만났습니다. 모양은 같은데 붙는 정책의 종류가 다릅니다.

**① 역할의 신뢰 정책 (서비스가 역할을 맡을 때).** 1절의 Gateway 서비스 역할 예시가 이것입니다. AgentCore의 [Runtime 실행 역할 신뢰 정책](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-permissions.html#runtime-permissions-trust-policy)과 [Gateway 서비스 역할 신뢰 정책](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-prerequisites-permissions.html#gateway-service-role-permissions-trust) 문서 예시 모두 `StringEquals aws:SourceAccount`와 `ArnLike aws:SourceArn`을 같이 씁니다. Runtime 예시의 `SourceArn`은 `arn:aws:bedrock-agentcore:<리전>:<계정>:*`처럼 리전·계정 범위이고, Gateway 예시는 `gateway/...`까지 내려갑니다.

**② 자원 기반 정책 (서비스가 내 자원에 직접 쓸 때).** CloudWatch [Transaction Search를 API로 켤 때](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Enable-TransactionSearch.html)는 X-Ray가 CloudWatch Logs에 스팬을 쓸 수 있도록 Logs 자원 정책을 넣습니다. 여기서는 역할을 맡는 것이 아니라 서비스 주체가 로그 그룹에 바로 씁니다. 문서 예시의 구조를 예시 값으로 옮기면 이렇습니다.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "xray.amazonaws.com" },
      "Action": "logs:PutLogEvents",
      "Resource": [
        "arn:aws:logs:ap-northeast-2:123456789012:log-group:aws/spans:*",
        "arn:aws:logs:ap-northeast-2:123456789012:log-group:/aws/application-signals/data:*"
      ],
      "Condition": {
        "ArnLike": { "aws:SourceArn": "arn:aws:xray:ap-northeast-2:123456789012:*" },
        "StringEquals": { "aws:SourceAccount": "123456789012" }
      }
    }
  ]
}
```

①은 "서비스가 **이 역할을** 맡아도 되나", ②는 "서비스가 **이 자원에** 써도 되나"를 묻습니다. 묻는 대상은 달라도 "어느 계정의 어느 자원을 위해 일하는 요청인가"를 확인하는 방법은 같습니다.

### 닭과 달걀: ARN은 자원을 만든 뒤에야 생긴다

Gateway 서비스 역할의 `aws:SourceArn`에는 Gateway ARN이 들어가야 합니다. 그런데 Gateway를 만들 때 이 역할을 넘겨야 하고, Gateway ARN(정확히는 끝의 ID)은 만들기 전에는 모릅니다. [Gateway 문서](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-prerequisites-permissions.html#gateway-service-role-permissions-trust)는 이 순서를 직접 안내합니다. 처음 역할을 만들 때는 `Condition`을 빼도 되고, Gateway를 만든 뒤 계정 ID와 **Gateway ARN**으로 `Condition`을 다시 넣으라는 것입니다.

두 번째 장면에서 에이전트가 한 순서가 이것이었습니다. 처음에는 `gateway/*`로 넓게 두고, Gateway가 생긴 뒤 그 ID 하나로 좁혔습니다. 이때 두 정책을 함께 손봤지만 좁히는 대상은 다릅니다. 신뢰 정책의 `SourceArn`은 **역할을 맡기는 쪽**, 즉 방금 만든 Gateway의 ARN으로 좁힙니다. 권한 정책의 `Resource`는 **역할로 부를 쪽**, 즉 Gateway가 호출할 도구로 좁힙니다. 1절 예시라면 Lambda 함수 ARN입니다. 여기에 Gateway ARN을 넣으면 함수 호출이 허용되지 않습니다. 아래 두 파일은 1절의 신뢰 정책과 권한 정책 JSON을 저장한 것입니다.

```sh
# 좁힌 신뢰 정책 적용
aws iam update-assume-role-policy --profile admin \
  --role-name MyProjGatewayRole --policy-document "$(cat gateway-role-trust.json)"

# 좁힌 권한 정책 적용 (인라인 정책 예)
aws iam put-role-policy --profile admin \
  --role-name MyProjGatewayRole --policy-name MyProjGatewayTools \
  --policy-document "$(cat gateway-role-policy.json)"
```

> **신뢰 정책도 검사기에 넣을 수 있습니다.** IAM Access Analyzer의 [`validate-policy`](https://docs.aws.amazon.com/access-analyzer/latest/APIReference/API_ValidatePolicy.html)는 권한 정책만 보는 도구가 아닙니다. 권한 정책은 `--policy-type IDENTITY_POLICY`로, 신뢰 정책은 자원 기반 정책이므로 `--policy-type RESOURCE_POLICY --validate-policy-resource-type AWS::IAM::AssumeRolePolicyDocument`로 검사합니다. 이번에는 적용 전에 둘 다 돌려 결과 0건을 확인했습니다.
{: .prompt-tip }

```sh
aws accessanalyzer validate-policy --profile dev \
  --policy-type RESOURCE_POLICY \
  --validate-policy-resource-type AWS::IAM::AssumeRolePolicyDocument \
  --policy-document "$(cat gateway-role-trust.json)" \
  --query 'findings' --output json
```

## 곁가지: "만들었는데 바로 안 된다"의 정체

> **IAM은 최종 일관성(eventual consistency) 모델입니다.** [IAM 문서](https://docs.aws.amazon.com/IAM/latest/UserGuide/troubleshoot_general.html#troubleshoot_general_eventual-consistency)에 따르면 IAM은 전 세계에 분산된 시스템이라, 사용자·그룹·역할·정책을 만들거나 바꾼 내용이 모든 엔드포인트에 보이기까지 시간이 걸립니다. 캐시 때문에 더 걸릴 수도 있습니다. 권장 사항은 IAM 변경을 서비스의 핵심 경로에 넣지 말고 따로 준비 단계에서 하고, **운영 흐름이 기대기 전에 전파됐는지 확인**하라는 것입니다. 문서에는 몇 초를 기다리라는 숫자가 없습니다.
{: .prompt-info }

이번 작업에서 에이전트는 "역할이 퍼지는 데 10초쯤", "권한이 퍼질 때까지 30초쯤", 다시 만들기 전 `sleep 60` 같은 숫자를 썼습니다. 이 숫자들은 **에이전트의 경험치이지 문서 값이 아닙니다.** 기다리는 것 자체는 맞지만, 몇 초면 충분하다는 보장은 없습니다.

반대 경우도 있었습니다. 정책을 고친 뒤 15초, 1분, 2분을 기다려도 똑같은 권한 거부가 나왔는데, 원인은 전파가 아니라 정책 구성(태그 액션이 평가되는 자원)이었습니다. 그 이야기는 [관리자 권한 없이 CDK 배포하기 2편]({% post_url 2026-11-05-cdk-least-privilege-first-deploy %})에 있습니다. 그렇다고 문서에 전파 시간의 상한이 있는 것은 아니니, "몇 분이 지났으니 전파 문제는 아니다"라고 단정할 수는 없습니다. 그래도 몇 분 뒤에도 같은 거부가 되풀이된다면, 기다리기만 하지 말고 정책 내용, 오류 메시지가 가리키는 액션과 자원, 실제로 호출한 주체를 함께 확인하는 편이 빠릅니다.

## 그때 왜 그렇게 했나

이제 두 장면으로 돌아갑니다.

### 첫 번째 장면: 관리자가 SLR을 한 번 만든 이유

런타임을 처음 만들 때 계정에는 Runtime Identity SLR이 없었습니다. 그래서 AgentCore가 SLR을 만들려 했고, 그 요청은 호출자인 최소 권한 사용자의 `iam:CreateServiceLinkedRole` 권한으로 검사돼 403이 났습니다. 에이전트가 살펴본 바로는 그 런타임 생성 경로의 문서 권한 표에도 SLR 생성 권한은 없었습니다(관찰). 문서의 권한 표만 믿지 말고, 최소 권한으로 서비스 자원을 처음 만든다면 필요한 SLR이 계정에 이미 있는지 `get-role`로 먼저 보는 편이 안전합니다.

해결 방법은 두 가지였습니다.

1. 최소 권한 사용자에게 `iam:CreateServiceLinkedRole`을 준다. 2절의 예시처럼 그 SLR ARN과 `iam:AWSServiceName` 조건으로 좁히면 문서상 정당한 방법입니다.
2. 관리자가 SLR을 한 번 직접 만든다.

저희는 2번을 골랐습니다. 그 사용자는 조회와 호출만 하도록 정해 둔 상태였고, IAM 쓰기 권한은 처음 승인한 범위에 없었습니다. 또 SLR은 계정에 한 번만 있으면 되니, 한 번 쓸 권한을 계속 들고 있게 하는 것보다 관리자가 한 번 만드는 편이 권한 면적이 작습니다. 이후 본 배포에서도 배포 전에 관리자가 같은 SLR을 먼저 만드는 단계를 따로 두었습니다. 1번이 틀린 것은 아닙니다. 사용자가 여럿이고 SLR이 자주 생겼다 지워지는 환경이라면 1번이 나을 수도 있습니다.

되돌리기에 넣은 SLR 삭제 단계는 2절의 순서 그대로입니다. 쓰던 리전 전부에서 런타임 목록이 비었는지 확인하고, 삭제 작업을 제출하고, `DeletionTaskId`로 `SUCCEEDED`를 확인하고, `get-role`이 `NoSuchEntity`인지 봤습니다. 실제로 이 순서로 지웠고 두 결과를 모두 확인했습니다.

### 두 번째 장면: 역할이 없는데 Gateway가 만들어진 일

Gateway는 서비스 역할이 없는데도 READY가 됐습니다. 왜 만들 때 역할이 있는지 확인하지 않는지는 문서에서 찾지 못했습니다. **관찰한 사실은 "만들기 성공이 역할 확인을 뜻하지 않았다"는 것까지입니다.** 그래서 순서를 이렇게 잡는 편이 안전합니다.

1. 서비스 역할을 만든다 (신뢰 정책 + 권한 정책).
2. 잠시 기다린 뒤 `get-role`로 역할이 조회되는지 확인한다. 조회된다고 모든 서비스 엔드포인트에 전파됐다는 증명은 아니므로, 마지막 확인은 5번의 실제 호출로 한다.
3. 그 역할을 쓰는 자원(Gateway)을 만든다.
4. 자원 ARN이 생기면 신뢰 정책의 `SourceArn`을 그 자원(Gateway) ARN으로 좁힌다. 권한 정책의 `Resource`는 그 자원이 호출할 대상(예: Lambda 함수 ARN)으로 제한한다.
5. 실제 호출(도구 목록, 검색 한 건)로 역할이 쓰이는지 확인한다.

이번에는 역할을 만든 뒤 신뢰 정책을 그 Gateway 하나로 좁혔고, 좁힌 뒤에도 검색은 정상이었습니다.

### 다른 역할에 붙인 조건

같은 작업의 다른 역할들에도 신뢰 정책 조건을 붙였습니다.

- **AgentCore 실행 역할**: Runtime 문서 예시와 같은 형태로 `StringEquals aws:SourceAccount` + `ArnLike aws:SourceArn`(리전·계정 범위 와일드카드)을 붙였습니다. 문서 중에는 신뢰 정책 예시가 조건 없이 나오는 곳도 있어서, 조건 때문에 막힐 경우를 대비해 `SourceAccount`만 남긴 대체 신뢰 정책을 미리 준비했습니다. 실제로는 조건을 붙인 원래 정책으로 생성과 호출이 성공해서 대체안은 쓰지 않았습니다.
- **도구 Lambda 실행 역할**: `StringEquals aws:SourceAccount`만 붙였고, 함수는 모두 정상으로 만들어졌습니다. 다만 [Lambda 실행 역할 문서](https://docs.aws.amazon.com/lambda/latest/dg/lambda-intro-execution-role.html)의 신뢰 정책 예시에는 조건이 없고, 이 조건이 실제 호출 때 어떻게 평가되는지는 문서로 확인하지 못했습니다. 그래서 여기서는 "저희는 붙였다"까지만 적고, 권장 사항으로 쓰지는 않습니다.

## 다음에 조심할 것

1. 서비스가 맡을 역할이라면, 먼저 그 서비스 문서가 `aws:SourceAccount`·`aws:SourceArn` 조건을 쓰는 예시를 주는지 확인했나. 준다면 신뢰 정책에 문서 예시와 같은 형태로 붙였나.
2. `SourceArn`에 넣을 ARN이 자원을 만든 뒤에야 생긴다면, 만든 뒤 좁히는 단계를 계획에 넣었나. 그때 권한 정책의 `Resource`는 출처 자원이 아니라 호출 대상으로 좁히나.
3. 최소 권한 사용자로 서비스 자원을 처음 만든다면, 필요한 SLR이 이미 있는지 `get-role`로 확인했나. 없다면 관리자가 미리 만들지, `iam:CreateServiceLinkedRole`(+`iam:AWSServiceName` 조건)을 줄지 정했나.
4. 되돌리기에 SLR 삭제를 넣었다면, 그 SLR을 쓰는 자원이 **쓰던 리전 전부에서** 0개인지 먼저 확인하나. 삭제는 비동기이니 상태까지 확인하고, `FAILED`면 이유를 보고 정리한 뒤 다시 요청하나.
5. 자원 만들기 성공을 역할 확인으로 여기지 않고, 역할 존재와 실제 호출을 따로 확인하나.
6. (제 작업 원칙) IAM 변경 직후에는 잠시 기다리되 기다림만 늘리지 않는다. 몇 분 뒤에도 같은 거부면 정책·오류 메시지·호출 주체를 다시 본다.

## 정리

- 역할에는 정책이 둘 붙습니다. **신뢰 정책**은 누가 맡을 수 있는지, **권한 정책**은 맡은 뒤 무엇을 할 수 있는지를 정합니다.
- **서비스 역할**은 내가 쓰고 고치는 역할이고, **서비스 연결 역할**은 서비스가 정의하고 소유하는 역할입니다. SLR을 서비스가 "자동으로" 만들어도, 그 요청을 한 주체에게 `iam:CreateServiceLinkedRole`이 있어야 합니다.
- 서비스 주체는 모든 고객이 함께 쓰는 이름이라 `Principal`만으로는 "누구를 위해 일하는 요청인지"를 가리지 못합니다. **`aws:SourceAccount`·`aws:SourceArn`**이 그 빈자리를 메웁니다. 같은 조건이 역할의 신뢰 정책에도, 자원 기반 정책에도 쓰입니다.
- IAM 변경은 바로 보이지 않을 수 있지만, 몇 초를 기다리라는 문서 값은 없습니다. 기다려도 그대로면 기다림만 늘리지 말고 정책과 호출 주체를 함께 봅니다.
