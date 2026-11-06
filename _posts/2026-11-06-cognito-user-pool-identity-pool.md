---
title: "Cognito 사용자 풀과 자격 증명 풀: 로그인한 브라우저가 AWS를 직접 부르려면"
date: 2026-11-06 10:40:00 +0900
categories: [AWS, 보안]
tags: [aws-concepts, aws, cognito, user-pool, identity-pool, iam, sts, iot-core]
description: "브라우저가 AWS IoT Core에 직접 붙는 대시보드를 만들며 만난 질문에서 출발해, Cognito 사용자 풀의 토큰과 그룹, 자격 증명 풀의 자격 증명 ID·인증/게스트 역할·역할 매핑·신뢰 정책 조건, IoT 정책이 따로 필요한 이유, 권한을 내릴 때의 한계를 정리합니다."
---

현장 장비의 상태를 웹 대시보드에서 보는 시스템을 AI 에이전트와 같이 만들었습니다. 장비와 웹은 서로 직접 통신하지 않고, 둘 다 AWS IoT Core에 붙어 MQTT 메시지를 주고받습니다. 장비가 상태를 올리면 웹이 구독해서 보여 주고, 웹이 명령을 올리면 장비가 받습니다. 웹은 로그인한 사용자만 쓸 수 있고, 브라우저가 IoT Core에 **MQTT over WebSocket**으로 직접 붙습니다. 이때 요청에는 AWS 자격 증명으로 만든 SigV4 서명이 붙습니다.

인증은 Amazon Cognito로 구성했습니다. 로그인은 **사용자 풀(user pool)**이, 브라우저가 IoT에 붙을 임시 AWS 권한은 **자격 증명 풀(identity pool)**이 맡았습니다. 여기에 사용자를 둘로 나눠야 했습니다. 상태를 보기만 하는 사용자와, 장비에 명령까지 보낼 수 있는 사용자입니다. 그래서 로그인한 뒤 사용자에게 맞는 IoT 정책을 붙이는 서버 함수를 따로 두었습니다.

구조는 동작했지만, 만들고 나서 보니 설명하지 못하는 부분이 남아 있었습니다.

> 로그인은 이미 했는데 왜 AWS 권한을 또 받아야 하지? 그리고 IAM 역할이 있는데 왜 IoT 정책을 또 붙이지?

이 글은 그 질문에 대한 정리입니다. 두 풀이 각각 무엇을 증명하고 무엇을 내주는지를 공식 문서 기준으로 기초부터 짚고, 자격 증명 풀 내부(자격 증명 ID, 인증·게스트 역할, 역할 선택, 신뢰 정책 조건)를 살펴본 뒤, IoT Core라는 특수한 경우와 권한을 내릴 때의 한계까지 다룹니다. 마지막에 그때 실제로 정한 설정으로 돌아갑니다.

## 두 풀 한 줄 복습

두 풀을 한 장짜리 표로 비교한 내용은 [인증 한 번에 정리: JWT, IAM(SigV4), Cognito는 각각 무엇을 증명하나]({% post_url 2026-11-01-auth-basics-jwt-iam-cognito %})에 있습니다. 여기서는 한 줄씩만 적습니다.

- **사용자 풀**: "이 사람은 누구인가"에 답합니다. 가입·로그인을 맡고, 결과로 JWT(ID·access·refresh 토큰)를 줍니다.
- **자격 증명 풀**: "이 사람이 어떤 AWS 리소스를 쓸 수 있나"에 답합니다. 믿을 수 있는 토큰을 받아 STS의 **임시 AWS 자격 증명**으로 바꿔 줍니다.

브라우저가 AWS 서비스를 **직접** 부르려면 요청에 SigV4 서명이 필요하고, 서명에는 AWS 자격 증명이 필요합니다. 사용자 풀의 JWT는 AWS 자격 증명이 아닙니다. 그래서 JWT를 AWS 자격 증명으로 바꿔 줄 자격 증명 풀이 하나 더 들어갑니다. "로그인했는데 왜 또 받나"의 답이 이것입니다. 로그인으로 받은 것은 신원 증명이고, AWS를 부를 열쇠는 따로 받아야 합니다.

