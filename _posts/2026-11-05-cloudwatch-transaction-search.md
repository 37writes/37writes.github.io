---
title: "CloudWatch Transaction Search가 뭐길래: 에이전트 추적을 켜기 전에 계정에서 바뀌는 것"
date: 2026-11-05 14:10:00 +0900
categories: [AWS, AI 에이전트]
tags: [aws-concepts, aws, cloudwatch, x-ray, transaction-search, observability, agentcore, opentelemetry]
description: "AgentCore 추적을 보려면 먼저 켜라는 CloudWatch Transaction Search를 기초부터 정리합니다. span과 trace, aws/spans 로그 그룹, 리소스 정책·목적지·색인 세 단계의 순서, 표본 추출과 색인의 차이, 비용, 켜기 전 기록과 되돌리기 체크리스트까지 다룹니다."
---

## 그때 넘어간 질문 하나

AI 에이전트(Claude Code)와 함께 Amazon Bedrock AgentCore에 에이전트를 처음 배포하려던 참이었습니다. 배포 전에 에이전트가 제가 정해야 할 질문 목록을 올렸고, 그중 한 줄이 "계정 전체 설정인 CloudWatch Transaction Search를 켤지"였습니다.

저는 다른 질문들에 한 줄씩 답하면서 그 사이에 "Transaction Search가 뭐야?"라고 적었습니다. 돌아온 것은 설명이 아니라 결정 표의 한 칸이었습니다. "이 리전에서 켠다. AWS 설정을 바꾸는 일이라 배포 때 승인 명령에 넣는다." 개념 설명은 한참 뒤, 켜는 명령 세 줄을 받기 바로 앞에야 나왔습니다.

명령은 제가 직접 실행했고 결과도 문제없었습니다. 그래도 남는 것이 있었습니다. 에이전트가 질문을 결정으로 바꿔 버리면, 사람은 무엇을 바꾸는지 모르는 채로 계정 설정을 바꾸는 명령을 실행하게 됩니다. 이 글은 그때 건너뛴 설명을 채웁니다. 기초(trace와 span)에서 출발해 Transaction Search가 계정에서 무엇을 바꾸는지, 켜는 세 단계가 왜 그 순서인지, 되돌릴 때 무엇을 조심해야 하는지 정리합니다.

내용은 2026-11 시점 AWS 공식 문서로 다시 확인했고, 직접 겪은 일은 뒤쪽 "그때 한 일로 돌아가기"에 모았습니다. 계정 ID와 이름은 예시 값으로 바꿨습니다.

## 기초: trace와 span

분산 추적(distributed tracing)은 요청 하나가 여러 구성 요소를 지나가는 길을 기록하는 방법입니다. 단위는 두 가지입니다.

- **span**: 작업 하나의 기록입니다. 시작·끝 시각, 걸린 시간, 그리고 메타데이터(속성)를 담습니다. CloudWatch 문서는 span을 "분산 추적의 기본 단위"라고 부릅니다.
- **trace**: span들이 부모-자식으로 이어진 묶음입니다. 요청 하나가 처음부터 끝까지 어디를 지났는지를 보여 줍니다.

추적 계측(instrumentation)과 문맥 전파(context propagation)가 설정된 에이전트라면 이렇게 대입할 수 있습니다. 사용자 질문 하나가 trace 하나이고, 그 안에서 모델을 부른 일, 도구를 부른 일, 메모리를 조회한 일이 각각 span으로 남습니다. 질문과 trace가 정확히 어떻게 대응하는지는 구현에 따라 다릅니다. "에이전트가 도구를 언제, 어떤 순서로, 얼마나 오래 불렀나"를 나중에 확인하려면 이 span들이 어딘가에 쌓여 있어야 합니다.

span을 만드는 것은 에이전트 코드와 프레임워크의 계측입니다. AgentCore 문서도 에이전트 코드에 ADOT(AWS Distro for OpenTelemetry) SDK를 넣고 프레임워크가 trace를 내보내도록 설정하라고 안내합니다. 이 글에서 다루는 Transaction Search는 그렇게 **보내진 span을 받는 쪽**의 설정입니다. 켠다고 해서 계측하지 않은 작업이 저절로 기록되지는 않습니다.

## Transaction Search를 켜기 전: span은 X-Ray로 간다

AWS에서 span을 받는 곳은 AWS X-Ray입니다. Transaction Search를 켜기 전의 기본 경로는 앱이나 SDK가 `PutTraceSegments` API로 trace 데이터(segment)를 X-Ray에 보내는 것입니다.

