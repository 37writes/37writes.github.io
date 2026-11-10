---
title: "KVS 큰 그림: 카메라 영상은 '땡겨오는' 게 아니라 만나서 흐른다"
date: 2026-11-10 10:00:00 +0900
categories: [AWS, 영상 스트리밍]
tags: [aws-concepts, aws, kvs, webrtc, kinesis-video-streams, iot, cognito]
description: "현장 장비 카메라를 브라우저에서 실시간으로 보려다 만난 질문에서 출발해, Kinesis Video Streams의 비디오 스트림과 WebRTC 신호 채널의 차이, 시그널링·길 찾기·미디어 세 층, 마스터와 뷰어, 브라우저와 장비가 받는 두 갈래 임시 자격을 정리합니다."
---

> **시리즈: AWS KVS로 실시간 영상 보내기**
> 1. **KVS 큰 그림: 영상은 '땡겨오는' 게 아니라 만나서 흐른다** ← 지금 글
> 2. 시그널링: SDP offer/answer와 KVS 신호 채널
> 3. NAT와 STUN: 왜 두 기기는 바로 못 붙나
> 4. TURN과 ICE: 끝내 못 붙으면 중계한다
> 5. 암호화와 브라우저 보안: DTLS-SRTP, 그리고 CSP
> 6. 녹화: KVS WebRTC 수집과 저장 세션
> 7. 다시 보기: HLS 원리와 KVS 재생

현장 장비의 상태를 웹에서 보는 관제 웹 대시보드를 AI 에이전트와 같이 만들고 있었습니다. 장비는 카메라가 달린 원격 장비이고, 안에 실린 작은 보조 컴퓨터가 AWS IoT Core에 MQTT(상태 메시지를 주고받는 가벼운 메시징 방식)로 붙어 위치와 상태를 올립니다. 카메라도 이미 화면에 나오긴 했습니다. 다만 장비가 작은 JPEG 사진을 **1초에 한 장** MQTT로 보내고, 대시보드가 그림을 바꿔 그리는 방식이었습니다. 움직이는 장비를 보기에는 너무 느렸습니다.

그래서 에이전트에게 이렇게 부탁했습니다.

> Amazon Kinesis Video Streams(KVS)로 장비 영상을 **땡겨오는** 기능 개발을 검토해 줘.

머릿속 그림은 단순했습니다. 브라우저가 어떤 주소로 "영상 주세요"라고 요청하면, 장비나 AWS 어딘가가 영상을 내려보내 주는 그림입니다. 파일을 내려받거나 유튜브를 트는 것과 같은 모양입니다.

돌아온 설계는 그림이 달랐습니다. **장비가 먼저 KVS에 접속해서 기다리고, 브라우저가 그 자리로 찾아갑니다.** 둘은 거기서 "나는 이런 영상을 이런 주소로 받을 수 있다"는 쪽지를 주고받고, **영상은 그 자리를 거치지 않고 다른 길로** 흐릅니다. 쪽지를 주고받는 길과 영상이 흐르는 길이 따로였습니다. 게다가 KVS 안에도 영상을 다루는 기능이 두 갈래 있었고, 내가 떠올린 "땡겨오기"는 오히려 다른 쪽 기능에 더 가까웠습니다.

이 글은 그 차이를 정리한 시리즈의 첫 편입니다. KVS의 두 기능이 무엇이 다른지, WebRTC가 왜 "만나서 흐르는" 구조인지, KVS가 그 구조에서 무엇을 맡는지, 그리고 브라우저와 장비가 **각각 어떤 자격으로** KVS에 접속하는지를 공식 문서 기준으로 기초부터 짚습니다. 뒤 편에서 다룰 시그널링, NAT·STUN, TURN·ICE, 암호화, 녹화, 다시 보기가 이 큰 그림의 어디에 놓이는지도 지도처럼 보여 드립니다. 마지막에는 그때 실제로 정한 것으로 돌아옵니다.

## Kinesis Video Streams에는 영상 기능이 두 갈래 있다

"KVS"라고 하면 한 가지 서비스처럼 들리지만, 실시간 영상을 생각할 때는 두 기능을 나눠 봐야 합니다. 이 구분이 이 시리즈 전체의 출발점입니다.

### 비디오 스트림: 클라우드로 올려 보관하고, 꺼내 본다

첫째는 이름 그대로의 **Kinesis 비디오 스트림(video stream)**입니다. [공식 개발자 안내서](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/what-is-kinesis-video.html)는 이것을 장치의 라이브 영상을 AWS 클라우드로 보내고, 실시간 처리나 배치 분석 애플리케이션을 만드는 관리형 서비스로 설명합니다. 핵심 동작은 이렇습니다.

- **올리기**: 카메라 쪽 프로그램(생산자, producer)이 [`PutMedia`](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/API_dataplane_PutMedia.html)로 영상을 보냅니다. `PutMedia`는 요청 하나에 조각 하나를 보내는 보통의 REST 호출이 아니라, **오래 열어 두는 HTTP 연결** 하나로 조각(fragment)을 계속 흘려보내는 API입니다. 형식은 Matroska(MKV, 압축된 영상과 소리를 시간 순서대로 담는 컨테이너 형식)만 받고, MKV의 클러스터 하나가 KVS의 조각 하나가 됩니다.
- **보관하기**: 스트림에 보관 기간을 정하면 KVS가 조각을 저장하고 저장 상태로 암호화합니다. 보관 기간([`DataRetentionInHours`](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/API_CreateStream.html))의 기본값은 0이고, 0이면 스트림이 데이터를 계속 보관하지 않습니다. 조각에는 생산자 시각과 서버가 받은 시각이 함께 붙어서, 나중에 시간으로 찾을 수 있습니다.
- **꺼내 보기**: 저장된 조각을 `GetMedia`로 그대로 읽거나, HLS·DASH 같은 표준 재생 방식으로 봅니다.

여기서 HLS(HTTP Live Streaming)가 바로 "땡겨오기"의 그림입니다. 플레이어가 재생 목록 파일을 받고, 거기 적힌 조각 파일을 HTTP로 **하나씩 내려받아** 이어 붙입니다. 브라우저가 묻고 서버가 답하는, 우리에게 익숙한 웹 요청의 모양입니다. 대신 조각 단위로 움직이므로 지연이 생깁니다. [KVS HLS 안내서](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/hls-playback.html)는 라이브 재생 지연을 **보통 3~5초, 경우에 따라 1~10초**로 적고, 지연이 조각 길이보다 짧을 수는 없다고 설명합니다. HLS의 원리와 KVS 재생은 7편에서 자세히 다룹니다.

### WebRTC 신호 채널: 두 기기가 직접 만나게 해 준다

둘째는 **Kinesis Video Streams with WebRTC**입니다. [WebRTC 개발자 안내서](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/what-is-kvswebrtc.html)는 WebRTC를 브라우저와 모바일 앱 사이의 실시간 통신(RTC)을 위한 열린 기술 규격으로 소개하고, 사람과 사람이 주고받기에 필요한 **낮은 지연**의 미디어 전송을 위해 **피어 사이 직접 교환(peer-to-peer)**을 쓴다고 설명합니다. KVS는 이 표준을 **완전 관리형**으로 제공합니다. 안내서의 표현으로는 시그널링 서버나 미디어 중계 서버 같은 WebRTC용 클라우드 인프라를 **직접 만들고 운영하고 늘릴 필요가 없다**는 것이 핵심입니다.