<figure class="diagram">
{% include figures/cognito-user-pool-identity-pool/two-pools-two-gates.svg %}
<figcaption>로그인(사용자 풀)과 AWS 권한(자격 증명 풀)은 따로 받고, IoT Core는 IAM 역할과 자격 증명 ID에 붙은 IoT 정책이 둘 다 허용해야 통과시킨다</figcaption>
</figure>

## 사용자 풀: 무엇을 내주나

사용자 풀에 로그인이 성공하면 Cognito는 세션을 만들고 [토큰 세 개](https://docs.aws.amazon.com/cognito/latest/developerguide/amazon-cognito-user-pools-using-tokens-with-identity-providers.html)를 돌려줍니다.

| 토큰 | 내용 | 주로 쓰는 곳 |
|---|---|---|
| ID 토큰 | 사용자 신원에 관한 클레임 (`sub`, 이메일 같은 속성, 그룹) | 내 앱이 사용자를 알아볼 때, **자격 증명 풀에 건넬 때** |
| access 토큰 | `scope` 같은 권한 클레임, 그룹 | API 호출, Cognito 사용자 셀프 서비스 API |
| refresh 토큰 | 암호화되어 있어 앱이 읽을 수 없음 | 새 ID·access 토큰 받기 |

이 글에서 중요한 클레임은 세 가지입니다.

- **`sub`**: 사용자 풀이 사용자마다 붙이는 고유 ID(UUID)입니다. 뒤에 나오는 자격 증명 풀의 "자격 증명 ID"와는 **다른 값**입니다.
- **`cognito:groups`**: 사용자가 속한 [그룹](https://docs.aws.amazon.com/cognito/latest/developerguide/cognito-user-pools-user-groups.html) 목록입니다. ID 토큰과 access 토큰 모두에 들어갑니다. 그룹은 "보기 전용", "운영자"처럼 사용자를 묶는 이름표입니다.
- **`cognito:roles`, `cognito:preferred_role`**: 그룹에 IAM 역할을 지정해 두었을 때만 ID 토큰에 들어갑니다. 뒤의 "역할 선택"에서 다시 봅니다.

ID 토큰의 유효 시간은 앱 클라이언트마다 5분에서 1일 사이로 정합니다. 자격 증명 풀은 이 ID 토큰을 받아 자격 증명을 내주므로, ID 토큰 수명은 뒤의 "권한을 내릴 때"와도 이어집니다.

가입 흐름에는 Lambda 트리거를 걸 수 있습니다. 이 시스템에서는 두 개를 썼습니다. 가입 요청이 들어오면 **PreSignUp** 트리거가 허용할 가입인지 검사하고, 이메일 인증까지 끝나 가입이 확정되면 **PostConfirmation** 트리거가 새 사용자를 기본 그룹(보기 전용)에 넣습니다. 화면이 아니라 서버에서 검사하므로 화면을 우회해도 소용이 없습니다.

## 자격 증명 풀: 토큰을 AWS 자격 증명으로

### 자격 증명 ID

자격 증명 풀이 가장 먼저 하는 일은 사용자에게 **자격 증명 ID(identity ID)**를 정해 주는 것입니다. `ap-northeast-2:00000000-0000-0000-0000-000000000000`처럼 `리전:UUID` 형태입니다. 같은 사용자가 같은 로그인으로 다시 오면 같은 자격 증명 ID를 돌려받습니다.

이 ID가 중요한 이유는 **AWS 쪽에서 사용자를 가리키는 이름이 이것**이기 때문입니다. IAM 정책 변수 `${cognito-identity.amazonaws.com:sub}`도 사용자 풀의 `sub`가 아니라 이 자격 증명 ID로 바뀝니다. [Cognito 문서](https://docs.aws.amazon.com/cognito/latest/developerguide/iam-roles.html)도 이 값이 "원래 IdP의 `sub`가 아니다"라고 따로 적어 둡니다. 뒤에서 IoT 정책을 붙이는 대상도 이 자격 증명 ID입니다.

### 강화 흐름과 기본 흐름

토큰을 자격 증명으로 바꾸는 방법은 [두 가지 흐름](https://docs.aws.amazon.com/cognito/latest/developerguide/authentication-flow.html)이 있습니다.

**강화(enhanced) 흐름**은 API 두 번이면 끝납니다.

1. `GetId`: 사용자 풀의 ID 토큰을 내고 자격 증명 ID를 받습니다.
2. `GetCredentialsForIdentity`: 자격 증명 ID와 같은 ID 토큰을 내고 AWS 자격 증명을 받습니다.

역할 선택은 자격 증명 풀이 설정대로 합니다. 뒤에서 Cognito가 STS `AssumeRoleWithWebIdentity`를 대신 부르고, 이렇게 받은 자격 증명은 **1시간** 유효합니다.

**기본(basic, classic) 흐름**은 세 번입니다.

1. `GetId`로 자격 증명 ID를 받고
2. `GetOpenIdToken`으로 자격 증명 풀이 발급한 OpenID 토큰을 받은 뒤
3. 앱이 직접 STS `AssumeRoleWithWebIdentity`를 불러 자격 증명을 받습니다.

기본 흐름에서는 **앱이 역할을 고릅니다.** 세션 기간도 직접 정할 수 있어 더 세밀하지만, 그만큼 클라이언트가 고른 역할을 믿어야 합니다. 문서 표현으로는 기본 흐름의 토큰은 "자격 증명 풀과 `amr`(인증 상태)을 신뢰하는 **어떤 IAM 역할**과도" 바꿀 수 있습니다. 그래서 공식 문서는 강화 흐름을 가장 안전한 선택으로 권하고, 새 자격 증명 풀에서 기본 흐름을 기본으로 켜지 말라고 합니다. 역할 매핑을 설정한 자격 증명 풀에서는 기본 흐름이 아예 지원되지 않습니다.

### 브라우저에서 자격 증명 받기

AWS SDK for JavaScript v3에서는 `@aws-sdk/credential-providers`의 `fromCognitoIdentityPool`이 강화 흐름을 대신 해 줍니다. [SDK 문서](https://github.com/aws/aws-sdk-js-v3/tree/main/packages/credential-providers#fromcognitoidentitypool)대로 `GetId`로 자격 증명 ID를 받고(이 결과는 캐시합니다), `GetCredentialsForIdentity`로 임시 자격 증명을 만듭니다. 아래는 이 글을 위해 새로 쓴 최소 예시이고 값은 모두 자리표시자입니다(실행은 확인하지 않았습니다).

```javascript
import { fromCognitoIdentityPool } from "@aws-sdk/credential-providers";

const REGION = "ap-northeast-2";
const USER_POOL_ID = "ap-northeast-2_EXAMPLE";
const IDENTITY_POOL_ID = "ap-northeast-2:00000000-0000-0000-0000-000000000000";

// 로그인으로 받은 ID 토큰을 넘기면, AWS SDK 클라이언트에 꽂을 자격 증명 공급자를 돌려준다
export function awsCredentialsFrom(idToken) {
  return fromCognitoIdentityPool({
    clientConfig: { region: REGION },
    identityPoolId: IDENTITY_POOL_ID,
    logins: {
      // 키: "cognito-idp.<리전>.amazonaws.com/<사용자 풀 ID>", 값: access 토큰이 아니라 ID 토큰
      [`cognito-idp.${REGION}.amazonaws.com/${USER_POOL_ID}`]: idToken,
    },
  });
}
```

`logins`의 키가 "어느 사용자 풀이 발급한 토큰인가"를 알려 줍니다. 자격 증명 풀은 이 공급자가 자기에게 등록된 사용자 풀·앱 클라이언트인지, 토큰이 유효하고 만료되지 않았는지 확인한 뒤에야 자격 증명 ID를 내줍니다.

## 인증 역할과 게스트 역할

자격 증명 풀에는 기본 역할이 두 칸 있습니다.

- **인증된(authenticated) 역할**: 로그인한 사용자가 받는 역할
- **비인증(unauthenticated) 역할**: 로그인하지 않은 **게스트**가 받는 역할

게스트 접근을 켜면, 앱은 로그인 없이 `GetId`를 불러 새 자격 증명 ID를 받고 비인증 역할의 자격 증명을 얻을 수 있습니다. [문서](https://docs.aws.amazon.com/cognito/latest/developerguide/authentication-flow.html)는 만들 수 있는 자격 증명 수에 제한이 없으니 내주는 권한을 잘 이해하라고 경고합니다. 쉽게 말해 **앱 주소만 아는 누구나** 그 권한을 받을 수 있습니다.

AWS가 게스트에게 걸어 두는 안전장치가 하나 있습니다. 강화 흐름에서 비인증 사용자의 자격 증명에는 **범위 축소(scope-down) 세션 정책**이 덧씌워집니다. 세션의 실제 권한은 역할 정책과 세션 정책의 교집합이라, 역할에 무엇을 붙였든 정해진 서비스 목록 밖으로는 나갈 수 없습니다. 다만 이 목록에는 S3, DynamoDB, Lambda, 그리고 **AWS IoT**도 들어 있습니다. 이 글의 경우를 막아 주지는 않는다는 뜻입니다. 이 세션 정책은 비인증 사용자에게만 적용되고, 인증된 사용자의 권한은 역할 정책이 그대로 정합니다.

IoT Core 쪽 규칙도 게스트에게 너그럽습니다. [AWS IoT 개발자 가이드](https://docs.aws.amazon.com/iot/latest/developerguide/cog-iot-policies.html)에 따르면 비인증 자격 증명의 권한은 **IAM 역할만으로** 정해집니다. 뒤에 나오는 IoT 정책 단계가 없습니다. 문서도 비인증 사용자에게는 아주 제한된 리소스만 허용하라고 권합니다.

게스트 기능이 필요 없는 서비스라면 **끄는 것**(`AllowUnauthenticatedIdentities: false`)이 가장 단순한 방어입니다.

## 역할 선택과 신뢰 정책

### 로그인한 사용자에게 어떤 역할을 줄까

인증된 사용자의 역할은 [세 가지 방식](https://docs.aws.amazon.com/cognito/latest/developerguide/role-based-access-control.html)으로 고릅니다.

| 방식 | 어떻게 고르나 |
|---|---|
| 기본 인증 역할 | 로그인한 사용자 모두에게 같은 역할 하나 |
| 토큰에서 선택 (Choose role from token) | 사용자 풀 그룹에 지정한 IAM 역할을 ID 토큰의 `cognito:preferred_role`·`cognito:roles`에서 읽는다 |
| 규칙으로 선택 (Choose role with rules) | 토큰 클레임을 `Equals`·`NotEqual`·`StartsWith`·`Contains`로 비교해 처음 맞는 규칙의 역할을 준다. 공급자당 규칙 최대 25개 |

토큰에서 고르는 방식은 이렇게 동작합니다. 그룹마다 우선순위(precedence)를 둘 수 있고, 숫자가 가장 작은 그룹의 역할이 `cognito:preferred_role`에 들어갑니다. 여러 그룹에 속해 역할 후보가 여럿이면, 앱이 `GetCredentialsForIdentity`의 `CustomRoleArn`으로 `cognito:roles` 안의 하나를 고를 수 있습니다. 목록에 없는 역할을 요청하면 거부됩니다. 아무것도 정할 수 없을 때는 **역할 확인(Role resolution)** 설정(`AmbiguousRoleResolution`)에 따라 기본 인증 역할을 주거나(`AuthenticatedRole`) 요청을 거부합니다(`Deny`). 규칙 방식에서 맞는 규칙이 없을 때도 같은 설정을 따릅니다.

규칙 방식에는 [공식 문서](https://docs.aws.amazon.com/cognito/latest/developerguide/role-based-access-control.html#best-practices-for-role-based-access-control)가 굵게 경고하는 함정이 있습니다. **사용자가 스스로 바꿀 수 있는 클레임**(예: 쓰기를 허용한 사용자 속성)을 높은 권한의 역할에 매핑하면, 누구나 그 값을 바꿔서 그 역할을 받을 수 있습니다. 권한을 가르는 기준은 관리자만 바꿀 수 있는 값(그룹 등)이어야 합니다.

### 역할 쪽에서 막는 조건: `aud`와 `amr`

역할을 고르는 것은 자격 증명 풀이지만, 그 역할을 **맡아도 되는지**는 역할의 신뢰 정책이 정합니다. 자격 증명 풀이 맡을 역할의 신뢰 정책은 보통 이렇게 생겼습니다. 이 글을 위해 새로 쓴 예시이고 풀 ID는 자리표시자입니다.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "cognito-identity.amazonaws.com" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "cognito-identity.amazonaws.com:aud": "ap-northeast-2:00000000-0000-0000-0000-000000000000"
        },
        "ForAnyValue:StringLike": {
          "cognito-identity.amazonaws.com:amr": "authenticated"
        }
      }
    }
  ]
}
```

STS에 제출되는 토큰은 사용자 풀의 ID 토큰이 아니라, 자격 증명 풀이 그것을 바꿔 발급한 **자격 증명 풀 토큰**입니다. 두 조건은 이 토큰의 클레임을 봅니다([Cognito IAM 역할 문서](https://docs.aws.amazon.com/cognito/latest/developerguide/iam-roles.html)).

- **`aud`**: 토큰을 발급한 자격 증명 풀의 ID입니다. `cognito-identity.amazonaws.com`이라는 주체는 모든 AWS 고객의 자격 증명 풀이 공유합니다. `aud`로 "**내** 자격 증명 풀"을 지정하지 않으면 남의 풀이 발급한 토큰도 이 역할을 맡을 수 있게 됩니다. 그래서 지금은 IAM이 이 주체에 `aud` 같은 조건이 없는 신뢰 정책을 아예 저장하지 않습니다.
- **`amr`**: 인증 상태입니다. Cognito는 토큰의 `amr`에 `authenticated` 또는 `unauthenticated`를 넣습니다. 인증된 사용자용 역할에 `amr: authenticated` 조건이 없으면, 같은 풀의 **게스트 토큰**으로도 그 역할을 맡을 수 있는 길이 남습니다. 특히 앱이 역할을 고르는 기본 흐름에서 그렇습니다.

정리하면 역할 선택(자격 증명 풀 설정)과 신뢰 정책(역할 쪽 조건)은 서로 다른 층의 잠금입니다. 앞의 것이 "누구에게 무엇을 줄까"라면, 뒤의 것은 "누가 와도 이 역할만은 이 풀의 로그인 사용자에게만"입니다.

## IoT Core에서는 문이 하나 더 있다

이제 두 번째 질문, "IAM 역할이 있는데 왜 IoT 정책을 또 붙이나"입니다.

### 두 곳에 권한을 지정해야 한다

[AWS IoT 개발자 가이드](https://docs.aws.amazon.com/iot/latest/developerguide/cog-iot-policies.html)는 인증된 Cognito 자격 증명에 대해 **두 곳에 권한을 지정해야 한다**고 설명합니다.

1. 자격 증명 풀의 인증 역할에 붙은 **IAM 정책**
2. 그 Cognito 자격 증명(자격 증명 ID)에 붙은 **AWS IoT Core 정책**

[Amazon Cognito identities](https://docs.aws.amazon.com/iot/latest/developerguide/cognito-identities.html) 문서도 인증된 자격 증명을 쓸 때는 IAM 정책에 더해 IoT 정책을 붙여야 하고, 그때 `AttachPolicy` API로 사용자 한 명 한 명에게 권한을 줄 수 있다고 적습니다. `AttachPolicy`와 `ListAttachedPolicies`의 대상(`target`)에는 자격 증명 ID(`리전:id`)를 그대로 넣습니다.

IAM 역할 하나에 권한을 다 넣어도 IoT 정책이 없으면 IoT Core는 받아 주지 않습니다. 두 곳이 모두 허용해야 지나갈 수 있습니다. 앞의 그림 아래쪽 "두 문"이 이것입니다. 앞에서 본 비인증 자격 증명은 이 두 번째 문이 없다는 점과 대비됩니다.

### IAM 역할은 상한선, 사용자별 차이는 IoT 정책

이 구조를 쓰면 역할 분담이 자연스럽게 나옵니다.

- **IAM 역할**: 로그인한 사용자 모두가 같은 역할을 씁니다(기본 인증 역할 하나). 그래서 가장 넓은 권한, 즉 명령 게시까지 포함한 **상한선**을 담습니다.
- **IoT 정책**: 자격 증명 ID마다 붙습니다. 보기 전용 사용자에게는 상태 토픽 구독·수신만 허용하는 정책을, 운영자에게는 명령 토픽 게시까지 허용하는 정책을 붙입니다.

두 문의 교집합이 실제 권한이므로, 보기 전용 사용자는 IAM 역할에 게시 권한이 있어도 IoT 정책에서 막힙니다.

그룹마다 IAM 역할을 따로 두고 토큰으로 역할을 고르는 방법도 있습니다. 하지만 IoT Core는 그 경우에도 자격 증명 ID에 IoT 정책이 붙어 있기를 요구합니다. 브라우저가 IoT Core에 직접 붙는 한 **누군가 서버 쪽에서 IoT 정책을 붙이는 단계는 어차피 필요**합니다. 그래서 이 시스템은 역할 매핑 없이 기본 인증 역할 하나를 상한선으로 두고, 사용자별 차이는 IoT 정책으로만 나누었습니다.

### 정책을 붙이는 함수가 지켜야 할 것

IoT 정책은 클라이언트가 스스로 붙이게 두면 안 됩니다. 클라이언트가 붙일 수 있다면 운영자 정책도 스스로 붙일 수 있으니까요. 그래서 로그인 직후 브라우저가 부르는 서버 함수를 따로 두었습니다. 이 함수가 하는 일은 세 줄로 요약됩니다.

1. 호출자가 누구인지 확인한다 (자격 증명 ID와 사용자 풀 `sub`)
2. 사용자 풀에서 그 사람의 그룹을 조회한다
3. 그 자격 증명 ID에 붙은 IoT 정책을 그룹에 맞게 **맞춘다** (필요한 것만 붙이고 나머지는 뗀다)

가장 중요한 것은 1번입니다. **사용자 식별자를 요청 본문에서 읽으면 안 됩니다.** 본문은 클라이언트가 마음대로 쓸 수 있으니, 남의 자격 증명 ID를 적어 보내면 남의 권한을 바꿀 수 있습니다.

이 함수를 API Gateway 뒤에 두고 IAM 권한 부여(SigV4)를 켜면, API Gateway가 서명을 확인한 뒤 호출자의 Cognito 정보를 요청 컨텍스트에 넣어 줍니다. [API Gateway 컨텍스트 변수 문서](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-logging-variables.html) 기준으로 `cognitoIdentityId`에는 호출자의 자격 증명 ID가, `cognitoAuthenticationProvider`에는 `cognito-idp.<리전>.amazonaws.com/<풀 ID>,cognito-idp.<리전>.amazonaws.com/<풀 ID>:CognitoSignIn:<sub>` 형태로 사용자 풀의 `sub`가 들어 있습니다. 서명된 요청에서 AWS가 채운 값이라 클라이언트가 바꿀 수 없습니다.

핵심만 의사 코드에 가깝게 쓰면 이렇습니다(이 글을 위해 새로 쓴 예시, 실행 미확인, Lambda 프록시 페이로드 1.0의 필드 위치 기준).

```python
import re

POLICY_FOR = {"operator": "web-operator", "viewer": "web-viewer"}  # 그룹 → IoT 정책 이름
WEB_POLICIES = set(POLICY_FOR.values())
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

def handler(event, context):
    ident = event["requestContext"]["identity"]      # API Gateway가 서명 확인 뒤 채운 값
    identity_id = ident.get("cognitoIdentityId")
    sub = (ident.get("cognitoAuthenticationProvider") or "").rpartition(":CognitoSignIn:")[2]
    if not identity_id or not UUID.match(sub):       # 본문은 읽지 않는다
        return deny("no_identity")

    try:
        groups = groups_of_user(sub)                  # 사용자 풀에서 그룹 조회
    except Exception:
        detach(identity_id, WEB_POLICIES)             # 확인 못 하면 닫는 쪽으로
        return deny("lookup_failed")

    wanted = {POLICY_FOR[g] for g in pick_strongest(groups)}   # 0개 또는 1개
    detach(identity_id, attached(identity_id) & WEB_POLICIES - wanted)  # 먼저 떼고
    attach(identity_id, wanted - attached(identity_id))                 # 그다음 붙인다
    return ok() if wanted else deny("not_approved")
```

`sub`가 UUID 모양인지 확인하는 것은 이 값이 사용자 조회 필터에 들어가기 때문입니다. 떼기를 붙이기보다 먼저 하는 것은 강등할 때 잠깐이라도 두 정책이 같이 붙어 권한이 커지는 순간을 없애기 위해서입니다. 그리고 그룹을 확인하지 못하면 웹용 정책을 모두 떼고 거절합니다. 권한 확인이 실패했을 때 열어 두는 쪽이 아니라 **닫는 쪽으로** 실패하게 하는 것입니다. 이렇게 하면 함수 자신에게 필요한 권한도 `iot:AttachPolicy`·`iot:DetachPolicy`·`iot:ListAttachedPolicies`와 사용자 풀 조회 정도로 좁힙니다.

## 권한을 내릴 때: 이미 나간 자격 증명은 거둘 수 없다

운영자를 보기 전용으로 내리는 순간을 생각해 봅니다. 관리자가 그룹을 바꿔도 곧바로 권한이 줄지 않습니다. 이유는 두 가지입니다.

**첫째, IoT 정책은 함수가 불릴 때만 바뀝니다.** 정책은 사용자가 아니라 자격 증명 ID에 붙어 있고, 위 함수는 사용자가 다시 부를 때만 정책을 맞춥니다. 그 전까지는 이전 정책이 붙어 있습니다.

**둘째, 이미 발급된 임시 자격 증명은 만료 전까지 유효합니다.** 강화 흐름의 자격 증명은 1시간 유효합니다. 이 자격 증명을 한 사람 것만 골라 무효로 만드는 방법은 없습니다. IAM에는 [역할의 활성 세션 취소](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_revoke-sessions.html)가 있지만, 이것은 특정 시각 이전에 발급된 그 역할의 **모든** 세션을 거부하는 정책(`aws:TokenIssueTime` 조건의 Deny)을 역할에 붙이는 방식입니다. 로그인 사용자 모두가 같은 역할을 쓰는 구조에서는 모두가 한꺼번에 끊깁니다. 비상 수단이지 강등 절차는 아닙니다.

그래서 할 수 있는 것은 **다음 자격 증명을 못 받게 막고, 다음 갱신 때 정책을 맞추는 것**입니다.

1. **전역 로그아웃**: `AdminUserGlobalSignOut`은 대상 사용자의 refresh·ID·access 토큰을 모두 철회합니다([토큰 철회 문서](https://docs.aws.amazon.com/cognito/latest/developerguide/token-revocation.html)). 그런데 같은 문서가 짚듯이, 철회된 JWT도 서명과 만료만 보는 라이브러리로 검증하면 **여전히 유효하게 보입니다.** ID 토큰을 받는 쪽이 철회 여부를 따로 묻지 않으면 소용이 반쯤 없어집니다.
2. **자격 증명 풀의 `ServerSideTokenCheck`**: 이 설정을 켜면 자격 증명 풀이 OIDC 토큰이나 AWS 자격 증명을 내주기 **전에** 연결된 사용자 풀에 "이 사용자가 전역 로그아웃되거나 삭제되지 않았는지"를 확인하고, 그렇다면 `400 Not Authorized`를 돌려줍니다([API 문서](https://docs.aws.amazon.com/cognitoidentity/latest/APIReference/API_CognitoIdentityProvider.html)). 1번과 합치면, 열려 있던 화면은 아직 유효한 ID 토큰을 들고 있어도 새 자격 증명을 받지 못합니다.
3. **갱신할 때마다 정책 다시 맞추기**: 웹이 자격 증명을 갱신할 때마다 정책 맞추기 함수를 다시 부르고, 거절되면 IoT 연결을 끊고 로그아웃합니다. 로그인할 때 한 번만 부르면 열어 둔 화면이 갱신을 이어 가는 동안 이전 정책이 남을 수 있습니다.

이렇게 해도 이미 받은 자격 증명이 만료될 때까지(길어야 1시간)는 남습니다. 이 시간을 받아들일 수 없는 서비스라면 구조 자체를 다시 봐야 합니다(정리 절의 "자격 증명 풀이 필요 없는 경우").

## 그때 정한 것

처음의 대시보드로 돌아가, 위 개념에 비추어 실제로 정한 것들입니다.

- **두 풀을 다 쓴다.** 브라우저가 IoT Core에 직접 MQTT over WebSocket으로 붙기 때문입니다. 로그인은 사용자 풀(이메일·비밀번호, SRP), IoT 접속 권한은 자격 증명 풀과 IAM 역할이 맡습니다.
- **게스트를 끈다.** 로그인 없이 받는 임시 권한은 이 서비스에 쓸 곳이 없고, IoT에서는 IAM 역할만으로 권한이 정해지는 길이라 위험만 남습니다.
- **역할 신뢰 정책에 `aud`와 `amr: authenticated`를 둔다.** 내 자격 증명 풀의 로그인 사용자만 그 역할을 맡게 합니다.
- **서버 측 토큰 확인(`ServerSideTokenCheck`)을 켠다.** 전역 로그아웃이 자격 증명 갱신까지 막도록 합니다.
- **가입하면 보기 전용, 명령 권한은 관리자만 준다.** 가입 확정 트리거는 기본 그룹만 넣고, 운영자 그룹은 관리자가 지정합니다. 가입만으로 명령 권한이 생기는 길은 없습니다.
- **사용자별 차이는 IoT 정책으로 나누고, 붙이는 함수는 닫는 쪽으로 실패한다.** 사용자 식별자는 서명된 호출 정보에서만 읽습니다.
- **사용자 풀 삭제 보호를 켜고, 이메일 변경은 새 주소 인증 뒤에만 반영한다.** 실수로 풀을 지우면 모든 사용자가 사라지고, 인증 없이 이메일을 바꿀 수 있으면 가입 검사를 우회하는 길이 생깁니다.
- **MFA는 개발 단계라 생략했다.** 비밀번호만으로 로그인하는 상태이고, 명령 권한이 있는 계정부터 MFA를 붙이는 것을 열린 문제로 남겼습니다.

백엔드는 지금 SAM 템플릿에서 Amplify Gen2 + CDK로 옮기는 중이고, 위 설정은 새 구성에서도 그대로 가져갑니다.

## 정리

- **사용자 풀**은 "누구인가"를 확인하고 JWT를 줍니다. ID 토큰에는 `sub`와 `cognito:groups`가 들어 있고, 그룹에 IAM 역할을 지정하면 `cognito:roles`·`cognito:preferred_role`도 들어갑니다.
- **자격 증명 풀**은 그 토큰을 받아 **자격 증명 ID**를 정하고, 역할을 골라 **STS 임시 자격 증명**을 내줍니다. 강화 흐름(`GetId` → `GetCredentialsForIdentity`)을 쓰고, 자격 증명은 1시간 유효합니다. 기본 흐름은 앱이 역할을 고르므로 새 풀에서 켜지 않습니다.
- **게스트(비인증) 역할**은 로그인 없이 누구나 받는 권한입니다. 쓰지 않으면 끕니다.
- **역할 선택**은 기본 역할 하나, 토큰의 그룹 역할, 규칙 중에서 고릅니다. 사용자가 바꿀 수 있는 클레임으로 높은 권한을 매핑하지 않습니다.
- **역할 신뢰 정책**에는 `aud`(내 자격 증명 풀)와 `amr`(authenticated) 조건을 둡니다.
- **IoT Core**는 인증된 Cognito 자격 증명에 IAM 정책과 자격 증명 ID에 붙인 IoT 정책을 **둘 다** 요구합니다. IAM 역할은 공통 상한선, 사용자별 차이는 IoT 정책입니다. 정책을 붙이는 함수는 식별자를 서명된 호출 정보에서만 읽고 닫는 쪽으로 실패합니다.
- **권한을 내릴 때** 이미 나간 자격 증명은 만료까지 남습니다. 전역 로그아웃 + `ServerSideTokenCheck` + 갱신마다 정책 다시 맞추기로 그 시간을 최대 1시간으로 묶습니다.

마지막으로, **자격 증명 풀이 필요 없는 경우**도 있습니다. 브라우저가 AWS를 직접 부르지 않고 내 백엔드가 대신 부른다면, 브라우저는 사용자 풀의 JWT만 백엔드에 보이고 백엔드는 자기 IAM 역할로 AWS를 부르면 됩니다. 이 경우 사용자 풀만으로 충분하고, 권한을 내릴 때도 백엔드가 요청마다 판단하니 "이미 나간 자격 증명"이 생기지 않습니다. 대신 모든 메시지가 백엔드를 거치게 됩니다. 브라우저가 AWS에 직접 붙어야 하는 이유가 있을 때 자격 증명 풀을 고르고, 그때는 위의 문 두 개와 1시간을 같이 설계해야 합니다.