OTLP(OpenTelemetry Protocol, OpenTelemetry 데이터를 보내는 표준 프로토콜)로 X-Ray의 OTLP 엔드포인트에 보내는 길도 있습니다. 다만 이 길은 Transaction Search가 켜져 있어야 span이 닿습니다(CloudWatch 문서: ["Enable Transaction Search so that spans reach the X-Ray OTLP endpoint"](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-OTLP-NoCodeEbpf.html)). 그래서 이 절의 "켜기 전" 설명은 `PutTraceSegments` 경로에 한정됩니다.

X-Ray에는 "받은 데이터를 어디에 둘지"라는 설정이 있습니다. API 이름은 [`UpdateTraceSegmentDestination`](https://docs.aws.amazon.com/xray/latest/api/API_UpdateTraceSegmentDestination.html)이고, 값은 둘뿐입니다.

| 목적지 | 뜻 |
|---|---|
| `XRay` | X-Ray 자체 저장소에 둡니다. X-Ray 콘솔의 trace 화면으로 봅니다 |
| `CloudWatchLogs` | CloudWatch Logs의 로그 그룹에 구조화된 로그로 둡니다. Transaction Search가 이 목적지를 필요로 합니다 |

제 계정에서 처음 읽은 값은 `XRay`였습니다. 내 계정이 지금 어느 쪽인지는 `aws xray get-trace-segment-destination`으로 확인할 수 있습니다.

## Transaction Search를 켜면 바뀌는 것

Transaction Search는 목적지를 `CloudWatchLogs`로 바꾸고, 그렇게 받은 span을 검색·분석하는 CloudWatch 기능입니다. 켜면 다음이 달라집니다.

1. **span이 `aws/spans` 로그 그룹에 쌓입니다.** X-Ray 형식 trace는 저장 전에 OpenTelemetry 의미 규약(semantic convention) 형식으로 자동 변환됩니다.
2. **받은 span 전부를 검색합니다.** CloudWatch 콘솔의 시각 편집기에서 span 속성으로 찾고, span이 최대 10,000개인 큰 trace도 볼 수 있습니다.
3. **일부 trace만 trace summary로 색인합니다.** 색인(indexing)은 수집된 trace 중 일부를 X-Ray에서 검색할 수 있는 요약(trace summary)으로 만드는 일입니다. 어느 trace를 고를지는 trace ID 기준의 비율로 정합니다. X-Ray의 trace 검색·분석·Insights 기능은 이 요약이 있는 trace에만 적용됩니다.
4. **CloudWatch Logs 기능을 span에 쓸 수 있습니다.** 지표 필터, 구독 필터, 로그 이상 탐지, Contributor Insights가 됩니다. 반대로 `PutLogEvents`로 span을 직접 넣거나, Logs의 변환·보강(transformation) 기능을 span에 쓰는 것은 지원하지 않습니다.
5. **X-Ray OTLP 엔드포인트로 보낸 span도 받습니다.** 앞에서 말한 대로, OTLP로 보내는 길은 Transaction Search가 켜져 있어야 동작합니다.

흐름으로 그리면 이렇습니다. 굵은 글씨가 이 글에서 다루는 네 가지 설정이고, 각각 흐름의 다른 자리에 걸립니다. 아래 점선 갈래는 AgentCore 에이전트의 span이 `aws/spans` 대신 들어갈 수 있는 다른 저장 위치입니다. 목적지·정책을 건너뛰는 길이 아니라, 같은 활성화가 전제이고 그 로그 그룹에 대한 권한이 따로 필요합니다(뒤의 "span이 꼭 `aws/spans`에 있는 것은 아니다"에서 다룹니다).

<figure class="diagram">
{% include figures/cloudwatch-transaction-search/span-flow.svg %}
<figcaption>표본 규칙은 앱 쪽에서 기록 여부를, 목적지·리소스 정책은 span이 갈 곳을, 색인 규칙은 그중 요약으로 만들 비율을 정합니다</figcaption>
</figure>

### 범위: 계정 전체 설정

가장 먼저 알아야 할 점은 이 설정의 범위입니다. 공식 문서는 이렇게 씁니다.

> Transaction search is configured for the entire account and switches all spans ingestion through X-Ray into cost effective collection mode

"이 프로젝트의 span만"이 아니라 **이 계정에서 X-Ray로 span을 보내는 모든 것**이 새 방식으로 바뀐다는 뜻입니다. 같은 계정을 쓰는 다른 팀·프로젝트의 span도 CloudWatch Logs로 가고, 그 수집 요금도 함께 붙습니다.

한 가지 덧붙이면, X-Ray API는 리전별 엔드포인트이고 목적지·색인 설정도 리전마다 읽고 바꿉니다. 저도 명령마다 `--region`을 붙여 한 리전에서만 켰습니다. 그래서 실무에서는 "계정의 그 리전 전체"로 생각하는 것이 안전합니다. 한 리전에서 켰다고 다른 리전이 같이 바뀐다고 가정하지 마시고, 리전마다 `get-trace-segment-destination`으로 확인하세요.

## 켜는 세 단계와 그 순서

콘솔에서는 CloudWatch → Application Signals → Transaction Search → **Enable Transaction Search**로 켜고, 색인 비율만 입력하면 필요한 정책을 콘솔이 만들어 줍니다. 다만 콘솔로 켜는 사람에게는 문서의 Prerequisites에 적힌 권한이 필요합니다(X-Ray 목적지·색인 규칙 읽기/쓰기, Logs 리소스 정책, Application Signals 시작, 서비스 연결 역할 생성 등).

CLI나 SDK로 켤 때는 세 단계를 직접 합니다. 절차 원문은 CloudWatch 문서의 [Enable Transaction Search](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Enable-TransactionSearch.html)에 있습니다.

아래 명령의 `<region>`과 `123456789012`는 자리 표시자입니다. 실행 전에 모두 본인의 리전(예: `us-east-1`)과 계정 ID로 바꾸세요. `<region>`을 그대로 두면 셸이 `<`를 입력 리다이렉션으로 읽어 오류가 나거나 엉뚱하게 동작합니다.

먼저 지금 값을 읽어 **파일로 저장**해 둡니다. 나중에 되돌릴 기준값입니다. 화면에만 출력하면 남지 않습니다. 표본 규칙은 `--query`로 줄이지 말고 전체를 저장하세요. 이름·비율이 같아도 reservoir, 우선순위, 매칭 조건이 다를 수 있어서, 전체가 있어야 나중에 "그대로인지"를 비교할 수 있습니다.

```bash
# 0. 지금 설정 읽기 (되돌리기 기준값을 파일로 저장)
aws xray get-trace-segment-destination --region <region> > before-destination.json
aws xray get-indexing-rules --region <region> > before-indexing-rules.json
aws xray get-sampling-rules --region <region> > before-sampling-rules.json
aws logs describe-resource-policies --region <region> > before-logs-resource-policies.json
aws logs describe-log-groups --log-group-name-prefix aws/spans --region <region> > before-spans-log-group.json
```

### ① 리소스 정책: X-Ray가 내 로그 그룹에 쓰도록 허락

```bash
aws logs put-resource-policy --region <region> \
  --policy-name TransactionSearchXRayAccess \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Sid": "TransactionSearchXRayAccess",
      "Effect": "Allow",
      "Principal": {"Service": "xray.amazonaws.com"},
      "Action": "logs:PutLogEvents",
      "Resource": [
        "arn:aws:logs:<region>:123456789012:log-group:aws/spans:*",
        "arn:aws:logs:<region>:123456789012:log-group:/aws/application-signals/data:*"
      ],
      "Condition": {
        "ArnLike": {"aws:SourceArn": "arn:aws:xray:<region>:123456789012:*"},
        "StringEquals": {"aws:SourceAccount": "123456789012"}
      }
    }]
  }'
```

이것은 IAM 사용자나 역할에 붙이는 정책이 아닙니다. CloudWatch Logs 쪽에 붙는 **자원 기반 정책(resource-based policy)** 입니다. `Principal`이 `xray.amazonaws.com`, 즉 X-Ray라는 서비스가 `aws/spans`와 `/aws/application-signals/data` 로그 그룹에 로그를 쓸 수 있게 문을 열어 줍니다.

조건 두 줄은 "그 서비스가 아무 계정을 위해서나 쓰는 것"을 막습니다. `aws:SourceArn`은 이 계정·리전의 X-Ray에서 온 요청만, `aws:SourceAccount`는 이 계정의 요청만 허용합니다. 다른 계정이 X-Ray를 시켜 내 로그 그룹에 쓰게 하는 혼동된 대리인(confused deputy) 문제를 막는 장치입니다.

### ② 목적지 전환: XRay → CloudWatchLogs

```bash
aws xray update-trace-segment-destination --destination CloudWatchLogs --region <region>
```

이 명령이 실제로 "켜는" 단계입니다. 응답의 상태는 `PENDING`이나 `ACTIVE`입니다. 바로 `ACTIVE`가 되지 않고 `PENDING`을 거칩니다.

### ③ 색인 규칙: 받은 span 중 몇 %를 요약으로

```bash
aws xray update-indexing-rule --region <region> --name Default \
  --rule '{"Probabilistic":{"DesiredSamplingPercentage":1}}'
```

이름이 `Default`인 색인 규칙의 비율을 정합니다. [API 문서](https://docs.aws.amazon.com/xray/latest/api/API_ProbabilisticRuleValueUpdate.html)상 `DesiredSamplingPercentage`는 "색인할 traceId의 비율"이고 소수(Double)입니다. 즉 span 하나하나를 고르는 것이 아니라 trace ID를 기준으로 trace를 고릅니다. 뒤의 비용 표에 나오는 "색인된 span 수"는 요금을 세는 단위라서, 고르는 단위(trace ID)와는 구분해서 보세요. 1%는 무료 범위이고, 문서는 1%가 "보통 충분하다"고 씁니다. AgentCore 문서는 이 단계를 선택(Optional)으로 둡니다.

### 확인

```bash
aws xray get-trace-segment-destination --region <region>
# {"Destination": "CloudWatchLogs", "Status": "ACTIVE"} 이면 켜진 것
```

문서는 켠 뒤 span이 검색·분석에 나타나기까지 10분쯤 걸릴 수 있다고 합니다.

### 왜 정책이 먼저인가

순서를 바꿔 목적지를 먼저 `CloudWatchLogs`로 돌리면, X-Ray가 span을 로그 그룹에 넣어야 하는데 쓸 권한이 없는 상태가 생깁니다. 문을 먼저 열고(정책), 길을 돌리고(목적지), 마지막에 얼마나 요약할지(색인)를 정하는 순서입니다. 공식 문서의 API 절차도 이 순서입니다.

## 표본 추출과 색인은 다른 것

여기가 가장 헷갈리는 대목입니다. "몇 %"를 정하는 설정이 두 군데 있기 때문입니다.

| | 표본 추출 (head sampling) | 색인 (indexing) |
|---|---|---|
| 설정 | X-Ray 표본 규칙(sampling rule) | X-Ray 색인 규칙(indexing rule) |
| 정하는 쪽 | 앱·SDK 쪽, trace 시작 지점 | 서버 쪽, 수집이 끝난 뒤 |
| 정하는 것 | 이 요청을 기록할지 | 수집된 trace 중 몇 %를 trace ID 기준으로 골라 trace summary로 만들지 |
| 버려진 것 | span이 아예 만들어지지 않음 | `aws/spans`에는 그대로 남아 Transaction Search로 검색됨 |

X-Ray 기본 표본 규칙은 "초당 첫 요청 1건(reservoir)과 그 밖의 요청 5%(rate)"입니다. X-Ray 표본 규칙을 읽도록 설정된 SDK라면 이 비율로 기록할 요청을 고릅니다. 이 결정은 보통 trace를 시작하는 첫 서비스에서 한 번 내려지고, 뒤따르는 서비스는 그 결정을 따릅니다. 표본 규칙의 reservoir·fixed rate·매칭 조건은 X-Ray 문서의 [sampling rules](https://docs.aws.amazon.com/xray/latest/devguide/xray-console-sampling.html)에 설명되어 있습니다.

CloudWatch 문서는 비용 효율적인 조합으로 **"표본 추출은 높게(가능하면 전부), 색인은 낮게"** 를 소개합니다. span 전체는 싼 수집 요금으로 `aws/spans`에 받아 두고, 비싼 요약은 일부만 만드는 방식입니다.

저는 표본 규칙은 건드리지 않았습니다(기본값 그대로). 표본 규칙도 계정 공용이라 다른 프로젝트에 영향을 주기 때문입니다. 색인 비율만 0%에서 1%로 바꿨습니다. 그래서 변경 범위가 정책·목적지·색인 셋으로 묶였고, 되돌리기도 단순해졌습니다.

## AgentCore가 왜 먼저 켜라고 하나

AgentCore 문서는 AgentCore 서비스가 만든 지표·span·trace를 보려면 먼저 **일회성 설정**으로 Transaction Search를 켜라고 합니다. AgentCore 콘솔의 Observability 화면과 CloudWatch 콘솔의 생성형 AI 관측(Generative AI observability) 화면(Sessions, Traces, Spans 탭)이 보여 주는 것이 바로 이 span 데이터입니다. span이 CloudWatch Logs에 없으면 보여 줄 것이 없습니다. Gateway 같은 자원의 Tracing 토글도 Transaction Search가 켜져 있어야 켤 수 있습니다.

AgentCore 서비스 전체 구조는 [AWS로 AI 에이전트 만들기 전에 알아야 할 서비스 지도]({% post_url 2026-11-01-aws-ai-agent-services-map %})에 정리해 두었습니다.

배포 방법에 따라 할 일이 갈립니다.

- **AgentCore CLI(`agentcore deploy`)로 배포**: CLI가 기본적으로 Transaction Search를 자동으로 켭니다. 자동으로 켜지 않게 하려면 `agentcore config transactionSearch false`([AgentCore 관측 시작 안내](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/observability-get-started.html)).
- **CDK나 직접 쓴 명령으로 배포**: 배포 구성에 활성화 설정을 넣지 않았다면 따로 켜야 합니다. CloudFormation·CDK로 켜는 방법도 [문서](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-Transaction-Search-Cloudformation.html)에 있습니다. 제 배포 구성에는 활성화 설정이 없어서, 위 세 단계를 따로 했습니다([CDK 첫 배포 이야기]({% post_url 2026-11-05-cdk-least-privilege-first-deploy %})).

### span이 꼭 `aws/spans`에 있는 것은 아니다

최근 AgentCore 문서에 바뀐 점이 있습니다. AgentCore Runtime 에이전트는 span을 공용 `aws/spans` 대신 **에이전트 자체 로그 그룹** `/aws/bedrock-agentcore/runtimes/<agent_id>-<endpoint_name>`의 `spans` 스트림으로 보낼 수 있고, 지원 리전에서는 새로 만든 에이전트의 기본값이 이쪽입니다. 에이전트마다 환경 변수 `UNIFIED_TRACES_DESTINATION_ENABLED`로 바꿀 수 있습니다.

[문서](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/observability-configure.html#observability-configure-unified-traces)는 에이전트 로그 그룹으로 span을 보내려면 세 가지가 모두 맞아야 한다고 씁니다.

- **Transaction Search가 켜져 있어야 합니다.** 문서 표현으로 "Without Transaction Search, AgentCore can't deliver spans to the agent's log group."
- **에이전트 실행 역할(execution role)에 그 에이전트 로그 그룹에 대한 `logs:PutResourcePolicy` 권한이 있어야 합니다.** AgentCore는 이 권한으로 X-Ray가 그 로그 그룹에 span을 쓸 수 있게 합니다([실행 역할 문서](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-permissions.html#runtime-permissions-execution)). 앞의 ① 리소스 정책은 `aws/spans`와 `/aws/application-signals/data`만 대상으로 하므로, 그것만으로 에이전트 로그 그룹까지 허용되지는 않습니다.
- **에이전트가 ADOT 0.18.0 이상을 써야 합니다.** 그보다 낮은 버전은 이 설정을 무시하고 공용 `aws/spans`로 보냅니다.

또 목적지를 바꿔도 이미 보낸 span은 옮겨지지 않고 원래 로그 그룹에 남습니다. 그러니 span을 찾을 때는 "공용 목적지를 쓰던 기간의 span은 `aws/spans`, 에이전트별 목적지로 바꾼 뒤의 span은 에이전트 로그 그룹"으로 두 곳을 보세요.

## 비용

span은 일반 로그와 따로 과금됩니다. 가격 페이지 표현으로 "Spans ingested as logs will not incur log ingestion pricing", 즉 로그 수집 요금 대신 span 수집 요금이 붙습니다. 아래는 작성 시점 [CloudWatch 가격 페이지](https://aws.amazon.com/cloudwatch/pricing/)의 미국 동부(버지니아 북부) 기준 예시입니다. 리전마다 다르고 바뀔 수 있으니 쓰는 리전 값을 직접 확인하세요.

| 항목 | 가격 (작성 시점, 미국 동부 예시) |
|---|---|
| span 수집 | 0~10TB 구간 GB당 $0.35 (그 위 구간은 더 쌈) |
| 색인 1% | 수집 요금에 포함 (추가 요금 없음) |
| 1%를 넘는 색인 | 색인된 span 100만 개당 $0.75 (고르는 단위는 trace ID, 세는 단위는 span) |
| 무료 사용 | 계정당 3개월, span 수집 100GB와 trace summary 색인 100만 개 중 먼저 닿는 것까지 |

계정 전체 설정이라는 점과 합치면, 비용에서 볼 것은 "내 에이전트의 span"보다 "이 계정·리전에서 X-Ray로 들어오는 모든 span"입니다.

## 그때 한 일로 돌아가기

이제 처음 장면으로 돌아가, 그 명령 세 줄 앞뒤로 한 일을 정리합니다.

**왜 켜야 했나.** 앞선 시험 배포에서 에이전트 런타임 로그에 OTLP span 내보내기 오류(`Failed to export span batch code: 400, reason: Bad Request`)가 반복해서 보였습니다. Transaction Search가 꺼져 있는 것이 원인 후보였지만 확인하지는 않았고, 에이전트의 답에는 영향이 없었습니다. CloudWatch 문서에도 span이 X-Ray OTLP 엔드포인트에 닿게 하려면 Transaction Search를 켜라는 안내가 있습니다(켠 뒤 그 오류가 사라졌는지는 따로 확인하지 못했습니다). 더 큰 이유는 다음 단계였습니다. 에이전트가 도구를 언제 어떻게 불렀는지를 측정과 시험의 근거로 쓰려면 span이 남아 있어야 했습니다.

**켜기 전에 두 번 읽기.** 사전 확인 단계에서 한 번, 켜기 직전에 한 번 더 0단계 명령을 실행했고 두 결과가 같았습니다.

| 항목 | 켜기 전 값 |
|---|---|
| 목적지 | `XRay`, `ACTIVE` |
| 색인 규칙 | `Default`, 0% |
| 표본 규칙 | `Default` 하나, rate 0.05, reservoir 1 (기본값) |
| 그 리전의 Logs 리소스 정책 | 없음 |
| `aws/spans` 로그 그룹 | 없음 |

이 표를 "되돌리기 기준값"으로 문서에 적고, "켜기 직전에 다시 읽어 기록과 다르면 멈추고 사람에게 묻는다"는 규칙을 같이 두었습니다.

**켜기는 사람이.** 계정 공용 설정을 바꾸는 쓰기 작업이라, 에이전트가 직접 실행하지 않고 제가 명령을 보고 실행했습니다. 색인 비율은 무료 범위인 1%로 했고, 더 올릴지는 첫 배포 뒤 비용을 보고 정하기로 남겨 두었습니다.

**켠 직후 확인.** 목적지는 `CloudWatchLogs`·`PENDING`이었고, 표본 규칙은 그대로, 리소스 정책은 생겼고, 색인은 1%였습니다. 30초마다 상태를 읽으며 기다렸더니 약 5분 반 뒤에 `ACTIVE`가 됐습니다. 문서의 "10분" 안쪽이었습니다.

**되돌리기 준비.** 프로젝트 단계가 끝나면 되돌리기로 하고 순서를 적어 두었습니다(아직 실행 전입니다). 아래는 그 순서에 대기와 중단 조건을 넣어 다시 정리한 것입니다.

```bash
#!/usr/bin/env bash
# revert-transaction-search.sh: 파일로 저장해 `bash revert-transaction-search.sh`로 실행
# 0단계에서 저장한 값이 XRay / 0% / 정책 없음이었다고 가정
set -euo pipefail          # 한 줄이라도 실패하면 거기서 멈춘다
REGION=us-east-1           # 본인 리전으로 바꾼다

# 1) 색인 비율을 기록한 값으로
aws xray update-indexing-rule --region "$REGION" --name Default \
  --rule '{"Probabilistic":{"DesiredSamplingPercentage":0}}'

# 2) 목적지를 XRay로 (응답이 PENDING일 수 있다)
aws xray update-trace-segment-destination --destination XRay --region "$REGION"

# 3) Destination=XRay, Status=ACTIVE를 둘 다 돌려줄 때까지 기다린다 (30초 간격, 최대 15분)
done_switch=no
for _ in $(seq 1 30); do
  aws xray get-trace-segment-destination --region "$REGION"
  ready=$(aws xray get-trace-segment-destination --region "$REGION" \
    --query "Destination=='XRay' && Status=='ACTIVE'" --output text)
  if [ "$ready" = "True" ]; then
    done_switch=yes
    break
  fi
  sleep 30
done

if [ "$done_switch" != yes ]; then
  echo "목적지 전환이 끝나지 않았다. 리소스 정책은 지우지 않고 멈춘다. 사람이 확인할 것." >&2
  exit 1
fi

# 4) 전환이 끝난 것을 확인한 뒤에만 정책을 지운다
aws logs delete-resource-policy --policy-name TransactionSearchXRayAccess --region "$REGION"

# 5) 0단계 명령을 다시 실행해 저장한 기준값 파일과 비교한다
```

켤 때의 반대 순서입니다. 요약을 멈추고(색인), 길을 되돌리고(목적지), 마지막에 문을 닫습니다(정책).

여기서 가장 조심할 곳은 3번입니다. 목적지 변경 명령은 성공해도 `PENDING`을 돌려줄 수 있어서, 명령이 끝났다는 것만으로 전환이 끝났다고 볼 수 없습니다. 전환 중에 정책부터 지우면 X-Ray가 아직 로그 그룹에 쓰려는데 권한이 없는 상태가 생길 수 있습니다. 그래서 `get-trace-segment-destination`이 `Destination=XRay`와 `Status=ACTIVE`를 **둘 다** 돌려준 뒤에만 정책을 지웁니다. 중간에 명령이 실패하거나 기다리는 시간이 넘으면 정책을 지우지 않고 멈춰서 사람이 확인합니다. 스크립트 맨 위의 `set -euo pipefail`은 앞 명령이 실패했는데 다음 줄이 그대로 실행되는 일을 막습니다. 대화형 셸에 붙여 넣지 말고 파일로 실행하세요(실패 시 `exit`가 터미널을 닫을 수 있습니다).

표본 규칙은 바꾸지 않았으니 그대로인지 확인만 하고, `aws/spans` 로그 그룹은 남길 기록을 정리한 뒤 지울지 사람이 정하기로 했습니다.

솔직하게 적어 두면, 이번처럼 CLI로 켠 구성에 대한 별도 비활성화 절차는 공식 문서에서 찾지 못했습니다. 위 명령은 API가 허용하는 값(`XRay | CloudWatchLogs`)과 켜는 절차를 거꾸로 적용한 것이고, 아직 실행해 보지 않았습니다. 참고로 CloudFormation(`AWS::XRay::TransactionSearchConfig`)으로 켠 구성에 대해서는 "스택을 삭제하면 Transaction Search가 꺼지고 `aws/spans` 로그 그룹은 남는다"는 [공식 안내](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-Transaction-Search-Cloudformation.html)가 있습니다. 처음부터 CloudFormation으로 구성한 경우의 이야기라서, 이번 같은 CLI 구성에 그 방법을 가져다 쓰라는 뜻은 아닙니다.

## 주의할 점

- **계정 공용 설정입니다.** 켜기 전에 같은 계정·리전을 쓰는 다른 팀이 있는지 확인하세요. 되돌릴 때도 직전에 "그 사이 누가 바꿨나"를 먼저 묻고, 바뀌었으면 덮어쓰지 않습니다. 남이 켜 둔 것을 내 기준값으로 꺼 버릴 수 있기 때문입니다.
- **"기본값으로"가 아니라 "기록한 값으로" 되돌립니다.** 처음 읽은 값이 `XRay`·0%가 아닐 수도 있습니다. 되돌리기 명령의 값은 0단계에서 저장한 표에서 가져옵니다.
- **문서 예시의 `aws:SourceArn`을 확인하고 복사하세요.** AgentCore observability 문서의 한 줄짜리 CLI 예시는 `aws:SourceArn`을 `arn:partition:logs:...`로 적었지만, 같은 페이지의 펼친 JSON과 CloudWatch 문서는 `arn:aws:xray:<region>:<account>:*`입니다. 요청을 보내는 주체가 X-Ray이므로 X-Ray ARN이 맞습니다.
- **`ModifiedAt` 하나만 보고 판단하지 마세요.** [API 문서](https://docs.aws.amazon.com/xray/latest/api/API_IndexingRule.html)상 `ModifiedAt`은 색인 규칙을 마지막으로 수정한 시각입니다. 그런데 제 조회에서는 바꾼 기억이 없는데도 조회할 때마다 조회 시각으로 나와서, "누가 색인 규칙을 바꿨나" 하고 의심했습니다. 제가 확인한 CloudTrail 범위에서는 X-Ray `Update*` 변경 이벤트를 찾지 못했고, 원인은 확인하지 못했습니다. 그러니 변경 여부는 이 값 하나가 아니라 실제 규칙 값(비율), CloudTrail 이벤트, 문서상의 의미를 함께 놓고 판단하세요.
- **span에 본문이 실릴 수 있습니다.** AgentCore 문서의 `AWS_GENAI_CONTENT_EXTRACTION_OPT_OUT` 설명("Keeps model payloads and tool request/response data on spans")처럼, span 속성에는 모델 입력·출력과 도구 요청·응답이 남을 수 있습니다. 민감한 데이터를 다루는 에이전트라면 `aws/spans`(또는 에이전트 로그 그룹)의 보관 기간과 접근 권한, 마스킹을 미리 정해 두세요.
- **배포 방법에 따라 켜지는 방식이 다릅니다.** AgentCore CLI(`agentcore deploy`)는 기본적으로 Transaction Search를 자동으로 켭니다(끄는 설정 `agentcore config transactionSearch false`가 있습니다). 공용 계정이라면 배포 전에 이 기본값을 알고 정하세요. 다른 방법으로 배포한다면 배포 구성에 활성화 설정이 있는지 확인하세요.
- 작은 함정 하나: 확인 명령을 묶을 때 zsh에서 구분선으로 `echo ===`를 쓰면 `=` 확장 때문에 `== not found`로 실패하고 묶음 전체가 종료 코드 1을 냅니다. `echo '==='`처럼 따옴표로 감싸세요.

## 체크리스트

**켜기 전**
- [ ] 목적지, 색인 규칙, 표본 규칙(줄이지 않은 전체), 그 리전의 Logs 리소스 정책, `aws/spans` 존재 여부를 읽어 파일로 저장한다
- [ ] 같은 계정·리전을 쓰는 다른 팀·프로젝트가 있는지 확인한다

**켜기**
- [ ] 리소스 정책 → 목적지 `CloudWatchLogs` → 색인 1% 순서로 실행한다
- [ ] `get-trace-segment-destination`이 `ACTIVE`가 될 때까지 기다린다 (몇 분)
- [ ] `aws/spans` 보관 기간을 정한다
- [ ] 비용 알림을 걸어 둔다

**되돌리기**
- [ ] 직전에 다른 사람이 설정을 바꿨는지 확인한다 (바뀌었으면 덮어쓰지 않는다)
- [ ] 기록한 값으로 색인 비율을 되돌린다
- [ ] 목적지를 `XRay`로 바꾼다
- [ ] `get-trace-segment-destination`이 `Destination=XRay`, `Status=ACTIVE`를 둘 다 돌려줄 때까지 기다린다 (오류나 시간 초과면 여기서 멈추고 사람이 확인한다)
- [ ] 그다음에만 리소스 정책을 지운다
- [ ] 표본 규칙이 그대로인지 본다
- [ ] `aws/spans` 로그 그룹을 남길지 지울지 정한다
- [ ] 처음 읽기 명령을 다시 돌려 기준값과 비교한다

## 정리

- span은 작업 하나의 기록이고, span이 이어진 것이 trace입니다. 에이전트에서는 모델·도구·메모리 호출 하나하나가 span입니다.
- Transaction Search는 X-Ray가 받은 span의 목적지를 X-Ray 저장소에서 CloudWatch Logs `aws/spans`로 바꾸고, 전부를 검색하게 하며, trace ID 기준으로 고른 일부 trace만 trace summary로 색인합니다.
- 켜는 순서는 리소스 정책(문 열기) → 목적지(길 돌리기) → 색인 비율(요약할 양)입니다.
- 표본 추출은 "기록할지", 색인은 "기록된 것 중 요약할지"입니다. 둘은 다른 설정입니다.
- 계정(실무상 그 리전) 전체에 걸리는 설정이라, 켜기 전에 기록하고 되돌릴 때는 기록한 값으로 되돌립니다.

에이전트와 일하다 보면 "뭐야?"라는 질문이 결정 한 칸으로 정리되고 넘어가는 순간이 있습니다. 계정 설정을 바꾸는 항목이라면 그 자리에서 설명을 듣고 나서 결정하는 것이 맞았습니다. 다음에는 그렇게 하려고 합니다.
