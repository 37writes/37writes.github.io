---
title: "인증 한 번에 정리: JWT, IAM(SigV4), Cognito는 각각 무엇을 증명하나"
date: 2026-11-01 22:30:00 +0900
categories: [AWS, 보안]
tags: [auth, jwt, iam, sigv4, cognito, oauth, bedrock, agentcore]
description: "AI 에이전트에 웹 검색을 붙이다 만난 'IAM 인증 vs JWT 인증' 선택지에서 출발해, 인증과 인가, JWT 구조와 검증, IAM 정책과 SigV4 서명, Cognito user pool과 identity pool을 정리하고 셋을 엮은 서비스 구조와 실제로 겪은 IAM 함정까지 다룹니다."
---

개발용 AI 에이전트에 웹 검색 도구를 붙이려고 했습니다. 에이전트는 Claude Code이고 모델은 Amazon Bedrock으로 부릅니다. 검색 도구는 AWS Bedrock AgentCore Gateway에 AWS가 제공하는 Web Search 커넥터를 꽂아서 쓰는 구조입니다.

Gateway를 만들려고 하니 첫 설정부터 **인바운드 인증**을 고르라고 합니다. 선택지는 `AWS_IAM`, `CUSTOM_JWT`, `AUTHENTICATE_ONLY`, `NONE` 네 개입니다. 지금은 저 혼자 쓰니 IAM으로 정했습니다. 내 컴퓨터의 로컬 프록시(`mcp-proxy-for-aws`)가 이미 가진 AWS 키로 SigV4 서명을 붙여 Gateway를 부르는 구성입니다. 그런데 나중에 이것을 **사람들이 로그인해서 쓰는 웹·앱 서비스**로 만들고 싶어졌고, 그 순간 질문이 생겼습니다.

> 로그인은 Cognito로 하고, 토큰은 JWT로 받고, 서버는 IAM으로 부른다는데… 그래서 셋은 각각 무엇을 증명하는 건가?

이 글은 그 질문에 대한 답입니다. 인증과 인가의 차이에서 시작해 JWT, IAM(SigV4 서명), Cognito를 차례로 설명하고, 마지막에 셋을 엮은 서비스 구조와 실제로 겪은 IAM 함정을 정리합니다.

## 인증과 인가: "누구야"와 "해도 돼"

먼저 두 단어를 나눠 둡니다.

- **인증(Authentication)**: "너 누구야?"에 답하는 일입니다. 로그인, 서명 확인이 여기에 속합니다.
- **인가(Authorization)**: "너 이거 해도 돼?"에 답하는 일입니다. 정책, 권한, scope가 여기에 속합니다.

둘은 보통 연달아 일어나지만 따로 실패합니다. 신원은 맞는데 권한이 없으면 HTTP에서는 `403 Forbidden`, 신원부터 확인이 안 되면 `401 Unauthorized`가 일반적입니다. 이 글에 나오는 JWT, IAM, Cognito는 모두 이 두 질문에 답하는 도구인데, **증명하는 방식**이 다릅니다.

## 증명 방식은 크게 두 가지

서버에 "나 이 사람(이 프로그램)이야"를 증명하는 방법은 크게 두 갈래입니다.

**토큰을 들고 다니는 방식 (bearer token, 대표적으로 JWT).** bearer는 토큰 형식이 아니라 "가진 사람을 믿는다"는 사용 방식이고, JWT는 그런 토큰에 많이 쓰는 형식입니다. 로그인하면 발급자가 서명한 토큰을 받고, 요청마다 그 토큰을 그대로 보여 줍니다(`Authorization: Bearer <토큰>`). 받는 쪽은 발급자의 서명이 맞는지, 만료되지 않았는지, 자기에게 발급된 토큰인지를 봅니다. 구조가 단순한 대신, 토큰 자체가 열쇠입니다. **새어 나가면 만료될 때까지 누구나 그 토큰으로 요청할 수 있습니다.**

