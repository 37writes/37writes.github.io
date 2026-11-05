---
title: "Bedrock 모델 ID 앞의 global.은 무슨 뜻일까: 교차 리전 추론 프로필과 데이터가 처리되는 곳"
date: 2026-11-05 14:05:00 +0900
categories: [AWS, AI 에이전트]
tags: [aws-concepts, aws, bedrock, cross-region-inference, inference-profile, iam, scp, cloudtrail, data-residency]
description: "서울 엔드포인트로 부른 Bedrock 모델이 실제로 어디서 처리되는지, In-Region·apac.·global.의 차이, Global 호출에 IAM ARN이 세 개 필요한 이유와 aws:RequestedRegion unspecified, Global을 막는 Deny·SCP와 CloudTrail inferenceRegion 확인법을 공식 문서 기준으로 정리합니다."
---

## 고르기 전에 몰랐던 것

AI 에이전트(Claude Code)와 Amazon Bedrock 위에 에이전트 서비스를 만들던 중이었습니다. 계획을 세우던 에이전트가 객관식 질문을 하나 던졌습니다.

> 에이전트 모델을 어디서 처리할까요?
> 1. 서울에서만 (추천)
> 2. 시범 단계만 Global 허용
> 3. Global 허용

선택지마다 한 줄 설명이 붙어 있었습니다. 시범 단계에는 공개 자료만 다루니 최신 모델을 Global로 쓰고, 내부 자료를 넣기 전에 서울로 돌아오자는 2번이 그럴듯해 보여서 2번을 골랐습니다.

그런데 고르고 나서 생각해 보니 세 가지를 모르고 있었습니다.

- "Global"이면 요청이 **실제로 어디서** 처리되는가?
- 그걸 **어떻게 확인**하는가?
- 나중에 서울로 돌아올 때 Global을 **어떻게 막는가**?

이 글은 그 세 질문에 답하려고 쓴 개념 복습입니다. [AWS로 AI 에이전트 만들기 전에 알아야 할 서비스 지도]({% post_url 2026-11-01-aws-ai-agent-services-map %})에서 "`global.`과 `apac.`은 처리 범위가 다르고 `additionalEventData.inferenceRegion`으로 확인한다"고 한 문단으로 적고 넘어갔는데, 그 문단을 기초부터 풀어 봅니다. 모든 사실은 2026년 11월 5일에 다시 연 AWS 공식 문서 기준입니다.

## 먼저 용어 몇 개

- **리전(Region)**: AWS가 데이터센터를 묶어 운영하는 지역 단위입니다. 서울은 `ap-northeast-2`, 도쿄는 `ap-northeast-1`입니다.
- **엔드포인트(endpoint)**: API 요청을 받는 주소입니다. Bedrock에서 모델을 부르는 런타임 API는 리전마다 따로 있어서, 서울로 부르면 `bedrock-runtime.ap-northeast-2.amazonaws.com`으로 요청이 갑니다. SDK에서 `region_name="ap-northeast-2"`를 주는 것이 이것입니다.
- **기반 모델(FM, foundation model)**: Bedrock이 제공하는 모델 자체입니다. IAM에서는 `arn:aws:bedrock:<리전>::foundation-model/<모델 ID>` 같은 자원으로 보입니다.
- **추론 프로필(inference profile)**: "어떤 FM을, 어느 리전들로 보내 처리할 수 있는가"를 정의한 자원입니다. 모델 ID 앞에 `apac.`, `global.` 같은 접두사가 붙은 것은 AWS가 미리 만들어 둔 시스템 정의(system-defined) 프로필입니다. 이 프로필로 요청을 여러 리전에 보내는 것을 **교차 리전 추론(cross-Region inference, CRIS)**이라고 합니다.
- **원본 리전(source Region)**: API를 부른 리전입니다. 서울 엔드포인트로 불렀다면 서울입니다.
- **목적지 리전(destination Region)**: Bedrock이 그 요청을 실제로 보내 처리할 수 있는 리전입니다.

