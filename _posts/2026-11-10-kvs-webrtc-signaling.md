---
title: "WebRTC 시그널링: SDP offer/answer와 KVS 신호 채널이 하는 일"
date: 2026-11-10 10:05:00 +0900
categories: [AWS, 영상 스트리밍]
tags: [aws-concepts, aws, kvs, webrtc, sdp, signaling, websocket]
description: "장비를 껐다 켜면 브라우저가 70초 뒤에야 다시 붙던 문제에서 출발해, WebRTC 시그널링이 왜 필요한지, SDP를 줄마다 어떻게 읽는지, offer/answer 순서, KVS 신호 채널의 API·메시지·ClientId·메시지 TTL·한도를 공식 문서 기준으로 정리합니다."
---

> **시리즈: AWS KVS로 실시간 영상 보내기**
> 1. [KVS 큰 그림: 영상은 '땡겨오는' 게 아니라 만나서 흐른다]({% post_url 2026-11-10-kvs-webrtc-big-picture %})
> 2. **시그널링: SDP offer/answer와 KVS 신호 채널** ← 지금 글
> 3. [NAT와 STUN: 왜 두 기기는 바로 못 붙나]({% post_url 2026-11-10-webrtc-nat-stun %})
> 4. TURN과 ICE: 끝내 못 붙으면 중계한다 (예정)
> 5. 암호화와 브라우저 보안: DTLS-SRTP, 그리고 CSP (예정)
> 6. 녹화: KVS WebRTC 수집과 저장 세션 (예정)
> 7. 다시 보기: HLS 원리와 KVS 재생 (예정)

카메라가 달린 현장 장비의 영상을 관제 웹 대시보드에서 실시간으로 보는 기능을 AI 에이전트와 같이 만들었습니다. 실시간 영상은 Amazon Kinesis Video Streams(KVS)의 WebRTC 기능으로 보냈습니다. 장비가 먼저 KVS 신호 채널에 접속해 기다리고, 브라우저가 찾아가 연결을 맺는 구조입니다.

처음 연결은 잘 됐습니다. 문제는 복구 시험에서 나왔습니다. 장비 쪽 송신 프로그램을 껐다가 다시 켜자, 브라우저가 영상을 다시 받기까지 **장비가 돌아온 뒤 70초**가 걸렸습니다. 브라우저는 몇십 초마다 다시 시도하고 있었으니 장비가 돌아오면 다음 시도에서 바로 붙어야 정상입니다. 그런데 장비가 돌아온 직후의 시도는 실패했고, 그다음 시도에서야 연결됐습니다. 코드의 흐름 시험은 모두 통과한 상태였습니다.

원인은 코드의 순서 실수가 아니라 **신호 채널이 메시지를 보관하는 방식**이었습니다. 이것을 이해하려면 시그널링이 무엇을 주고받는지, 주고받는 문서(SDP)가 어떻게 생겼는지, KVS 신호 채널이 메시지를 어떻게 배달하는지를 알아야 했습니다. 이 글은 그 정리입니다.

- 시그널링이 왜 필요한가, 표준은 어디까지 정해 두었나
- SDP를 한 줄씩 읽는 법과 offer/answer 모델
- KVS 신호 채널의 실제 동작: API 세 개, 서명한 WebSocket 주소, 메시지 형식, ClientId, 메시지 TTL, 한도
- 그때 겪은 두 사례(오래된 answer, 대답하지 않는 서비스)와 고친 방법
- 연결된 뒤 시그널링을 닫는 이유와 주의할 점

이 글에 미리 나오는 용어 네 개는 한 줄씩만 짚고 갑니다. **NAT**는 집이나 회사 공유기 같은 경계 장치가 안쪽 주소(와 포트)를 바깥 주소로 바꾸는 기능이고, **STUN**은 바깥에서 보이는 내 주소를 확인하거나 피어 사이 연결을 검사하는 프로토콜입니다. 주소를 알아낼 때는 STUN 서버에 요청합니다. **TURN**은 직접 연결이 안 될 때 패킷을 대신 옮겨 주는 중계 프로토콜과 그것을 제공하는 서버이고, **ICE**는 가능한 주소 후보를 모아 실제로 통하는 길을 골라내는 절차입니다. 이것들이 실제로 길을 찾는 원리는 3·4편에서, SDP에 든 암호 지문이 어떻게 쓰이는지는 5편에서 따로 다룹니다. 이 글에서는 "그 값들을 어떻게 서로에게 전하나"까지만 봅니다.

## 시그널링은 왜 필요한가

### 두 피어가 서로 모르는 것

WebRTC는 브라우저 같은 두 프로그램(피어, peer)이 영상·음성·데이터를 **피어 사이에서 실시간으로** 주고받게 하는 기술입니다. 가능하면 서버를 거치지 않고 직접 보내고, 직접 통신이 어려우면 TURN 중계 서버를 거칩니다. 어느 쪽이든 미디어를 보내려면 처음에 서로에 대해 알아야 할 것이 많습니다.

| 알아야 할 것 | 왜 필요한가 |
|---|---|
| 어떤 미디어를 주고받나 | 영상만인지, 소리도 있는지, 누가 보내고 누가 받는지 |
| 어떤 코덱으로 | 내가 H.264를 보내도 상대가 풀지 못하면 소용이 없습니다 |
| 어느 주소로 | 상대의 IP와 포트. 대개 NAT 뒤에 있어 후보가 여러 개입니다 |
| 연결 확인용 비밀값 | 엉뚱한 상대가 연결 확인에 끼어들지 못하게 하는 짧은 사용자 이름과 비밀번호 |
| 암호화 인증서의 지문 | 연결을 맺은 상대가 정말 시그널링으로 이야기한 그 상대인지 확인하는 값 |

닭과 달걀 문제가 생깁니다. 직접 연결하려면 이 정보가 필요한데, 이 정보를 건넬 직접 연결은 아직 없습니다. 그래서 **둘 다 이미 닿을 수 있는 다른 길**로 먼저 이 정보를 주고받습니다. 이 사전 대화가 **시그널링(signaling)** 이고, 그 다른 길이 **시그널링 서버**입니다.

흔히 소개팅 주선자에 비유합니다. 주선자는 두 사람에게 서로의 연락처와 취향을 전해 줄 뿐, 실제 대화에는 끼지 않습니다. 실제 동작도 같습니다. 시그널링 서버를 지나가는 것은 몇 KB짜리 텍스트(제안서·답장·주소 후보)뿐이고, 연결이 맺어지면 영상 패킷은 시그널링 서버를 전혀 거치지 않습니다. 직접 길이 막혀 있으면 TURN이라는 중계 서버를 거치는데, 이것도 시그널링 서버와는 별개의 서버입니다(4편).

### 표준은 시그널링 방법을 정하지 않는다