**요청마다 서명하는 방식 (AWS SigV4).** 비밀키는 내 쪽에만 두고, 요청 내용(메서드, 경로, 헤더, 본문 해시, 시각)에 대한 서명만 보냅니다. 받는 쪽(AWS)은 같은 계산을 다시 해서 서명이 맞는지 봅니다. 서명은 그 요청 내용에 묶여 있어서 요청을 바꾸면 맞지 않고, 대부분의 경우 서명 시각으로부터 5분 안에 도착해야 받아 줍니다. **서명이 새어 나가도 쓸 수 있는 범위가 그 요청 내용, 짧은 시간으로 좁습니다.** 다만 허용 시간 안에 똑같은 요청을 다시 보내는 것까지 막지는 않습니다.

<figure class="diagram">
{% include figures/auth-basics-jwt-iam-cognito/token-vs-signature.svg %}
<figcaption>JWT는 토큰 자체를 보여 주고, SigV4는 비밀키 대신 요청마다 만든 서명을 보낸다</figcaption>
</figure>

이 차이가 뒤에서 이 글의 설계인 "사람은 JWT, 서버는 IAM"으로 이어집니다. 브라우저나 앱에 장기 AWS 비밀키를 넣을 수는 없으니 이 설계에서는 사람 쪽이 토큰을 쓰고, 역할의 임시 자격 증명을 안전하게 둘 수 있는 서버 쪽이 서명을 씁니다. 다른 길도 있습니다. 클라이언트가 Cognito identity pool에서 임시 자격 증명을 받아 직접 SigV4로 부를 수도 있고, 서버끼리 OAuth client credentials로 받은 JWT를 쓸 수도 있습니다.

## JWT: 서명된 JSON 쪽지

### 구조

이 글은 Cognito가 발급하는 **서명된 JWT(JWS)**를 다룹니다. 암호화된 JWE 형식도 있지만 여기서는 제외합니다.

