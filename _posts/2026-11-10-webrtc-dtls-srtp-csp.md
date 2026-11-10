---
title: "WebRTC 암호화와 브라우저 보안: DTLS-SRTP, 그리고 CSP에 KVS 주소를 넣은 이유"
date: 2026-11-10 10:20:00 +0900
categories: [AWS, 영상 스트리밍]
tags: [aws-concepts, aws, kvs, webrtc, dtls, srtp, csp, security]
description: "WebRTC 영상이 DTLS-SRTP로 암호화되는 원리(지문, a=setup 역할, 암호 묶음과 ECDSA·RSA 인증서)와, Kinesis Video Streams를 쓰는 페이지의 CSP connect-src에 주소 세 줄이 필요한 이유, STUN·TURN과 srcObject가 CSP 검사 밖인 점을 정리합니다."
---

> **시리즈: AWS KVS로 실시간 영상 보내기**
> 1. KVS 큰 그림: 영상은 '땡겨오는' 게 아니라 만나서 흐른다
> 2. 시그널링: SDP offer/answer와 KVS 신호 채널
> 3. NAT와 STUN: 왜 두 기기는 바로 못 붙나
> 4. TURN과 ICE: 끝내 못 붙으면 중계한다
> 5. **암호화와 브라우저 보안: DTLS-SRTP, 그리고 CSP** ← 지금 글
> 6. 녹화: KVS WebRTC 수집과 저장 세션
> 7. 다시 보기: HLS 원리와 KVS 재생

현장 장비의 카메라 영상을 관제 웹 대시보드에서 실시간으로 보는 기능을 AI 에이전트와 같이 만들었습니다. 영상은 Amazon Kinesis Video Streams(KVS)의 WebRTC 기능으로 보냅니다. 장비 쪽 보조 컴퓨터가 영상을 보내는 쪽(마스터), 브라우저가 받는 쪽(뷰어)입니다.

기능이 거의 다 붙었을 때 에이전트에게 보안 검토를 맡겼습니다. 돌아온 목록 중에 이런 줄이 있었습니다.

> 보안 헤더(CSP)가 실제로 적용되지 않을 수 있습니다.

에이전트는 헤더를 고치자고 추천했습니다. 저는 그 줄을 이해하지 못했습니다.

> 보안 헤더 문제는 정확히 뭔지 모르겠어.
>
> 보안 수정을 추천한다고?? 어떻게 수정할지 알려줘.

그래서 배포할 것과 똑같은 헤더를 로컬 시험 서버에 붙여 대시보드를 띄워 봤습니다. 로그인까지는 잘 됐습니다. 그런데 카메라를 열자 영상이 나오지 않았습니다. 콘솔에는 `connect-src` 위반으로 KVS 주소가 막혔다는 메시지가 찍혔습니다. 헤더가 "제대로" 적용되는 순간 카메라가 멈춘 것입니다.

비슷한 시기에 다른 곳에서도 보안 문제가 하나 터졌습니다. 녹화를 켜려고 장비를 KVS의 녹화용 서버(저장 세션)에 붙였더니, 영상이 흐르기도 전에 **DTLS 핸드셰이크**가 실패했습니다. 오류 메시지는 `error []`, 빈 목록 하나뿐이었습니다.

두 문제는 이름에 똑같이 "보안"이 붙지만 지키는 대상이 다릅니다.

- **DTLS-SRTP**는 영상 그 자체를 지킵니다. 길 중간에서 패킷을 엿보거나 바꾸지 못하게 합니다.
- **CSP**는 웹 페이지를 지킵니다. 페이지에 끼어든 스크립트가 아무 곳에나 접속하지 못하게, 페이지가 접속할 수 있는 주소를 미리 정해 둡니다.

이 글은 이 두 가지를 기초부터 다룹니다. 앞부분은 WebRTC 영상이 어떻게 암호화되는지, 상대를 무엇으로 믿는지, 누가 DTLS 클라이언트가 되는지, 왜 인증서 종류 때문에 핸드셰이크가 깨졌는지입니다. 뒷부분은 CSP가 무엇인지, KVS를 쓰는 페이지에 왜 주소 세 줄이 필요했는지, 어떤 접속은 CSP 검사를 받지 않는지입니다. 마지막에 그때 정한 설정과 측정값, 주의할 점으로 돌아옵니다.

## 앞 편 세 문장 복습

WebRTC에서 두 기기는 먼저 **시그널링**으로 서로의 조건을 적은 문서(SDP offer와 answer)를 주고받습니다. KVS에서는 이 문서가 서명된 WebSocket 주소로 붙는 **신호 채널**을 지나갑니다. 그다음 **ICE**가 STUN으로 알아낸 주소와 TURN 중계 주소 같은 후보들을 짝지어 실제로 패킷이 오가는 길을 찾습니다.

이 글은 그 길이 찾아진 다음부터입니다. 길이 열렸다고 바로 영상을 보내지 않습니다. 그 길 위에서 먼저 상대를 확인하고 키를 나눕니다.

<figure class="diagram">
{% include figures/webrtc-dtls-srtp-csp/two-layers.svg %}
<figcaption>인증서 지문은 시그널링으로 먼저 건너가고, 미디어 길에서는 DTLS 핸드셰이크가 상대 인증서를 그 지문과 대조한 뒤 SRTP 키를 꺼낸다. 영상은 SRTP 패킷으로 흐른다</figcaption>
</figure>

## 1부. 영상은 어떻게 암호화되나

### WebRTC에서 암호화는 고를 수 없다