이 기능의 중심 리소스는 스트림이 아니라 **신호 채널(signaling channel)**입니다. 신호 채널에는 영상이 저장되지 않습니다. 채널은 두 기기가 연결을 찾고, 맺고, 끊는 데 필요한 **쪽지(시그널링 메시지)**를 전달할 뿐이고, 영상은 두 기기 사이에서 따로 흐릅니다. 신호 채널만으로는 녹화가 남지 않습니다.

### 둘을 비교하면

| | 비디오 스트림 | WebRTC 신호 채널 |
|---|---|---|
| 중심 리소스 | 스트림(보관 기간을 정할 수 있는 저장소) | 신호 채널(연결을 주선하는 자리) |
| 영상이 지나는 곳 | 항상 KVS를 거침. 보관 기간(`DataRetentionInHours`)이 0보다 크면 저장 | 두 기기 사이 직접, 안 되면 TURN 중계 |
| 보내는 방법 | `PutMedia`(MKV 조각을 오래 열린 HTTP 연결로) | WebRTC 연결(SRTP, 보통 UDP) |
| 보는 방법 | HLS·DASH·`GetMedia`로 꺼내 봄 | 브라우저의 `RTCPeerConnection`으로 받음 |
| 지연 | HLS 라이브 보통 3~5초 | 실시간 대화용(낮은 지연) |
| 방향 | 생산자 → 클라우드 → 소비자 한 방향 | 양방향 가능(말하기·듣기 둘 다) |
| 녹화 | 보관 기간을 0보다 크게 정하면 남음(기본값 0은 보관 안 함) | 따로 없음(아래 "WebRTC 수집"으로 연결) |

어느 쪽을 쓸지는 **사람이 지금 화면을 보고 반응해야 하는가**로 고르면 대체로 맞습니다. 원격 장비를 보면서 조종하거나, 문 앞에 누가 왔는지 보고 말을 거는 일은 몇 초의 지연도 거슬립니다. 이때가 WebRTC입니다. 반대로 나중에 다시 보거나, 쌓인 영상을 분석하거나, 여러 사람이 몇 초 늦게 봐도 되는 경우라면 비디오 스트림과 HLS가 단순합니다.

둘 다 필요할 때도 있습니다. 실시간으로 보면서 녹화도 남기고 싶은 경우입니다. KVS는 이를 위해 **WebRTC 수집(WebRTC ingestion)**이라는 기능으로 신호 채널과 스트림을 잇습니다. [안내서](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/webrtc-ingestion.html)는 이 기능으로 1초 미만 지연의 실시간 스트리밍과 클라우드 저장을 함께 할 수 있다고 설명합니다. 채널을 스트림에 연결하면 연결 구조가 꽤 달라지는데, 이 이야기는 6편에서 따로 합니다. 이 글은 **녹화를 연결하지 않은 신호 채널**을 기준으로 큰 그림을 그립니다.

## '땡겨오기'와 '만나서 흐르기'는 무엇이 다른가

그러면 WebRTC는 왜 "브라우저가 요청하고 장비가 답하는" 모양이 아닐까요. 이유는 **누가 누구에게 먼저 연결을 걸 수 있는가**에 있습니다.

웹 페이지를 열 때 브라우저가 서버에 바로 연결할 수 있는 것은, 서버가 인터넷 어디서나 찾아갈 수 있는 **공개 주소**에 있기 때문입니다. 현장 장비는 사정이 다릅니다. 장비는 대개 공유기나 이동통신망 같은 **NAT(주소 변환 장치)** 뒤에 있습니다. NAT 뒤의 기기는 바깥으로 연결을 걸 수는 있지만, 별도로 포트를 열어 두지 않은 일반적인 환경에서는 바깥에서 먼저 들어오는 연결을 받지 못합니다. 브라우저도 마찬가지로 사무실이나 집의 NAT 뒤에 있는 경우가 많습니다. 결국 **서로가 서로에게 먼저 걸 수 없는** 두 기기가 영상을 주고받아야 합니다. NAT가 정확히 무엇을 기억하고 무엇을 막는지는 3편에서 패킷 단위로 풀어 봅니다.

방법은 두 단계입니다.

1. **둘 다 찾아갈 수 있는 제3의 자리에서 만난다.** 공개 주소에 있는 서버는 양쪽 모두 바깥으로 연결을 걸어 닿을 수 있습니다. 장비가 먼저 그 자리에 접속해 기다리고, 브라우저가 나중에 같은 자리로 접속합니다. 이 자리에서 둘은 "나는 이런 형식의 영상을 주고받을 수 있고, 나에게는 이런 주소들로 닿을 수 있을지 모른다"는 쪽지를 교환합니다. 이것이 **시그널링**이고, KVS 신호 채널이 바로 그 자리입니다.
2. **쪽지에 적힌 주소로 직접 길을 뚫어 본다.** 둘은 서로의 후보 주소로 동시에 패킷을 보내 봅니다. 양쪽이 동시에 바깥으로 패킷을 내보내면, 각자의 NAT가 "내가 먼저 보낸 상대의 답"으로 여겨 통과시키는 경우가 많습니다. 길이 뚫리면 영상은 그 길로 직접 흐릅니다. 끝내 뚫리지 않으면, 둘 다 닿을 수 있는 **중계 서버(TURN)**를 거쳐 흐릅니다.

비유로 말하면 시그널링은 **공용 게시판**입니다. 두 사람이 같은 게시판에 각자 연락처와 통화 가능한 방법을 적어 두고, 상대의 메모를 읽은 다음 **게시판이 아니라 전화로** 직접 이야기합니다. 전화가 안 터지면 교환원(TURN)을 거쳐 연결합니다. 게시판에는 대화 내용이 남지 않습니다.

비유를 실제 동작으로 옮기면 이렇습니다. 게시판에 적는 메모는 **SDP**(세션 설명, 어떤 코덱과 해상도로 주고받을지. 코덱은 영상을 압축하고 복원하는 규칙으로, 압축된 결과를 담는 MKV 같은 컨테이너와는 다른 개념입니다)와 **ICE 후보**(나에게 닿을 수 있는 IP와 포트 목록)입니다. 이 메모는 KVS 신호 채널의 WebSocket으로 오가며 크기가 몇 KB 수준입니다. 전화 통화에 해당하는 영상은 SRTP 패킷으로 흐르고, 신호 채널을 지나지 않습니다. 직접 경로에서는 보통 UDP로 오가고, TURN 중계를 거칠 때는 기기와 TURN 서버 사이가 TCP나 TLS일 수도 있습니다. 어느 경우든 쪽지 창구와 영상 길은 브라우저 안에서도 서로 다른 연결(WebSocket과 `RTCPeerConnection`)입니다.

"땡겨오기"라는 말이 틀린 것은 아니지만, WebRTC에서는 **당기는 쪽이 따로 없습니다.** 둘이 같은 자리에서 만나 합의하고, 합의한 길로 영상이 흐를 뿐입니다.

## WebRTC의 세 층: 시그널링, 길 찾기, 미디어

WebRTC 연결은 세 층으로 나눠 보면 이해가 쉽습니다. 각 층은 무엇이 오가는지, 누가 만들어 주는지가 다릅니다.

<figure class="diagram">
{% include figures/kvs-webrtc-big-picture/signaling-vs-media.svg %}
<figcaption>시그널링(점선)은 KVS 신호 채널을 거쳐 연락처만 오가고, 영상(실선)은 장비와 브라우저 사이의 직접 경로나 TURN 중계로 따로 흐른다. STUN은 바깥 주소만 알려 주고 영상을 나르지 않는다</figcaption>
</figure>

### 1층, 시그널링: 연락처를 주고받는다

연결을 맺기 전에 두 기기는 서로를 알아야 합니다. 주고받는 것은 두 가지입니다.