JWT(JSON Web Token, [RFC 7519](https://www.rfc-editor.org/rfc/rfc7519))는 점(`.`)으로 나뉜 세 부분입니다.

```text
header.payload.signature
```

- **header**: 서명 알고리즘(`alg`)과 서명 키 ID(`kid`). Cognito는 `RS256`으로 서명합니다.
- **payload**: 클레임(claim)이라 부르는 정보 묶음. 누가, 누구에게서, 언제까지 유효한지가 들어갑니다.
- **signature**: 발급자가 비밀키로 header와 payload에 서명한 값.

header와 payload는 **base64url로 인코딩한 JSON**입니다. 공백 없이 `{"`로 시작하는 JSON이면 보통 `eyJ`로 시작합니다.

RFC 7519가 정한 표준 클레임은 이렇습니다.

| 클레임 | 뜻 |
|---|---|
| `iss` | 발급자 (issuer) |
| `sub` | 주체, 보통 사용자 ID (subject) |
| `aud` | 이 토큰을 받을 대상 (audience) |
| `exp` | 만료 시각 (Unix 초) |
| `nbf` | 이 시각 전에는 무효 (not before) |
| `iat` | 발급 시각 (issued at) |
| `jti` | 토큰 고유 ID |

### payload는 암호화가 아니다

가장 많이 하는 오해가 "JWT는 암호화된 토큰"이라는 생각입니다. base64url은 **인코딩**이라 누구나 풀 수 있습니다. 직접 해 보면 바로 보입니다. 아래 토큰은 이 글을 위해 만든 가짜 토큰입니다.

```python
# jwt_peek.py: 서명 검증 없이 JWT의 header와 payload를 읽기만 한다
import base64, json, sys

def b64url_decode(part: str) -> bytes:
    return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))  # 빠진 패딩 채우기

header, payload, signature = sys.argv[1].split(".")
print(json.loads(b64url_decode(header)))
print(json.dumps(json.loads(b64url_decode(payload)), indent=2))
```

```console
$ python3 jwt_peek.py eyJraWQiOiJleGFtcGxlLWtpZCIsImFsZyI6IlJTMjU2In0.eyJzdWIiOiJ1c2VyLWExYjJjMyIsImlzcyI6Imh0dHBzOi8vY29nbml0by1pZHAuYXAtbm9ydGhlYXN0LTIuYW1hem9uYXdzLmNvbS9hcC1ub3J0aGVhc3QtMl9FWEFNUExFIiwiY2xpZW50X2lkIjoiZXhhbXBsZWNsaWVudCIsInRva2VuX3VzZSI6ImFjY2VzcyIsInNjb3BlIjoib3BlbmlkIiwiaWF0IjoxNzkzNTAwMDAwLCJleHAiOjE3OTM1MDM2MDB9.c2lnbmF0dXJlLW5vdC1yZWFs
{'kid': 'example-kid', 'alg': 'RS256'}
{
  "sub": "user-a1b2c3",
  "iss": "https://cognito-idp.ap-northeast-2.amazonaws.com/ap-northeast-2_EXAMPLE",
  "client_id": "exampleclient",
  "token_use": "access",
  "scope": "openid",
  "iat": 1793500000,
  "exp": 1793503600
}
```

키 없이 내용이 다 보입니다. 그러니 **payload에 비밀번호 같은 비밀값은 넣지 않습니다.** 개인정보는 필요한 것만 담고, 토큰이 어디까지 전달되고 기록되는지 의식합니다(Cognito ID 토큰은 `email` 같은 사용자 속성을 담습니다). 그리고 읽을 수 있다는 것은 고칠 수도 있다는 뜻입니다. `sub`를 남의 ID로 바꿔 다시 인코딩하는 것은 몇 줄이면 됩니다. Cognito 문서도 JWT는 쉽게 디코드되고 수정될 수 있으며, 수정된 access 토큰은 권한 상승, 수정된 ID 토큰은 사칭으로 이어질 수 있다고 경고합니다.

위조를 막는 것은 **세 번째 부분, 서명**입니다. payload를 한 글자라도 바꾸면 서명이 맞지 않습니다. 디코드는 "읽기"일 뿐이고, 서버가 믿어도 되는지는 **검증**으로만 알 수 있습니다.

### 서버가 검증할 것

Cognito가 발급한 토큰을 받는 서버라면 [Cognito의 JWT 검증 문서](https://docs.aws.amazon.com/cognito/latest/developerguide/amazon-cognito-user-pools-using-tokens-verifying-a-jwt.html) 기준으로 다음을 확인합니다.

1. **서명**: user pool의 공개키 목록(JWKS)에서 header의 `kid`와 같은 키를 찾아 서명을 확인합니다. JWKS 주소는 `https://cognito-idp.<리전>.amazonaws.com/<userPoolId>/.well-known/jwks.json`입니다. 키는 교체될 수 있으니 `kid`를 키로 캐시하고 주기적으로 새로 받습니다.
2. **`exp`**: 지금 시각보다 뒤인지. 토큰 안에 들어 있어서 Cognito에 묻지 않고 확인할 수 있습니다.
3. **`iss`**: 내 user pool 주소와 같은지. 다른 풀, 다른 리전에서 발급한 토큰을 걸러냅니다.
4. **대상**: ID 토큰은 `aud`, access 토큰은 `client_id`가 내 앱 클라이언트 ID와 같은지.
5. **`token_use`**: API에서 access 토큰만 받기로 했다면 값이 `access`인지.

빠지기 쉬운 것이 하나 더 있습니다. **서명과 `exp`가 맞아도, 그 사이 로그아웃이나 철회가 있었는지는 알 수 없습니다.** 토큰이 스스로 유효 기간을 들고 다니는 구조라서, 오프라인 검증만으로는 철회를 감지하지 못합니다. access 토큰 수명을 짧게 두면 새어 나간 토큰이 통하는 시간이 줄어들지만, 이것은 피해를 줄이는 완화책입니다. 즉시 막아야 한다면 서버 쪽에 세션이나 철회 상태를 따로 두고 요청마다 확인해야 합니다.

## IAM: 누가, 무엇을, 어디에

### 정책의 세 요소

AWS IAM은 "**누가(Principal)** **무엇을(Action)** **어디에(Resource)** 할 수 있나"를 JSON 정책으로 정합니다. 주체에는 사람이 쓰는 **IAM 사용자**, 서버나 다른 계정이 맡는 **역할(Role)**, 그리고 AWS 서비스가 대신 일할 때 맡는 **서비스 역할**(예: Gateway가 커넥터를 부를 때 맡는 역할)이 있습니다.

예를 들어 "이 주체는 이 Gateway 하나만 호출할 수 있다"는 정책은 이렇게 씁니다. 호출할 사용자·역할에 붙이는 identity-based 정책이라 `Principal`이 없고, 붙인 대상이 곧 주체입니다. 계정 ID와 Gateway ID는 예시 값입니다.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "InvokeOneGateway",
      "Effect": "Allow",
      "Action": "bedrock-agentcore:InvokeGateway",
      "Resource": "arn:aws:bedrock-agentcore:ap-northeast-1:123456789012:gateway/my-gateway-12345"
    }
  ]
}
```

`Resource`를 `*`로 두지 않고 Gateway 하나로 좁힌 것이 핵심입니다. AgentCore 문서도 Gateway를 만든 뒤에는 Resource를 그 Gateway로 좁히라고 권합니다.

### 평가 규칙: 기본은 거부, Deny가 이긴다

[IAM 정책 평가 로직](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic_policy-eval-denyallow.html)에서 꼭 기억할 것은 두 가지입니다.

- **기본은 거부입니다(암묵적 거부).** 정책 어디에도 허용이 없으면 거부됩니다. (루트 사용자만 예외입니다.)
- **명시적 `Deny`는 `Allow`를 이깁니다.** 여러 정책 중 하나라도 이 요청을 `Deny`하면 다른 곳의 `Allow`와 상관없이 거부됩니다.

이 글에서 겪은 IAM 문제도 "허용을 빠뜨린 것"이었습니다. 뒤의 "주의할 점"에서 그 사례를 다룹니다.

### SigV4: IAM 자격 증명으로 요청에 서명하기

IAM 정책이 "누가 무엇을 해도 되는지"라면, [SigV4(Signature Version 4)](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv.html)는 "이 요청을 보낸 게 정말 그 주체인지"를 증명하는 서명 프로토콜입니다. AWS CLI와 SDK가 매 요청마다 자동으로 해 주고 있어서 평소에는 보이지 않습니다.

과정은 이렇습니다.

1. **canonical request**: 메서드, 경로, 쿼리, 서명할 헤더, 본문 해시를 정해진 형식으로 한 줄씩 늘어놓습니다.
2. **서명 키 만들기**: 비밀 액세스 키에서 출발해 **날짜 → 리전 → 서비스** 순서로 범위를 좁힌 키를 파생합니다. 그래서 같은 키라도 리전과 날짜가 다르면 서명이 다릅니다.
3. **서명 계산 후 헤더에 붙이기**: 결과를 `Authorization` 헤더로 보냅니다.

```text
Authorization: AWS4-HMAC-SHA256
  Credential=AKIDEXAMPLE/20261101/<리전>/<서비스>/aws4_request,
  SignedHeaders=host;x-amz-date,
  Signature=<요청마다 다른 값>