화상 통화 기술 중에는 암호화를 켜고 끄는 선택지가 있는 것이 많습니다. WebRTC는 그렇지 않습니다. 브라우저의 WebRTC 보안 구조를 정한 [RFC 8827](https://www.rfc-editor.org/rfc/rfc8827) 6.5절은 이렇게 정합니다.

- 모든 미디어 채널은 SRTP와 SRTCP로 보호해야 하고(MUST), 암호화하지 않은 평문 RTP로 보내면 안 됩니다(MUST NOT).
- 미디어 채널마다 DTLS-SRTP를 제시해야 합니다(MUST). 데이터 채널은 DTLS로 보호합니다.

그래서 브라우저의 `RTCPeerConnection`에는 "암호화 끄기" 옵션이 없습니다. 개발자가 할 일은 암호화를 켜는 것이 아니라, 암호화가 제대로 맞물리게 하는 것입니다. 상대가 브라우저면 거의 신경 쓸 일이 없습니다. 상대가 서버나 다른 라이브러리일 때 문제가 생깁니다. 뒤에서 그 사례를 봅니다.

먼저 이름 네 개를 짚고 갑니다.

| 이름 | 한 줄 풀이 |
|---|---|
| **RTP** | 영상·소리를 작은 패킷으로 잘라 순서 번호와 시각을 붙여 보내는 형식. 그 자체로는 암호화가 없다 |
| **SRTP** | RTP 패킷의 내용을 암호화하고, 위조·재전송을 막는 인증 태그를 붙인 형식 ([RFC 3711](https://www.rfc-editor.org/rfc/rfc3711)) |
| **TLS** | HTTPS가 쓰는 암호화 연결. 상대 인증서를 확인하고 키를 나눈다. TCP처럼 순서가 보장되는 길을 전제로 한다 |
| **DTLS** | TLS를 UDP 위에서 쓰도록 고친 것. 패킷이 빠지거나 순서가 바뀌어도 핸드셰이크가 견딘다 ([RFC 6347](https://www.rfc-editor.org/rfc/rfc6347)은 DTLS 1.2, [RFC 9147](https://www.rfc-editor.org/rfc/rfc9147)은 DTLS 1.3) |

실시간 영상은 지연을 줄이려고 보통 UDP로 보냅니다. 패킷 하나가 늦게 오느니 버리는 편이 낫기 때문입니다. TLS는 UDP 위에서 그대로 쓸 수 없으니 DTLS를 씁니다.

### DTLS-SRTP: DTLS로 키를 나누고, SRTP로 영상을 보낸다

DTLS와 SRTP가 어떻게 합쳐지는지 정한 것이 [RFC 5764](https://www.rfc-editor.org/rfc/rfc5764)의 **DTLS-SRTP**입니다. 이름 때문에 "영상을 DTLS로 감싸서 보낸다"고 생각하기 쉬운데, 실제는 다릅니다. 역할이 나뉩니다.

1. **DTLS는 핸드셰이크만 합니다.** 상대 인증서를 확인하고, 둘만 아는 비밀 값을 만듭니다.
2. **그 비밀 값에서 SRTP 키를 꺼냅니다.** RFC 5764는 TLS의 키 추출 기능(exporter)에 `EXTRACTOR-dtls_srtp`라는 라벨을 주어 SRTP용 키와 솔트를 뽑게 합니다.
3. **영상은 SRTP 패킷으로 보냅니다.** RFC 5764는 미디어를 DTLS의 application_data 레코드로 보내지 않는다고 적습니다. SRTP 패킷은 DTLS 틀 없이 그대로 선로에 나갑니다.

왜 영상을 DTLS로 감싸지 않을까요? SRTP는 RTP 머리(순서 번호, 시각, 송신자 식별자)는 그대로 두고 내용만 암호화합니다. 받는 쪽과 중간 장비가 머리를 보고 순서를 맞추거나 손실을 셀 수 있습니다. 영상 패킷마다 붙는 덧붙임도 작습니다. 실시간 미디어에 맞춘 형식이 이미 있으니, 키 교환만 검증된 TLS 방식에 맡긴 것입니다.

어떤 SRTP 방식을 쓸지는 핸드셰이크에서 정합니다. 클라이언트가 첫 메시지(ClientHello)의 `use_srtp` 확장에 쓸 수 있는 SRTP 방식(profile) 목록을 넣고, 서버가 그중 하나를 골라 답합니다. 서버는 클라이언트가 제시하지 않은 방식을 고를 수 없습니다. RFC 8827은 `SRTP_AES128_CM_HMAC_SHA1_80`을 반드시 지원할 방식으로 정합니다.

### 한 포트에 세 가지 패킷이 섞인다

WebRTC는 보통 UDP 포트 하나로 ICE 확인용 STUN 패킷, DTLS 핸드셰이크 패킷, SRTP 미디어 패킷을 모두 주고받습니다. 받는 쪽은 패킷의 **첫 바이트**만 보고 셋을 구분합니다. RFC 5764 5.1.2절의 규칙입니다.

| 첫 바이트 값 | 패킷 |
|---|---|
| 0–1 | STUN (ICE 연결 확인) |
| 20–63 | DTLS (핸드셰이크) |
| 128–191 | RTP·RTCP (여기서는 SRTP·SRTCP) |

세 형식의 첫 바이트가 겹치지 않게 생겼기 때문에 가능한 일입니다. 순서도 정해져 있습니다. RFC 8827 6.3절은 ICE로 상대에게 닿는지 확인하기 전에는 ICE 아닌 패킷을 보내면 안 된다고 정합니다. 그래서 순서는 언제나 **STUN 확인 → DTLS 핸드셰이크 → SRTP 미디어**입니다. 위 그림의 미디어 층이 이 순서입니다.

연결된 뒤에도 STUN은 멈추지 않습니다. [RFC 7675](https://www.rfc-editor.org/rfc/rfc7675)의 동의 확인(consent freshness)으로, 상대가 아직 이 패킷을 받겠다고 하는지 주기적으로 묻습니다. 상대가 응답하지 않으면 보내기를 멈춥니다. 상대가 원하지 않는 곳으로 영상을 계속 쏟아붓지 않게 하는 장치입니다.

### 핸드셰이크 한 바퀴

DTLS 1.2의 전체 핸드셰이크를 RFC 6347 기준으로 보면 이렇습니다. 메시지를 한 번에 몰아 보내는 묶음을 비행(flight)이라고 부릅니다.

```text
클라이언트                                  서버
ClientHello (use_srtp, 암호 묶음 목록)  ──▶
                                       ◀──  HelloVerifyRequest (쿠키)
ClientHello (쿠키 포함)                 ──▶
                                       ◀──  ServerHello (고른 묶음, 고른 SRTP 방식)
                                            Certificate
                                            ServerKeyExchange
                                            CertificateRequest
                                            ServerHelloDone
Certificate
ClientKeyExchange
CertificateVerify
ChangeCipherSpec, Finished              ──▶
                                       ◀──  ChangeCipherSpec, Finished
```

HTTPS와 비교하면 다른 점이 두 가지 보입니다.

- **HelloVerifyRequest(쿠키)**: UDP는 보낸 주소를 속이기 쉽습니다. 서버가 아무 ClientHello에나 큰 응답을 돌려주면, 남의 주소를 적어 보낸 공격에 증폭기로 쓰일 수 있습니다. 그래서 서버는 먼저 작은 쿠키를 돌려주고, 그 쿠키를 다시 가져온 클라이언트에게만 본 응답을 보냅니다.
- **양쪽 모두 인증서를 냅니다**: 서버가 `CertificateRequest`로 클라이언트 인증서도 요구하고, 클라이언트는 `Certificate`와 `CertificateVerify`로 답합니다. 보통 HTTPS는 서버만 인증서를 냅니다. WebRTC는 두 기기가 대등하니 서로 확인합니다. [RFC 5763](https://www.rfc-editor.org/rfc/rfc5763)이 이 상호 인증을 정합니다.

오늘날 브라우저끼리는 DTLS 1.3을 쓰기도 합니다. 1.3은 비행 구성이 다르지만(더 짧습니다), "인증서를 서로 내고 확인한 뒤 키를 꺼낸다"는 뼈대는 같습니다. 이 글의 실험에서 어떤 버전이 쓰였는지는 뒤의 `getStats()` 절에 있습니다.

### 인증서는 자체 서명, 믿음은 지문으로

여기서 이상한 점이 하나 있습니다. HTTPS 인증서는 공인 인증 기관(CA)이 서명해 줍니다. 브라우저는 그 서명을 따라 올라가 믿을 만한지 판단합니다. 그런데 WebRTC의 두 기기에는 도메인 이름이 없습니다. 브라우저가 통화마다 CA에서 인증서를 받아 올 수도 없습니다.

그래서 WebRTC의 DTLS 인증서는 **자체 서명(self-signed)**입니다. RFC 5763은 이 인증서가 공개 키를 담아 나르는 그릇일 뿐이라고 설명합니다. RFC 8827 4.1절은 통화마다 새로 만들어 써도 된다고 적습니다. 브라우저는 `RTCPeerConnection`을 만들 때 키 쌍과 인증서를 스스로 만듭니다.

CA 서명이 없으면 무엇으로 상대를 믿을까요? 답은 **지문(fingerprint)**입니다. 각자 자기 인증서의 해시를 SDP에 적어 시그널링으로 먼저 보냅니다. [RFC 8122](https://www.rfc-editor.org/rfc/rfc8122)가 정한 형식은 해시 이름 뒤에 대문자 16진수를 콜론으로 이은 것입니다. 실제 SDP에는 이런 줄이 들어갑니다. 값은 이 글을 위해 만든 가짜입니다.

```text
a=fingerprint:sha-256 01:56:50:0B:CE:BB:04:5E:E8:2D:32:FC:BB:ED:D1:7E:FF:B8:3C:2D:78:C2:3B:13:52:E4:68:80:70:E5:DF:12
a=setup:actpass
```

그다음 미디어 길에서 DTLS 핸드셰이크를 할 때, 받는 쪽은 상대가 낸 인증서의 해시를 직접 계산합니다. 그 값이 시그널링으로 받은 지문과 같으면 "SDP를 보낸 그 상대가 맞다"고 판단합니다. 다르면 연결을 끊습니다. [RFC 8842](https://www.rfc-editor.org/rfc/rfc8842)는 지문이 맞지 않으면 세션을 끝내야 한다고(MUST) 정합니다.

비유하면 이렇습니다. 처음 만나는 사람의 얼굴 사진을 믿을 만한 친구에게 미리 받아 두고, 약속 장소에서 실제 얼굴과 사진을 대조하는 것입니다. 실제 동작으로 옮기면 사진은 지문이고, 친구는 시그널링 채널이고, 얼굴 대조는 DTLS 핸드셰이크 안의 인증서 해시 비교입니다.

### 그래서 시그널링 채널이 믿을 만해야 한다

이 방식에는 분명한 약점이 있습니다. 지문이 지나가는 시그널링 채널을 공격자가 쥐고 있다면 어떻게 될까요? 공격자는 SDP 속 지문을 자기 인증서의 지문으로 바꿔치기할 수 있습니다. 그러면 양쪽은 공격자를 상대로 핸드셰이크를 하고, 지문도 맞으니 아무 경고 없이 연결됩니다. 이것이 중간자 공격(MITM)입니다.

표준도 이 한계를 숨기지 않습니다. RFC 5763은 지문 방식이 미디어 경로의 능동 공격은 막지만 시그널링 경로의 공격은 막지 못한다고 적습니다. 공격에 성공하려면 시그널링 속 지문을 바꿔야 한다는 뜻이기도 합니다. RFC 8827 9.1절은 HTTPS를 쓰더라도 시그널링 서버 자신이 중간자가 될 수 있다고 적습니다. 그래서 신원 제공자(IdP)로 상대 신원을 따로 확인하는 방법도 정의하는데, 이 시스템은 그 방법을 쓰지 않았습니다. 대신 시그널링 서버(KVS)를 믿는 구조입니다.

결국 **영상의 기밀성은 시그널링 채널의 보안만큼만 강합니다.** KVS의 신호 채널은 이 점에서 두 겹으로 지켜집니다.

- 브라우저와 장비는 신호 채널에 **TLS로 암호화된 WSS** 주소로 붙습니다. 길 중간에서 SDP를 엿보거나 바꿀 수 없습니다.
- 그 주소에는 **IAM 자격으로 만든 SigV4 서명**이 붙습니다. 채널에 마스터나 뷰어로 붙을 권한이 있는 쪽만 들어올 수 있습니다. SigV4 서명은 [인증 한 번에 정리: JWT, IAM(SigV4), Cognito]({% post_url 2026-11-01-auth-basics-jwt-iam-cognito %})에서, 브라우저가 그 자격을 받는 방법은 [Cognito 사용자 풀과 자격 증명 풀]({% post_url 2026-11-06-cognito-user-pool-identity-pool %})에서 다뤘습니다.

반대로 말하면, 채널에 붙을 권한을 아무에게나 주면 그 사람도 SDP를 보내고 받을 수 있습니다. [KVS ConnectAsMaster 문서](https://docs.aws.amazon.com/kinesisvideostreams-webrtc-dg/latest/devguide/ConnectAsMaster.html)에 따르면 마스터 자리는 가장 최근에 접속한 쪽이 차지합니다. IAM 정책에서 마스터 권한과 뷰어 권한을 나누는 것이 곧 영상 보안의 일부인 이유입니다.

### a=setup: 누가 DTLS 클라이언트가 되나

DTLS에도 클라이언트와 서버가 있습니다. ClientHello를 먼저 보내는 쪽이 클라이언트입니다. 그런데 WebRTC의 두 기기는 대등합니다. 누가 클라이언트를 할지는 RFC 5764 3절대로 핸드셰이크 바깥에서 정합니다. SDP의 `a=setup` 줄이 그 역할입니다.

| 값 | 뜻 |
|---|---|
| `actpass` | 어느 쪽이든 할 수 있다. **offer는 반드시 이 값** ([RFC 8842](https://www.rfc-editor.org/rfc/rfc8842)) |
| `active` | 내가 먼저 ClientHello를 보낸다 = DTLS 클라이언트 |
| `passive` | 상대의 ClientHello를 기다린다 = DTLS 서버 |

offer를 보내는 쪽이 `actpass`로 열어 두면, answer를 보내는 쪽이 `active`나 `passive` 중에서 고릅니다. RFC 5763 5절은 answer 쪽이 `active`를 고르기를 권합니다(RECOMMENDED). answer를 보내자마자 ClientHello를 보낼 수 있어서, answer가 상대에게 도착하는 시간과 핸드셰이크가 겹쳐 연결이 빨라지기 때문입니다.

브라우저 둘을 한 페이지 안에서 연결해 직접 확인해 봤습니다. 캔버스 영상을 한쪽 `RTCPeerConnection`(offer 쪽)에서 다른 쪽(answer 쪽)으로 보내는 실험이고, ego lite의 Chromium 156에서 돌렸습니다.

| | offer 쪽 | answer 쪽 |
|---|---|---|
| SDP의 `a=setup` | `actpass` | `active` |
| SDP의 지문 | `sha-256` | `sha-256` |
| `getStats()`의 `dtlsRole` | `server` | `client` |

권고대로 answer 쪽이 `active`를 골라 DTLS 클라이언트가 됐습니다.

이 규칙은 KVS에서 의미가 있습니다. 보통 KVS WebRTC에서는 뷰어(브라우저)가 offer를 보내고 마스터(장비)가 answer를 보냅니다. 그러면 장비가 DTLS 클라이언트가 됩니다. 녹화용 저장 세션은 방향이 반대입니다. [JoinStorageSession API 문서](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/API_webrtc_JoinStorageSession.html)에는 호출마다 offer가 한 번 보내진다고 적혀 있고, 실제로 저장 세션이 offer를 보내고 장비가 answer를 보냈습니다. 어느 경우든 장비 쪽 라이브러리가 `active`를 고르면 **장비가 DTLS 클라이언트**로서 ClientHello를 보내게 됩니다. 이 사실이 다음 절 사고의 출발점입니다.

### 암호 묶음과 인증서 종류: 핸드셰이크가 `error []`로 끝난 이유

TLS 1.2와 DTLS 1.2에서 클라이언트는 ClientHello에 **암호 묶음(cipher suite)** 목록을 넣습니다. 묶음 이름 하나에 여러 가지가 같이 정해져 있습니다.

```text
TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
    ─────  ─────      ───────────  ──────
    키 교환 서버 인증서   대칭 암호      해시
```

가운데 `ECDSA` 자리가 핵심입니다. 이 자리는 **서버 인증서의 키 종류**를 정합니다. [RFC 8422](https://www.rfc-editor.org/rfc/rfc8422)는 `ECDHE_ECDSA` 묶음을 쓰려면 서버 인증서에 ECDSA(또는 EdDSA) 키가 있어야 하고, `ECDHE_RSA` 묶음을 쓰려면 RSA 키가 있어야 한다고 정합니다. 서버 인증서가 RSA인데 클라이언트가 `ECDHE_ECDSA` 계열만 제시하면, 서버는 고를 묶음이 없습니다.

RFC 8827은 브라우저가 DTLS 1.2와 `TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256`(P-256 곡선)을 반드시 지원하게 합니다. 브라우저끼리는 둘 다 ECDSA 인증서를 만들기 때문에 이 조합으로 자연스럽게 맞습니다. 그래서 WebRTC 라이브러리 중에는 ECDSA 계열만 제시하는 것도 있습니다. 상대가 늘 브라우저라면 문제가 없습니다.

이번 장비 쪽 송신기는 Python의 aiortc 라이브러리였고, ECDHE-ECDSA 계열만 제시했습니다. 뷰어가 브라우저일 때는 잘 붙었습니다. 그런데 녹화용 저장 세션의 DTLS 인증서는 **RSA**였습니다. 앞 절대로 장비가 DTLS 클라이언트이니, 장비가 ECDSA 묶음만 담은 ClientHello를 보내고, RSA 인증서를 가진 서버는 고를 것이 없어 핸드셰이크를 끊습니다. 라이브러리는 이 실패를 빈 오류 목록 `error []`로만 보여 줬습니다. AWS 문서가 저장 세션 인증서의 종류를 적어 두지는 않아서, 이것은 붙어 보고 안 사실입니다.

같은 상황을 OpenSSL로 다시 만들 수 있습니다. 내 컴퓨터(OpenSSL 3.6.4)에서 RSA 인증서를 가진 DTLS 1.2 서버를 띄우고, 클라이언트 묶음을 바꿔 가며 붙여 봤습니다.

```sh
# RSA 2048 자체 서명 인증서와 DTLS 1.2 서버
openssl req -x509 -newkey rsa:2048 -nodes -keyout rsa.key -out rsa.crt -days 1 -subj /CN=dtls-demo
openssl s_server -dtls1_2 -accept 127.0.0.1:4433 -cert rsa.crt -key rsa.key

# (다른 터미널) 1) ECDSA 묶음만 제시
openssl s_client -dtls1_2 -connect 127.0.0.1:4433 -cipher ECDHE-ECDSA-AES128-GCM-SHA256

# 2) RSA 묶음을 하나 더 제시
openssl s_client -dtls1_2 -connect 127.0.0.1:4433 \
  -cipher 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256'
```

1번은 실패합니다. 서버 쪽에는 `no shared cipher`(같이 쓸 묶음이 없다)가, 클라이언트 쪽에는 경고 번호 40(`handshake failure`)이 찍힙니다.

```text
# 서버
...:tls_post_process_client_hello:no shared cipher:...
# 클라이언트
...:ssl/tls alert handshake failure:...:SSL alert number 40
New, (NONE), Cipher is (NONE)
```

2번은 성공합니다. 서버가 RSA 묶음을 골랐습니다.

```text
verify error:num=18:self-signed certificate
Peer signature type: rsa_pss_rsae_sha256
New, TLSv1.2, Cipher is ECDHE-RSA-AES128-GCM-SHA256
Protocol: DTLSv1.2
Server public key is 2048 bit
```

첫 줄의 `self-signed certificate`도 눈여겨볼 만합니다. OpenSSL은 CA 서명이 없다고 경고하지만, WebRTC에서는 이것이 정상입니다. 앞에서 본 대로 믿음은 CA가 아니라 지문으로 정합니다.

그래서 장비 쪽 송신기가 제시하는 묶음에 RSA 계열 세 가지를 더했습니다. 모두 AEAD(암호화와 위조 검사를 한 번에 하는 방식)이고 키 교환이 ECDHE라서 전방 보안(forward secrecy, 나중에 키가 새어도 지난 대화는 풀 수 없는 성질)을 유지합니다. RFC 8827도 전방 보안이 있는 묶음을 우선하라고 합니다.

- `ECDHE-RSA-AES128-GCM-SHA256`
- `ECDHE-RSA-AES256-GCM-SHA384`
- `ECDHE-RSA-CHACHA20-POLY1305`

aiortc는 이 목록을 바꾸는 공개 설정이 없어서 라이브러리 내부 값을 고쳐야 했습니다. 내부 구조가 바뀌면 조용히 지나가지 않고 바로 오류를 내게 해 뒀습니다. **지문 확인은 그대로 둡니다.** 묶음을 넓힌 것은 "어떤 종류의 인증서를 받아들일지"를 넓힌 것이지, "누구의 인증서를 믿을지"를 바꾼 것이 아닙니다. 상대 인증서가 RSA든 ECDSA든 SDP로 받은 지문과 맞아야 연결됩니다.

한 가지 덧붙입니다. TLS 1.3에서는 이런 어긋남이 묶음 이름에서 생기지 않습니다. [RFC 8446](https://www.rfc-editor.org/rfc/rfc8446)의 1.3 묶음(예: `TLS_AES_128_GCM_SHA256`)은 대칭 암호와 해시만 정하고, 인증서 종류는 서명 알고리즘 협상에서 따로 정합니다. 1.3 묶음은 1.2에서 쓸 수도 없습니다. 이번 사례는 DTLS 1.2 방식으로 묶음을 고르는 라이브러리에서 생긴 일입니다.

저장 세션에 붙으려면 맞춰야 할 것이 이것만은 아니었습니다. 소리 트랙이 꼭 있어야 했고, 후보를 보내는 방식과 메시지 형식도 브라우저 상대일 때와 달랐습니다. "WebRTC 상대가 브라우저가 아니라 AWS 서버일 때"의 나머지는 6편에서 다룹니다.

### getStats()로 실제 협상 결과 보기

핸드셰이크가 무엇으로 맞았는지는 추측할 필요가 없습니다. 브라우저의 `getStats()`가 알려 줍니다. [W3C WebRTC Statistics](https://www.w3.org/TR/webrtc-stats/)의 `RTCTransportStats`에는 DTLS 상태·역할·버전·묶음과 SRTP 방식이, `RTCCertificateStats`에는 지문과 해시 알고리즘이 있습니다.

```js
// 연결된 RTCPeerConnection에서 DTLS·SRTP 협상 결과를 꺼낸다
async function logDtls(pc) {
  const stats = await pc.getStats();
  stats.forEach((s) => {
    if (s.type === 'transport') {
      console.log({
        dtlsState: s.dtlsState,   // "connected"면 핸드셰이크 완료
        dtlsRole: s.dtlsRole,     // "client" 또는 "server"
        tlsVersion: s.tlsVersion, // 16진수 4자리. FEFD = DTLS 1.2, FEFC = DTLS 1.3
        dtlsCipher: s.dtlsCipher, // 고른 암호 묶음 (IANA 이름)
        srtpCipher: s.srtpCipher, // 고른 SRTP 방식
      });
    }
    if (s.type === 'certificate') {
      console.log(s.fingerprintAlgorithm); // 예: "sha-256"
    }
  });
}
```

앞의 브라우저 두 개 실험에서 이 코드를 돌린 결과는 이랬습니다(Chromium 156).

| 항목 | 값 |
|---|---|
| `dtlsState` | `connected` |
| `tlsVersion` | `FEFC` (DTLS 1.3) |
| `dtlsCipher` | `TLS_AES_128_GCM_SHA256` |
| `srtpCipher` | `SRTP_AES128_CM_HMAC_SHA1_80` |
| `fingerprintAlgorithm` | `sha-256` |

브라우저끼리는 DTLS 1.3으로 맞았고, 묶음 이름에 인증서 종류가 없는 1.3 묶음이 골라졌습니다. SRTP 방식은 RFC 8827이 필수로 정한 그 값입니다. 다른 브라우저나 버전에서는 값이 다를 수 있습니다. 연결이 안 될 때 이 값들과 상대 쪽 로그를 나란히 놓으면, 어느 단계에서 어긋났는지 좁히기 쉽습니다.

## 2부. 페이지는 어디에 접속할 수 있나: CSP

### CSP는 무엇이고 왜 쓰나

에이전트가 말한 "보안 헤더"는 **CSP(Content Security Policy)**였습니다. 대화 중에 에이전트는 보안 헤더를 "서버가 페이지와 함께 브라우저에 주는 안전 규칙"이라고 풀어 줬습니다. 정확한 설명입니다.

[MDN의 CSP 안내](https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CSP)에 따르면, 서버는 페이지 응답에 `Content-Security-Policy` 헤더를 붙여 보냅니다. 브라우저는 그 페이지가 어떤 출처에서 스크립트를 불러오고, 어디에 접속하고, 어디서 이미지와 영상을 가져올 수 있는지를 그 규칙대로 제한합니다. 가장 큰 목적은 **XSS(교차 사이트 스크립팅)의 피해를 줄이는 것**입니다.

예를 들어 보겠습니다. 장비 이름 같은 사용자 입력을 화면에 그대로 넣는 실수가 있어서, 공격자가 스크립트를 페이지에 끼워 넣었다고 합시다. 그 스크립트는 로그인한 사용자의 권한으로 돕니다. 메모리의 토큰이나 임시 AWS 자격 증명을 읽어 공격자 서버로 보내려 할 것입니다. 이때 CSP가 "이 페이지는 자기 출처와 KVS, 로그인 서비스에만 접속할 수 있다"고 정해 두었다면, 공격자 서버로 가는 요청은 브라우저가 막습니다. [CSP Level 3 명세](https://www.w3.org/TR/CSP3/)도 `connect-src`를 설명하며 데이터 유출(data exfiltration) 위험을 언급합니다. CSP는 XSS 자체를 없애지는 못하지만, 끼어든 스크립트가 할 수 있는 일을 크게 줄입니다.

### 지시어와 기본값

CSP는 지시어(directive)와 허용할 출처 목록을 세미콜론으로 이어 씁니다.

```text
Content-Security-Policy: default-src 'self'; img-src 'self' data:; connect-src 'self' https://api.example.com
```

자주 보는 지시어는 이렇습니다.

| 지시어 | 검사하는 것 |
|---|---|
| `default-src` | 아래 가져오기(fetch) 지시어가 따로 없을 때 쓰는 기본값 |
| `script-src` | 불러오고 실행할 수 있는 스크립트 |
| `connect-src` | 스크립트가 여는 연결: `fetch()`, XHR, WebSocket, EventSource, `sendBeacon()` 등 |
| `media-src` | `<video>`, `<audio>`가 불러오는 주소 |
| `img-src` | 이미지 |

가져오기 지시어가 없으면 `default-src`로 대신합니다. `default-src 'self'` 하나만 있으면 `connect-src`도 `'self'`로 취급됩니다. 그래서 `connect-src`를 따로 적지 않았더라도 KVS 주소는 막힙니다. `'self'`는 페이지와 같은 출처(scheme, 호스트, 포트가 모두 같은 곳)를 뜻합니다.

### KVS 뷰어가 거치는 연결 세 종류

브라우저가 KVS로 영상을 받기까지 하는 HTTP·WebSocket 호출을 순서대로 보면 이렇습니다. 앞 편에서 본 흐름을 "어느 주소로 가나"만 남겨 다시 적었습니다.

1. **제어 API 호출**: `DescribeSignalingChannel`로 채널 정보를 찾고, [`GetSignalingChannelEndpoint`](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/API_GetSignalingChannelEndpoint.html)로 이 채널에 붙을 주소를 받습니다. 리전의 고정 호스트 `https://kinesisvideo.<region>.amazonaws.com`에 HTTPS POST를 보냅니다. 다른 출처로 보내는 요청이라 브라우저는 그 전에 CORS 사전 요청(OPTIONS)도 보냅니다.
2. **ICE 서버 설정 받기**: 1번에서 받은 HTTPS 엔드포인트에 [`GetIceServerConfig`](https://docs.aws.amazon.com/kinesisvideostreams/latest/dg/API_signaling_GetIceServerConfig.html)를 호출합니다. TURN 서버 주소(`Uris`)와 그 서버에 쓸 임시 사용자 이름·비밀번호, 유효 시간(`Ttl`)을 받습니다. 이 호스트는 채널마다 따로 발급되는 `<무엇>.kinesisvideo.<region>.amazonaws.com` 형태입니다.
3. **시그널링 WebSocket**: 1번에서 받은 WSS 엔드포인트에 서명을 붙여 WebSocket으로 붙고, 여기서 SDP와 ICE 후보를 주고받습니다. 이 호스트도 `<무엇>.kinesisvideo.<region>.amazonaws.com` 형태입니다.

세 가지 모두 스크립트가 여는 연결이니 `connect-src` 검사를 받습니다. 헤더에 이 주소들이 없으면 1번에서 바로 막힙니다. 처음 본 위반 메시지가 정확히 그 1번 호스트였습니다.

### 왜 세 줄이어야 하나

그래서 `connect-src`에 세 줄을 더했습니다.

```text
connect-src 'self'
  https://kinesisvideo.<region>.amazonaws.com
  https://*.kinesisvideo.<region>.amazonaws.com
  wss://*.kinesisvideo.<region>.amazonaws.com
```

`https://*.kinesisvideo…` 한 줄로 줄이고 싶어집니다. 하지만 CSP의 주소 맞추기 규칙 때문에 줄일 수 없거나, 줄이면 위험합니다. 세 가지 이유가 있습니다.

1. **와일드카드는 맨 호스트를 포함하지 않습니다.** CSP3의 호스트 맞추기 규칙에서 `*.example.com`은 `a.example.com` 같은 하위 도메인만 맞고, `example.com` 자체는 맞지 않습니다. 맞추는 방식이 "호스트가 `.example.com`으로 끝나는가"이기 때문입니다. 그래서 1번 제어 API 호스트 `kinesisvideo.<region>.amazonaws.com`은 별도 줄이 필요합니다.
2. **`https` 출처는 `wss`를 포함하지 않습니다.** CSP3의 scheme 맞추기에서 `http`는 `https`로, `ws`는 `wss`·`http`·`https`로, `wss`는 `https`로 넓혀 맞춥니다. 반대 방향은 없습니다. `https://*.kinesisvideo…`만 있으면 시그널링 WebSocket(`wss://`)은 막힙니다. 명세대로라면 `wss://*.kinesisvideo…` 한 줄이 `https` 호출까지 덮지만, 브라우저마다 다를 여지가 있습니다. MDN은 `connect-src 'self'`가 모든 브라우저에서 `ws` scheme으로 풀리지는 않는다고 적어 둡니다. 그래서 둘 다 적는 편이 읽기에도 분명합니다.
3. **2·3번 호스트는 실행 중에 정해집니다.** 엔드포인트는 `GetSignalingChannelEndpoint`가 실행할 때 돌려주는 값이라, 채널이나 시점에 따라 달라질 수 있습니다. 개발 중에 본 호스트 이름 하나를 적어 두면 언젠가 깨집니다. 그래서 `*.kinesisvideo.<region>.amazonaws.com`으로 적습니다. 다만 리전까지 고정해, `*.amazonaws.com`처럼 모든 AWS 서비스 호스트를 열지는 않습니다. AWS 호스트에도 공격자가 자기 계정으로 만든 자원이 있을 수 있기 때문입니다.

<figure class="diagram">
{% include figures/webrtc-dtls-srtp-csp/csp-directives.svg %}
<figcaption>KVS 화면에서 connect-src는 제어 API·ICE 설정·시그널링 세 연결을, media-src는 HLS 다시 보기를 검사한다. srcObject 실시간 영상과 STUN·TURN 접속은 그 검사 밖이었다</figcaption>
</figure>

### 헤더 예시

예시 리전 `us-west-2`로 쓴 헤더입니다. 로그인용 Cognito 주소처럼 원래 있던 줄은 줄였습니다. 실제 HTTP 헤더는 한 줄이고, 여기서는 읽기 좋게 줄을 나눴습니다.

```text
Content-Security-Policy:
  default-src 'self';
  script-src 'self';
  connect-src 'self'
    https://kinesisvideo.us-west-2.amazonaws.com
    https://*.kinesisvideo.us-west-2.amazonaws.com
    wss://*.kinesisvideo.us-west-2.amazonaws.com;
  media-src 'self' blob: https://*.kinesisvideo.us-west-2.amazonaws.com;
  object-src 'none';
  base-uri 'self';
  frame-ancestors 'none'
```

`media-src` 줄은 실시간 영상이 아니라 나중에 붙인 다시 보기 기능 때문에 들어갔습니다. 아래에서 따로 설명합니다.

### 막혔을 때와 세 줄을 넣었을 때

배포용과 같은 헤더를 붙인 로컬 시험 서버에서 두 경우를 비교했습니다.

| | A안: `connect-src`에 KVS 없음 | B안: 세 줄 추가 |
|---|---|---|
| 로그인 | 됨 | 됨 |
| 콘솔 | `connect-src` 위반, `https://kinesisvideo.<region>.amazonaws.com` 막힘 | 위반 0건 |
| 카메라 | 네트워크 오류 표시 뒤 재시도 반복 | 영상 재생 |
| 연결까지 | — | 1,254 ms |
| 첫 화면까지 | — | 1,284 ms |
| 받은 비트레이트 | — | 약 228 kbps, jitter 8–13 ms |

A안은 로그인까지는 되기 때문에 "로그인 문제"로 착각하기 쉽습니다. 로그인 서비스 주소는 원래 헤더에 있었고, KVS 주소만 빠져 있었습니다. 화면에는 네트워크 오류만 보이고 재시도가 계속 돌았습니다. 원인은 콘솔의 CSP 위반 메시지에만 있었습니다.

B안 값은 같은 컴퓨터 안의 host 경로에서 잰 것이라 실제 망을 지나는 연결보다 빠릅니다. 이 표는 "세 줄을 넣으니 막힘이 풀리고 정상 속도로 붙었다"는 비교로만 읽어 주세요.

### STUN·TURN 접속은 connect-src 검사를 받지 않았다

`connect-src`를 정리하다 보면 한 가지가 궁금해집니다. ICE는 STUN 서버와 TURN 서버에도 접속합니다. 그것도 `connect-src`에 넣어야 할까요?

MDN의 `connect-src` 문서가 나열하는 대상은 ping, `fetch()`, XHR, WebSocket, EventSource, `sendBeacon()` 같은 것들이고, WebRTC는 목록에 없습니다. 실제로 확인한 결과도 같았습니다. Chromium(ego lite)에서 `connect-src`에 STUN·TURN 주소를 하나도 넣지 않은 채, 브라우저와 장비가 모두 TURN 중계를 쓰는 relay/relay 경로로 영상을 받았습니다. 브라우저에서 TURN까지는 TLS였습니다. 영상은 정상으로 흘렀고 `turn:`·`turns:`·`stun:`에 대한 위반 보고는 0건이었습니다. Firefox와 Safari에서는 시험하지 않았습니다.

명세 쪽 사정도 찾아봤습니다. 2026년 10월 27일자 CSP Level 3 작업 초안에는 `connect-src`와 별도로 **`webrtc`** 지시어가 있습니다. 값은 `'allow'`나 `'block'`이고, ICE 후보 수집과 연결 확인을 허용할지 정합니다. 즉 명세도 WebRTC 접속을 `connect-src`가 아닌 별도 스위치로 다룹니다.

이 지시어가 지금 브라우저에서 동작하는지도 시험했습니다. 앞의 브라우저 두 개 실험 페이지에 `webrtc 'block'`을 더해 띄웠더니, Chromium 156은 콘솔에 `Unrecognized Content-Security-Policy directive 'webrtc'.`를 찍고 연결을 그대로 허용했습니다. 제 환경의 Chromium은 아직 이 지시어를 모르는 것입니다. 정리하면 이렇습니다.

- STUN·TURN 주소를 `connect-src`에 넣을 필요는 없었습니다(Chromium 관찰).
- 거꾸로 CSP로 WebRTC 접속을 막을 수도 아직은 없습니다. 페이지에서 WebRTC를 아예 못 쓰게 하려는 목적이라면 CSP에 기대지 않는 편이 안전합니다.
- 다만 TURN 자격을 받는 `GetIceServerConfig`는 평범한 HTTPS 호출이라 `connect-src` 대상입니다. 앞의 세 줄 중 둘째 줄이 그것입니다.

### media-src: 실시간 영상은 왜 검사 밖인가

`media-src`는 `<video>`, `<audio>`가 불러오는 주소를 제한합니다. 그런데 실시간 영상은 `media-src`에 아무것도 더하지 않아도 재생됐습니다.

이유는 영상을 붙이는 방법에 있습니다. WebRTC로 받은 영상은 `MediaStream` 객체이고, 이것을 `video.srcObject = stream`으로 붙입니다. `srcObject`에는 주소(URL)가 없습니다. CSP는 주소를 보고 허용 여부를 정하는 규칙이라 검사할 대상이 없습니다. 앞의 브라우저 두 개 실험을 `media-src 'self'`인 페이지에서 돌렸을 때도 160×120 캔버스 영상이 `srcObject`로 그대로 재생됐습니다.

같은 페이지에서 `MediaSource`로 만든 `blob:` 주소를 `<video>`의 `src`에 넣자 결과가 달라졌습니다. 콘솔에 `Loading media from 'blob:…' violates … media-src 'self'`가 찍히고, 시험 서버에도 `media-src`, 막힌 주소 `blob` 보고가 들어왔습니다. CSP3 명세대로 `'self'`는 `blob:` 주소를 포함하지 않습니다.

이 차이가 나중에 다시 보기 기능에서 드러났습니다. 녹화한 영상은 HLS로 재생합니다. hls.js는 재생 목록과 영상 조각을 `fetch`로 받고(`connect-src`), MSE(Media Source Extensions)로 `blob:` 주소를 만들어 `<video>`에 넣습니다(`media-src blob:`). MSE가 없는 Safari는 KVS 데이터 엔드포인트의 HLS 주소를 `<video>`에서 바로 엽니다(`media-src https://*.kinesisvideo…`). 그래서 헤더 예시의 `media-src 'self' blob: https://*.kinesisvideo.<region>.amazonaws.com`이 생겼습니다. HLS의 원리는 7편에서 다룹니다.

### 같은 헤더로 로컬에서 시험하기

CSP는 배포한 뒤에야 문제를 알게 되기 쉽습니다. 개발 서버는 보통 헤더를 붙이지 않기 때문입니다. 그래서 배포할 헤더 값을 그대로 붙여 주는 작은 로컬 서버를 두고, 위반 보고도 받게 했습니다. 아래는 이 글을 위해 새로 쓴 최소 예시입니다. 정적 폴더를 헤더와 함께 띄우고, `report-uri`로 들어오는 위반 보고에서 지시어와 막힌 주소의 호스트까지만 출력합니다.

```python
# csp_serve.py: 정적 폴더를 CSP 헤더와 함께 띄우고 위반 보고를 받는다
# 사용: python3 csp_serve.py <폴더> <포트> <헤더 값 파일>
import http.server, json, sys
from urllib.parse import urlsplit

ROOT, PORT, POLICY_FILE = sys.argv[1], int(sys.argv[2]), sys.argv[3]
directives = " ".join(open(POLICY_FILE).read().split()).split(";")
# 로컬은 http라서 https 강제 지시어는 뺀다
POLICY = "; ".join(d.strip() for d in directives
                   if d.strip() and d.strip() != "upgrade-insecure-requests")
POLICY += "; report-uri /__csp"

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def end_headers(self):
        self.send_header("Content-Security-Policy", POLICY)
        super().end_headers()

    def do_POST(self):
        if self.path != "/__csp":
            self.send_error(404)
            return
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        report = json.loads(body or b"{}").get("csp-report", {})
        blocked = report.get("blocked-uri", "")
        host = urlsplit(blocked).hostname or blocked  # 쿼리의 서명 값은 남기지 않는다
        print("CSP", report.get("effective-directive"), host, flush=True)
        self.send_response(204)
        self.end_headers()

http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
```

이 예시는 앞의 브라우저 두 개 실험 페이지를 띄워 돌려 봤습니다. 응답에 헤더가 붙고, `blob:` 위반이 생기자 서버에 `CSP media-src blob` 한 줄이 찍혔습니다(Chromium 156, Python 3.14).

몇 가지를 일부러 정했습니다.

- **헤더 값은 배포 설정에서 읽은 그대로 씁니다.** 시험용 헤더를 따로 손으로 적으면 배포 헤더와 어긋나고, 시험이 아무것도 증명하지 못합니다. 로컬이 http라서 의미가 없는 `upgrade-insecure-requests`만 뺍니다.
- **보고는 지시어와 호스트만 출력합니다.** 막힌 주소가 서명된 WebSocket 주소라면 쿼리 문자열에 서명이 들어 있습니다. 보고를 그대로 로그에 쓰면 접속 권한을 로그에 남기게 됩니다.
- **`report-uri`는 폐지 예정입니다.** [MDN](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Content-Security-Policy)은 `Reporting-Endpoints` 헤더와 `report-to`를 권하면서, 아직 `report-to`를 모르는 브라우저를 위해 `report-uri`도 같이 적으라고 합니다. 로컬 시험에는 `report-uri`로 충분했습니다.

이 서버로 시험하는 내내 위반 보고는 0건이었습니다. 운영 중인 사이트에 새 규칙을 넣을 때는 막지 않고 보고만 받는 [`Content-Security-Policy-Report-Only`](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Content-Security-Policy-Report-Only) 헤더로 먼저 며칠 지켜보는 방법도 있습니다.

### "적용되지 않을 수 있다"의 뜻

처음 에이전트가 지적한 "실제로 적용되지 않을 수 있다"는 이것과 또 다른 문제였습니다. 헤더를 호스팅 서비스의 빌드 설정 파일 안에 적어 두었는데, 그 방식은 폐지 예정이었고 실제 배포된 앱 응답에는 헤더가 하나도 없었습니다. 그래서 헤더를 호스팅 서비스가 정한 사용자 지정 헤더 전용 파일로 옮겼습니다.

이런 일은 설정 파일만 봐서는 알 수 없습니다. 배포한 뒤에는 응답 헤더를 직접 확인합니다. 아래 주소는 예시이고, 이 명령은 실행 미확인입니다.

```sh
curl -sI https://dashboard.example.com/ | grep -i '^content-security-policy'
```

헤더가 안 붙어 있으면 CSP는 없는 것과 같습니다. 붙어 있는데 KVS 주소가 빠져 있으면 카메라가 멈춥니다. 둘 다 확인해야 합니다.

## 로그에 남기지 않는 것

암호화와 CSP를 정리하다 보니, 디버깅하면서 로그에 무엇을 찍는지도 같은 문제라는 것을 알게 됐습니다. 연결이 안 될 때는 SDP와 주소를 통째로 찍고 싶어집니다. 하지만 그 안에는 **그 자체로 권한이거나 내부 정보인 값**이 들어 있습니다.

| 값 | 남기면 안 되는 이유 |
|---|---|
| TURN 사용자 이름·비밀번호 | 유효 시간 동안 누구든 그 TURN 서버로 중계를 쓸 수 있는 자격 |
| 임시 AWS 자격 증명 | 그 역할의 권한 그대로 AWS를 부를 수 있다 |
| 서명된 WSS 주소 | 주소 자체가 접속 권한. 이 구현에서는 5분짜리였지만 그동안은 누구든 그 역할로 채널에 붙을 수 있다 |
| SDP 속 내부 IP | host 후보에 기기의 사설 주소가 그대로 들어 있어 내부 망 구성을 드러낸다 |
| HLS 재생 주소 | 세션 값이 붙은 주소라, 가진 사람은 유효 시간 동안 영상을 볼 수 있다 |

그래서 이렇게 정했습니다.

- 도구가 출력하는 비밀 값은 `***`로 가립니다.
- 오류 메시지에 요청 주소를 넣지 않습니다. 서명된 주소가 오류와 함께 새는 일이 흔합니다.
- ICE 확인 도구는 서버 개수와 종류(`turn:udp`, `turns:tcp` 같은)만 출력합니다.
- 디버그 로그에는 offer의 생김새(어떤 m= 줄이 몇 개, `a=setup` 값 등)만 남깁니다.

앞의 시험 서버가 위반 보고에서 호스트만 출력한 것도 같은 이유입니다.

## 주의할 점

- **상대가 브라우저가 아니면 묶음부터 의심합니다.** DTLS 1.2로 협상하는 라이브러리가 ECDSA 계열만 제시하면 RSA 인증서를 가진 상대와는 붙지 않습니다. `no shared cipher`나 경고 번호 40, 빈 오류가 보이면 서로 제시한 묶음과 인증서 종류를 비교합니다.
- **묶음을 넓혀도 지문 확인은 끄지 않습니다.** 받아들일 인증서 종류를 넓히는 것과 상대를 믿는 기준을 바꾸는 것은 다른 일입니다.
- **영상 보안은 시그널링 보안만큼만 강합니다.** 지문은 시그널링으로 건너가므로, 신호 채널에 누가 붙을 수 있는지(IAM 권한)를 좁히는 것이 곧 영상 보호입니다.
- **`a=setup`으로 DTLS 역할이 바뀝니다.** offer를 누가 보내느냐에 따라 같은 장비가 DTLS 클라이언트가 되기도 합니다. 저장 세션은 offer를 보내는 쪽입니다.
- **`connect-src`는 세 줄을 다 적습니다.** 와일드카드는 맨 호스트를 덮지 않고, `https`는 `wss`를 덮지 않습니다. 호스트는 실행 중에 정해지니 와일드카드로 적되, 리전까지는 고정합니다.
- **`default-src`만 있어도 `connect-src`가 정해진 것입니다.** 따로 적지 않았다고 열려 있는 것이 아닙니다.
- **STUN·TURN은 `connect-src`로 열지도 막지도 못했습니다.** Chromium에서 관찰한 결과이고, 다른 브라우저는 확인하지 않았습니다. `webrtc` 지시어는 명세 초안에 있지만 시험한 Chromium은 인식하지 않았습니다.
- **`srcObject`는 `media-src` 검사 밖, `blob:`은 안입니다.** 실시간 영상만 있을 때 통과했다고 다시 보기(HLS)도 통과하리라 보면 안 됩니다.
- **헤더는 배포된 응답에서 확인합니다.** 설정 파일에 적었다고 붙는 것이 아닙니다. 로컬 시험은 배포 헤더 값을 그대로 읽어 씁니다.
- **위반 보고와 오류 로그에 서명된 주소를 남기지 않습니다.**

## 정리

| 질문 | 답 |
|---|---|
| WebRTC 영상은 암호화되나 | 항상 된다. 평문 RTP는 표준이 금지한다 (RFC 8827) |
| DTLS와 SRTP는 어떻게 나뉘나 | DTLS는 핸드셰이크와 키 추출, 영상은 DTLS 틀 없이 SRTP 패킷 (RFC 5764) |
| 자체 서명 인증서를 무엇으로 믿나 | 시그널링으로 먼저 받은 SDP의 `a=fingerprint`와 인증서 해시를 대조 |
| 그래서 무엇이 중요해지나 | 시그널링 채널. KVS는 TLS(WSS)와 SigV4 서명으로 지킨다 |
| 누가 DTLS 클라이언트인가 | `a=setup`. offer는 `actpass`, answer가 보통 `active`를 골라 클라이언트가 된다 |
| 저장 세션과 왜 안 붙었나 | 장비가 ECDSA 묶음만 제시했고 상대 인증서는 RSA. ECDHE-RSA AEAD 묶음을 더해 해결, 지문 확인은 그대로 |
| CSP는 무엇인가 | 페이지가 불러오고 접속할 수 있는 출처를 브라우저에 알려 주는 응답 헤더. XSS 피해를 줄인다 |
| KVS에 필요한 `connect-src` | 제어 API 호스트, `https://*.kinesisvideo…`, `wss://*.kinesisvideo…` 세 줄 |
| STUN·TURN도 넣어야 하나 | 넣지 않아도 됐다 (Chromium 관찰). TURN 자격을 받는 HTTPS 호출은 `connect-src` 대상 |
| `media-src`는 언제 필요한가 | `srcObject` 실시간 영상은 불필요, HLS 다시 보기는 `'self' blob:`과 KVS 데이터 호스트 |

정리하면 DTLS-SRTP는 "영상이 길 위에서 안전한가"를, CSP는 "이 페이지가 어디로 말을 걸 수 있는가"를 지킵니다. 앞의 것은 시그널링을 믿을 수 있어야 성립하고, 뒤의 것은 헤더가 실제로 붙어 있어야 성립합니다. 이번에 막힌 두 곳도 결국 그 전제가 어긋난 자리였습니다. 하나는 상대가 브라우저라는 가정이 틀렸고, 다른 하나는 헤더가 붙어 있다는 가정이 틀렸습니다.

다음 편에서는 같은 신호 채널에 녹화용 저장 세션을 붙여, 실시간으로 흐르는 영상을 KVS 스트림에 저장하는 과정을 다룹니다.