- **SDP offer / answer**: 한쪽이 "이런 미디어를 이런 조건으로 주고받고 싶다"는 제안(offer)을 보내면, 다른 쪽이 "그중 이것을 받아들인다"는 응답(answer)을 돌려줍니다. SDP(Session Description Protocol)는 코덱, 해상도, 암호화에 쓸 정보 같은 세션 내용을 적는 표준 형식입니다.
- **ICE 후보(candidate)**: "나에게 닿을 수 있는 주소" 목록입니다. 같은 망 안의 주소, NAT 바깥에서 보이는 주소, 중계 서버의 주소가 후보가 됩니다.

흥미로운 점은 **WebRTC 표준이 이 쪽지를 어떻게 전달할지는 정하지 않는다**는 것입니다. [KVS 동작 원리 문서](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/kvswebrtc-how-it-works.html)도 이 교환의 전송 방식은 표준에 정해져 있지 않으며 HTTPS나 보안 WebSocket 등 어떤 방식이든 쓸 수 있다고 적습니다. 그래서 WebRTC 서비스를 직접 만들면 시그널링 서버부터 만들어야 하고, KVS는 이 부분을 **신호 채널과 WebSocket API**로 대신해 줍니다. 쪽지 하나의 크기는 정해져 있습니다. [KVS WebRTC 할당량](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/kvswebrtc-limits.html) 표에서 `SendSDPOffer`, `SendSDPAnswer`, `SendICECandidate` 메시지는 **각각 최대 10k(조정 불가)**입니다. offer와 answer의 순서, 메시지 보관 같은 자세한 동작은 2편에서 다룹니다.

### 2층, 길 찾기: STUN, TURN, ICE

쪽지에 적을 주소를 모으고, 그중 실제로 통하는 길을 고르는 층입니다.