```

보기 좋게 줄을 나눴지만 실제로는 한 줄 문자열입니다. 역할의 임시 자격 증명으로 서명하면 `X-Amz-Security-Token` 헤더도 함께 붙습니다.

받은 쪽은 같은 계산을 다시 해서 서명을 비교합니다. 이 과정 덕분에 세 가지가 보장됩니다.

- **신원 확인**: 비밀 액세스 키를 가진 사람만 맞는 서명을 만들 수 있습니다. 비밀키 자체는 네트워크로 나가지 않습니다.
- **변조 방지**: 서명에 포함된 요청 요소(메서드, 경로, 서명한 헤더, 본문 해시)를 중간에 바꾸면 서명이 맞지 않습니다.
- **재전송 공격 완화**: 대부분의 경우 요청이 서명 시각으로부터 5분 안에 도착해야 합니다. 서명은 요청 내용에 묶이지만, 그 시간 안에 같은 요청을 다시 보내는 것까지 막지는 않습니다.

JWT와 비교하면, JWT는 "발급자가 이 사람을 보증한다"는 **쪽지**이고 SigV4는 "이 요청을 내가 지금 보냈다"는 **도장**입니다.

## Cognito: 로그인 담당과 AWS 자격 증명 교환 담당

Amazon Cognito는 이름 하나에 부품이 두 개 들어 있습니다. [공식 개요](https://docs.aws.amazon.com/cognito/latest/developerguide/what-is-amazon-cognito.html)도 두 부품이 서로 다른 질문에 답한다고 설명합니다.

| | User pool | Identity pool |
|---|---|---|
| 답하는 질문 | 이 사용자는 누구인가 (인증) | 이 사용자가 어떤 AWS 리소스에 갈 수 있나 (AWS 인가) |
| 하는 일 | 회원가입·로그인, 사용자 디렉터리, OIDC 발급자로서 JWT 발급 | 신뢰하는 토큰을 받아 STS의 임시 AWS 자격 증명으로 교환 |
| 내주는 것 | ID 토큰, access 토큰, refresh 토큰 | 권한이 제한된 임시 AWS 자격 증명 |
| 쓰는 때 | 내 앱·API에 로그인을 붙일 때 | 앱이 S3, DynamoDB 같은 AWS 서비스를 **직접** 부를 때 |

User pool은 구글·애플 같은 소셜 로그인, 기업 SAML·OIDC 연동, MFA도 맡습니다. 어느 방식으로 로그인했든 앱이 받는 ID·access 토큰은 Cognito가 발급한 같은 형식의 JWT라서, 백엔드는 검증 코드 하나만 두면 됩니다. refresh 토큰은 새 토큰을 받을 때만 쓰는 값이라 앱이 내용을 읽지 않습니다.

**둘은 서로 없어도 쓸 수 있습니다.** 내 백엔드만 요청을 받고 AWS 호출은 백엔드가 한다면 user pool만으로 충분합니다. 브라우저가 S3에 직접 올리는 것처럼 클라이언트가 AWS를 직접 부를 때 identity pool이 필요해질 수 있습니다(백엔드가 만든 presigned URL로 올리면 필요 없습니다). Cognito user pool로 로그인하고 토큰을 API 요청에 붙이는 배포 구성은 [1인 개발자의 AWS 배포 구조]({% post_url 2026-10-29-solo-dev-aws-deploy-architecture %})에서 다뤘습니다.

백엔드에서 Cognito 토큰을 검증할 때는 직접 구현하기보다 라이브러리를 씁니다. Node.js라면 AWS가 권하는 [`aws-jwt-verify`](https://github.com/awslabs/aws-jwt-verify)가 앞에서 말한 서명·`exp`·`iss`·`client_id`·`token_use` 확인과 JWKS 캐시를 맡아 줍니다. 최소 형태는 이 정도입니다.

```javascript
import { CognitoJwtVerifier } from "aws-jwt-verify";