의외로 WebRTC 표준은 시그널링을 **어떻게** 할지 정하지 않습니다. 브라우저 쪽 동작을 정한 [JSEP(RFC 9429)](https://www.rfc-editor.org/rfc/rfc9429.html#section-3.1)는 3.1절에서 "JSEP는 특정 시그널링 모델이나 상태 기계를 정하지 않는다"고 적고, 주소 찾기·재전송·충돌 처리 같은 문제를 "전적으로 애플리케이션에 맡긴다"고 합니다(RFC 9429는 2024년에 이전판 RFC 8829를 대체한 현행판이고, 이 글에서 인용하는 JSEP 절 번호는 모두 RFC 9429 기준입니다). [KVS 개발자 안내서](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/kvswebrtc-how-it-works.html)도 "이 교환에 쓰는 전송 프로토콜은 WebRTC 표준에 정해져 있지 않다. HTTPS, 보안 WebSocket, 그 밖의 어떤 통신 방법이든 쓸 수 있다"고 설명합니다.

표준이 정한 것은 **무엇을 주고받는가**(SDP라는 문서 형식과 offer/answer 규칙)와 **브라우저 API**(`createOffer`, `setLocalDescription`, `addIceCandidate` 등)입니다. 브라우저는 SDP 문자열을 만들어 주고 받은 문자열을 적용할 뿐이고, 그 문자열을 상대에게 나르는 일은 애플리케이션 몫입니다. 직접 만든 WebSocket 서버로 날라도 되고, 채팅 메시지에 붙여 보내도 됩니다.

KVS 신호 채널은 이 "나르는 일"을 AWS가 관리형으로 맡아 주는 서비스입니다. 시그널링 서버를 직접 운영하지 않아도 되고, 누가 채널에 붙을 수 있는지를 IAM 정책으로 정할 수 있습니다. 대신 배달 규칙은 KVS가 정한 대로 따라야 합니다. 앞에서 말한 70초 문제가 바로 그 배달 규칙에서 나왔습니다.

## SDP 해부: 제안서를 한 줄씩 읽기

### SDP의 생김새

**SDP(Session Description Protocol, [RFC 8866](https://www.rfc-editor.org/rfc/rfc8866.html))** 는 "이런 미디어 세션을 열자"를 적는 텍스트 형식입니다. 원래 전화·화상회의 프로토콜(SIP)에서 쓰던 것을 WebRTC가 그대로 가져왔습니다. 생김새는 단순합니다. 한 줄에 하나씩 `<한 글자 종류>=<값>`을 적습니다.

- `v=`, `o=`, `s=`, `t=`처럼 맨 위에 오는 줄은 **세션 전체**에 대한 정보입니다.
- `m=` 줄이 나오면 거기서부터 다음 `m=` 줄 전까지가 **미디어 하나**(영상 하나, 소리 하나)에 대한 설명입니다. 이 묶음을 "m= 섹션"이라고 부릅니다.
- `a=`는 속성(attribute)입니다. WebRTC에 필요한 정보 대부분이 `a=` 줄에 들어 있습니다.

아래는 브라우저가 "영상을 받기만 하겠다"고 만든 offer를 줄여 쓴 **가짜 예시**입니다. 실제 브라우저가 만드는 SDP는 이보다 훨씬 깁니다(코덱마다 `rtcp-fb`, `fmtp` 줄이 붙고, RTP 확장 헤더 줄도 여럿 있습니다). 주소는 문서용 예약 주소(RFC 5737)이고, 비밀번호와 지문도 지어낸 값입니다.

```text
v=0
o=- 8102345678 2 IN IP4 127.0.0.1
s=-
t=0 0
a=group:BUNDLE 0
m=video 9 UDP/TLS/RTP/SAVPF 102 96
c=IN IP4 0.0.0.0
a=mid:0
a=recvonly
a=rtcp-mux
a=ice-ufrag:Xk3d
a=ice-pwd:EXAMPLEexamplePassword00
a=ice-options:trickle
a=fingerprint:sha-256 4A:1F:...(32바이트를 콜론으로 이은 값)...:9C
a=setup:actpass
a=rtpmap:102 H264/90000
a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f
a=rtpmap:96 VP8/90000
a=candidate:1 1 udp 2122260223 192.0.2.10 54321 typ host
```

### 줄마다 풀이

**세션 부분**

| 줄 | 뜻 |
|---|---|
| `v=0` | SDP 버전. 늘 0입니다 |
| `o=- 8102… 2 IN IP4 127.0.0.1` | 만든 쪽과 세션 식별자, 버전 번호. 같은 연결에서 SDP를 다시 만들면 버전 번호가 올라갑니다. WebRTC에서는 주소 부분에 의미가 없습니다 |
| `s=-`, `t=0 0` | 세션 이름과 시간. WebRTC에서는 형식상 넣는 자리 채움 값입니다 |
| `a=group:BUNDLE 0` | 여기 적힌 `mid`의 미디어들을 **한 연결(한 포트 쌍)에 묶어** 보낸다는 뜻. 영상과 소리가 있으면 `BUNDLE 0 1`처럼 둘 다 적힙니다 |

**미디어(m=) 섹션**

| 줄 | 뜻 |
|---|---|
| `m=video 9 UDP/TLS/RTP/SAVPF 102 96` | 영상 미디어 하나. `9`는 아직 주소 후보가 없을 때 넣는 자리 채움 포트입니다(JSEP 5.2.1). `UDP/TLS/RTP/SAVPF`는 전송 방식 이름입니다. **RTP**는 영상·음성 조각을 실어 나르는 미디어 패킷 형식, **RTCP**는 수신 상태와 피드백(손실, 화면 다시 요청 등)을 주고받는 제어 패킷, **SRTP**는 암호화로 보호한 RTP입니다. 합치면 "UDP 위에서, DTLS로 키를 나눈 SRTP로 미디어를 보내고, RTCP 피드백을 쓴다"는 뜻입니다. 끝의 `102 96`은 이 미디어에 쓸 수 있는 **페이로드 타입 번호 목록**이고, **앞에 있을수록 더 선호**합니다 |
| `c=IN IP4 0.0.0.0` | 연결 주소. 실제 주소는 ICE 후보로 따로 주고받으므로 자리 채움 값을 넣습니다 |
| `a=mid:0` | 이 m= 섹션의 이름표. BUNDLE과 ICE 후보가 이 이름으로 섹션을 가리킵니다 |
| `a=recvonly` | 방향. 나는 받기만 한다. 그 밖에 `sendonly`, `sendrecv`, `inactive`가 있습니다 |
| `a=rtcp-mux` | 미디어(RTP)와 제어(RTCP)를 같은 포트로 보낸다 |
| `a=rtpmap:102 H264/90000` | 페이로드 타입 102번은 H.264, 시간 단위 90 kHz. 번호는 그 SDP 안에서만 통하는 약속입니다. 상대 브라우저는 같은 H.264에 다른 번호를 붙일 수도 있습니다 |
| `a=fmtp:102 … profile-level-id=42e01f` | 102번 코덱의 세부 조건. `42e01f`는 H.264 Constrained Baseline 프로필, 레벨 3.1이라는 뜻입니다. 이번 구성은 장비 인코더와 브라우저가 맞추기 쉬운 이 프로필을 첫 선택으로 골랐습니다 |
| `a=rtpmap:96 VP8/90000` | 96번은 VP8. H.264가 안 맞을 때의 두 번째 선택지입니다 |

**연결을 맺는 데 쓰는 값**

| 줄 | 뜻 | 자세히 |
|---|---|---|
| `a=ice-ufrag`, `a=ice-pwd` | ICE 연결 확인에 쓰는 사용자 이름 조각과 비밀번호. 피어는 상대 주소 후보로 확인 패킷(STUN 요청)을 보낼 때 이 값으로 자기를 증명합니다 | 3·4편 |
| `a=ice-options:trickle` | 주소 후보를 SDP에 다 담지 않고 **찾는 대로 따로 흘려보낼 수 있다**(trickle ICE, [RFC 8838](https://www.rfc-editor.org/rfc/rfc8838.html)) | 아래 |
| `a=fingerprint:sha-256 …` | 이 피어가 암호화 연결(DTLS)에 쓸 **인증서의 해시**. 연결을 맺을 때 상대가 내민 인증서가 이 지문과 맞는지 확인합니다 | 5편 |
| `a=setup:actpass` | DTLS 핸드셰이크를 누가 먼저 걸지. offer는 반드시 `actpass`("어느 쪽이든 좋다")를 쓰고, answer는 `active` 또는 `passive`로 정합니다(JSEP 5.2.1, 5.3.1) | 5편 |
| `a=candidate:1 1 udp 2122260223 192.0.2.10 54321 typ host` | 주소 후보 하나. 순서대로 식별자, 구성 요소 번호, 전송 프로토콜, 우선순위, IP, 포트, 종류(`host` 내 컴퓨터 주소, `srflx` NAT 바깥 주소, `relay` TURN 중계 주소) | 3·4편 |

여기서 눈여겨볼 점이 하나 있습니다. SDP의 `o=` 줄은 **작성자가 만든 세션과 그 세션 기술의 버전**을 식별합니다([RFC 8866 5.2절](https://www.rfc-editor.org/rfc/rfc8866.html#section-5.2)). 하지만 이것은 "이 answer가 상대의 어느 offer에 대한 답인가"를 직접 가리키는 요청 ID가 아닙니다. answer의 `o=`는 answer를 만든 쪽의 세션 값이고, offer의 세션 값을 되돌려 적지 않습니다. 그래서 받은 answer를 어느 offer와 짝지을지는 시그널링 계층이 책임져야 합니다. 이 사실이 뒤의 첫 번째 사례에서 그대로 문제가 됩니다.

### offer/answer 모델: 누가 제안하고 누가 고르나

SDP를 주고받는 규칙은 **offer/answer 모델([RFC 3264](https://www.rfc-editor.org/rfc/rfc3264.html))** 입니다.

1. **offer를 만드는 쪽(offerer)** 이 "나는 이런 미디어를, 이런 코덱들로, 이 선호 순서로 주고받을 수 있다"를 적어 보냅니다.
2. **answer를 만드는 쪽(answerer)** 은 offer의 m= 섹션마다 **같은 순서로** 하나씩 답합니다. 각 섹션에서 자기도 지원하는 코덱만 남기고(공통 부분), 방향도 맞춥니다. offer가 `recvonly`("나는 받기만 한다")면 answer는 `sendonly` 또는 `inactive`여야 합니다([RFC 3264 6.1절](https://www.rfc-editor.org/rfc/rfc3264.html#section-6.1)). 상대가 영상을 보내기로 하면 `sendonly`, 지금은 보내지 않으면 `inactive`입니다. 그 미디어를 아예 거절할 때는 answer의 해당 `m=` 줄 포트를 0으로 적습니다.
3. answer를 받은 순간 양쪽이 같은 내용에 합의한 상태가 됩니다.

공통 코덱이 하나도 없으면 협상은 실패합니다. [KVS 문제 해결 문서](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/troubleshooting.html)도 "answer가 오지 않는다면 offer에 호환되는 코덱이 없어서 상대가 offer를 받아들이지 못했을 수 있다"며, offer에서 `a=rtpmap` 줄을 확인하라고 안내합니다.

**이 글의 구성과 일반적인 KVS 샘플에서는 뷰어(브라우저)가 offer를 만들고, 마스터(장비)가 answer를 만듭니다.** 같은 문제 해결 문서가 이 흐름을 "offer는 마스터에 연결하려는 뷰어가 만들고, answer는 offer를 받은 쪽이 만든다"고 소개합니다. 다만 이것은 서비스의 고정 규칙이 아닙니다. [SendSdpOffer 문서](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/SendSdpOffer.html)는 마스터가 어느 뷰어에게든 offer를 보낼 수 있다고 적고 있고(뷰어는 마스터에게만), 6편에서 볼 녹화 모드에서는 KVS 쪽 저장 세션이 offer를 만드는 흐름도 나옵니다. "마스터"는 대화를 주도하는 쪽이라기보다 **먼저 채널에 들어와 기다리는 쪽**이라고 이해하면 됩니다.

### API를 부르는 순서와 상태

브라우저 API로는 이렇게 진행됩니다.

| 순서 | offerer (이 글의 구성에서는 뷰어) | answerer (이 글의 구성에서는 마스터) |
|---|---|---|
| 1 | `createOffer()`로 SDP를 만든다 | |
| 2 | `setLocalDescription(offer)` → 상태 `have-local-offer`, **이때부터 주소 후보 수집 시작** | |
| 3 | 시그널링으로 offer를 보낸다 | |
| 4 | | `setRemoteDescription(offer)` → 상태 `have-remote-offer` |
| 5 | | `createAnswer()` → `setLocalDescription(answer)` → 상태 `stable`, 후보 수집 시작 |
| 6 | | 시그널링으로 answer를 보낸다 |
| 7 | `setRemoteDescription(answer)` → 상태 `stable` | |
| 8 | 양쪽이 찾은 후보를 서로 보내고, 받은 후보를 `addIceCandidate()`로 넣는다 | 같음 |

순서가 중요한 이유가 두 가지 있습니다.

- **후보 수집은 `setLocalDescription`에서 시작합니다.** JSEP 4.1.8절은 `createOffer`가 "후보 수집을 일으키지 않는다"고, 4.1.11절은 `setLocalDescription`이 "전송 통로를 만들고 후보 수집을 시작한다"고 적습니다. 그래서 이 예시처럼 후보 풀(`iceCandidatePoolSize`, 기본값 0)을 쓰지 않는 첫 연결에서는, offer를 만들어 두기만 하고 적용하지 않으면 주소 후보가 하나도 생기지 않습니다. 후보 풀을 설정하면 브라우저가 `setLocalDescription` 전에 후보를 미리 모아 둘 수 있습니다([RFC 9429 3.5.4절](https://www.rfc-editor.org/rfc/rfc9429.html#section-3.5.4)).
- **상대 후보는 상대 SDP를 적용한 뒤에만 넣을 수 있습니다.** 상대 SDP(remote description)가 없을 때 `addIceCandidate()`를 부르면 브라우저는 `InvalidStateError`로 거절합니다. 후보가 answer보다 먼저 도착할 수도 있으므로, 받은 후보를 잠시 모아 두었다가 answer를 적용한 뒤 넣어야 합니다. KVS 공식 JavaScript SDK의 시그널링 클라이언트도 SDP를 받기 전에 온 후보는 버퍼에 넣어 두었다가 SDP를 받은 뒤에 내보냅니다.

### trickle ICE: 후보는 나중에 따로

후보 수집에는 시간이 걸립니다. 내 컴퓨터 주소(host)는 바로 나오지만, NAT 바깥 주소(srflx)는 STUN 서버에 물어봐야 하고, 중계 주소(relay)는 TURN 서버에 자리를 받아야 합니다. 모든 후보가 모일 때까지 offer를 붙잡고 있으면 그만큼 연결이 늦어집니다.

그래서 WebRTC는 보통 **trickle ICE**를 씁니다. offer는 바로 보내고, 후보는 찾을 때마다 `onicecandidate` 이벤트로 하나씩 받아 시그널링으로 따로 보냅니다. 상대도 후보를 받는 대로 `addIceCandidate()`로 넣고 바로 연결 확인을 시작합니다. KVS 신호 채널에 `ICE_CANDIDATE`라는 메시지 종류가 따로 있는 것이 이 때문입니다.

모든 라이브러리가 trickle을 쓰지는 않습니다. 이번에 장비 쪽 시뮬레이터로 쓴 Python 라이브러리 aiortc는 이번에 쓴 버전과 구성에서 후보를 다 모은 뒤 answer에 한꺼번에 담아 보냈습니다. 같은 컴퓨터 안의 시험에서도 KVS의 STUN/TURN 서버를 쓰게 하자 후보 수집을 기다리는 데만 약 5초가 걸렸습니다(그 망에서는 그렇게 기다리고도 내 컴퓨터 주소 후보만 나왔습니다). trickle이 없으면 가장 느린 후보가 연결 시작 시간을 정합니다.

## KVS 신호 채널은 실제로 어떻게 움직이나

### 채널, 마스터, 뷰어

KVS에서 시그널링의 단위는 **신호 채널(signaling channel)** 이라는 AWS 리소스입니다. 장비 하나에 채널 하나를 만들었습니다(이름 예: `device-a-cam`). 채널 종류는 `SINGLE_MASTER` 하나뿐입니다.

- **마스터**: 채널에 하나만 붙을 수 있습니다. 채널의 어느 뷰어와도 메시지를 주고받을 수 있습니다. 이 시스템에서는 장비입니다.
- **뷰어**: 채널마다 기본 10개까지 붙을 수 있습니다(늘릴 수 있는 soft 한도). 뷰어는 **마스터하고만** 이야기할 수 있고, 다른 뷰어는 보지도 못합니다. 이 시스템에서는 브라우저 탭입니다.

[안내서](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/kvswebrtc-how-it-works.html)는 이 구조를 "마스터 하나가 뷰어 여럿과 연결되는 일대소수(one-to-few) 모델"이라고 부릅니다.

### 뷰어가 영상을 보기까지

<figure class="diagram">
{% include figures/kvs-webrtc-signaling/offer-answer-sequence.svg %}
<figcaption>이 글의 구성(뷰어가 offer)에서 신호 채널은 offer·answer·주소 후보만 나르고, 영상은 채널을 거치지 않고 두 피어 사이(또는 TURN 중계)로 흐른다</figcaption>
</figure>

브라우저는 로그인한 사용자의 임시 AWS 자격 증명(Cognito 자격 증명 풀, [Cognito 사용자 풀과 자격 증명 풀]({% post_url 2026-11-06-cognito-user-pool-identity-pool %}) 참고)으로 아래 순서를 밟습니다.

**① `DescribeSignalingChannel`**: 채널 이름으로 채널 정보를 받습니다. 여기서 필요한 것은 채널의 **ARN**(Amazon Resource Name, AWS 리소스를 가리키는 고유 이름)과 상태(`ACTIVE`)입니다. 뒤의 모든 단계가 ARN으로 채널을 가리킵니다.

**② `GetSignalingChannelEndpoint`**: 이 채널에 붙을 주소를 받습니다. 요청에 프로토콜 목록(`WSS`, `HTTPS`)과 역할(`VIEWER` 또는 `MASTER`)을 넣으면 [응답](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/API_GetSignalingChannelEndpoint.html)으로 주소 두 개가 옵니다.

- `wss://…` : 시그널링 메시지를 주고받을 **보안 WebSocket** 주소
- `https://…` : 다음 단계의 `GetIceServerConfig`를 부를 **HTTPS** 주소

역할에 따라 주소가 다릅니다. 문서는 "`MASTER` 역할은 채널의 어느 뷰어와도 통신할 수 있는 엔드포인트를, `VIEWER` 역할은 `MASTER`하고만 통신할 수 있는 엔드포인트를 만든다"고 설명합니다. 주소 호스트는 채널마다 다르게 나오므로 미리 적어 둘 수 없고, 매번 이 API로 받아야 합니다.

**③ `GetIceServerConfig`**: ②에서 받은 HTTPS 주소로 TURN 서버 정보를 받습니다. [응답](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/API_signaling_GetIceServerConfig.html)의 `IceServerList`에는 서버마다 `Uris`(주소 목록), `Username`, `Password`, `Ttl`(유효 시간, 초)이 들어 있습니다. 시험한 채널에서는 서버 2개, 주소 6개(호스트마다 `turn:…?transport=udp`, `turns:…?transport=udp`, `turns:…?transport=tcp`, 모두 포트 443)에 유효 시간 300초가 왔습니다. [할당량 문서](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/kvswebrtc-limits.html)의 TURN 자격 수명 5분과 같습니다. STUN 서버는 이 응답에 따로 오지 않고 `stun:stun.kinesisvideo.<리전>.amazonaws.com:443` 형식으로 정해져 있습니다([문제 해결 문서](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/troubleshooting.html)). 이 값들을 모아 `RTCPeerConnection`의 `iceServers`로 넘깁니다.

**④ 서명한 WSS 주소로 접속**: ②의 WSS 주소에 쿼리 문자열로 채널 ARN(`X-Amz-ChannelARN`)과 뷰어 식별자(`X-Amz-ClientId`)를 붙이고, 그 주소 전체에 **SigV4 서명**을 합니다. SigV4는 AWS 자격 증명으로 요청에 서명하는 방식입니다([인증 한 번에 정리: JWT, IAM(SigV4), Cognito]({% post_url 2026-11-01-auth-basics-jwt-iam-cognito %})에서 다뤘습니다).

보통의 AWS API 호출은 서명을 `Authorization` 헤더에 넣습니다. 그런데 브라우저의 `new WebSocket(url)`은 요청 헤더를 정할 수 없습니다. 그래서 서명을 **주소의 쿼리 문자열에 넣는 방식(presigned URL)** 을 씁니다. 공식 JavaScript SDK의 서명 코드를 보면 쿼리 문자열에 `X-Amz-Algorithm`, `X-Amz-Credential`, `X-Amz-Date`, `X-Amz-Expires`, `X-Amz-SignedHeaders`, `X-Amz-Signature`가 붙고, 임시 자격 증명이면 `X-Amz-Security-Token`이 더 붙습니다. `X-Amz-Expires`는 299초, 즉 **약 5분 동안 유효**합니다.

시험에서 잰 서명 주소 길이는 뷰어 481자, 마스터 1,550자였습니다. 그때 뷰어 시험은 만료 없는 개발자 키로, 마스터는 장비 인증서로 받은 임시 자격으로 서명했습니다. 임시 자격에는 긴 세션 토큰이 따라오고 그것이 `X-Amz-Security-Token`으로 주소에 그대로 들어가서 길이가 세 배가 됐습니다. 이번 경우에는 두 주소의 길이 차이가 서명에 쓴 자격의 종류 차이에서 왔습니다.

이 주소는 **5분짜리 접속 권한 그 자체**입니다. 주소를 가진 사람은 만료 전까지 그 채널에 뷰어로 붙을 수 있습니다. 그래서 로그·화면·오류 메시지 어디에도 서명 주소를 남기지 않았습니다. TURN 사용자 이름과 비밀번호, 임시 자격 증명도 같은 이유로 남기지 않았습니다.

마스터는 같은 일을 `MASTER` 역할로 합니다. 차이가 하나 있습니다. 공식 SDK는 **뷰어만** `X-Amz-ClientId`를 붙이고 마스터는 붙이지 않습니다. 채널에 마스터는 하나뿐이니 따로 이름이 필요 없기 때문입니다.

**⑤ offer 보내기**: 접속이 열리면 뷰어가 offer를 만들어 보냅니다. [SendSdpOffer 문서](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/SendSdpOffer.html)의 메시지 형식은 이렇습니다.

```json
{
  "action": "SDP_OFFER",
  "recipientClientId": "string",
  "messagePayload": "string",
  "correlationId": "string"
}
```

- `action`: `SDP_OFFER`, `SDP_ANSWER`, `ICE_CANDIDATE` 중 하나.
- `recipientClientId`: 받는 쪽. 뷰어가 보내면 받는 쪽은 언제나 마스터이므로 이 값은 무시됩니다. 마스터가 보낼 때는 어느 뷰어에게 보낼지 반드시 적어야 합니다.
- `messagePayload`: **base64로 인코딩한** 내용. 공식 SDK는 `RTCSessionDescription`을 JSON으로 바꾼 `{"type":"offer","sdp":"v=0\r\n…"}`을 base64로 감싸 넣습니다. 후보도 `RTCIceCandidate`를 JSON으로 바꿔 같은 방식으로 넣습니다.
- `correlationId`: 선택. 넣으면 이 메시지에 오류가 났을 때 같은 ID가 달린 `STATUS_RESPONSE`로 알려 줍니다.

**⑥ answer와 후보 받기**: 받는 메시지는 [비동기 이벤트](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/async-message-reception-api.html)로 옵니다.

```json
{
  "senderClientId": "string",
  "messageType": "SDP_ANSWER",
  "messagePayload": "base64 문자열",
  "statusResponse": { "correlationId": "…", "errorType": "…", "statusCode": "…", "description": "…" }
}
```

`messageType`은 `SDP_OFFER`, `SDP_ANSWER`, `ICE_CANDIDATE`, `GO_AWAY`, `RECONNECT_ICE_SERVER`, `STATUS_RESPONSE` 중 하나입니다. 마스터는 offer를 받으면 `senderClientId`를 보고 어느 뷰어인지 알고, 그 뷰어 앞으로 answer를 보냅니다.

**⑦ 후보를 주고받고 연결**: 양쪽이 `ICE_CANDIDATE`를 주고받으며 연결 확인을 합니다. 길이 정해지고 암호화 핸드셰이크가 끝나면 영상이 흐르기 시작합니다. 시뮬레이터 마스터와 Python 뷰어를 같은 컴퓨터에서 실제 KVS 채널로 이었을 때(내 컴퓨터 주소 후보만 쓴 경우) offer를 보내고 answer가 오기까지 **0.16초**, 첫 프레임까지 0.44초가 걸렸습니다. 그때 offer는 1,848바이트였습니다. 신호 채널을 한 번 왕복하는 비용 자체는 작다는 뜻입니다.

### ClientId: 뷰어의 우편함 주소

`ClientId`는 뷰어를 구분하는 이름입니다. [ConnectAsViewer 문서](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/ConnectAsViewer.html)가 정한 규칙은 이렇습니다.

- 1~256자, 영문·숫자·`_`·`.`·`-`. **`AWS_`로 시작하면 안 됩니다.**
- **같은 `ClientId`로 새로 접속하면 새 연결이 이전 연결보다 우선합니다.** 연결 정보가 새 것으로 덮어써집니다.

마스터 쪽에서 보면 `ClientId`는 **답장을 보낼 우편함 주소**입니다. 마스터는 offer를 보낸 뷰어의 `ClientId`를 `recipientClientId`에 넣어 answer를 보냅니다. 신호 채널은 그 주소로 메시지를 배달할 뿐, 그 answer가 어느 offer에 대한 답인지는 따지지 않습니다. 앞에서 본 대로 SDP의 `o=`도 세션과 버전을 가리킬 뿐, 어느 offer에 대한 답인지를 가리키는 요청 ID는 아닙니다. 그래서 **이 구현에서는 `ClientId`를 연결 시도를 구분하는 열쇠로 썼습니다.** 애플리케이션이 따로 시도 ID를 설계해 구분하는 방법도 있습니다.

같은 `ClientId`를 여러 탭이 같이 쓰면 나중에 연 탭이 앞 탭의 연결을 밀어냅니다. 탭마다, 그리고 뒤에서 볼 이유로 **시도마다** 다른 값을 써야 합니다.

### 메시지 TTL: 배달 못 한 메시지를 얼마나 들고 있나

채널을 만들 때 정하는 값 중 [`MessageTtlSeconds`](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/API_SingleMasterConfiguration.html)가 있습니다. 문서는 이것을 "신호 채널이 **배달하지 못한 메시지를 버리기 전까지 보관하는 시간**"이라고 정의합니다. 5~120초 사이로 정할 수 있고, 이 시스템은 60초로 정했습니다. 다만 모든 메시지를 차례로 쌓아 두는 큐는 아닙니다. [SendSdpOffer](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/SendSdpOffer.html) 문서는 같은 클라이언트 앞으로 아직 배달되지 않은 offer가 있으면 새 offer가 그것을 덮어쓴다고 적고 있습니다.

보관하는 이유는 쉽게 짐작할 수 있습니다. 받는 쪽이 잠깐 끊겼다 다시 붙는 사이에 온 메시지가 사라지지 않게 하려는 것입니다. 하지만 보관은 양날의 칼입니다. "받는 쪽이 아직 그 메시지를 원하는가"는 서비스가 알 수 없으므로, **이미 쓸모없어진 메시지도 TTL 동안은 배달을 기다립니다.** 70초 문제의 원인이 여기 있었습니다.

### 서비스는 성공했을 때 아무 말도 하지 않는다

SendSdpOffer 문서의 응답 절은 짧습니다. "메시지가 시그널링 백엔드에 잘 도착하면 **아무 응답도 돌려주지 않는다**. 서비스에 오류가 났고 요청에 `correlationId`가 있으면 오류 내용을 `STATUS_RESPONSE`로 돌려준다."

"잘 도착했다"는 것은 신호 채널이 받았다는 뜻이지 마스터가 받았다는 뜻이 아닙니다. 마스터가 채널에 없어도 offer는 채널에 잘 도착했고, TTL 동안 배달을 기다립니다. 서비스 입장에서는 오류가 아니므로 알려 줄 것도 없습니다. 이것이 두 번째 사례의 배경입니다.

### 한도 (공식 할당량 페이지, 2026-11-10 확인)

[할당량 페이지](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/kvswebrtc-limits.html)에서 시그널링과 관련된 값만 추렸습니다. (h)는 늘릴 수 없는 hard 한도, (s)는 요청해서 늘릴 수 있는 soft 한도입니다.

| 항목 | 마스터 | 뷰어 |
|---|---|---|
| 채널당 동시 연결 수 | 1 (h) | 10 (s) |
| 연결 최대 유지 시간 | 1시간 (h) | 1시간 (h) |
| 유휴 연결 제한 | 10분 (h) | 10분 (h) |
| `GO_AWAY`를 받은 뒤 연결이 끊기기까지 | 최대 1분 (h) | 최대 1분 (h) |
| 접속 요청 빈도 | 채널당 3 TPS (h) | 채널당 3 TPS (h) |

| 메시지 | 빈도 한도 | 내용 크기 |
|---|---|---|
| `SDP_OFFER`, `SDP_ANSWER` | WebSocket 연결당 5 TPS (h) | 10K (h) |
| `ICE_CANDIDATE` | WebSocket 연결당 20 TPS (h) | 10K (h) |

여기서 10K는 `messagePayload`, 즉 **base64로 인코딩한 뒤의 길이**입니다. base64는 3바이트를 4글자로 늘리므로 원래 `{"type":…,"sdp":…}` JSON은 약 7.5 KB를 넘으면 안 됩니다. 브라우저 SDP는 지원하는 코덱마다 `rtpmap`·`fmtp`·`rtcp-fb` 줄이 붙어 생각보다 빨리 커집니다. 그래서 이 시스템은 주고받을 코덱을 **H.264 Constrained Baseline을 먼저, VP8을 대비책으로, 두 가지로 제한**했습니다(브라우저 쪽에서는 [`RTCRtpTransceiver.setCodecPreferences()`](https://developer.mozilla.org/en-US/docs/Web/API/RTCRtpTransceiver/setCodecPreferences) 같은 방법으로 offer에 넣을 코덱을 고를 수 있습니다). trickle ICE로 후보를 SDP 밖으로 빼는 것도 SDP를 작게 유지하는 데 도움이 됩니다.

## 최소 예시: 브라우저 뷰어의 뼈대

아래는 위 흐름을 브라우저 코드로 줄여 쓴 뼈대입니다. **실행 미확인** 예시입니다. ①~④(채널 정보, 엔드포인트, ICE 서버, SigV4 서명)는 `prepareSignaling()` 한 줄로 생략했습니다. 실제로는 공식 JavaScript SDK나 AWS SDK의 서명 기능을 쓰면 됩니다. 뒤에서 설명할 두 사례의 대책(시도마다 새 `ClientId`, offer 전에 온 answer 버리기, JSON이 아닌 프레임과 모르는 메시지 종류 무시, 15초 무응답 판단)을 함께 넣었습니다. 15초 안에 answer가 없을 때와 받은 내용을 적용하지 못했을 때는 시도를 정리한 뒤 호출한 쪽이 넘긴 `onNoAnswer`, `onError`를 부릅니다. 다시 시도할지는 호출한 쪽의 재연결 정책이 정합니다.

```javascript
// 실행 미확인 최소 예시. 서명과 자격 증명 부분은 생략했다.
async function connectOnce(video, { onNoAnswer, onError }) {
  const clientId = `viewer-${crypto.randomUUID()}`;          // 시도마다 새 ClientId
  const { wssUrl, iceServers } = await prepareSignaling(clientId); // ①~④ (생략)

  const pc = new RTCPeerConnection({ iceServers });
  pc.addTransceiver('video', { direction: 'recvonly' });
  pc.ontrack = (e) => {
    video.srcObject = e.streams[0] ?? new MediaStream([e.track]); // streams는 빈 배열일 수 있다
  };

  const ws = new WebSocket(wssUrl);
  const encode = (obj) => btoa(JSON.stringify(obj));
  const decode = (b64) => JSON.parse(atob(b64));
  const HANDLED = new Set(['SDP_ANSWER', 'ICE_CANDIDATE']);
  const pendingCandidates = [];
  let offerSent = false;
  let answerTimer;

  const close = () => { clearTimeout(answerTimer); ws.close(); pc.close(); };
  const fail = (err) => { close(); onError(err); };

  pc.onicecandidate = ({ candidate }) => {
    if (candidate && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ action: 'ICE_CANDIDATE', messagePayload: encode(candidate) }));
    }
  };

  ws.onopen = async () => {
    try {
      await pc.setLocalDescription(await pc.createOffer()); // 후보 풀이 없으면 여기서 후보 수집이 시작된다
      ws.send(JSON.stringify({ action: 'SDP_OFFER', messagePayload: encode(pc.localDescription) }));
      offerSent = true;
      // 서비스는 "마스터 없음"을 알려 주지 않는다. 아는 것은 answer가 안 왔다는 사실뿐이다
      answerTimer = setTimeout(() => { close(); onNoAnswer(); }, 15_000);
    } catch (err) { fail(err); }
  };

  ws.onmessage = async ({ data }) => {
    let msg;
    try { msg = JSON.parse(data); } catch { return; }      // 빈 프레임 등 JSON이 아니면 무시
    if (!HANDLED.has(msg?.messageType) || !msg.messagePayload) return; // 모르는 종류는 풀기 전에 무시
    let payload;
    try { payload = decode(msg.messagePayload); } catch { return; } // 내용이 깨진 메시지도 무시

    try {
      if (msg.messageType === 'SDP_ANSWER') {
        if (!offerSent || pc.remoteDescription) return;    // 내 offer 전에 온 answer는 이전 시도의 것
        clearTimeout(answerTimer);
        await pc.setRemoteDescription(payload);
        for (const c of pendingCandidates.splice(0)) await pc.addIceCandidate(c);
      } else if (pc.remoteDescription) {
        await pc.addIceCandidate(payload);
      } else {
        pendingCandidates.push(payload);                   // answer보다 먼저 온 후보는 모아 둔다
      }
    } catch (err) { fail(err); }                           // 적용 실패는 무시하지 않고 이 시도를 정리한다
  };

  pc.onconnectionstatechange = () => {
    if (pc.connectionState === 'connected') ws.close();   // 연결된 뒤에는 시그널링을 닫아도 영상은 흐른다
    else if (pc.connectionState === 'failed') fail(new Error('connection failed'));
  };

  return pc;
}
```

몇 가지를 덧붙입니다.

- `JSON.stringify(pc.localDescription)`은 `RTCSessionDescription`의 `toJSON()` 덕분에 `{"type":"offer","sdp":"…"}`이 됩니다. 후보도 `RTCIceCandidate.toJSON()`으로 `candidate`, `sdpMid`, `sdpMLineIndex`, `usernameFragment`가 담깁니다.
- 메시지는 세 단계로 거릅니다. 바깥 JSON을 풀지 못하거나 이 뼈대가 다루지 않는 `messageType`이면 내용을 풀기 전에 버리고, 다루는 종류라도 base64·JSON 내용이 깨져 있으면 버립니다. 반면 받은 answer나 후보를 `setRemoteDescription()`·`addIceCandidate()`로 적용하다 실패한 것은 정상 메시지 무시와 다르므로 시도를 정리하고 `onError`로 알립니다. 후보 하나의 실패를 시도 전체의 실패로 볼지는 정책에 따라 다를 수 있고, 이 뼈대는 단순하게 둘 다 정리합니다.
- 상대가 트랙을 스트림에 묶지 않고 보내면 `track` 이벤트의 `streams`가 빈 배열입니다([W3C WebRTC](https://www.w3.org/TR/webrtc/#rtctrackevent)). 그래서 `e.track`으로 `MediaStream`을 만드는 대체 경로를 두었습니다.
- 뷰어는 `recipientClientId`를 넣지 않았습니다. 뷰어가 보내는 메시지는 늘 마스터에게 가고, 넣어도 무시됩니다.
- 오류를 받고 싶으면 메시지마다 `correlationId`를 넣고 `STATUS_RESPONSE`를 처리하면 됩니다. 이 뼈대는 생략했습니다.
- 마스터 쪽은 거꾸로입니다. `SDP_OFFER`를 받으면 `senderClientId`별로 `RTCPeerConnection`을 하나씩 만들고, `setRemoteDescription(offer)` → `createAnswer()` → `setLocalDescription()` 뒤 그 `ClientId` 앞으로 `SDP_ANSWER`를 보냅니다.

## 사례 1: 오래된 answer가 새 시도에 배달됐다

이제 도입의 70초로 돌아갑니다. 시험은 개발용 컴퓨터 한 대에서 장비 역할의 시뮬레이터(마스터)와 실제 브라우저(뷰어)를 실제 KVS 채널로 이어서 했습니다. 브라우저는 이렇게 동작하게 만들어 두었습니다.

- 영상 바이트가 8초 동안 늘지 않으면 연결이 끊겼다(`CONNECTION_LOST`)고 보고 다시 시도합니다.
- offer를 보낸 뒤 15초 동안 answer가 없으면 `NO_MASTER`(이 구현이 붙인 이름)로 기록하고, 약 30초(±20%) 뒤 다시 시도합니다.
- 고치기 전에는 한 탭이 **같은 `ClientId`로** 계속 다시 시도했습니다.

### 무슨 일이 있었나

고치기 전 시험의 흐름은 이랬습니다(시각은 경과 시간으로만 적습니다).

1. 마스터를 끄자 브라우저가 **9초** 만에 끊김을 알아챘습니다.
2. 이후 `NO_MASTER` → 대기 → 재시도가 되풀이됐습니다. 시도마다 offer를 보냈지만 마스터가 없으니 답이 없었습니다.
3. 마스터를 다시 켰습니다.
4. 21초 뒤 브라우저의 다음 시도가 **접속하자마자 answer를 받았습니다.** 그 answer를 적용했지만 15초 뒤 ICE 연결 확인이 실패(`ICE_FAILED`)했습니다.
5. 그다음 시도에서야 연결됐습니다. **마스터가 돌아온 지 70초 뒤**였습니다.

4번이 이상합니다. 새 시도는 아직 offer를 보내기도 전인데 answer가 먼저 왔습니다.

### 왜 그랬나

다음은 TTL 문서와 이번 시험에서 받은 메시지 순서를 합쳐 재구성한 설명입니다. 미배달 메시지를 TTL 동안 보관한다는 것은 문서에 있는 규칙이지만, 아래 다섯 단계 전체를 AWS 문서가 한 흐름으로 보장하는 것은 아닙니다. 특히 4번(다시 붙은 같은 `ClientId`에 남은 answer가 배달됨)은 이번 시험에서 관측한 동작입니다.

1. **마스터가 없는 동안 보낸 offer는 채널에 남아 있었습니다.** 메시지 TTL(60초) 동안 배달을 기다립니다. 서비스는 성공 응답을 주지 않으므로 브라우저는 이 사실을 모릅니다. 15초가 지나자 브라우저는 그 시도를 포기하고 WebSocket을 닫았습니다.
2. **마스터가 돌아와 접속하자 채널은 남아 있던 offer를 배달했습니다.** 마스터는 성실하게 `RTCPeerConnection`을 만들고 answer를 그 offer를 보낸 `ClientId` 앞으로 보냈습니다.
3. 그 `ClientId`의 뷰어는 이미 나가고 없었습니다. **이번에는 answer가 배달되지 못한 채 TTL 동안 채널에 남았습니다.**
4. 브라우저의 다음 시도가 **같은 `ClientId`로** 접속했습니다. 채널 입장에서는 기다리던 받는 사람이 돌아온 것이므로, 남아 있던 answer를 바로 건넸습니다.
5. 브라우저는 그 answer를 이번 시도의 답으로 알고 적용했습니다. SDP에는 어느 offer의 답인지 적혀 있지 않으니 브라우저도 구분할 수 없었습니다.

그런데 그 answer는 **이전 offer에 맞춰 만든 것**입니다. 마스터 쪽 `RTCPeerConnection`은 이전 offer의 `ice-ufrag`·`ice-pwd`를 기억하고 있고, 새 시도의 브라우저는 새로 만든 offer의 값을 씁니다. ICE 연결 확인 요청은 "상대의 ufrag:내 ufrag" 형태의 사용자 이름과 상대 비밀번호로 서명해 보냅니다([RFC 8445](https://www.rfc-editor.org/rfc/rfc8445.html#section-7.2.2) 7.2.2절). 양쪽이 서로 다른 대화의 값을 들고 있으니 확인 요청이 서로 맞지 않고, 결국 연결 확인이 실패합니다. 기록에 남은 결과는 "answer를 적용하고 15초 뒤 `ICE_FAILED`"였습니다.

<figure class="diagram">
{% include figures/kvs-webrtc-signaling/stale-answer-timeline.svg %}
<figcaption>이번 시험에서는 같은 ClientId로 다시 시도하자 채널에 남은 옛 answer를 받아 한 번 더 실패했다. 시도마다 새 ClientId를 쓰자 옛 answer가 새 시도에 닿지 않았다</figcaption>
</figure>

### 어떻게 고쳤나

두 가지를 바꿨습니다.

1. **시도마다 새 `ClientId`를 씁니다.** `GetIceServerConfig`를 부를 때도 같은 새 ID를 씁니다. 이전 시도 앞으로 남은 메시지는 이전 `ClientId`의 우편함에 남고, 새 시도는 그 우편함을 열지 않습니다.
2. **자기 offer를 보내기 전에 온 answer는 버립니다.** 새 ID라도 혹시 모를 경우를 막는 두 번째 안전장치입니다.

마스터 쪽 규칙은 그대로 두었습니다. 같은 `ClientId`로 새 offer가 오면 이전 연결을 닫고, 오래된 offer 때문에 만든 연결이 20초 안에 연결되지 않으면 정리합니다.

고친 뒤 같은 시험을 다시 했습니다.

| 항목 | 고치기 전 | 고친 뒤 |
|---|---|---|
| 마스터를 끈 뒤 끊김 감지 | 9초 | 10초 |
| 마스터가 돌아온 뒤 처음 시도 | 오래된 answer를 받아 실패 | **바로 연결** |
| 마스터가 돌아온 뒤 연결까지 | **70초** | **14초** |
| 마스터에 남은 쓸모없는 연결 | — | 20초 뒤 정리, 살아 있는 뷰어에는 영향 없음 |

14초는 이번 시험의 관측값이고, 재시도 대기 중 마스터가 언제 돌아오느냐에 따라 달라집니다. 다음 시도까지의 대기는 최대 약 36초(30초 +20%)이며, 그 뒤에 접속·offer/answer·ICE 연결 수립 시간이 더해집니다. 시도가 진행 중일 때 마스터가 돌아오거나 실패·요청 제한이 겹치면 더 길어질 수 있으므로, 36초를 연결 완료까지의 상한으로 읽으면 안 됩니다. 간격을 줄이면 더 빨리 붙지만 API 호출과 메시지가 그만큼 늘어나므로, 현장 시험에서 정할 값으로 남겼습니다.

### TTL을 줄이면 되지 않나

메시지 TTL을 최소값(5초)으로 내리는 방법도 생각할 수 있습니다. 하지만 TTL은 짧게 끊겼다 붙는 뷰어가 메시지를 잃지 않게 하려고 있는 값이고, 5초로 줄여도 "5초 안에 돌아온 경우"에는 같은 문제가 생깁니다. 시간으로 막는 대신 **대화마다 다른 주소(`ClientId`)를 쓰는 것**이 조건과 상관없이 통하는 해결입니다.

### 가짜 소켓 시험으로는 왜 안 보였나

웹 쪽에는 시그널링 흐름 시험이 이미 있었고 모두 통과했습니다. 그런데 이 버그는 그 시험으로 찾지 못했고 실제 브라우저와 실제 채널에서만 드러났습니다.

이유는 간단합니다. 가짜 소켓은 **우리가 아는 동작만** 흉내 냅니다. 보낸 offer에 바로 answer를 돌려주는 가짜는 만들기 쉽지만, "받는 사람이 없는 메시지를 60초 동안 들고 있다가 같은 이름이 다시 오면 건네준다"는 서비스의 배달 규칙까지 넣어 두지는 않았습니다. 버그가 코드 논리가 아니라 **서비스의 배달 방식과 코드 사이**에 있었으니, 그 방식을 모르는 시험이 잡을 수 없었습니다. 찾은 뒤에는 두 경우(시도마다 새 ID, offer 전에 온 answer 무시)를 시험에 넣었습니다.

## 사례 2: 마스터가 없어도 서비스는 아무 말도 하지 않는다

마스터가 채널에 없을 때 뷰어가 offer를 보내면 무슨 일이 일어나는지 실제 채널에서 확인해 봤습니다. Node로 뷰어 역할의 스크립트를 만들어 offer를 보냈더니, 0.1초 뒤 **빈 프레임 하나**만 왔고, 그 뒤 12초 동안 오류도 answer도 오지 않았습니다.

앞의 문서 내용과 맞습니다. offer는 채널에 잘 도착했고(그래서 응답이 없고), 마스터가 오기를 TTL 동안 기다립니다. 서비스에게 "마스터 없음"은 오류가 아니라 "아직 배달 전"일 뿐입니다. 그래서 뷰어가 직접 확인할 수 있는 것은 **정해 둔 시간 동안 answer가 오지 않았다**는 사실뿐입니다. 이 구현은 그 시간을 15초로 정하고, 이 타임아웃에 `NO_MASTER`라는 이름을 붙였습니다. 이름과 달리 실제로 확인한 사실은 answer 미수신이고, 마스터 부재·협상 실패(앞에서 본 코덱 불일치처럼)·지연은 마스터 쪽 기록이나 `STATUS_RESPONSE` 같은 추가 진단으로 구별해야 합니다. 같은 컴퓨터 안 시험에서 offer → answer가 0.16초, 실제 브라우저의 연결이 1~2.5초 걸렸으니 넉넉히 잡은 값입니다. 다만 3·4편에서 볼 TURN 경로나 느린 망에서는 후보 수집에 시간이 더 걸릴 수 있으니, 너무 짧게 잡으면 마스터가 있는데도 없다고 판단하게 됩니다.

여기서 사례 1과 이어지는 점이 보입니다. 15초 뒤 포기한 그 offer는 사라지지 않고 채널에 남습니다. 마스터가 TTL 안에 돌아오면 그 offer에 answer를 만들고, 그 answer가 다음 시도로 배달됩니다. **침묵하는 서비스와 오래된 answer는 같은 배달 규칙의 앞면과 뒷면**입니다.

빈 프레임도 한 번 문제를 일으켰습니다. KVS는 가끔 **내용이 0자인 텍스트 프레임**을 보냅니다. 처음에는 모든 프레임을 JSON으로 해석하다가 이 프레임에서 오류가 나 시험이 실패했습니다. 지금은 마스터와 뷰어 모두 JSON이 아닌 프레임을 무시합니다. 공식 JavaScript SDK의 시그널링 클라이언트도 해석할 수 없는 메시지를 조용히 무시하는데, 코드 주석에는 "앞으로 생길 메시지와의 호환을 위해"라는 이유가 적혀 있습니다. 모르는 메시지가 와도 죽지 않는 수신 코드가 기본입니다.

## 연결된 뒤에는 시그널링을 닫는다

### 영상은 시그널링과 무관하게 흐른다

이 구성에서 시그널링이 하는 일은 연결을 **맺을 때까지**입니다. 일반적으로는 연결 뒤에도 트랙을 바꾸거나 ICE를 재시작하는 재협상에 시그널링이 다시 필요할 수 있습니다. 이번 구성은 연결 후 재협상 대신 새 연결을 만들기 때문에(뒤의 표) 뷰어 시그널링을 닫을 수 있었습니다. 연결이 맺어진 뒤의 영상 패킷은 두 피어 사이(또는 TURN)로 흐르고, 신호 채널의 WebSocket과는 아무 관계가 없습니다. 같은 컴퓨터 안 시험에서도 뷰어가 시그널링을 닫은 뒤 영상이 계속 흐르는 것을 확인했습니다.

그래서 뷰어는 연결되면 바로 시그널링을 닫게 했습니다. 이유는 한도표에 있습니다.

- **연결 최대 1시간**: 1시간이 지나면 서비스가 연결을 끊습니다. 열어 두면 1시간마다 다시 접속해야 합니다.
- **유휴 10분**: 메시지가 오가지 않으면 10분 뒤 끊깁니다.
- **뷰어 자리**: 뷰어 연결 수는 채널당 기본 10개입니다. 영상만 보는 뷰어가 시그널링 자리를 계속 차지할 이유가 없습니다.

뷰어 시그널링은 연결을 맺는 동안만 열려 있고, 연결되거나 실패하면 닫힙니다. 15초는 answer를 기다리는 타임아웃일 뿐이고, answer를 받은 뒤 `connected`가 될 때까지의 시간은 따로 더해집니다. 이번 시험에서 브라우저 연결은 1~2.5초 걸렸으니 두 한도와는 거리가 멀었습니다. 다시 연결해야 할 때만 새로 엽니다.

### 마스터는 계속 기다려야 한다

마스터는 언제 올지 모르는 뷰어를 기다려야 하니 시그널링을 닫을 수 없습니다. 그래서 끊기면 다시 붙는 것이 기본 동작입니다.

- **`GO_AWAY`**: [문서](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/Disconnect.html)는 배포나 서버 점검 같은 때 서비스가 보내는 "연결 종료 시작" 알림이라고 설명합니다. 받은 쪽은 남은 메시지를 처리하고 연결을 끊고 필요하면 다시 접속하라는 뜻이고, 받은 뒤 최대 1분 안에 연결이 끊깁니다. 이 시스템의 마스터는 `GO_AWAY`를 받으면 바로 새 서명 주소로 다시 접속합니다. 이미 흐르고 있는 영상은 시그널링과 상관없이 계속 갑니다.
- **`RECONNECT_ICE_SERVER`**: 중계(TURN) 연결 종료를 알리는 메시지입니다. 새 ICE 서버 설정을 받아 다시 연결하라는 뜻입니다.
- **유휴 제한**: 뷰어 없이 기다리는 마스터는 메시지가 오가지 않습니다. 시험에서 20초마다 WebSocket 핑을 보내던 마스터가 699초 동안 끊기지 않은 일이 한 번 있었습니다. 하지만 한 번뿐인 관찰이고 핑 때문인지 다른 이유인지 구분하지 못했으므로, "핑을 보내면 유휴 제한이 갱신된다"고 결론 내리지 않았습니다. 마스터는 어느 쪽이든 끊기면 다시 붙도록 만들어 두는 것으로 충분합니다.

### 영상이 끊기면: 새 연결로 바꾼다

연결된 뒤 영상이 끊기는 경우의 정책도 간단히 적어 둡니다.

| 상황 | 감지 | 동작 |
|---|---|---|
| 짧은 끊김 | ICE 상태 `disconnected` | 3초 기다린다. 회복되면 그대로 |
| 끊김 지속 | `failed`, 또는 영상 통계가 8초 동안 늘지 않음 | **새 `RTCPeerConnection`으로 교체**: 새 `ClientId`, 새 ICE 서버 설정, 새 시그널링 접속 |
| 계속 실패 | 지수 백오프 1·2·4·8·16·30초(상한), ±20% 흔들림, 최대 8회 | 그래도 안 되면 안내 문구와 [다시 연결] 버튼, 스냅샷 화면으로 대체 |
| 자격 만료 | HTTP API 호출에서 받은 403, `ExpiredToken` | 자격 증명을 새로 받아 다시 연결 |

403 판별은 `GetSignalingChannelEndpoint` 같은 HTTP API 호출에만 씁니다. 브라우저의 `WebSocket`은 접속이 거절돼도 HTTP 상태 코드나 응답 본문을 스크립트에 알려 주지 않기 때문입니다([WHATWG WebSockets](https://websockets.spec.whatwg.org/#feedback-from-the-protocol)). WSS 접속 실패는 자격 만료 시각을 확인해 갱신하고 일반 재접속 정책으로 다루는 편이 안전합니다.

브라우저에는 같은 연결 안에서 길만 다시 찾는 `restartIce()`도 있습니다. 이번에는 구현과 시험이 단순한 "새 연결로 교체"를 먼저 골랐고, 두 방식의 복구 시간은 현장 시험에서 비교하기로 했습니다. ICE 재시작이 무엇을 다시 하는지는 4편에서 다룹니다.

## 주의할 점

1. **`ClientId`는 연결 시도 단위로 새로 만든다.** 신호 채널은 받는 사람 이름으로만 배달하고, SDP에는 어느 offer의 답인지 적혀 있지 않습니다. 같은 이름을 다시 쓰면 이전 대화의 메시지가 새 대화로 들어올 수 있습니다. 탭 여러 개가 같은 값을 쓰면 나중 탭이 앞 탭을 밀어냅니다. `AWS_`로 시작하는 값은 쓸 수 없습니다.
2. **answer는 내 offer를 보낸 뒤에 온 것만 적용한다.** 새 ID와 함께 두 번째 안전장치로 둡니다.
3. **상대 후보는 상대 SDP를 적용한 뒤에 넣는다.** 먼저 온 후보는 모아 두었다가 answer 적용 뒤에 `addIceCandidate()`로 넣습니다.
4. **침묵은 정상이다.** 서비스는 성공에 답하지 않고 "마스터 없음"을 알려 주지 않습니다. 타임아웃으로 알 수 있는 것은 answer 미수신뿐이고, 오류를 받고 싶으면 `correlationId`를 넣어 `STATUS_RESPONSE`를 봅니다.
5. **JSON이 아닌 프레임, 모르는 메시지 종류는 내용을 풀기 전에 무시한다.** 빈 텍스트 프레임이 실제로 옵니다. 다루는 종류라도 내용이 깨져 있으면 무시하고, 받은 SDP·후보를 적용하다 실패한 것은 무시하지 말고 시도를 정리합니다.
6. **메시지 내용 10K는 base64 기준이다.** 원래 SDP JSON은 약 7.5 KB 아래로 둡니다. 코덱을 줄이고 후보는 trickle로 따로 보냅니다.
7. **서명한 WSS 주소, TURN 자격, SDP는 기록하지 않는다.** 서명 주소는 약 5분짜리 접속 권한이고, TURN 자격도 그 자체로 권한입니다. SDP의 `a=candidate` 줄에는 내부 IP가 들어 있습니다. 디버그가 필요하면 방향이나 ufrag의 해시처럼 모양만 남깁니다.
8. **연결되면 뷰어 시그널링은 닫고, 마스터는 끊기면 다시 붙게 만든다.** 1시간·10분 한도와 `GO_AWAY`를 정상적인 사건으로 다룹니다.
9. **관리형 서비스의 배달 규칙은 가짜 객체 시험에 들어 있지 않다.** 실제 채널과 실제 브라우저로 "끊었다 다시 붙기"를 꼭 한 번 돌려 봅니다.

## 정리

- 시그널링은 두 피어가 직접 연결하기 전에 미디어 형식, 주소 후보, 연결 확인용 비밀값, 인증서 지문을 **다른 길로** 주고받는 사전 대화입니다. WebRTC 표준은 그 길을 정하지 않고, 무엇을(SDP) 어떤 규칙으로(offer/answer) 주고받는지만 정합니다.
- SDP는 `종류=값` 줄의 목록이고, `m=` 섹션마다 코덱(`rtpmap`, 선호 순서), 방향, `ice-ufrag`/`ice-pwd`, `fingerprint`, `setup`, 후보가 들어 있습니다. offerer가 제안하고 answerer가 공통 부분을 고릅니다. 후보 풀을 쓰지 않으면 후보 수집은 `setLocalDescription`에서 시작하고, 상대 후보는 상대 SDP를 적용한 뒤에 넣습니다.
- 이 글의 구성에서는 뷰어가 `DescribeSignalingChannel` → `GetSignalingChannelEndpoint` → `GetIceServerConfig`를 부르고, SigV4로 서명한 WSS 주소(약 5분 유효)로 접속해 base64로 감싼 `SDP_OFFER`·`ICE_CANDIDATE`를 보냅니다. 마스터는 뷰어의 `ClientId` 앞으로 answer를 보냅니다.
- 신호 채널은 배달 못 한 메시지를 메시지 TTL(5~120초) 동안 보관하고, 성공에는 답하지 않습니다. 이 두 규칙 때문에 뷰어가 타임아웃으로 알 수 있는 것은 answer 미수신뿐이고, 이번 시험에서는 같은 `ClientId`로 다시 시도하자 오래된 answer를 받았습니다. 시도마다 새 `ClientId`로 바꾸자 이번 시험의 복구 시간이 70초에서 14초로 줄었습니다.
- 연결된 뒤 영상은 시그널링과 따로 흐르므로 뷰어는 시그널링을 닫고, 마스터는 `GO_AWAY`와 1시간·10분 한도에 맞춰 다시 붙습니다.

한 가지 예고를 붙입니다. 이 글의 결론은 "`ClientId`는 시도마다 새로"였지만, 녹화를 켜면 이 결정이 정반대가 됩니다. 녹화 채널에서는 브라우저가 KVS 쪽 저장 세션에 붙는데, 저장 세션은 끊긴 뷰어의 자리를 잠시 붙잡아 두고 동시에 붙을 수 있는 수도 적어서, 다시 붙을 때마다 새 ID를 쓰면 자리를 혼자 다 차지하게 됩니다. 그 이야기는 6편에서 합니다.

[다음 편]({% post_url 2026-11-10-webrtc-nat-stun %})에서는 SDP의 `a=candidate` 줄에 들어갈 주소가 어디서 오는지, 두 기기가 왜 서로의 주소를 알아도 바로 붙지 못하는지를 NAT와 STUN으로 풀어 봅니다.