- **STUN**(Session Traversal Utilities for NAT, [RFC 8489](https://www.rfc-editor.org/rfc/rfc8489)): 기기가 STUN 서버에 요청을 보내면, 서버는 "그 요청이 어느 공인 IP와 포트에서 왔는지"를 알려 줍니다. 기기는 이것으로 NAT 바깥에서 자신이 어떻게 보이는지 압니다. 다만 이 주소는 **그 STUN 서버에서 본 주소**이고, 다른 상대에게도 같은 주소로 닿는다는 보장은 없습니다(3편). STUN 서버는 영상을 나르지 않습니다.
- **TURN**(Traversal Using Relays around NAT, [RFC 8656](https://www.rfc-editor.org/rfc/rfc8656)): 직접 길이 끝내 안 뚫릴 때 영상을 **대신 받아 넘겨 주는** 중계 서버입니다. 기기는 TURN 서버에 자기 몫의 중계 주소를 하나 할당받고, 그 주소도 후보로 상대에게 알립니다.
- **ICE**(Interactive Connectivity Establishment, [RFC 8445](https://www.rfc-editor.org/rfc/rfc8445)): 위 후보들을 모으고, 상대의 후보와 짝을 지어 하나씩 시험해서 쓸 길을 고르는 절차입니다.

KVS 동작 원리 문서는 이 과정을 후보를 모두 모은 뒤 한 번에 보내는 **단순화한 흐름**으로 설명합니다. A는 STUN 서버에 요청을 보내 자신의 공인 주소를 알아내고 후보 목록에 넣은 뒤 offer를 만듭니다. offer는 신호 채널을 통해 B에게 갑니다. B도 같은 방식으로 후보를 모아 answer를 돌려줍니다. 그다음 양쪽의 ICE는 상대가 알려 준 후보 주소마다 **STUN 요청을 직접 보내 보고**(연결 검사), 응답이 돌아온 짝을 쓸 수 있는 길로 표시합니다. 그중 한 짝을 골라 미디어를 흘립니다.

실제 브라우저와 KVS SDK 예제는 이보다 겹쳐서 움직입니다. offer를 먼저 보내고 후보는 찾는 대로 하나씩 따로 보내는 **trickle ICE**([RFC 8838](https://www.rfc-editor.org/rfc/rfc8838))라서, 후보 수집과 교환과 연결 검사가 동시에 진행됩니다. TURN 중계 주소(relay 후보)도 직접 경로가 실패한 뒤에야 구하는 것이 아니라, 수집 단계에서 다른 후보와 함께 미리 확보해 상대에게 알립니다. 또 모든 짝의 시험이 끝나기를 기다리지 않습니다. 연결을 주도하는 쪽(controlling agent)이 검사를 통과한 짝을 지명(nomination)하면 그 짝으로 전송이 시작됩니다([RFC 8445](https://www.rfc-editor.org/rfc/rfc8445) §2.3, §8.1). 직접 통하는 짝이 있으면 보통 그쪽이, 통하는 짝이 relay뿐이면 TURN 경로가 쓰입니다. 후보의 종류와 우선순위, 지명 과정은 4편에서 자세히 다룹니다.

KVS는 이 층에서 **STUN과 TURN 서버를 리전마다 제공**합니다. TURN의 접속 정보(주소, 사용자 이름, 비밀번호)는 [`GetIceServerConfig`](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/API_signaling_GetIceServerConfig.html) API가 내주고, 이 자격은 **5분짜리**입니다(할당량 표의 "Credential Lifecycle"). STUN 주소는 리전마다 정해진 이름이라 [KVS WebRTC JavaScript SDK의 예제](https://github.com/awslabs/amazon-kinesis-video-streams-webrtc-sdk-js)는 `stun:stun.kinesisvideo.<리전>.amazonaws.com:443` 형식으로 직접 만들어 넣습니다. 왜 두 기기가 바로 못 붙는지는 3편, TURN과 ICE의 후보 고르기는 4편에서 단계별 그림으로 다룹니다.

### 3층, 미디어: 고른 길로 암호화된 영상이 흐른다

길이 정해지면 비로소 영상과 소리가 흐릅니다. WebRTC 미디어는 **SRTP**(암호화된 RTP)로 나갑니다. RTP는 실시간 음성·영상을 작은 패킷으로 나누고 순서 번호와 시각 정보를 붙여 보통 UDP로 나르는 형식이고, SRTP는 그 RTP를 암호화한 것입니다. 암호화 키는 시그널링으로 보내지 않고, 두 기기가 고른 길 위에서 **DTLS 핸드셰이크**(DTLS는 UDP처럼 패킷 단위로 오가는 통신에 쓰는 TLS 계열 보안 절차입니다)로 직접 정합니다(DTLS-SRTP, [RFC 5764](https://www.rfc-editor.org/rfc/rfc5764)). WebRTC 보안 구조([RFC 8827](https://www.rfc-editor.org/rfc/rfc8827))는 미디어 암호화를 선택 사항이 아니라 필수로 둡니다. 그래서 TURN 중계를 거치더라도 중계 서버는 암호화된 패킷을 넘길 뿐입니다. 이 층은 5편에서 다룹니다.

### 시리즈 지도

| 층 | 무엇이 오가나 | KVS가 주는 것 | 다루는 편 |
|---|---|---|---|
| 시그널링 | SDP offer/answer, ICE 후보 (몇 KB) | 신호 채널, 서명한 WebSocket 주소 | 2편 |
| 길 찾기 | STUN 요청·응답, 연결 시험 | 리전별 STUN, TURN(`GetIceServerConfig`) | 3편, 4편 |
| 미디어 | DTLS 핸드셰이크, SRTP 영상·소리 | TURN 중계(직접 길이 없을 때) | 5편 |
| 녹화·다시 보기 | 저장 세션 → 스트림, HLS 조각 | WebRTC 수집, 비디오 스트림, HLS | 6편, 7편 |

## KVS WebRTC의 역할 이름: 신호 채널, 마스터, 뷰어

KVS로 WebRTC를 쓰면 몇 가지 이름을 계속 만나게 됩니다. [동작 원리 문서](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/kvswebrtc-how-it-works.html)의 정의를 기준으로 정리합니다.

### 신호 채널과 채널 형식

**신호 채널**은 애플리케이션들이 시그널링 메시지를 주고받아 피어 연결을 찾고, 맺고, 제어하고, 끝낼 수 있게 하는 리소스입니다. 계정과 리전 안에서 이름이 유일하고, ARN으로 권한을 겁니다. 문서는 신호 채널을 **"하나의 마스터가 여러 뷰어와 연결되는 일대소수(one-to-few) 모델"**로 설명합니다.

채널을 만드는 [`CreateSignalingChannel`](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/API_CreateSignalingChannel.html)의 `ChannelType`에는 값이 두 개 적혀 있지만(`SINGLE_MASTER | FULL_MESH`), 문서는 **지원되는 형식은 현재 `SINGLE_MASTER`뿐**이라고 적습니다. 채널에는 메시지 보관 시간(`MessageTtlSeconds`, 기본 60초)도 있습니다. 이 값이 왜 중요한지는 2편에서 실제로 겪은 일과 함께 다룹니다.

### 마스터와 뷰어

- **마스터(master)**: 연결을 **먼저 시작해 채널에서 기다리는** 쪽입니다. `ConnectAsMaster`로 채널에 접속하고, 접속한 모든 뷰어를 찾아 미디어를 주고받을 수 있습니다. 채널 하나에 마스터는 **하나**입니다.
- **뷰어(viewer)**: `ConnectAsViewer`로 접속해 **마스터하고만** 미디어를 주고받는 쪽입니다. 뷰어는 같은 채널의 다른 뷰어를 보거나 다른 뷰어와 통신할 수 없습니다.

카메라 영상을 보는 서비스라면 보통 **카메라 장비가 마스터, 브라우저가 뷰어**입니다. 그런데 이름에 속지 않아야 할 점이 있습니다. 마스터는 "영상을 보내는 쪽"이라는 뜻이 아닙니다. **먼저 접속해 기다리는 쪽, 여럿을 상대하는 쪽**이라는 뜻입니다. WebRTC는 양방향이므로 뷰어가 마이크 소리를 보내고 마스터가 받는 것도 가능합니다. 영상 방향은 SDP에서 정하는 것이고, 마스터·뷰어 역할은 "누가 채널의 주인 자리에 앉는가"를 정합니다. 역할은 접속 시간 순서나 offer를 누가 보내느냐로 저절로 정해지지 않고, 어느 접속 API(`ConnectAsMaster`/`ConnectAsViewer`)로 붙느냐로 정해집니다.

### 한도: 마스터 1, 뷰어 10, 연결 1시간

[할당량 페이지](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/kvswebrtc-limits.html)를 이 글을 쓰며 다시 열어 확인한 값입니다. **[s]**는 늘려 달라고 요청할 수 있는 값, **[h]**는 고정 값입니다.

| 항목 | 값 |
|---|---|
| 채널당 동시 마스터 연결(`ConnectAsMaster`) | 1 [h] |
| 채널당 동시 뷰어 연결(`ConnectAsViewer`) | 10 [s] |
| 시그널링 연결 최대 유지 시간 | 1시간 [h] |
| 시그널링 연결 유휴 제한 | 10분 [h] |
| `GO_AWAY` 메시지 뒤 연결이 끊길 때까지 | 최대 1분 [h] |
| SDP offer·answer, ICE 후보 메시지 크기 | 각 10k [h] |
| TURN 비트레이트 | 5Mbps [h] |
| TURN 자격 유효 시간 | 5분 [h] |
| TURN 할당 수 | 채널당 50 [h] |
| 녹화 채널의 저장 세션(`JoinStorageSessionAsViewer`) 동시 클라이언트 | 3 [h] |

이 표에서 기억할 것이 세 가지입니다.

첫째, **뷰어 10명은 시그널링 연결의 한도**입니다. 영상을 10명에게 무리 없이 보낼 수 있다는 뜻은 아닙니다. 녹화를 연결하지 않은 채널에서 마스터는 뷰어마다 **따로** WebRTC 연결을 맺습니다. 연결마다 영상이 따로 나가므로 장비의 업로드는 대략 "비트레이트 × 시청자 수"가 됩니다. 업로드가 빠듯한 원격 장비라면 한도보다 이쪽이 먼저 문제가 됩니다. 녹화를 연결하면 이 구조가 바뀌고 한도도 3으로 내려갑니다(6편).

둘째, **시그널링 연결은 오래 살지 못합니다.** 최대 1시간, 유휴 10분입니다. 장비처럼 채널에서 계속 기다려야 하는 마스터는 끊기면 다시 접속하도록 만들어야 하고, 서비스가 곧 끊는다는 뜻의 `GO_AWAY`를 받으면 1분 안에 새로 접속해야 합니다. 이 한도는 쪽지 창구(WebSocket)의 수명입니다. 영상이 흐르는 `RTCPeerConnection`은 별개 연결이라, 시그널링이 끊기는 것과 영상이 끊기는 것은 따로 살펴야 합니다.

셋째, **TURN 중계는 세션당 5Mbps가 상한이고 늘릴 수 없습니다.** 중계로 흐를 가능성이 있다면 화질 설계를 이 상한 안에서 해야 합니다.

### 가장 최근에 접속한 마스터가 이긴다

마스터가 하나뿐이라면, 두 번째 마스터가 접속하면 어떻게 될까요. 거절될 것 같지만 그렇지 않습니다. [`ConnectAsMaster` API 문서](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/kvswebrtc-websocket-apis-2.html)는 이렇게 적습니다.

> If more than one client connects as master to a specific channel, then the most recent request takes precedence. Existing connection metadata is overwritten by the new one.

여러 클라이언트가 같은 채널에 마스터로 접속하면 **가장 최근 요청이 우선**하고, 기존 연결 정보는 새것으로 덮어씌워집니다. 즉 그 채널의 `ConnectAsMaster` 권한을 가진 누구든 **진짜 장비를 밀어내고 그 자리에 앉을 수 있습니다.** 그러면 그다음에 들어온 뷰어는 가짜 마스터가 보내는 영상을 보게 됩니다.

그래서 KVS WebRTC의 권한 설계는 "누가 볼 수 있나"만큼 **"누가 마스터 자리에 앉을 수 있나"**가 중요합니다. 이 점이 다음 절의 자격 설계로 이어집니다.

## 누가 어떤 자격으로 접속하나

이 글의 구성에서는 브라우저와 장비가 KVS의 제어 API와 시그널링 API를 **직접** 부릅니다. 이런 호출에는 AWS 자격 증명으로 만든 **SigV4 서명**이 필요하고, 시그널링 WebSocket도 접속 주소 자체에 서명을 붙입니다(서명 방식은 [인증 한 번에 정리: JWT, IAM(SigV4), Cognito]({% post_url 2026-11-01-auth-basics-jwt-iam-cognito %})에 정리해 두었습니다). 그래서 이 구성에서는 브라우저와 장비가 각자 **서명에 쓸 임시 AWS 자격**을 가져야 합니다.

다른 구성도 있습니다. [KVS WebRTC JavaScript SDK 안내](https://github.com/awslabs/amazon-kinesis-video-streams-webrtc-sdk-js)는 백엔드가 AWS 자격으로 서명한 접속 주소와 ICE 서버 정보를 만들어 브라우저에 넘겨, 브라우저는 AWS 자격을 아예 갖지 않게 하는 방법도 설명합니다. 또 HLS 재생은 재생 주소를 받는 API 호출만 서명하고, 그 뒤의 재생 목록·조각 요청은 주소에 담긴 세션 토큰으로 인증됩니다(7편). 이 글은 직접 부르는 구성을 기준으로, 그 자격을 어디서 받느냐를 봅니다. 둘은 출발점이 다르기 때문에 길도 다릅니다.

<figure class="diagram">
{% include figures/kvs-webrtc-big-picture/two-credential-paths.svg %}
<figcaption>브라우저는 로그인 토큰을 Cognito 자격 증명 풀에, 장비는 X.509 인증서를 IoT 자격 증명 공급자에 내고 각자 임시 자격 증명을 받는다. 어느 쪽에도 장기 AWS 액세스 키를 두지 않는다(장비의 인증서 개인 키는 여전히 지켜야 할 비밀이다)</figcaption>
</figure>

### 브라우저: Cognito 자격 증명 풀의 임시 자격

브라우저 쪽 사람은 **로그인**을 합니다. Cognito 사용자 풀로 로그인해 받은 ID 토큰을 **자격 증명 풀**에 내면, 자격 증명 풀이 IAM 역할을 골라 STS 임시 자격 증명(1시간)을 내줍니다. 이 과정과 역할 고르기, 신뢰 정책 조건은 [Cognito 사용자 풀과 자격 증명 풀: 로그인한 브라우저가 AWS를 직접 부르려면]({% post_url 2026-11-06-cognito-user-pool-identity-pool %})에서 자세히 다뤘습니다.

뷰어 역할에 붙일 권한은 영상을 **보는 데 필요한 동작만**입니다. 녹화를 연결하지 않은 채널이라면 다음 넷이 기본입니다.

| 동작 | 하는 일 |
|---|---|
| `kinesisvideo:DescribeSignalingChannel` | 채널 이름으로 채널 ARN과 상태를 확인 |
| `kinesisvideo:GetSignalingChannelEndpoint` | 뷰어용 WebSocket(WSS)·HTTPS 주소 받기 |
| `kinesisvideo:GetIceServerConfig` | TURN 주소와 5분짜리 자격 받기 |
| `kinesisvideo:ConnectAsViewer` | 신호 채널에 뷰어로 접속 |

반대로 **뷰어 역할에 절대 넣지 않을 것**이 `kinesisvideo:ConnectAsMaster`입니다. 앞 절에서 본 대로, 이 권한이 있으면 브라우저가 장비를 밀어내고 마스터가 될 수 있기 때문입니다. `kinesisvideo:*` 같은 와일드카드를 쓰면 이 권한이 딸려 들어가므로 동작을 하나씩 적습니다. 리소스도 내 서비스의 채널 ARN으로 좁힙니다.

### 장비: AWS IoT 자격 증명 공급자

장비에는 로그인할 사람이 없습니다. 대신 장비는 이미 **X.509 인증서**를 갖고 있습니다. AWS IoT Core에 MQTT로 붙을 때 쓰는 그 인증서입니다. IoT Core는 인증서로 상호 TLS(mTLS, 서버와 클라이언트가 서로 인증서를 확인하는 TLS) 인증을 하지만, KVS 같은 다른 AWS 서비스는 인증서 인증을 받지 않고 SigV4 서명만 받습니다.

이 틈을 메우는 것이 [AWS IoT Core 자격 증명 공급자(credentials provider)](https://docs.aws.amazon.com/iot/latest/developerguide/authorizing-direct-aws.html)입니다. 공식 문서의 표현대로, 장치에 내장된 X.509 인증서를 장치의 고유 신원으로 써서 AWS 요청을 인증하게 해 주고, 그래서 **장치에 액세스 키 ID와 비밀 액세스 키를 저장할 필요를 없애 줍니다.** 문서가 설명하는 흐름을 순서대로 옮기면 이렇습니다.

1. 장비가 자격 증명 공급자에 HTTPS 요청을 보냅니다. 이 요청은 mTLS라서 장비의 인증서와 개인 키로 연결을 맺습니다.
2. 공급자는 IoT Core의 인증·권한 모듈에 인증서가 유효한지, 그 장비가 토큰을 요청할 권한이 있는지 묻습니다.
3. 유효하고 권한이 있으면 성공, 아니면 장비에 오류를 돌려줍니다.
4. 공급자가 AWS STS에 **미리 정해 둔 IAM 역할을 대신 맡겠다**고 요청합니다.
5. STS가 권한이 제한된 임시 보안 토큰을 공급자에 돌려줍니다.
6. 공급자가 그 토큰을 장비에 넘깁니다.
7. 장비는 그 토큰으로 KVS 요청에 SigV4 서명을 합니다.
8. KVS는 IAM에 서명 확인과 권한 판단을 맡기고, IAM은 그 역할에 붙은 정책으로 판단합니다.

여기에 등장하는 이름이 몇 가지 있습니다.

- **role alias**: 장비가 "어느 IAM 역할을 맡을지"를 가리키는 별칭입니다. 장비 안에 역할 ARN을 직접 적어 두면 역할이 바뀔 때마다 장비를 고쳐야 하므로, 문서는 별칭을 두고 별칭이 가리키는 역할만 바꾸는 방법을 권합니다.
- **자격 유효 시간** (`credentialDurationSeconds`): role alias에 정하며 **최소 900초, 최대 43,200초(12시간), 기본 3,600초(1시간)**입니다. 단, 그 역할의 최대 세션 시간보다 길 수는 없습니다.
- **인증서에 붙는 IoT 정책**: 그 인증서가 어느 role alias로 역할을 맡을 수 있는지를 `iot:AssumeRoleWithCertificate` 동작으로 허용합니다.
- **역할의 신뢰 정책**: 그 역할을 `credentials.iot.amazonaws.com` 서비스가 맡을 수 있게 허용합니다.
- **Thing 이름 머리글**: 요청에 `x-amzn-iot-thingname` 머리글로 Thing 이름을 넣을 수 있습니다. 문서는 Thing 속성을 정책 변수로 쓸 때만 이 값이 필요하다고 적습니다. 그리고 이 이름은 **인증서에 연결된 Thing의 이름과 같아야 하고, 다르면 403**입니다.
- **정책 변수**: 장비가 `x-amzn-iot-thingname` 머리글로 Thing 이름을 주면 공급자는 임시 토큰에 `credentials-iot:ThingName`과 `credentials-iot:ThingTypeName`을 넣고, `credentials-iot:AwsCertificateId`는 머리글이 없어도 넣어 줍니다. 그래서 아래 정책처럼 Thing 이름을 쓰는 정책이라면 장비가 이 머리글을 꼭 보내야 하고, 빠뜨리면 이름 변수가 없어 접근이 거부될 수 있습니다. 이 세 값은 **IAM 정책에서만** 쓸 수 있고 IoT 정책에서는 쓸 수 없습니다. 역할 하나를 여러 장비가 같이 쓰더라도 "자기 Thing 이름과 같은 채널에만" 같은 규칙을 걸 수 있다는 뜻입니다.

장비가 자격을 받는 요청은 공식 문서의 예를 따르면 다음 모양입니다. 공식 예처럼 그냥 `curl`을 부르면 성공했을 때 임시 자격 전체가 터미널에 찍히므로, 여기서는 **연결 확인용**으로 응답 본문을 버리고 HTTP 상태 코드만 보게 바꿨습니다. 값은 모두 자리 표시자입니다(실행 미확인).

```sh
# 자격 증명 공급자 주소는 계정마다 다르다
aws iot describe-endpoint --endpoint-type iot:CredentialProvider

# 연결 확인용: 응답 본문(임시 자격)은 /dev/null로 버리고 상태 코드만 출력한다
curl --silent --output /dev/null --write-out "%{http_code}\n" \
  --cert device.pem.crt --key private.pem.key --cacert AmazonRootCA1.pem \
  -H "x-amzn-iot-thingname: device-a" \
  "https://<credentials-endpoint>/role-aliases/kvs-master-device-a/credentials"
# 200이면 발급 성공, 403이면 인증서·Thing 이름·IoT 정책을 확인한다
```

실제 장비 프로그램은 같은 요청을 HTTP 클라이언트로 보내고, 응답을 **메모리에서만** 읽어 서명에 씁니다. 응답 JSON은 바깥에 `credentials` 객체가 한 겹 더 있는 모양입니다.

```json
{ "credentials": { "accessKeyId": "…", "secretAccessKey": "…", "sessionToken": "…", "expiration": "…" } }
```

장비는 `credentials` 안의 세 값으로 KVS 호출에 서명하고, `expiration` 전에 같은 요청으로 새 자격을 받습니다. 이 값은 파일이나 로그에 쓰지 않습니다.

마스터 역할의 권한 정책은, 예를 들어 채널 이름을 `<Thing 이름>-cam`으로 정했다면 정책 변수로 이렇게 좁힐 수 있습니다. KVS 공식 문서의 [IoT로 스트림 접근 제어](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/how-iot.html) 예제가 스트림 ARN에 `${credentials-iot:ThingName}`을 넣는 것과 같은 방식을 신호 채널에 옮긴 것입니다(실행 미확인).

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "kinesisvideo:DescribeSignalingChannel",
        "kinesisvideo:GetSignalingChannelEndpoint",
        "kinesisvideo:GetIceServerConfig",
        "kinesisvideo:ConnectAsMaster"
      ],
      "Resource": "arn:aws:kinesisvideo:*:*:channel/${credentials-iot:ThingName}-cam/*"
    }
  ]
}
```

뷰어 역할과 반대로 여기에는 `ConnectAsMaster`가 있고 `ConnectAsViewer`가 없습니다. 장비는 마스터 역할만, 브라우저는 뷰어 역할만 맡게 하는 것입니다. 앞에서 말했듯 역할은 어느 접속 API로 붙느냐로 정해지고 영상이 흐르는 방향과는 따로입니다. 이 글의 예에서는 마스터가 채널에서 기다리고, 뷰어가 offer를 보냅니다.

### 장비에 장기 AWS 액세스 키를 두지 않는 이유

가장 쉬운 방법은 IAM 사용자를 하나 만들고 그 액세스 키를 장비에 넣어 두는 것입니다. 이 방법을 쓰지 않는 이유를 표로 비교하면 이렇습니다.

| | 장비에 IAM 액세스 키 | 인증서 → 자격 증명 공급자 |
|---|---|---|
| 키가 새면 | 지울 때까지 계속 쓸 수 있음. 바꾸려면 장비마다 새 키를 넣어야 함 | 받은 자격은 정해진 시간 뒤 만료. 단, 인증서 개인 키가 새면 인증서를 AWS에서 비활성화할 때까지 새 자격을 계속 받을 수 있음 |
| 새 비밀이 생기나 | 장비마다 키라는 비밀이 하나 더 생김 | IoT 접속에 쓰던 인증서와 개인 키를 그대로 씀(새 비밀은 없지만 개인 키는 여전히 비밀) |
| 권한 범위 | 사용자 권한 그대로, 장비별로 나누려면 사용자도 장비 수만큼 | 역할과 정책 변수로 "자기 채널의 마스터 자리만"처럼 좁힘 |
| 누가 썼나 | 같은 키를 나눠 쓰면 구별이 어려움 | 토큰에 Thing 이름과 인증서 ID가 담김 |

현장 장비는 사람 손이 닿지 않는 곳에 오래 놓여 있고, 분실되거나 디스크가 복제될 수 있습니다. 그런 장비에 "지우기 전까지 유효한 키"를 두는 것은 위험을 장비 수만큼 늘리는 일입니다. 자격 증명 공급자를 쓰면 장비에 AWS 액세스 키를 둘 필요가 없고, 받은 AWS 자격은 길어야 정해진 시간 안에 사라집니다.

그렇다고 장비에 비밀이 하나도 없는 것은 아닙니다. mTLS에는 인증서와 짝이 되는 **개인 키**가 필요합니다. 이 개인 키가 새면, 그 인증서를 AWS에서 비활성화할 때까지 누구든 같은 요청으로 새 임시 자격을 계속 받을 수 있습니다. 그래서 개인 키를 파일 권한이나 보안 하드웨어로 보호하고, 분실이나 유출이 의심되면 인증서를 바로 비활성화하는 절차가 여전히 필요합니다. 달라지는 것은 비밀의 개수와 끊는 방법입니다. IoT 접속에 이미 쓰던 비밀 하나로 끝나고, 인증서 하나를 끄면 그 장비의 새 자격 발급이 멈춥니다.

## 전체 흐름 한 번 훑기

이제 조각을 이어 붙여, 녹화를 연결하지 않은 채널에서 사용자가 카메라를 켜고 영상이 나오기까지를 따라가 봅니다.

1. **카메라 켜기 명령**: 사용자가 대시보드에서 카메라를 켜면, 기존 명령 경로(MQTT)로 장비에 "카메라 켜기"가 갑니다. 영상과는 상관없는, 이미 있던 길입니다.
2. **장비가 마스터로 접속해 기다림**: 장비는 인증서로 자격 증명 공급자에서 임시 자격을 받고, `GetSignalingChannelEndpoint`(역할 `MASTER`)로 주소를 받고, `GetIceServerConfig`로 TURN 정보를 받은 뒤, 서명한 WSS 주소로 `ConnectAsMaster` 접속을 엽니다. 아직 영상은 보내지 않습니다. 기다릴 뿐입니다.
3. **브라우저가 뷰어로 접속**: 브라우저는 로그인으로 받은 Cognito 임시 자격으로 `DescribeSignalingChannel` → `GetSignalingChannelEndpoint`(역할 `VIEWER`, WSS와 HTTPS) → `GetIceServerConfig`를 차례로 부르고, 서명한 WSS 주소로 `ConnectAsViewer` 접속을 엽니다.
4. **쪽지 교환**: 브라우저가 SDP offer를 보내고, 장비가 받아 SDP answer를 돌려줍니다. 이어서 양쪽이 ICE 후보를 주고받습니다. 후보를 다 모으기 전에 찾는 대로 하나씩 보내는 방식을 trickle ICE라고 합니다.
5. **길 찾기와 영상**: 양쪽 ICE가 후보 짝을 시험해 길을 고르고, 그 길 위에서 DTLS 핸드셰이크로 암호화 키를 정한 뒤, 장비가 SRTP로 영상을 보냅니다. 길은 직접 경로일 수도 있고 TURN 중계일 수도 있습니다.

장비는 다음 뷰어를 위해 채널에 계속 남아 있어야 하므로, 1시간·10분 한도에 맞춰 다시 접속하는 일을 스스로 해야 합니다.

브라우저 쪽 3~4단계를 코드로 줄이면 다음과 같습니다. AWS SDK for JavaScript v3와 KVS WebRTC JavaScript SDK를 쓴다고 가정한 최소 예시이고, 오류 처리와 재연결은 뺐습니다(실행 미확인). 실행하려면 몇 가지가 전제됩니다. `import`를 풀어 줄 번들러(예: Vite), Cognito 자격 증명 풀에서 미리 받아 둔 임시 자격, HTTPS 또는 `localhost`로 연 페이지, 그리고 `<video autoplay playsinline muted>` 요소입니다. 브라우저의 자동 재생 정책 때문에 소리가 켜진 영상은 사용자 동작 없이 재생이 시작되지 않을 수 있어 `muted`를 붙입니다.

```js
import { KinesisVideoClient, DescribeSignalingChannelCommand,
         GetSignalingChannelEndpointCommand } from "@aws-sdk/client-kinesis-video";
import { KinesisVideoSignalingClient,
         GetIceServerConfigCommand } from "@aws-sdk/client-kinesis-video-signaling";
import { SignalingClient, Role } from "amazon-kinesis-video-streams-webrtc";

// credentials: Cognito 자격 증명 풀에서 받은 임시 자격 (accessKeyId, secretAccessKey, sessionToken)
export async function watch(region, channelName, credentials, videoEl) {
  const kv = new KinesisVideoClient({ region, credentials });

  // ① 채널 ARN
  const { ChannelInfo } = await kv.send(
    new DescribeSignalingChannelCommand({ ChannelName: channelName }));
  const channelARN = ChannelInfo.ChannelARN;

  // ② 뷰어용 주소 (WSS: 쪽지 창구, HTTPS: ICE 서버 정보 API)
  const { ResourceEndpointList } = await kv.send(new GetSignalingChannelEndpointCommand({
    ChannelARN: channelARN,
    SingleMasterChannelEndpointConfiguration: { Protocols: ["WSS", "HTTPS"], Role: "VIEWER" },
  }));
  const ep = Object.fromEntries(ResourceEndpointList.map(e => [e.Protocol, e.ResourceEndpoint]));

  // ③ STUN(리전 고정 주소) + TURN(5분짜리 자격)
  const clientId = crypto.randomUUID();
  const sig = new KinesisVideoSignalingClient({ region, credentials, endpoint: ep.HTTPS });
  const { IceServerList } = await sig.send(
    new GetIceServerConfigCommand({ ChannelARN: channelARN, ClientId: clientId }));
  const iceServers = [
    { urls: `stun:stun.kinesisvideo.${region}.amazonaws.com:443` },
    ...IceServerList.map(s => ({ urls: s.Uris, username: s.Username, credential: s.Password })),
  ];

  // ④ 신호 채널에 뷰어로 접속하고 offer를 보낸다
  const pc = new RTCPeerConnection({ iceServers });
  pc.addTransceiver("video", { direction: "recvonly" });
  pc.ontrack = (e) => { videoEl.srcObject = e.streams[0]; };

  const signaling = new SignalingClient({
    channelARN, channelEndpoint: ep.WSS, role: Role.VIEWER,
    clientId, region, credentials,
  });
  signaling.on("open", async () => {
    await pc.setLocalDescription(await pc.createOffer());
    signaling.sendSdpOffer(pc.localDescription);
  });
  signaling.on("sdpAnswer", (answer) => pc.setRemoteDescription(answer));
  signaling.on("iceCandidate", (c) => pc.addIceCandidate(c));
  pc.onicecandidate = ({ candidate }) => { if (candidate) signaling.sendIceCandidate(candidate); };

  signaling.open();
  return { pc, signaling };
}

// 사용 예: 페이지에 <video id="cam" autoplay playsinline muted></video>를 두고
// const { pc, signaling } = await watch("<리전>", "device-a-cam", credentials, document.getElementById("cam"));
```

코드를 보면 층이 그대로 드러납니다. ①②는 제어 API, ③은 길 찾기 준비, ④의 `signaling`은 쪽지 창구, `pc`(`RTCPeerConnection`)는 실제 영상이 흐르는 연결입니다. `signaling`과 `pc`가 **서로 다른 객체**라는 점이 "쪽지 길과 영상 길이 따로"라는 이 글의 요점입니다.

## 그때 정한 것

처음의 "땡겨오기" 요청으로 돌아가, 위 개념에 비추어 실제로 정한 것들입니다.

- **실시간 영상은 KVS WebRTC 신호 채널로 한다.** 사람이 대시보드를 보며 장비 상태를 판단해야 하므로 HLS의 몇 초 지연보다 WebRTC가 맞았습니다. 시그널링 서버와 TURN 서버(예: coturn)를 직접 운영하는 길도 있었지만 고르지 않았습니다. 서버를 띄우고, 인증을 붙이고, 중계 서버의 대역폭과 비용을 관리하는 일을 관리형 서비스에 맡기고, 권한은 이미 쓰고 있던 IAM으로 거는 편이 작은 팀에 맞았습니다. 대가는 위 표의 한도를 그대로 받아들이는 것입니다. 마스터는 하나, TURN은 5Mbps, 시그널링 연결은 1시간입니다.
- **장비 하나에 채널 하나.** 채널 형식은 `SINGLE_MASTER`이고, 장비마다 `device-a-cam` 같은 채널을 따로 만들었습니다. 카메라 하나가 여러 브라우저에 영상을 주는 구조가 일대소수 모델과 그대로 맞고, 무엇보다 **권한을 채널 ARN 단위로 나눌 수 있습니다.** 장비 A의 자격으로는 장비 A의 채널에만 접근하게 하려면, 채널이 장비마다 따로 있어야 합니다.
- **마스터 자리는 그 장비만 앉게 한다.** "가장 최근 마스터가 이긴다"는 동작 때문에 이것이 권한 설계의 중심이 됐습니다. 장비마다 마스터 역할과 `kvs-master-<thing>` 형식의 role alias를 따로 두고, 장비 인증서에 붙는 IoT 정책은 **자기 role alias의 `iot:AssumeRoleWithCertificate`만** 허용했습니다. 역할 권한도 자기 채널 ARN 하나로 좁히고 `credentials-iot:ThingName`이 그 장비일 때만 쓰이게 묶었습니다. 앞의 정책 변수 예시는 장비가 많아질 때 역할 하나로 같은 효과를 내는 방법입니다. 확인 시험에서 장비 A의 인증서로 장비 B의 role alias를 요청하면 **403**이 났고, 서비스 밖의 채널 주소를 요청하면 `AccessDeniedException`이 났습니다. 개발자 계정으로 마스터를 흉내 내는 시험은 그 장비의 마스터가 꺼져 있을 때만 하기로 했습니다. 켜진 장비를 밀어낼 수 있기 때문입니다.
- **뷰어는 Cognito 임시 자격, 보기 동작만.** 개발 단계에서는 로그인한 사용자라면 누구나 영상을 볼 수 있게 했습니다. 영상이 이미 대시보드에서 보던 상태 정보와 같은 등급이라고 봤기 때문입니다. 허용 동작은 위의 보기 계열 몇 개(녹화 채널에서는 저장 세션에 뷰어로 붙는 동작이 더해집니다)뿐이고, `ConnectAsMaster`와 채널을 만들거나 바꾸는 동작은 없습니다. 다만 그룹이 지정되지 않은 로그인 사용자도 볼 수 있는 빈틈이 있다는 것을 알고, 운영 전에 그룹별로 나누는 일을 남겨 두었습니다.
- **기록하지 않는 값을 정했다.** 화면·로그·문서·커밋에 쓰지 않는 값은 이유가 다른 두 종류입니다. 첫째는 **그 자체로 접속 권한**인 값입니다. TURN 사용자 이름과 비밀번호, 임시 자격 증명, 서명한 WSS 주소, 녹화 재생 주소(HLS, 세션 토큰이 들어 있음)는 가진 사람이 유효 시간 동안 그대로 쓸 수 있습니다. 둘째는 접속 권한은 아니지만 **내부 망 구성을 드러내는** 값입니다. SDP와 ICE 후보에 들어 있는 내부 IP는 그것만으로 KVS 요청에 서명하거나 암호화된 영상을 풀 수는 없지만, 장비와 사용자가 어떤 망에 있는지를 알려 주는 프라이버시 정보입니다. 진단 도구는 ICE 서버의 **개수와 종류만** 보여 주게 했습니다.
- **MQTT 스냅샷을 폴백으로 남겼다.** WebRTC는 망에 따라 안 될 수 있습니다. UDP가 막힌 망도 있고, TURN까지 막히는 망도 있습니다. 그때도 장비가 지금 무엇을 보고 있는지는 느리게라도 알아야 합니다. 기존 1초 한 장 스냅샷 경로는 이미 로그인과 권한이 검증된 길이고, 영상보다 훨씬 가벼우며, 영상 경로와 서로 독립입니다. 그래서 카메라 패널은 WebRTC를 먼저 시도하고, **15초 안에 연결되지 않으면 스냅샷으로 넘어가며**, 폴백 중에는 60초마다 조용히 WebRTC를 다시 시도하게 했습니다. 영상 서버를 일부러 막은 시험에서 패널은 16~18초에 스냅샷으로 넘어갔습니다. 다만 채널에 녹화를 연결하면 이 폴백이 사실상 쓸모가 없어지는 일이 생겼는데, 이 이야기는 6편에서 합니다.

이렇게 만든 뒤 일반 인터넷에 붙은 노트북 브라우저에서 대시보드 카메라 패널을 열었을 때, 재생 시작까지 4.0초(첫 프레임 2.6초)가 걸렸습니다. 이 숫자는 한 환경의 측정값일 뿐입니다. 이동통신망(LTE)이나 그 뒤의 통신사 NAT 환경에서는 아직 한 번도 시험하지 않았고, 그런 망에서 직접 연결이 될지 TURN으로 흐를지는 장비를 현장에 붙여 봐야 압니다.

## 주의할 점

**마스터는 "보내는 쪽"이 아니라 "먼저 앉아 기다리는 쪽"입니다.** 역할 이름과 영상 방향을 섞으면 권한 설계가 헷갈립니다. 영상 방향은 SDP에서, 자리는 `ConnectAsMaster`/`ConnectAsViewer`에서 정합니다.

**`ConnectAsMaster` 권한은 곧 가로채기 권한입니다.** 같은 채널에 마스터가 둘이면 나중 쪽이 이깁니다. 뷰어 역할에 넣지 않고, 와일드카드로 딸려 들어가지 않게 동작을 하나씩 적고, 장비별 자격은 자기 채널로만 좁힙니다. 시험용 마스터를 띄울 때는 진짜 장비가 꺼져 있는지 먼저 봅니다.

**뷰어 10명은 시그널링 한도입니다.** 녹화를 연결하지 않은 채널에서 영상은 뷰어마다 따로 나가므로, 장비 업로드가 먼저 바닥날 수 있습니다. 녹화를 연결하면 구조와 한도(3명)가 함께 바뀝니다.

**시그널링 연결은 1시간·유휴 10분이면 끊깁니다.** 기다리는 쪽(마스터)은 다시 접속하는 코드가 반드시 있어야 하고, `GO_AWAY`를 받으면 1분 안에 옮겨 가야 합니다. 시그널링 WebSocket과 영상의 `RTCPeerConnection`은 별개 객체이므로, 재접속 코드가 어느 쪽을 다시 여는지 구분해서 짭니다.

**쪽지는 10k를 넘을 수 없습니다.** SDP에는 코덱 후보가 줄줄이 들어가므로, 코덱을 많이 열어 두면 offer가 커집니다. 2편에서 코덱 후보를 줄인 이유와 함께 다룹니다.

**TURN은 5Mbps 상한이 있고 요금도 따로 붙습니다.** 직접 연결이 안 되는 망에서는 영상 전체가 TURN으로 흐르므로 화질을 상한 안에서 설계합니다. 요금 단가는 리전과 시기에 따라 다르므로 숫자를 옮겨 적지 말고 [KVS 요금 페이지](https://aws.amazon.com/kinesis/video-streams/pricing/)에서 직접 확인합니다. TURN 자격은 5분짜리이니 연결할 때마다 새로 받습니다.

**장비 자격의 유효 시간은 역할의 최대 세션 시간을 넘을 수 없습니다.** role alias에 12시간을 적어도 역할이 1시간까지만 허용하면 맞지 않습니다. 길게 잡을수록 공급자 호출은 줄지만, 새어 나간 자격이 살아 있는 시간도 길어집니다.

**접속 권한 그 자체인 값을 남기지 않습니다.** 서명한 WSS 주소, TURN 비밀번호, 임시 자격은 디버깅 중에 로그로 찍기 쉬운 값입니다. 처음부터 가리는 출력 함수를 두는 편이 안전합니다. SDP와 ICE 후보의 내부 IP는 접속 권한은 아니지만 망 구성이 드러나므로 같은 함수로 함께 가립니다.

## 정리

- **KVS에는 영상 기능이 두 갈래 있습니다.** 비디오 스트림은 `PutMedia`로 올려 저장하고 HLS 등으로 꺼내 보는 기능이고(HLS 라이브 지연 보통 3~5초), WebRTC 신호 채널은 두 기기가 직접 만나 낮은 지연으로 주고받게 주선하는 기능입니다. 둘을 잇는 것이 WebRTC 수집입니다.
- **WebRTC는 "땡겨오기"가 아니라 "만나서 흐르기"입니다.** NAT 뒤의 두 기기는 서로에게 먼저 걸 수 없으므로, 둘 다 닿을 수 있는 신호 채널에서 쪽지를 교환하고, 영상은 고른 길로 따로 흐릅니다.
- **세 층으로 봅니다.** 시그널링(SDP offer/answer, ICE 후보), 길 찾기(STUN으로 바깥 주소 확인, ICE로 길 시험, 안 되면 TURN 중계), 미디어(DTLS로 키를 정한 SRTP). 쪽지 창구와 영상 연결은 서로 다른 연결입니다.
- **신호 채널은 `SINGLE_MASTER`, 마스터 1·뷰어 10(조정 가능)입니다.** 마스터는 먼저 접속해 기다리는 쪽이고, 같은 채널에 마스터가 또 접속하면 **가장 최근 요청이 이깁니다.**
- **브라우저와 장비는 다른 길로 임시 자격을 받습니다.** 브라우저는 로그인 토큰을 Cognito 자격 증명 풀에, 장비는 X.509 인증서를 IoT 자격 증명 공급자에 냅니다. 장비 쪽 자격은 role alias로 정하고 기본 1시간(900~43,200초)이며, `credentials-iot:ThingName` 같은 정책 변수로 자기 채널에만 묶을 수 있습니다. 어느 쪽에도 장기 AWS 액세스 키를 두지 않습니다. 다만 장비의 인증서 개인 키는 여전히 보호해야 할 비밀입니다.
- **권한의 핵심은 마스터 자리입니다.** 뷰어에는 보기 동작만, 장비에는 자기 채널의 마스터 자리만 줍니다.

다음 편에서는 1층, 시그널링을 들여다봅니다. SDP offer와 answer에 실제로 무엇이 들어 있는지, KVS 신호 채널이 쪽지를 어떻게 전달하고 보관하는지, 그리고 그 보관 때문에 겪은 "오래된 answer" 문제를 다룹니다.