// 서버가 뜰 때 한 번 만든다 (JWKS를 캐시한다)
const verifier = CognitoJwtVerifier.create({
  userPoolId: "ap-northeast-2_EXAMPLE",
  tokenUse: "access",        // access 토큰만 받는다
  clientId: "exampleclient", // 내 앱 클라이언트에 발급된 토큰만
});

// 요청마다: "Authorization: Bearer <토큰>"에서 꺼내 검증
export async function currentUser(authorizationHeader = "") {
  const match = /^Bearer +(\S+)$/.exec(authorizationHeader);
  if (!match) return null;                          // → 401
  const token = match[1];
  try {
    const claims = await verifier.verify(token);    // 서명·exp·iss·client_id·token_use
    return claims.sub;                               // 이후 사용자 ID로 쓴다
  } catch {
    return null;                                     // → 401
  }
}
```

## 셋을 엮으면: 사람은 JWT로, 서버는 IAM으로

이제 처음 질문으로 돌아갑니다. 로그인해서 쓰는 에이전트 서비스를 만든다면 구조는 어떻게 될까요. 아래는 **설계안이고 아직 구현 전**입니다.

<figure class="diagram">
{% include figures/auth-basics-jwt-iam-cognito/human-jwt-server-iam.svg %}
<figcaption>설계안: 사용자는 Cognito JWT로 백엔드에 자신을 증명하고, 백엔드부터는 IAM 역할의 SigV4 서명으로 AWS를 부른다</figcaption>
</figure>

1. **사용자 → Cognito user pool**: 로그인하고 JWT(access 토큰)를 받습니다.
2. **앱 → 백엔드(에이전트 서버)**: 질문을 보낼 때 `Authorization: Bearer <JWT>`를 붙입니다. 백엔드는 위의 검증을 하고, `sub`로 사용자를 구분해 요금제와 사용량 한도를 확인합니다.
3. **백엔드 → Bedrock 모델, AgentCore Gateway**: 백엔드는 **자기 IAM 역할**로 SigV4 서명해서 부릅니다. 사용자의 JWT는 여기까지 내려가지 않습니다.
4. **Gateway → Web Search 커넥터**: Gateway는 자기 **서비스 역할**로 커넥터를 부릅니다(아웃바운드).

이 설계에서 경계는 백엔드 한 곳입니다. 그 앞은 사람의 세계라 JWT로, 그 뒤는 기계의 세계라 IAM으로 증명합니다. 처음에 혼자 쓰려고 IAM 인증으로 정한 Gateway도, 서비스에서는 백엔드가 같은 방식으로 부르면 되니 그대로 쓸 수 있습니다.

Gateway를 `CUSTOM_JWT`로 두어 사용자 토큰을 Gateway가 직접 검증하게 할 수도 있습니다. 그래도 이 설계에서 Gateway를 IAM으로 둔 이유는, **사용자별 한도와 과금 통제는 어차피 백엔드가 해야 하기 때문**입니다. 검색 한 건, 모델 호출 한 번마다 돈이 드니, 한 사용자가 요청을 쏟아내면 그 비용은 서비스가 냅니다. 검증을 백엔드 한 곳에 모으면 "누구인지"와 "얼마나 썼는지"를 같은 자리에서 판단할 수 있습니다.

## AgentCore Gateway 인바운드 인증 4가지

처음 고민의 출발점이었던 선택지를 [Gateway 인바운드 인증 문서](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-inbound-auth.html) 기준으로 정리하면 이렇습니다.

| 방식 | Gateway가 하는 일 | 언제 |
|---|---|---|
| `AWS_IAM` | 호출자의 SigV4 서명을 확인하고(인증), 호출자 정책에 `bedrock-agentcore:InvokeGateway`가 있는지 본다(인가) | 서버·기계가 부를 때. 이 글의 백엔드 |
| `CUSTOM_JWT` | 설정한 OIDC 발급자(discovery URL)의 토큰인지 검증하고, 허용한 client·audience·scope를 본다 | OAuth 토큰을 가진 클라이언트가 직접 부를 때 |
| `AUTHENTICATE_ONLY` | SigV4 서명만 확인한다. 인가는 하지 않는다 | 인가를 정책 엔진, 인터셉터 Lambda, 대상 서비스가 따로 할 때 |
| `NONE` | 인증도 인가도 하지 않는다 | 운영에서는 피한다 |

`CUSTOM_JWT`에는 알아 둘 동작이 두 가지 있습니다.

- 토큰이 없거나 유효하지 않으면 `401`, 토큰은 유효한데 scope가 부족하면 `403`을 돌려줍니다. 이때 `WWW-Authenticate` 헤더로 필요한 scope를 알려 줘서, MCP 클라이언트가 어떤 scope로 토큰을 받아야 하는지 스스로 알아낼 수 있습니다. 앞에서 말한 401(누구인지 모름)과 403(권한 없음)의 구분이 그대로 드러납니다.
- JWT 인증을 쓰면 토큰의 일부 클레임, 특히 `sub`가 **CloudTrail에 기록**됩니다. 그래서 `sub`에 이메일 같은 개인정보를 넣지 말고 GUID 같은 값을 쓰라고 권합니다.

`AUTHENTICATE_ONLY`와 `NONE`을 고르면 Gateway는 인가를 하지 않습니다. 문서도 이때는 인가를 다른 곳에서 반드시 해야 하며, 그러지 않으면 누구든 대상에 닿을 수 있다고 경고합니다. "인증만 됐다 = 해도 된다"가 아니라는, 앞의 인증·인가 구분이 실제 설정에서 드러나는 대목입니다.

## 주의할 점: 실제로 겪은 IAM 함정

에이전트 계정에 Bedrock 권한을 붙이면서 실제로 겪은 일입니다. 사용자 이름은 예시로 바꿨습니다.

### 1. 인라인 정책 2048자 한도: LimitExceeded

에이전트용 IAM 사용자에게 인라인 정책을 하나 더 넣으려다 이렇게 실패했습니다.

```text
An error occurred (LimitExceeded) when calling the PutUserPolicy operation:
Maximum policy size of 2048 bytes exceeded for user my-agent-user
```

한 IAM 사용자에 붙는 **인라인 정책은 모두 합쳐 2,048자**(공백 제외)까지만 들어갑니다. 정책 하나의 크기가 아니라 합계라는 점이 함정입니다. 기존 인라인 정책 두 개가 이미 1,135자를 쓰고 있어서 남은 자리는 913자였는데, 새 정책은 1,124자였습니다.

해결은 **고객 관리형 정책**을 만들어 사용자에게 attach하는 것이었습니다. 관리형 정책은 정책 하나당 6,144자까지 들어가고 인라인 합계 한도와 상관이 없습니다(한도는 [IAM 할당량 문서](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_iam-quotas.html) 기준). 실패한 시점에 아무것도 바뀌지 않았다는 것도 확인한 뒤에 바꿨습니다.

### 2. API가 평가하는 Action과 Resource를 함께 확인한다

Bedrock의 프롬프트 라우터를 만드는 `CreatePromptRouter`를 부르다 `AccessDenied`가 났습니다. 정책에는 라우터 ARN만 Resource로 넣었는데, 거부된 대상은 라우터에 넣으려던 **모델(추론 프로필) ARN**이었습니다. 이 API는 라우터를 만들면서 안에 넣을 모델도 참조하는데, 정책 초안이 그 모델 ARN을 Resource에서 빠뜨린 것이 원인이었던 것으로 보입니다.

교훈은 **그 API가 평가하는 Action과 필요한 Resource(타입)를 [서비스 권한 참조(Service Authorization Reference)](https://docs.aws.amazon.com/service-authorization/latest/reference/reference_policies_actions-resources-contextkeys.html)에서 함께 확인한다**는 것입니다. 앞에서 말한 "기본은 거부" 때문에, 빠진 허용 하나가 요청 전체를 막습니다. 비슷하게 권한 하나가 빠져 배포 환경에서만 기능이 실패한 사례는 [배포 환경에서만 실패하던 기능, 원인은 IAM 권한 누락]({% post_url 2026-10-28-dev-harness-first-bugfix-iam %})에 정리했습니다.

### 3. 붙이는 계정과 확인하는 계정을 나눈다

같은 AWS 계정 안에서, 권한을 붙이는 일은 관리자 IAM 주체로 하고 확인은 **실제로 그 권한을 쓸 에이전트 IAM 사용자**로 따로 했습니다. 에이전트 IAM 사용자에게는 IAM 쓰기 권한이 아예 없어서 자기 권한을 바꿀 수도 없습니다.

관리자 자격 증명으로 테스트하면 거의 모든 권한이 있으니 정책에 빠진 것이 있어도 통과합니다. 권한 누락은 **실제 주체의 자격 증명으로 실행해 봐야** 드러납니다.

## 정리

- **인증**은 "누구야", **인가**는 "해도 돼"입니다. 401과 403이 이 둘을 나눕니다.
- **JWT**는 발급자가 서명한 토큰을 그대로 보여 주는 방식입니다. payload는 누구나 읽을 수 있으니 비밀을 넣지 않고, 서버는 서명(JWKS의 `kid`)·`exp`·`iss`·`aud`/`client_id`·`token_use`를 검증합니다. 철회는 오프라인으로 알 수 없습니다. 짧은 수명은 피해 시간을 줄일 뿐이고, 즉시 차단은 서버 쪽 상태 관리가 맡습니다.
- **IAM**은 Principal·Action·Resource를 정책으로 정하고, 기본은 거부이며 명시적 Deny가 이깁니다. **SigV4**는 비밀키를 보내지 않고 요청마다 서명해, 서명이 새어도 쓸 수 있는 범위를 그 요청 내용과 짧은 시간으로 좁힙니다.
- **Cognito user pool**은 로그인과 JWT 발급, **identity pool**은 토큰을 임시 AWS 자격 증명으로 바꾸는 일을 맡고, 둘은 따로 써도 됩니다.
- 이 글의 로그인 서비스 설계에서는 **사람은 JWT로, 서버는 IAM으로** 증명합니다. 경계인 백엔드가 JWT를 검증하고 사용자별 한도를 지키며, 그 뒤의 AWS 호출은 백엔드의 IAM 역할로 합니다.
- IAM 권한은 인라인 합계 한도, API가 평가하는 Action과 Resource, 확인하는 주체를 함께 챙겨야 합니다.