핵심은 마지막 두 개입니다. **요청을 보내는 곳(원본)과 처리되는 곳(목적지)이 다를 수 있습니다.**

## 세 가지 처리 방식

Bedrock 문서는 모델 호출을 세 가지 방식으로 나눕니다([Regional availability by models](https://docs.aws.amazon.com/bedrock/latest/userguide/models-region-compatibility.html), [cross-Region inference](https://docs.aws.amazon.com/bedrock/latest/userguide/cross-region-inference.html)).

| 방식 | 모델 ID 모양 | 처리되는 곳 | 비용 |
| --- | --- | --- | --- |
| In-Region | `anthropic.claude-sonnet-5` (접두사 없음) | 요청한 그 리전 하나 | 그 리전 가격 |
| Geographic CRIS | `us.…`, `eu.…`, `apac.…`, `au.…` 등 | 그 지역(geography) 안의 리전들 | 표준 가격 |
| Global CRIS | `global.…` | 지원되는 전 세계 상용 리전 어디든 | Geographic보다 입력·출력 토큰이 약 10% 저렴 |

문서가 정의하는 지역(geography)은 US, Canada, EU, Asia Pacific, Japan, Australia, India입니다. 문서는 데이터 처리 위치 요건이 있으면 Geographic을, 그런 제약이 없고 비용을 줄이고 싶으면 Global을 고르라고 권합니다.

<figure class="diagram">
{% include figures/bedrock-cross-region-inference/routing.svg %}
<figcaption>요청은 늘 서울로 보내지만, 처리되는 곳은 모델 ID의 접두사가 정하고 기록은 서울에 남습니다</figcaption>
</figure>

### 교차 리전일 때 데이터는 어떻게 움직이나

공식 문서에서 데이터 처리와 관련된 문장을 모으면 이렇습니다.

- **입력과 출력은 원본 리전을 벗어날 수 있습니다.** Geographic이면 그 지역 안에서, Global이면 전 세계 상용 리전 어디로든 갑니다([Geographic](https://docs.aws.amazon.com/bedrock/latest/userguide/geographic-cross-region-inference.html), [Global](https://docs.aws.amazon.com/bedrock/latest/userguide/global-cross-region-inference.html)).
- **남용 탐지(abuse detection)를 위해 저장하는 모델이면, 입력과 출력은 목적지 리전에 저장됩니다.** 어떤 모델이 저장하는지는 [abuse detection](https://docs.aws.amazon.com/bedrock/latest/userguide/abuse-detection.html) 문서에 있습니다.
- **목적지에는 내 계정에서 켜지 않은 opt-in 리전도 들어갈 수 있습니다.** 그 리전을 켜지 않았어도 요청이 그리로 갈 수 있고, 남용 탐지 저장도 그 리전에서 일어날 수 있습니다.
- 리전 사이 전송은 **AWS 네트워크 안에서 암호화**되고 공용 인터넷을 지나지 않습니다.
- 라우팅 추가 요금은 없고, 가격은 **원본 리전 기준**으로 매깁니다.

### 접두사만 보고 판단하지 않는다

프로필의 목적지 목록에는 두 가지 성질이 있습니다([Supported Regions and models for inference profiles](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-profiles-support.html)).

- **같은 프로필이라도 원본 리전에 따라 목적지가 다릅니다.** 문서의 예로 `us.anthropic.claude-3-haiku-20240307-v1:0`은 오하이오에서 부르면 `us-east-1`, `us-east-2`, `us-west-2`로 가지만, 오리건에서 부르면 `us-east-1`, `us-west-2`로만 갑니다.
- **Geographic 프로필의 목적지 목록은 바뀌지 않습니다. Global 프로필의 목적지는 AWS가 상용 리전을 늘리면 함께 늘어날 수 있습니다.**

그래서 문서는 데이터 처리 위치 요건이 있으면 "프로필 ID의 지역 접두사만 보고 판단하지 말고, 쓰려는 모든 원본 리전에서 `GetInferenceProfile`을 불러 목적지를 확인하라"고 적어 둡니다. 확인 명령은 뒤의 체크리스트에 정리했습니다.

## 서울에서는 어떻게 되나

이제 처음 질문의 선택지가 왜 그렇게 생겼는지 보입니다. 2026년 11월 5일 기준 문서 표에서 서울(`ap-northeast-2`, `bedrock-runtime`) 행을 보면 이렇습니다.

| 모델 | In-Region | Geo | Global |
| --- | --- | --- | --- |
| Claude Opus 5, Claude Sonnet 5 | ✓ 지원 | ✗ 없음 | ✓ 지원 |
| Claude Opus 5.5 · Sonnet 5.5 · Haiku 5.5 | ✗ 없음 | ✗ 없음 | ✓ 지원 |
| Claude Sonnet 4.6, Claude Opus 4.8 | ✗ 없음 | ✗ 없음 | ✓ 지원 |

- 서울에서 **처리 위치를 서울로 고정할 수 있는 새 Claude는 Opus 5와 Sonnet 5**입니다.
- **최신 세대(5.5)는 서울에서 Global로만** 부를 수 있습니다.
- 중간안인 APAC 프로필도 새 Claude에는 없습니다. 모델 카드에 적힌 Sonnet 5와 Sonnet 5.5의 Geo 프로필은 `us.`, `eu.`, `au.` (Sonnet 5는 `in.`까지)뿐입니다. 작업 당시 서울에서 프로필 목록을 조회했을 때도 `apac.anthropic.*`는 옛 3.x 모델뿐이었습니다. 반면 `apac.amazon.nova-lite-v1:0`처럼 다른 회사 모델에는 APAC 프로필이 있었습니다.

처음에 "서울 in-region에는 옛 모델만 있다"고 이해했는데, 이건 틀린 이해였습니다. 정확히는 "가장 새 세대는 Global로만, 그 바로 전 세대는 서울 in-region으로도 된다"입니다. 그리고 같은 모델 계열이라도 버전마다 제공되는 프로필이 다르므로, 새 모델을 쓰기 전에는 그 모델 카드의 *Regional availability* 표를 먼저 봐야 합니다.

### "약 10% 저렴"의 비교 대상

Global이 약 10% 저렴하다는 것은 문서에 그대로 있는 문장입니다. 다만 비교 대상은 **Geographic CRIS**입니다. in-region이 아닙니다.

서울에서 5.5 모델은 Geo 선택지가 아예 없습니다. 그래서 서울에서 실제로 저울질하는 것은 "Sonnet 5.5 Global"과 "Sonnet 5 in-region"이고, 둘은 **서로 다른 모델**입니다. 이 둘의 요금 차이는 10%라는 숫자와 상관없이 각 모델의 가격표로 따로 비교해야 합니다.

## 권한: 왜 ARN이 여러 개 필요한가

IAM 정책은 문장(Statement)의 목록이고, 문장마다 **Effect**(Allow/Deny), **Action**(허용할 API, 예: `bedrock:InvokeModel`), **Resource**(대상 자원의 ARN), **Condition**(추가 조건)이 있습니다. 명시적 Deny는 어떤 Allow보다 우선합니다.

프로필로 모델을 부르면 Bedrock은 권한을 한 번이 아니라 **여러 자원에 대해** 검사합니다. 그래서 "프로필 ARN 하나만 허용"하면 부족합니다.

### Geographic: 프로필 + 원본 FM + 모든 목적지 FM

Geographic 프로필을 쓰려면 세 가지를 허용합니다([Geographic cross-Region inference](https://docs.aws.amazon.com/bedrock/latest/userguide/geographic-cross-region-inference.html)).

1. 지역 프로필 자체 (`arn:aws:bedrock:<원본>:<계정>:inference-profile/apac.<모델>`)
2. 원본 리전의 FM
3. **프로필에 적힌 모든 목적지 리전**의 FM

FM 쪽 문장에 `bedrock:InferenceProfileArn` 조건을 걸면 "이 프로필을 통해서만" FM을 부르게 제한할 수 있습니다. 이 조건 키는 FM 검사에서만 채워지고, 프로필 자원 검사에서는 채워지지 않습니다.

### Global: 세 부분, 그리고 리전이 빈 ARN

Global은 문서가 "three-part IAM policy"라고 부르는 구조가 필요합니다([Global cross-Region inference](https://docs.aws.amazon.com/bedrock/latest/userguide/global-cross-region-inference.html)). 아래는 문서 구조를 따라 새로 쓴 예시입니다. 계정은 자리표시자 `111122223333`, 원본 리전은 서울, 모델은 Sonnet 5.5입니다.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowGlobalProfileInSourceRegion",
      "Effect": "Allow",
      "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
      "Resource": "arn:aws:bedrock:ap-northeast-2:111122223333:inference-profile/global.anthropic.claude-sonnet-5-5",
      "Condition": { "StringEquals": { "aws:RequestedRegion": "ap-northeast-2" } }
    },
    {
      "Sid": "AllowSourceRegionModelViaProfile",
      "Effect": "Allow",
      "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
      "Resource": "arn:aws:bedrock:ap-northeast-2::foundation-model/anthropic.claude-sonnet-5-5",
      "Condition": {
        "StringEquals": {
          "aws:RequestedRegion": "ap-northeast-2",
          "bedrock:InferenceProfileArn": "arn:aws:bedrock:ap-northeast-2:111122223333:inference-profile/global.anthropic.claude-sonnet-5-5"
        }
      }
    },
    {
      "Sid": "AllowGlobalModelViaProfile",
      "Effect": "Allow",
      "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
      "Resource": "arn:aws:bedrock:::foundation-model/anthropic.claude-sonnet-5-5",
      "Condition": {
        "StringEquals": {
          "aws:RequestedRegion": "unspecified",
          "bedrock:InferenceProfileArn": "arn:aws:bedrock:ap-northeast-2:111122223333:inference-profile/global.anthropic.claude-sonnet-5-5"
        }
      }
    }
  ]
}
```
{: file="global-sonnet-5-5-allow.json" }

세 문장이 검사하는 대상은 이렇게 다릅니다.

| 문장 | 자원 ARN | `aws:RequestedRegion` | `bedrock:InferenceProfileArn` |
| --- | --- | --- | --- |
| 1. 프로필 | `…:ap-northeast-2:111122223333:inference-profile/global.…` | `ap-northeast-2` | 채워지지 않음 |
| 2. 원본 리전 FM | `…:ap-northeast-2::foundation-model/…` | `ap-northeast-2` | 프로필 ARN |
| 3. global FM | `arn:aws:bedrock:::foundation-model/…` | **`unspecified`** | 프로필 ARN |

세 번째가 핵심입니다.

- global FM의 ARN은 **리전과 계정 자리가 모두 비어 있습니다.** 문서는 이것이 의도된 것이고 교차 리전 동작에 필요하다고 적습니다.
- 이 자원을 검사할 때 `aws:RequestedRegion`은 실제 목적지 리전이 아니라 **`unspecified`**로 들어옵니다.

문서 예시의 Action은 `bedrock:InvokeModel` 하나입니다. 저는 응답을 스트리밍으로 받는 `ConverseStream`도 썼기 때문에 `bedrock:InvokeModelWithResponseStream`을 함께 넣었습니다. `ConverseStream` API 문서에 이 권한이 필요하다고 적혀 있습니다.

## Global을 막는 법

`unspecified`를 알고 나면 "Global을 어떻게 막는가"의 답이 나옵니다.

### 리전 이름 Deny로는 막히지 않는다

"`us-west-2`는 거부" 같은 리전 이름 기반 Deny는 Global의 세 번째 검사에 닿지 않습니다. 그 검사는 `aws:RequestedRegion = unspecified`로 평가되기 때문입니다. 문서도 이 점을 따로 경고합니다.

### 방법 1: 허용 하나를 빼기

Global은 세 허용이 모두 있어야 동작하므로, 하나만 빠져도 거부됩니다. 특히 리전이 빈 global FM(`arn:aws:bedrock:::foundation-model/…`) 허용을 넣지 않으면 됩니다.

### 방법 2: 역할에 명시적 Deny

나중에 누가 실수로 허용을 다시 넣어도 막히게 하려면 명시적 Deny를 둡니다. 문서는 이 방법이 보안 의도를 분명히 남긴다는 점도 장점으로 듭니다.

```json
{
  "Sid": "DenyGlobalCrossRegionInference",
  "Effect": "Deny",
  "Action": "bedrock:InvokeModel*",
  "Resource": "*",
  "Condition": { "StringEquals": { "aws:RequestedRegion": "unspecified" } }
}
```
{: file="deny-global-statement.json" }

### 방법 3: 조직 단위로 SCP

AWS Organizations를 쓰면 SCP(서비스 제어 정책)로 계정 전체에서 막을 수 있습니다. 문서의 예시는 `unspecified` 조건에 global 프로필 조건을 함께 겁니다.

```json
{
  "Effect": "Deny",
  "Action": "bedrock:*",
  "Resource": "*",
  "Condition": {
    "StringEquals": { "aws:RequestedRegion": "unspecified" },
    "ArnLike": { "bedrock:InferenceProfileArn": "arn:aws:bedrock:*:*:inference-profile/global.*" }
  }
}
```
{: file="scp-deny-global.json" }

### 반대로, 리전 제한 SCP가 있는데 쓰고 싶다면

이미 "허용된 리전 밖은 모두 거부"하는 SCP를 쓰는 조직이면 반대 문제가 생깁니다.

- **Global**: 허용 리전 목록에 `unspecified`를 넣거나, `bedrock:InferenceProfileArn`으로 교차 리전 경로만 예외로 둡니다.
- **Geographic**: 프로필의 목적지 리전을 **모두** 허용하거나 같은 방식의 프로필 예외를 둡니다. 목적지 중 하나라도 SCP로 막혀 있으면 다른 리전이 허용돼 있어도 요청이 실패합니다.

멀티 계정 환경에서 이 예외를 Control Tower와 함께 다루는 방법은 AWS 블로그 [Enable Amazon Bedrock cross-Region inference in multi-account environments](https://aws.amazon.com/blogs/machine-learning/enable-amazon-bedrock-cross-region-inference-in-multi-account-environments/)가 따로 다룹니다.

## 실제로 어디서 처리됐는지 확인하기

교차 리전 요청도 **CloudTrail은 원본 리전에 기록**합니다. CloudWatch 지표와 로그도 원본 리전에 남습니다. 실제로 처리된 리전은 CloudTrail 이벤트의 `additionalEventData.inferenceRegion` 필드에 남습니다.

확인 순서는 이렇게 잡을 수 있습니다. 1~3은 호출 전에, 4는 호출 뒤에 합니다.

1. **모델 카드**: [models at a glance](https://docs.aws.amazon.com/bedrock/latest/userguide/model-cards.html)에서 모델을 골라 *Regional availability* 표에서 내 원본 리전의 In-Region / Geo / Global 지원 여부를 봅니다.
2. **원본 리전에서 쓸 수 있는 프로필 목록**:

   ```bash
   aws bedrock list-inference-profiles \
     --region ap-northeast-2 \
     --type-equals SYSTEM_DEFINED \
     --query "inferenceProfileSummaries[?status=='ACTIVE'].inferenceProfileId" \
     --output table
   ```

3. **그 프로필의 목적지 리전**: `models[].modelArn`에 나오는 ARN의 리전 자리가 목적지입니다.

   ```bash
   aws bedrock get-inference-profile \
     --region ap-northeast-2 \
     --inference-profile-identifier apac.amazon.nova-lite-v1:0 \
     --query 'models[].modelArn'
   ```

4. **호출 뒤**: 원본 리전(서울)의 CloudTrail에서 그 호출 이벤트를 찾아 `additionalEventData.inferenceRegion` 값을 봅니다.

솔직하게 적으면, 저는 이 작업에서 4번의 값을 직접 조회해 보지는 않았습니다. 위 순서는 문서로 확인한 방법입니다. 내부 자료를 넣는 단계로 넘어가기 전에 이 값을 실제로 확인하는 것을 남은 일로 둡니다.

## 그때의 결정으로 돌아가면

처음의 선택지를 다시 보면 이렇게 정리됩니다.

| 선택지 | 결과 | 이번 판단 |
| --- | --- | --- |
| 서울에서만 (당시 추천) | 처리 위치는 서울로 고정. 쓸 수 있는 새 Claude는 Opus 5·Sonnet 5 | 다음 단계(내부 자료)에서 돌아갈 곳 |
| 시범 단계만 Global 허용 | 시범 단계는 Sonnet 5.5 Global, 전 세계 상용 리전에서 처리 가능 | **고른 안** |
| Global 허용 | 최신 모델을 계속 쓰지만, 내부 자료의 처리 위치 요건과 충돌 | 버림 |
| (APAC 프로필로 절충) | 서울에서 새 Claude에는 `apac.` 프로필이 없음 | 선택지에도 없었음 |

고른 안은 "공개 자료만 다루는 시범 단계에서만 Global을 허용하고, **내부 자료를 넣기 전에 서울 in-region(Opus 5 / Sonnet 5)으로 바꾸고 Global은 명시적 Deny로 막는다**"였습니다. 시범 단계에서는 실행 역할에 위의 세 부분 허용을 넣고 Sonnet 5.5 Global로 호출했습니다.

이 결정이 말이 되는 이유는 이렇습니다. 처리 위치가 문제가 되는 것은 **어떤 데이터가 흘러가느냐**입니다. 공개 자료만 다루는 동안에는 전 세계 어느 리전에서 처리되든 잃을 것이 적고, 최신 모델의 품질과 Global의 가격 이점을 얻습니다. 내부 자료가 들어오는 순간 조건이 바뀌므로, 그 시점을 전환 조건으로 못박아 둔 것입니다.

### 조심할 점

**in-region으로 바꾸면 모델도 바뀝니다.** 서울에서는 "처리 위치 고정"과 "최신 모델 사용"을 동시에 할 수 없습니다. Sonnet 5.5에서 Sonnet 5로 내려가면 답의 품질이 달라질 수 있어서, 이 위험도 결정과 함께 적어 두었습니다. 이 결정은 문제를 없앤 것이 아니라 **다음 단계로 미룬 것**입니다.

**Global은 목록이 늘어나는 "전 세계"입니다.** Global 프로필의 목적지는 AWS가 상용 리전을 추가하면 늘어날 수 있습니다. 오늘 확인한 목록이 내일도 같다고 가정하면 안 됩니다. 처리 위치 요건이 있으면 문서도 Geographic을 권합니다.

**프로필 ARN만 넣고 FM ARN을 빠뜨리면 AccessDenied가 납니다.** 다른 작업에서 Bedrock 프롬프트 라우터를 만들 때 실제로 이 실수를 했습니다. 정책 초안에 프로필 ARN만 있고 그 뒤의 모델 ARN이 빠져 있어서, 프로필 ARN에 대해 AccessDenied가 났습니다. 문서의 규칙대로 "프로필을 Resource에 넣으면 연결된 각 리전의 FM도 넣어야" 합니다.

**FM ARN의 리전 와일드카드가 생각보다 넓을 수 있습니다.** 다른 작업에서 APAC 프로필 뒤의 FM을 `arn:aws:bedrock:ap-*::foundation-model/…`로 허용한 적이 있습니다. 이 패턴은 그 프로필의 목적지가 아닌 `ap-` 리전까지 모두 포함합니다. 게다가 문서는 접두사만으로 목적지를 판단하지 말라고 합니다. `GetInferenceProfile`로 확인한 정확한 목적지 목록을 쓰는 편이 안전합니다.

**리전 자리를 `*`로 쓴 FM ARN은 확인해 볼 점입니다.** IAM 문서에서 `*`는 "어떤 문자 조합"이든 맞고, 문서 예시에서는 빈 자리와도 맞습니다(`amzn-s3-demo-bucket/*/test/*`가 `amzn-s3-demo-bucket//test/object.jpg`에 맞음). 그렇다면 `arn:aws:bedrock:*::foundation-model/…`은 리전이 빈 global FM ARN과도 맞아서, 의도하지 않게 Global의 세 번째 허용을 채울 수 있다고 추론할 수 있습니다. 직접 시험해 보지는 않았으므로 사실로 단정하지는 않습니다. 다만 문서의 넓은 예시 정책도 `arn:aws:bedrock:*::foundation-model/*`를 쓰니, 넓은 와일드카드 정책을 쓰는 역할이라면 Global이 열려 있다고 가정하고 점검하는 편이 낫습니다. Global을 막아야 한다면 앞의 명시적 Deny가 이런 불확실성까지 덮어 줍니다.

## 정리: 실전 체크리스트

**처리 리전 확인**
1. 모델 카드의 *Regional availability*에서 원본 리전의 In-Region / Geo / Global 지원 여부를 봅니다.
2. `aws bedrock list-inference-profiles --region <원본> --type-equals SYSTEM_DEFINED`로 쓸 수 있는 프로필을 봅니다.
3. `aws bedrock get-inference-profile --region <원본> --inference-profile-identifier <ID> --query 'models[].modelArn'`으로 목적지 리전을 봅니다. 쓰려는 원본 리전마다 따로 봅니다.
4. 호출 뒤 원본 리전 CloudTrail 이벤트에서 `additionalEventData.inferenceRegion`을 봅니다.

**Global을 쓸 때**
1. 세 부분(프로필, 원본 리전 FM, 리전이 빈 global FM)을 모두 허용합니다.
2. 스트리밍(`ConverseStream`, `InvokeModelWithResponseStream`)을 쓰면 `bedrock:InvokeModelWithResponseStream`도 넣습니다.
3. 리전 제한 SCP가 있으면 `unspecified` 허용이나 `bedrock:InferenceProfileArn` 예외를 둡니다.

**Global을 막을 때**
1. 세 허용 중 하나, 특히 `arn:aws:bedrock:::foundation-model/…`을 넣지 않습니다.
2. 역할에 `aws:RequestedRegion = unspecified` 조건의 명시적 Deny를 둡니다. 리전 이름 Deny로는 막히지 않습니다.
3. 조직 단위로는 SCP에 `unspecified` + `ArnLike bedrock:InferenceProfileArn …/global.*` Deny를 둡니다.
4. FM ARN의 리전 자리에 `*`나 `ap-*` 같은 넓은 와일드카드를 쓰지 않았는지 점검합니다.

처음의 세 질문에 한 줄씩 답하면 이렇습니다. Global이면 요청은 **지원되는 전 세계 상용 리전 어디서든** 처리될 수 있고, 실제 처리 리전은 **원본 리전 CloudTrail의 `inferenceRegion`**으로 확인하며, 막을 때는 리전 이름이 아니라 **`aws:RequestedRegion = unspecified`**를 Deny합니다.

## 더 읽을거리

- [Route model inference requests across AWS Regions with cross-Region inference](https://docs.aws.amazon.com/bedrock/latest/userguide/cross-region-inference.html): Geographic과 Global 비교표, 공통 고려 사항
- [Global cross-Region inference](https://docs.aws.amazon.com/bedrock/latest/userguide/global-cross-region-inference.html): 세 부분 IAM 정책, `unspecified`, 차단 방법, SCP 예시
- [Geographic cross-Region inference](https://docs.aws.amazon.com/bedrock/latest/userguide/geographic-cross-region-inference.html): 지역 프로필의 IAM·SCP 요건
- [Supported Regions and models for inference profiles](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-profiles-support.html): 원본·목적지 리전, 확인 명령
- [Prerequisites for inference profiles](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-profiles-prereq.html): `bedrock:InferenceProfileArn` 조건, Deny 예시
- [Regional availability by models](https://docs.aws.amazon.com/bedrock/latest/userguide/models-region-compatibility.html): 모델별·리전별 In-Region / Geo / Global 표
