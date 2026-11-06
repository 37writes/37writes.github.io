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

- **사용자 풀**: "이 사람은 누구인가"에 답합니다. 가입·로그인을 맡고, 결과로 ID·access 토큰(JWT)과 새 토큰을 받을 때 쓰는 refresh 토큰을 줍니다.
- **자격 증명 풀**: "이 사람이 어떤 AWS 리소스를 쓸 수 있나"에 답합니다. 믿을 수 있는 토큰을 받아 STS(AWS Security Token Service, 임시 AWS 자격 증명을 발급하는 서비스)의 **임시 AWS 자격 증명**으로 바꿔 줍니다.

이 시스템처럼 브라우저가 **IAM 인증(SigV4 서명)**으로 IoT Core에 직접 붙으려면, 서명에 쓸 AWS 자격 증명이 필요합니다. 사용자 풀의 JWT는 AWS 자격 증명이 아닙니다. 그래서 JWT를 AWS 자격 증명으로 바꿔 줄 자격 증명 풀이 하나 더 들어갑니다. 모든 AWS 직접 호출이 이 길을 타는 것은 아닙니다. IoT Core는 MQTT over WebSocket에서도 [사용자 지정 인증(custom authentication)](https://docs.aws.amazon.com/iot/latest/developerguide/protocols.html)을 지원하고, API Gateway는 JWT를 바로 검증하는 권한 부여자를 둘 수 있습니다. 이 글은 IAM 인증을 고른 경우를 다룹니다. "로그인했는데 왜 또 받나"의 답이 이것입니다. 로그인으로 받은 것은 신원 증명이고, AWS를 부를 열쇠는 따로 받아야 합니다.

<figure class="diagram">
{% include figures/cognito-user-pool-identity-pool/two-pools-two-gates.svg %}
<figcaption>로그인한 사용자 경로. 브라우저가 사용자 풀, 자격 증명 풀, 정책 맞추기 함수, IoT Core를 차례로 직접 부르고, IoT Core는 IAM 역할과 자격 증명 ID에 붙은 IoT 정책이 둘 다 허용해야 통과시킨다</figcaption>
</figure>

## 사용자 풀: 무엇을 내주나

사용자 풀에 로그인이 성공하면 Cognito는 세션을 만들고 [토큰 세 개](https://docs.aws.amazon.com/cognito/latest/developerguide/amazon-cognito-user-pools-using-tokens-with-identity-providers.html)를 돌려줍니다.

| 토큰 | 내용 | 주로 쓰는 곳 |
|---|---|---|
| ID 토큰 | 사용자 신원에 관한 클레임 (`sub`, 이메일 같은 속성, 그룹) | 내 앱이 사용자를 알아볼 때, **자격 증명 풀에 건넬 때** |
| access 토큰 | `scope` 같은 권한 클레임, 그룹 | API 호출, Cognito 사용자 셀프 서비스 API |
| refresh 토큰 | 암호화되어 있어 앱이 읽을 수 없음 | 새 ID·access 토큰 받기 |

클레임(claim)은 토큰 안에 든 정보 항목 하나하나를 말합니다. 이 글에서 중요한 클레임은 세 가지입니다.

- **`sub`**: 사용자 풀이 사용자마다 붙이는 고유 식별자입니다. 문서는 UUID라고 소개하지만, [ID 토큰 문서](https://docs.aws.amazon.com/cognito/latest/developerguide/amazon-cognito-user-pools-using-the-id-token.html)는 이 값이 RFC를 포함한 특정 UUID 형식을 따르지 않으니 **형식을 엄격하게 검사하지 말라**고 적어 둡니다. 불투명한 문자열로 다루면 됩니다. 뒤에 나오는 자격 증명 풀의 "자격 증명 ID"와는 **다른 값**입니다.
- **`cognito:groups`**: 사용자가 속한 [그룹](https://docs.aws.amazon.com/cognito/latest/developerguide/cognito-user-pools-user-groups.html) 목록입니다. 사용자가 그룹에 속해 있을 때 ID 토큰과 access 토큰 모두에 들어가고, 그룹이 없으면 이 클레임이 있다고 가정하면 안 됩니다. 그룹은 "보기 전용", "운영자"처럼 사용자를 묶는 이름표입니다.
- **`cognito:roles`, `cognito:preferred_role`**: 그룹에 IAM 역할을 지정해 두었을 때만 ID 토큰에 들어갑니다. 우선순위가 가장 높은 그룹이 여럿이고 역할이 서로 다르면 `cognito:preferred_role`은 생기지 않습니다. 뒤의 "역할 선택"에서 다시 봅니다.

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

여기서 "임시 자격 증명"은 `accessKeyId`, `secretAccessKey`, `sessionToken` 세 값과 만료 시각의 묶음입니다. 이 값으로 요청에 SigV4 서명을 합니다. `sessionToken`은 이름이 비슷해도 사용자 풀의 JWT와는 다른 것입니다. 사용자 풀 토큰, STS 자격 증명, 그 자격 증명으로 연 MQTT 연결은 수명도 각자 따로입니다. 하나가 끝난다고 다른 것도 같이 끝난다고 가정하지 않습니다.

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

이 공급자가 다시 해 주는 것은 AWS 자격 증명 발급까지입니다. 문자열로 넘긴 ID 토큰을 사용자 풀에서 새로 받아 오지는 않습니다. ID 토큰이 만료되면 로그인 쪽 코드가 refresh 토큰으로 새 ID 토큰을 받아 공급자를 다시 만들어야 합니다. 만료된 ID 토큰으로는 자격 증명을 다시 받을 수 없습니다.

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

토큰에서 고르는 방식은 이렇게 동작합니다. 그룹마다 우선순위(precedence)를 둘 수 있고, 숫자가 가장 작은 그룹의 역할이 `cognito:preferred_role`에 들어갑니다. 우선순위가 가장 높은 그룹이 여럿이고 그 역할이 서로 다르면 `cognito:preferred_role`이 비어 있습니다. 이렇게 역할 후보가 여럿이면, 앱이 `GetCredentialsForIdentity`의 `CustomRoleArn`으로 `cognito:roles` 안의 하나를 고를 수 있습니다. 목록에 없는 역할을 요청하면 거부됩니다. 아무것도 정할 수 없을 때는 **역할 확인(Role resolution)** 설정(`AmbiguousRoleResolution`)에 따라 기본 인증 역할을 주거나(`AuthenticatedRole`) 요청을 거부합니다(`Deny`). 규칙 방식에서 맞는 규칙이 없을 때도 같은 설정을 따릅니다.

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

그룹마다 IAM 역할을 따로 두고 토큰으로 역할을 고르는 방법도 있습니다. 하지만 IoT Core는 그 경우에도 자격 증명 ID에 IoT 정책이 붙어 있기를 요구합니다. 인증된 Cognito 자격 증명으로 IoT Core에 붙는 한 **누군가 그 자격 증명 ID에 IoT 정책을 붙이는 단계는 어차피 필요**합니다. 그래서 이 시스템은 역할 매핑 없이 기본 인증 역할 하나를 상한선으로 두고, 사용자별 차이는 IoT 정책으로만 나누었습니다.

### 정책을 붙이는 함수가 지켜야 할 것

[AWS IoT 개발자 가이드](https://docs.aws.amazon.com/iot/latest/developerguide/cog-iot-policies.html)에는 앱이 로그인 직후 `AttachPolicy`를 직접 부르는 예시도 있습니다. 모든 사용자에게 같은 정책 하나를 붙이는 구조라면 그것도 한 방법입니다. 이 글처럼 **그룹에 따라 운영자 정책을 고르고 떼야 하는** 구조에서는 판단을 클라이언트에 두기 어렵습니다. 어떤 정책을 붙일지 클라이언트가 고르게 하려면 역할에 운영자 정책 부착 권한까지 열어야 하기 때문입니다. 그래서 판단을 서버 함수 하나에 모으고, 로그인 직후 브라우저가 그 함수를 부르게 했습니다. 이 함수가 하는 일은 세 줄로 요약됩니다.

1. 호출자가 누구인지 확인한다 (자격 증명 ID와 사용자 풀 `sub`)
2. 사용자 풀에서 그 사람의 그룹을 조회한다
3. 그 자격 증명 ID에 붙은 IoT 정책을 그룹에 맞게 **맞춘다** (필요한 것만 붙이고 나머지는 뗀다)

가장 중요한 것은 1번입니다. **사용자 식별자를 요청 본문에서 읽으면 안 됩니다.** 본문은 클라이언트가 마음대로 쓸 수 있으니, 남의 자격 증명 ID를 적어 보내면 남의 권한을 바꿀 수 있습니다.

이 함수를 API Gateway 뒤에 두고 IAM 권한 부여(SigV4)를 켜면, API Gateway가 서명을 확인한 뒤 호출자의 Cognito 정보를 요청 컨텍스트에 넣어 줍니다. [API Gateway 컨텍스트 변수 문서](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-logging-variables.html) 기준으로 `cognitoIdentityId`에는 호출자의 자격 증명 ID가, `cognitoAuthenticationProvider`에는 `cognito-idp.<리전>.amazonaws.com/<풀 ID>,cognito-idp.<리전>.amazonaws.com/<풀 ID>:CognitoSignIn:<sub>` 형태로 사용자 풀의 `sub`가 들어 있습니다. 서명된 요청에서 AWS가 채운 값이라 클라이언트가 바꿀 수 없습니다.

핵심만 의사 코드에 가깝게 쓰면 이렇습니다(이 글을 위해 새로 쓴 예시, 실행 미확인, Lambda 프록시 페이로드 1.0의 필드 위치 기준).

```python
POLICY_FOR = {"operator": "web-operator", "viewer": "web-viewer"}  # 그룹 → IoT 정책 이름
WEB_POLICIES = set(POLICY_FOR.values())
MY_USER_POOL = "cognito-idp.ap-northeast-2.amazonaws.com/ap-northeast-2_EXAMPLE"

def handler(event, context):
    ident = event["requestContext"]["identity"]      # API Gateway가 서명 확인 뒤 채운 값
    identity_id = ident.get("cognitoIdentityId")
    provider = ident.get("cognitoAuthenticationProvider") or ""
    pool_part, _, sub = provider.rpartition(":CognitoSignIn:")
    # 본문은 읽지 않는다. 내 사용자 풀의 로그인인지, 값이 비어 있지 않은지만 본다
    if not identity_id or not sub or not pool_part.endswith(MY_USER_POOL):
        return deny("no_identity")

    try:
        groups = groups_of_user(sub)   # ListUsers 필터 'sub = "..."'에 넣을 때 따옴표·역슬래시를 이스케이프
    except Exception:
        try:
            detach(identity_id, attached(identity_id) & WEB_POLICIES)  # 기존 정책 제거를 시도
        except Exception:
            alert("detach_failed", identity_id)  # 제거도 실패: 이전 정책이 남아 있을 수 있다
        return deny("lookup_failed")

    wanted = {POLICY_FOR[g] for g in pick_strongest(groups)}   # 0개 또는 1개
    current = attached(identity_id)
    detach(identity_id, (current & WEB_POLICIES) - wanted)      # 먼저 떼고
    attach(identity_id, wanted - current)                       # 그다음 붙인다
    return ok() if wanted else deny("not_approved")
```

`sub`는 형식을 검사하지 않고 불투명한 문자열로 다룹니다. 대신 두 가지를 확인합니다. 하나는 이 값이 **내 사용자 풀**의 로그인에서 왔는지(공급자 문자열 앞부분)이고, 다른 하나는 비어 있지 않은지입니다. `sub`로 사용자를 찾을 때 쓰는 [`ListUsers`](https://docs.aws.amazon.com/cognito-user-identity-pools/latest/APIReference/API_ListUsers.html)의 필터는 `sub = "값"` 형태의 문자열이고, 문서는 값 안의 따옴표를 역슬래시로 이스케이프하라고 합니다. 필터가 비면 모든 사용자를 돌려준다는 점도 적혀 있으니 빈 값은 먼저 막습니다.

떼기를 붙이기보다 먼저 하는 것은 강등할 때 두 정책이 같이 붙어 있는 구간을 줄이기 위해서입니다. 그룹을 확인하지 못하면 새 권한은 주지 않고, 이미 붙은 웹용 정책을 떼어 보려 합니다. 권한 확인이 실패했을 때 열어 두는 쪽이 아니라 **닫는 쪽으로** 기울이는 것입니다. 이렇게 하면 함수 자신에게 필요한 권한도 `iot:AttachPolicy`·`iot:DetachPolicy`·`iot:ListAttachedPolicies`와 사용자 풀 조회 정도로 좁힙니다.

다만 이 의사 코드가 보장하지 **못하는** 것이 있습니다.

- **제거 실패**: 그룹 조회도 정책 떼기도 실패하면 API는 거절하지만 이전 정책은 그대로 남습니다. 경보를 보고 다시 시도하거나 사람이 처리하는 절차가 따로 있어야 합니다.
- **비원자성**: 떼기와 붙이기는 별개의 API 호출입니다. 중간에 함수가 끊기거나, 같은 자격 증명 ID로 함수가 동시에 두 번 돌면 결과가 엇갈릴 수 있습니다. 순서만으로 "권한이 커지는 순간이 없다"를 보장하지는 못합니다.
- **전파 지연**: [AWS IoT 정책 문서](https://docs.aws.amazon.com/iot/latest/developerguide/iot-policies.html)는 IoT가 정책 문서를 캐시하기 때문에 정책 변경이 적용되기까지 6~8분이 걸릴 수 있고, 권한을 거둔 뒤에도 몇 분 동안 접근이 될 수 있다고 적습니다. 정책을 뗀 순간 권한이 사라진다고 가정하면 안 됩니다.

## 권한을 내릴 때: 무엇이 막히고 무엇이 남나

운영자를 보기 전용으로 내리는 순간을 생각해 봅니다. 관리자가 사용자 풀에서 그룹을 바꿔도 IoT 쪽 권한은 곧바로 줄지 않습니다. 남아 있는 것은 세 가지입니다.

1. **자격 증명 ID에 붙은 IoT 정책**: 정책은 사용자 풀의 그룹이 아니라 자격 증명 ID에 붙어 있습니다. 위 함수가 다시 돌기 전까지는 운영자 정책이 그대로 남습니다.
2. **이미 발급된 임시 자격 증명**: 강화 흐름의 자격 증명은 1시간 유효하고, 만료 전에 이 키 하나만 골라 지우는 API는 없습니다.
3. **이미 열린 MQTT 연결**: [AWS IoT 프로토콜 문서](https://docs.aws.amazon.com/iot/latest/developerguide/protocols.html#connection-duration-limits)는 SigV4로 연 연결의 최대 지속 시간을 "최대 24시간, 보장 안 됨"으로 적습니다. 자격 증명이 1시간 뒤 만료된다고 해서 그 자격 증명으로 연 연결이 1시간 안에 끊긴다고 할 근거는 없습니다. 이 관계는 직접 재 보지 않았습니다.

### 키를 지울 수는 없어도 권한은 바꿀 수 있다

2번은 "키를 지울 수 없다"는 뜻이지 "그 키로 하는 일을 막을 수 없다"는 뜻이 아닙니다. [IAM 문서](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp_control-access_disable-perms.html)대로 임시 자격 증명의 권한은 요청마다 다시 평가되므로, 정책을 바꾸면 이미 나간 키의 권한도 달라집니다. 방법은 범위에 따라 갈립니다.

- **역할 전체**: IAM 콘솔의 [활성 세션 취소](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_revoke-sessions.html)는 특정 시각 이전에 발급된 그 역할의 **모든** 세션을 거부하는 정책(`aws:TokenIssueTime` 조건의 Deny)을 붙입니다. 로그인 사용자 모두가 같은 역할을 쓰는 구조에서는 모두가 한꺼번에 막히므로 비상 수단입니다.
- **특정 세션이나 사용자**: 같은 IAM 문서는 조건 키로 특정 역할 세션만 거부하는 방법도 설명합니다. Cognito의 [접근 정책](https://docs.aws.amazon.com/cognito/latest/developerguide/iam-roles.html#access-policies)에서는 `cognito-identity.amazonaws.com:sub`(자격 증명 ID)를 조건에 쓸 수 있습니다. 다만 이 조건이 이 글의 IoT 동작 전부에 그대로 먹히는지는 확인하지 않았습니다.
- **IoT 정책**: 이 구조에서 가장 자연스러운 방법입니다. 관리자가 강등하는 처리 안에서 서버가 그 사용자의 자격 증명 ID에서 운영자 정책을 **직접 떼는** 것입니다. 사용자가 다시 함수를 부르기를 기다리지 않아도 됩니다.

어느 쪽이든 앞에서 본 전파 지연과 이미 열린 연결 문제가 남으므로 "즉시 차단"은 아닙니다. 기존 연결을 끊는 수단을 더하더라도, 연결을 끊는 것만으로 다시 붙는 것까지 막히지는 않습니다. 정책이 바뀌어 있어야 다시 붙었을 때 막힙니다.

### 이 시스템이 한 것과 그 한계

이 시스템은 정책을 사용자 쪽 호출로 맞추는 방식을 골랐고, 그 위에 다음을 더했습니다.

1. **전역 로그아웃**: `AdminUserGlobalSignOut`은 대상 사용자의 refresh·ID·access 토큰을 모두 철회합니다([토큰 철회 문서](https://docs.aws.amazon.com/cognito/latest/developerguide/token-revocation.html)). 그런데 같은 문서가 짚듯이, 철회된 JWT도 서명과 만료만 보는 라이브러리로 검증하면 **여전히 유효하게 보입니다.**
2. **자격 증명 풀의 `ServerSideTokenCheck`**: 이 설정을 켜면 자격 증명 풀이 OIDC 토큰이나 AWS 자격 증명을 내주기 **전에** 연결된 사용자 풀에 "이 사용자가 전역 로그아웃되거나 삭제되지 않았는지"를 확인하고, 그렇다면 `400 Not Authorized`를 돌려줍니다([API 문서](https://docs.aws.amazon.com/cognitoidentity/latest/APIReference/API_CognitoIdentityProvider.html)). 1번과 합치면 **철회된 기존 토큰으로는 새 자격 증명을 받지 못합니다.**
3. **갱신할 때마다 정책 다시 맞추기**: 웹이 자격 증명을 갱신할 때마다 정책 맞추기 함수를 다시 부르고, 거절되면 IoT 연결을 끊고 로그아웃합니다.

이 조합으로 말할 수 있는 것은 여기까지입니다. **정상 클라이언트는 다음 동기화 때 강등됩니다.** 전역 로그아웃은 계정의 새 로그인까지 막지는 않습니다. 강등된 사용자가 다시 로그인하면 새 ID 토큰을 받고, 같은 자격 증명 ID로 공통 역할의 자격 증명을 다시 받습니다. 이때 정책 맞추기 함수를 건너뛰고 IoT에 바로 붙으면, 아직 떼지 않은 운영자 정책이 그대로 적용됩니다. 위 장치 중 자격 증명 발급과 정책 동기화를 하나로 묶거나 동기화를 강제하는 것은 없습니다. 그래서 **함수를 건너뛰는 클라이언트까지 포함한 강등 시간의 상한은 보장되지 않습니다.** 1시간이라는 숫자는 키 하나의 수명일 뿐 강등이 끝나는 시각이 아닙니다.

이 상한이 필요하다면 강등을 사용자 쪽 호출에 맡기지 말고 관리자 처리에서 서버가 정책을 직접 떼야 합니다. 그래도 전파 지연과 기존 연결은 남으니 그 시간은 따로 다뤄야 합니다. 그런 시간도 받아들일 수 없다면 구조 자체를 다시 봐야 합니다(정리 절의 "자격 증명 풀이 필요 없는 경우").

## 그때 정한 것

처음의 대시보드로 돌아가, 위 개념에 비추어 실제로 정한 것들입니다.

- **두 풀을 다 쓴다.** 브라우저가 IoT Core에 직접 MQTT over WebSocket으로 붙기 때문입니다. 로그인은 사용자 풀(이메일·비밀번호, SRP: 비밀번호를 서버로 보내지 않고 증명하는 인증 프로토콜), IoT 접속 권한은 자격 증명 풀과 IAM 역할이 맡습니다.
- **게스트를 끈다.** 로그인 없이 받는 임시 권한은 이 서비스에 쓸 곳이 없고, IoT에서는 IAM 역할만으로 권한이 정해지는 길이라 위험만 남습니다.
- **역할 신뢰 정책에 `aud`와 `amr: authenticated`를 둔다.** 내 자격 증명 풀의 로그인 사용자만 그 역할을 맡게 합니다.
- **서버 측 토큰 확인(`ServerSideTokenCheck`)을 켠다.** 전역 로그아웃한 기존 토큰으로는 새 자격 증명을 받지 못하게 합니다.
- **가입하면 보기 전용, 명령 권한은 관리자만 준다.** 가입 확정 트리거는 기본 그룹만 넣고, 운영자 그룹은 관리자가 지정합니다. 가입만으로 명령 권한이 생기는 길은 없습니다.
- **사용자별 차이는 IoT 정책으로 나누고, 붙이는 함수는 닫는 쪽으로 실패한다.** 사용자 식별자는 서명된 호출 정보에서만 읽습니다.
- **사용자 풀 삭제 보호를 켜고, 이메일 변경은 새 주소 인증 뒤에만 반영한다.** 실수로 풀을 지우면 모든 사용자가 사라지고, 인증 없이 이메일을 바꿀 수 있으면 가입 검사를 우회하는 길이 생깁니다.
- **강등은 갱신 때 다시 맞추는 방식으로 했다.** 이번에 정리하며 알게 된 주의점이 여기 있습니다. 이 방식은 정상 클라이언트를 다음 동기화 때 강등할 뿐이고, 함수를 건너뛰고 다시 로그인해 IoT에 붙는 클라이언트에게는 강등이 언제 끝난다고 말할 수 없습니다. 처음에는 "전역 로그아웃 + 서버 측 토큰 확인 + 갱신마다 재동기화면 길어야 1시간"으로 정리해 두었는데, 그 1시간은 보장이 아니었습니다. 관리자 강등 처리에서 서버가 정책을 직접 떼는 단계를 더하는 것을 남은 일로 둡니다.
- **MFA는 개발 단계라 생략했다.** 비밀번호만으로 로그인하는 상태이고, 명령 권한이 있는 계정부터 MFA를 붙이는 것을 열린 문제로 남겼습니다.

백엔드는 지금 SAM 템플릿에서 Amplify Gen2 + CDK로 옮기는 중이고, 위 설정은 새 구성에서도 그대로 가져갑니다.

## 정리

- **사용자 풀**은 "누구인가"를 확인하고 JWT를 줍니다. ID 토큰에는 `sub`(형식을 가정하지 않는 불투명 문자열)와, 그룹에 속해 있으면 `cognito:groups`가 들어 있고, 그룹에 IAM 역할을 지정하면 `cognito:roles`·`cognito:preferred_role`도 들어갑니다.
- **자격 증명 풀**은 그 토큰을 받아 **자격 증명 ID**를 정하고, 역할을 골라 **STS 임시 자격 증명**(access key·secret key·session token)을 내줍니다. 강화 흐름(`GetId` → `GetCredentialsForIdentity`)을 쓰고, 자격 증명은 1시간 유효합니다. 기본 흐름은 앱이 역할을 고르므로 새 풀에서 켜지 않습니다.
- **게스트(비인증) 역할**은 로그인 없이 누구나 받는 권한입니다. 쓰지 않으면 끕니다.
- **역할 선택**은 기본 역할 하나, 토큰의 그룹 역할, 규칙 중에서 고릅니다. 사용자가 바꿀 수 있는 클레임으로 높은 권한을 매핑하지 않습니다.
- **역할 신뢰 정책**에는 `aud`(내 자격 증명 풀)와 `amr`(authenticated) 조건을 둡니다.
- **IoT Core**는 인증된 Cognito 자격 증명에 IAM 정책과 자격 증명 ID에 붙인 IoT 정책을 **둘 다** 요구합니다. IAM 역할은 공통 상한선, 사용자별 차이는 IoT 정책입니다. 정책을 붙이는 함수는 식별자를 서명된 호출 정보에서만 읽고 닫는 쪽으로 실패합니다.
- **권한을 내릴 때** 이미 나간 키는 지울 수 없지만 권한은 정책으로 바꿀 수 있습니다. 전역 로그아웃 + `ServerSideTokenCheck`는 철회된 토큰으로 새 자격 증명을 받는 길을 막고, 갱신마다 재동기화는 정상 클라이언트를 다음 동기화 때 강등합니다. 함수를 건너뛰는 클라이언트까지 막는 상한은 이것만으로는 없고, 서버가 정책을 직접 떼더라도 IoT 정책 전파 지연과 이미 열린 연결은 따로 고려합니다.

마지막으로, **자격 증명 풀이 필요 없는 경우**도 있습니다. 자격 증명 풀은 브라우저가 IAM 인증으로 AWS에 직접 붙는 경우의 도구이고, 브라우저 직접 접속의 유일한 방법도 아닙니다(IoT Core의 사용자 지정 인증 같은 길도 있습니다). 브라우저가 AWS를 직접 부르지 않고 내 백엔드가 대신 부른다면, 브라우저는 사용자 풀의 JWT만 백엔드에 보이고 백엔드는 자기 IAM 역할로 AWS를 부르면 됩니다. 이 경우 사용자 풀만으로 충분하고, 권한을 내릴 때도 백엔드가 요청마다 판단하니 브라우저 손에 "이미 나간 AWS 자격 증명"이 생기지 않습니다. 대신 모든 메시지가 백엔드를 거치게 됩니다. 브라우저가 AWS에 직접 붙어야 하는 이유가 있을 때 자격 증명 풀을 고르고, 그때는 위의 문 두 개와 강등 경로를 같이 설계해야 합니다.
