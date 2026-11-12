---
title: "MQTT, TCP, UDP 정리: 'TCP가 아니고 MQTT로 보내는 거지?'에서 시작하는 통신 층과 MQTT의 특징"
date: 2026-11-12 18:45:00 +0900
categories: [네트워크, 프로토콜]
tags: [mqtt, tcp, udp, qos, aws-iot-core, websocket, webrtc, quic]
description: "실시간 위치 대시보드를 만들다 나온 질문 'TCP가 아니고 MQTT로 보내는 거지?'에서 출발해, 통신 층으로 MQTT·TCP·UDP의 관계를 정리하고 TCP와 UDP의 원리, MQTT의 토픽·QoS·retained·Last Will·keepalive·세션, AWS IoT Core에서 달라지는 점까지 공식 문서와 로컬 실험으로 짚습니다."
---

실시간 위치 대시보드를 AI 에이전트와 함께 만들고 있었습니다. 장치가 초당 5번 자기 위치를 AWS IoT Core에 MQTT로 보내고, 브라우저는 WebSocket으로 그 토픽을 구독해 지도 위 아이콘을 움직입니다. 카메라 영상은 이와 따로 WebRTC로 흐릅니다. 그런데 아이콘이 매끄럽게 움직이지 않고 잠깐 멈췄다가 앞으로 뚝 뛰는 일이 생겼습니다. 그 모습을 보다가 에이전트에게 이렇게 물었습니다.

> "TCP에서 그런가? 초기에는 UDP로 했어? 초기에는 데이터 끊김이나 렉 걸리는 현상이 없어 보였거든."
>
> "지금은 TCP가 아니고 MQTT로 데이터를 보내는 거지?"

돌아온 답의 요지는 이랬습니다. **MQTT와 TCP는 둘 중 하나를 고르는 관계가 아니라, MQTT가 TCP 위에서 도는 관계다.** 이 대시보드는 처음 만든 날부터 위치를 MQTT over TCP로 보냈고, UDP를 쓴 곳은 카메라의 WebRTC뿐이었습니다. "처음에는 안 끊겼다"는 느낌이 UDP에서 TCP로 바꿨기 때문은 아니라는 뜻입니다. 그 느낌이 어디서 왔는지는 당시 비교해서 잰 기록이 없어서 알 수 없습니다. 그사이 망 환경이 달라졌다는 것이 더 그럴듯한 후보일 뿐입니다.

질문 두 개에 답은 들었지만, 저는 MQTT, TCP, UDP가 각각 무엇을 약속하는지 제대로 설명하지 못했습니다. 이 글은 그것을 다시 짚는 정리입니다. 먼저 통신이 층으로 쌓여 있다는 그림에서 시작해 TCP와 UDP의 원리를 RFC로 보고, 이어서 MQTT의 특징을 OASIS 규격과 AWS IoT Core 문서로 자세히 봅니다. 마지막으로 이 내용이 실제 토픽 설계에 어떻게 쓰였는지, "UDP였으면 안 끊겼을까?"에 대한 정직한 답, 그리고 노트북에서 직접 돌려 본 예시 코드를 정리합니다.

## 이 글에서 따라갈 길

긴 글이라 결론의 뼈대를 먼저 적습니다.

- **층이 다릅니다.** MQTT는 응용 층, TCP와 UDP는 전송 층입니다. 같은 줄에서 고르는 것은 TCP와 UDP이고, MQTT는 그 위에 얹힙니다. MQTT 규격은 아래에 "순서가 지켜지고 잃어버리지 않는 바이트 흐름"을 요구하고, UDP만으로는 맞지 않는다고 적어 둡니다.
- **TCP는** 연결을 맺고, 바이트에 순서 번호를 붙여 빠진 것은 다시 보내고, 순서대로만 앱에 넘깁니다. 대신 메시지 경계가 없고, 앞이 빠지면 뒤가 기다립니다.
- **UDP는** 연결 없이 데이터그램 하나를 그대로 보냅니다. 경계는 지켜지지만 도착·순서·중복 방지를 약속하지 않습니다. 필요한 신뢰성은 위에서 다시 만듭니다(QUIC, WebRTC 데이터 채널).
- **MQTT는** 브로커를 가운데 두고 토픽으로 주고받는 publish/subscribe 프로토콜입니다. QoS 0·1·2, retained 메시지, Last Will, keepalive, 세션이 핵심이고, QoS는 끝에서 끝이 아니라 **구간마다** 따로 정해집니다.
- **AWS IoT Core는** MQTT 3.1.1과 5.0을 받지만 QoS 2가 없고, 와일드카드·retained·순서 같은 곳에서 규격과 다르게 동작하는 부분이 있습니다. UDP 위 MQTT는 받지 않습니다.

## 통신은 층으로 쌓여 있다

### 한 층은 아래 층의 약속 위에 자기 약속을 더한다

네트워크로 무언가를 보낼 때는 여러 프로토콜이 한 겹씩 쌓여서 일을 나눕니다. 위 층은 아래 층이 지켜 주는 약속을 믿고, 그 위에 자기 약속을 하나 더합니다. 이 글에 나오는 이름들을 층으로 나누면 이렇습니다.

| 층 | 예 | 이 층이 약속하는 것 |
|---|---|---|
| 응용 | MQTT, HTTP, WebRTC | 무엇을 누구에게 보내는지: 토픽, 요청·응답, 영상 트랙 |
| 보안 | TLS, DTLS | 상대가 맞는지 확인하고, 중간에서 읽거나 바꾸지 못하게 |
| 전송 | TCP, UDP (QUIC는 UDP 위) | 컴퓨터 안의 어느 프로그램(포트)까지, 어떤 방식으로 |
| 네트워크 | IP | 어느 컴퓨터까지, 여러 망을 건너서 |
| 링크 | Wi-Fi, LTE, 이더넷 | 바로 옆 장비까지, 전파나 선 위에서 |

택배에 비유하면 MQTT는 "어느 주소(토픽)로 어떤 상자(메시지)를 보내는지"를 적는 송장 규칙이고, TCP는 상자를 빠짐없이 순서대로 실어 나르는 트럭입니다. TLS는 상자를 잠그는 자물쇠, IP는 도시와 도시를 잇는 도로망, Wi-Fi는 집 앞 골목길쯤 됩니다. 송장 규칙과 트럭은 서로 대신할 수 없습니다. 둘 다 있어야 상자가 갑니다.

실제로 보내는 바이트도 이렇게 겹겹이 싸입니다. 장치가 위치 하나를 발행하면 MQTT PUBLISH 패킷이 만들어지고, 그 패킷이 TLS 레코드 안에 암호화되어 들어가고, 그 레코드가 TCP 세그먼트에 실리고, 세그먼트가 IP 패킷에, IP 패킷이 Wi-Fi 프레임에 실려 나갑니다. 받는 쪽은 바깥부터 한 겹씩 벗겨 MQTT까지 올라갑니다.

<figure class="diagram">
{% include figures/mqtt-tcp-udp/layers.svg %}
<figcaption>위치·상태는 MQTT / TLS / TCP 위로, 카메라 영상은 WebRTC(SRTP) / DTLS / UDP 위로 흐른다. 같은 줄에서 고르는 것은 전송 층의 TCP와 UDP이고, MQTT는 TCP 위에 얹힌다</figcaption>
</figure>

### 그래서 "TCP가 아니고 MQTT"는 질문이 성립하지 않는다

이 그림으로 돌아가면 처음 질문이 풀립니다. 위치 데이터는 "MQTT로" 가고, 동시에 "TCP로" 갑니다. 장치는 TCP 8883번 포트로 TLS를 맺고 그 위에서 MQTT를 말합니다. 브라우저는 TCP 443번 포트로 TLS를 맺고, 그 위에 WebSocket을, 다시 그 위에 MQTT를 얹습니다. 어느 쪽이든 아래에는 TCP가 있습니다.

고를 수 있는 것은 **같은 층 안에서**입니다. 전송 층에서는 TCP와 UDP 중 하나를, 응용 층에서는 MQTT, HTTP, WebRTC 중 하나를 고릅니다. 그리고 위 층을 고르면 아래 층이 따라오는 경우가 많습니다. MQTT를 고르면 TCP(또는 TCP 위의 WebSocket)가, WebRTC 영상을 고르면 UDP가 따라옵니다.

## TCP: 늦어도 빠짐없이, 순서대로

TCP의 현재 규격은 RFC 9293입니다. 2.2절은 TCP를 "신뢰할 수 있고(reliable), 순서가 지켜지는(in-order), 바이트 흐름(byte-stream) 서비스"라고 정의합니다. 이 세 단어가 TCP의 장점과 약점을 거의 다 설명합니다.

### 먼저 연결을 맺는다: 3-way handshake

TCP는 데이터를 보내기 전에 연결부터 맺습니다(connection-oriented). RFC 9293 3.5절의 3-way handshake는 이렇게 흐릅니다.

1. 클라이언트 → 서버: `SYN` (내 순서 번호는 여기서 시작한다)
2. 서버 → 클라이언트: `SYN, ACK` (네 번호 받았고, 내 번호는 여기서 시작한다)
3. 클라이언트 → 서버: `ACK` (네 번호도 받았다)

세 번을 주고받는 이유를 RFC는 "옛날에 보냈다가 늦게 도착한 중복 연결 요청이 새 연결로 오해받는 것을 막기 위해서"라고 설명합니다. 양쪽이 서로의 시작 번호를 확인해야 지금 연결이 진짜인지 알 수 있습니다.

이 대시보드에서는 연결 하나를 여는 데 왕복이 여러 번 듭니다. TCP 3-way handshake, 그 위에서 TLS handshake, 브라우저라면 WebSocket 업그레이드, 마지막으로 MQTT `CONNECT`와 `CONNACK`까지 지나야 첫 메시지를 보낼 수 있습니다. 연결이 자주 끊기는 망에서 다시 붙는 시간이 길게 느껴지는 이유입니다.

### 바이트 흐름: 메시지 경계가 없다

TCP가 약속하는 것은 "메시지"가 아니라 "바이트의 흐름"입니다. RFC 9293 3.7절은 세그먼트가 "앱의 send 호출과 하나씩 대응하지 않는 경우가 많다"고 하고, "TCP는 보낸 쪽과 받는 쪽의 경계 사이에 아무 대응도 보장하지 않는다"고 적습니다.

그래서 앱이 `send()`를 두 번 불러 메시지 두 개를 보내도, 받는 쪽의 `recv()` 한 번에 둘이 붙어서 올 수 있습니다. 반대로 메시지 하나가 둘로 쪼개져 올 수도 있습니다. 아래 [직접 해 보기](#직접-해-보기)에서 send 두 번이 recv 한 번에 붙어 오는 것을 실제로 확인합니다.

이 성질 때문에 TCP 위의 프로토콜은 **메시지를 어디서 자를지 스스로 정해야 합니다.** HTTP/1.1은 헤더의 `Content-Length`를 쓰고, MQTT는 모든 패킷 앞에 "이 뒤로 몇 바이트가 이 패킷이다"라는 길이(Remaining Length)를 붙입니다. MQTT 패킷 모양은 뒤에서 다시 봅니다.

### 순서 번호, ACK, 재전송

TCP가 "신뢰할 수 있는" 이유는 세 가지 장치 덕분입니다(RFC 9293 2.2절).

- **순서 번호(sequence number).** 연결로 보내는 모든 바이트에 번호가 붙습니다. 받는 쪽은 이 번호로 순서를 다시 맞추고 중복을 걸러 냅니다.
- **체크섬(checksum).** 헤더와 데이터가 오는 길에 깨졌는지 확인합니다. 깨진 세그먼트는 버립니다.
- **ACK와 재전송.** 받는 쪽은 "여기까지 다 받았다"는 ACK를 돌려보내고, 보내는 쪽은 ACK가 오지 않은 부분을 다시 보냅니다.

TCP 헤더는 옵션이 없으면 20바이트입니다. 순서 번호, ACK 번호, 창 크기, 체크섬 같은 칸이 여기 들어갑니다. 이 칸들이 TCP가 하는 일의 목록이기도 합니다.

### 흐름 제어와 혼잡 제어

TCP는 받는 쪽과 망이 감당할 수 있는 만큼만 보냅니다.

- **흐름 제어.** 받는 쪽은 ACK에 "지금 이만큼 더 받을 수 있다"는 창(window)을 실어 보냅니다. RFC 9293 3.8.6절은 이 창을 받는 쪽 버퍼 여유와 연결된, 받는 쪽이 받아들일 범위라고 설명합니다. 받는 앱이 느리게 읽으면 창이 줄고, 보내는 쪽은 그만큼 기다립니다.
- **혼잡 제어.** 받는 쪽이 아니라 **망**이 막히지 않게 하는 장치입니다. RFC 9293 3.8.2절은 TCP 구현이 혼잡 제어를 반드시(MUST) 갖춰야 한다고 정합니다. 손실을 망이 붐빈다는 신호로 보고 보내는 속도를 줄입니다.

여기서 앱 개발자가 놓치기 쉬운 점이 하나 있습니다. 앱이 `send()`를 불러 함수가 돌아왔다는 것은 보통 **운영체제의 송신 버퍼에 데이터를 넘겼다**는 뜻이지, 상대가 받았다는 뜻이 아닙니다. 망이 느려져 창이 줄면 데이터는 송신 버퍼에 쌓이고, 앱은 계속 "보냈다"고 생각합니다. 이 점은 뒤의 MQTT QoS 이야기와 이어집니다.

### 앞이 빠지면 뒤가 기다린다: head-of-line blocking

"순서가 지켜지는 바이트 흐름"이라는 약속에는 대가가 있습니다. 1, 2, 3, 4, 5번 세그먼트 중 3번만 사라지면, 받는 쪽 운영체제는 4번과 5번을 이미 들고 있어도 앱에 넘기지 못합니다. 넘기는 순간 3번 자리가 빈 흐름이 되어 약속이 깨지기 때문입니다. 3번이 다시 와서 빈칸이 채워져야 3·4·5번을 한꺼번에 넘깁니다. 맨 앞의 빈칸 하나가 줄 전체를 막는다고 해서 **head-of-line blocking**이라고 부릅니다.

위치처럼 "가장 최근 값만 의미 있는" 데이터에는 이것이 곧 "멈췄다가 뛰는" 화면이 됩니다. 데이터는 사라지지 않고 **늦을 뿐**이지만, 화면에는 늦은 데이터가 몰려와서 아이콘이 한 번에 여러 칸을 건너뜁니다. 빠진 세그먼트를 언제 다시 보내는지(중복 ACK, 재전송 타이머, RACK-TLP)와 Wi-Fi 손실이 어떻게 이 현상으로 이어지는지는 [Wi-Fi 2.4 GHz와 5 GHz 글]({% post_url 2026-11-11-wifi-2-4ghz-5ghz-packet-loss %})에서 그림과 함께 자세히 다뤘습니다. 이 글에서는 반복하지 않겠습니다.

### TCP는 상대가 살아 있는지 모른다

TCP에 대해 의외인 사실이 하나 더 있습니다. RFC 9293 2.2절은 TCP가 연결 지향이지만 "그 자체로 상대가 살아 있는지 알아내는 기능(liveness detection)을 갖고 있지 않다"고 적습니다. 상대 장치의 전원이 갑자기 나가면, 이쪽에서 아무것도 보내지 않는 한 연결은 한참 동안 "열려 있는" 것처럼 보일 수 있습니다.

그래서 TCP 위의 프로토콜들은 따로 생존 확인을 둡니다. MQTT의 keepalive와 PINGREQ/PINGRESP가 바로 그것이고, 장치가 갑자기 사라졌을 때 대신 "오프라인"을 알려 주는 Last Will도 이 생존 확인 위에서 동작합니다. 둘 다 뒤의 MQTT 절에서 봅니다.

## UDP: 보낸 그대로, 대신 아무것도 약속하지 않는다

### RFC 768: 최소한의 장치

UDP 규격 RFC 768은 세 쪽짜리 짧은 문서입니다. 이 문서는 UDP가 "최소한의 프로토콜 장치(a minimum of protocol mechanism)"로 앱이 다른 프로그램에 메시지를 보내게 해 준다고 소개하고, 바로 이어서 이렇게 적습니다.

> 이 프로토콜은 트랜잭션 중심이며, 전달과 중복 방지를 보장하지 않습니다. 순서가 지켜지는 신뢰할 수 있는 전달이 필요한 앱은 TCP를 써야 합니다.

UDP 헤더는 8바이트입니다. 칸은 네 개뿐입니다.

| 칸 | 크기 | 뜻 |
|---|---|---|
| Source Port | 2바이트 | 보내는 프로그램의 포트(선택) |
| Destination Port | 2바이트 | 받는 프로그램의 포트 |
| Length | 2바이트 | 헤더와 데이터를 합친 길이(최소 8) |
| Checksum | 2바이트 | 깨졌는지 확인(IPv4에서는 0이면 "체크섬 안 씀") |

TCP 헤더에 있던 순서 번호, ACK 번호, 창 크기가 하나도 없습니다. UDP가 하지 않는 일의 목록이 곧 이 빠진 칸들입니다.

### 연결이 없고, 경계가 지켜진다

UDP에는 연결을 맺거나 끊는 과정이 없습니다. RFC 8085(UDP 사용 지침)는 UDP를 "혼잡 제어가 없는 최소한의 메시지 전달 전송"이라고 부르고, 연결을 맺거나 끊는 절차가 없다고 정리합니다. 보내는 쪽은 주소와 포트만 알면 바로 `sendto()`를 부릅니다. 받는 쪽이 있는지도 확인하지 않습니다. 아래 예시에서 아무도 듣지 않는 포트로 보내도 `sendto()`가 그냥 성공하는 것을 볼 수 있습니다.

대신 UDP는 **보낸 단위(데이터그램)를 그대로** 전합니다. 한 번 `sendto()`한 것은 받는 쪽에서 `recvfrom()` 한 번으로 통째로 나옵니다. 둘이 붙거나 반으로 쪼개져 나오지 않습니다. TCP처럼 길이를 따로 붙여 자를 필요가 없습니다. 그 대신 데이터그램 하나가 통째로 사라지거나, 순서가 바뀌거나, 두 번 올 수 있습니다.

### 속도 조절은 앱의 몫

UDP에는 흐름 제어도 혼잡 제어도 없습니다. 그렇다고 마음대로 보내도 된다는 뜻은 아닙니다. RFC 8085는 UDP를 쓰는 앱이 보내는 속도를 스스로 조절해야 한다고(SHOULD) 하고, 데이터그램이 경로의 최대 크기(PMTU)를 넘어 IP 단편화가 생기지 않게 하라고 권합니다. TCP가 해 주던 일을 앱이나 그 위 프로토콜이 맡아야 한다는 뜻입니다.

### UDP를 쓰는 곳

"아무것도 약속하지 않는다"는 것이 오히려 장점인 곳이 있습니다.

- **짧은 질문과 답.** DNS는 UDP 53번 포트를 쓰고, RFC 1035 4.2.1절은 UDP로 실어 보내는 메시지를 512바이트로 제한합니다. 질문 하나에 답 하나라면 연결을 맺는 왕복이 더 아깝습니다. 답이 안 오면 앱이 다시 물으면 됩니다.
- **실시간 음성·영상.** 늦게 도착한 영상 프레임은 이미 지나간 장면이라 쓸모가 적습니다. WebRTC 영상은 SRTP로 UDP 위를 흐르고, 손실은 영상 코덱과 WebRTC 쪽에서 감당합니다. 카메라 영상이 어떤 길로 흐르는지는 [KVS 큰 그림 글]({% post_url 2026-11-10-kvs-webrtc-big-picture %})에 정리했습니다.
- **UDP 위에 신뢰성을 다시 만드는 프로토콜.** RFC 9000의 제목은 "QUIC: UDP 기반의 다중화되고 안전한 전송"입니다. QUIC는 UDP 위에서 흐름 제어가 있는 스트림, 빠른 연결 수립, 경로 이동(예: Wi-Fi에서 LTE로)을 제공합니다. HTTP/3(RFC 9114)가 이 QUIC 위에서 돕니다. 스트림이 여러 개라서 한 스트림의 손실이 다른 스트림을 막지 않는다는 점이 TCP와 다릅니다.

### 신뢰성을 골라 쓰는 길: WebRTC 데이터 채널

WebRTC에는 영상 말고 임의의 데이터를 보내는 **데이터 채널**도 있습니다. RFC 8831에 따르면 데이터 채널은 SCTP를 DTLS로 감싸 ICE/UDP 위로 보내고, 영상의 SRTP와 나란히 흐릅니다. 이 채널은 메시지마다 순서를 지킬지(ordered/unordered), 끝까지 다시 보낼지 일부만 다시 보낼지(full/partial reliability)를 고를 수 있습니다. RFC 8831 6.1절은 "재전송 횟수를 0으로 제한하고 순서 없는 전달을 함께 쓰면 UDP와 비슷한 서비스가 된다"고 적습니다.

브라우저 API에서는 W3C WebRTC 규격의 `RTCDataChannelInit`로 이 선택을 합니다.

| 옵션 | 기본값 | 뜻 |
|---|---|---|
| `ordered` | `true` | `false`면 순서를 맞추지 않고 도착한 대로 넘긴다 |
| `maxRetransmits` | 없음 | 다시 보내는 최대 횟수. `0`이면 다시 보내지 않는다 |
| `maxPacketLifeTime` | 없음 | 이 시간(ms)이 지나면 더는 다시 보내지 않는다 |

`maxRetransmits`와 `maxPacketLifeTime`은 함께 쓸 수 없고(오류), 둘 다 지정하지 않으면 끝까지 다시 보내는 신뢰 채널이 됩니다. 뒤의 "UDP였으면?" 절에서 이 옵션이 다시 나옵니다.

## TCP와 UDP 비교, 그리고 고르는 기준

| | TCP | UDP |
|---|---|---|
| 연결 | 3-way handshake로 맺는다 | 없음, 바로 보낸다 |
| 단위 | 바이트 흐름(경계 없음) | 데이터그램(경계 보존) |
| 손실 | 다시 보낸다 | 다시 보내지 않는다 |
| 순서 | 맞춰서 넘긴다 | 도착한 대로 |
| 중복 | 걸러 낸다 | 걸러 내지 않는다 |
| 흐름·혼잡 제어 | 있다 | 없다(앱이 조절) |
| 헤더 | 옵션 없이 20바이트 | 8바이트 |
| 손실 하나의 영향 | 뒤 데이터가 기다린다 | 그 데이터그램만 빠진다 |
| 대표 사용처 | HTTP/1.1·HTTP/2, TLS, MQTT | DNS, RTP/SRTP(WebRTC 영상), QUIC |

어느 쪽이 "더 좋다"는 없습니다. 데이터에 이렇게 물어보면 대개 답이 나옵니다.

- **늦게라도 다 와야 하나?** 명령, 설정, 파일, 결제, 상태 변화처럼 하나라도 빠지면 곤란한 데이터라면 TCP 쪽입니다.
- **늦을 바엔 버려도 되나?** 영상 프레임, 음성, 초당 여러 번 갱신되는 위치처럼 새 값이 곧 옛 값을 덮는 데이터라면 UDP 쪽이 어울립니다.
- **둘 다 섞여 있다면?** 이 대시보드처럼 흐름을 나눠서 각각 맞는 길로 보냅니다. 또는 QUIC나 WebRTC 데이터 채널처럼 UDP 위에서 메시지마다 신뢰성을 골라 쓰는 프로토콜을 씁니다.

현실에서는 이 기준만으로 정하지 못할 때가 많습니다. 쓰려는 서비스가 무엇을 받아 주는지, 방화벽이 무엇을 통과시키는지, 브라우저가 무엇을 지원하는지가 먼저 정해 버리기도 합니다. 이 대시보드가 위치를 TCP 위로 보낸 것도 "위치는 TCP가 맞아서"라기보다 "AWS IoT Core가 MQTT를 받고, MQTT는 TCP 위에서 돌기 때문"이었습니다.

## MQTT의 특징

이제 이 글의 중심인 MQTT입니다. MQTT는 OASIS가 표준으로 정한 프로토콜이고, 지금 널리 쓰는 판은 3.1.1과 5.0입니다. 아래 설명은 주로 3.1.1을 기준으로 하고, 5.0에서 달라진 점과 AWS IoT Core에서 달라지는 점은 따로 모았습니다.

### 한 문장으로: 브로커를 가운데 둔 publish/subscribe

MQTT 3.1.1 규격은 첫머리에서 MQTT를 "가볍고 열려 있고 단순하며 구현하기 쉽게 설계된 클라이언트·서버 publish/subscribe 메시지 전송 프로토콜"이라고 소개합니다. 같은 자리에 적힌 특징을 옮기면 이렇습니다.

- publish/subscribe 방식으로 **한 곳에서 여러 곳으로** 메시지를 나눠 주고, 앱끼리 서로를 몰라도 되게 한다.
- 메시지 내용(payload)이 무엇인지 상관하지 않는다.
- 세 가지 QoS로 메시지를 전달한다.
- 전송 오버헤드와 주고받는 프로토콜 메시지가 작다.
- 비정상적으로 끊긴 것을 관심 있는 쪽에 알리는 장치가 있다.

**publish/subscribe**가 무엇인지부터 봅시다. HTTP처럼 "장치가 대시보드에 직접 보내는" 방식이 아닙니다. 장치는 `devices/dev1/position`이라는 **토픽**에 메시지를 **발행(publish)**만 하고, 대시보드는 그 토픽을 **구독(subscribe)**만 합니다. 가운데의 **브로커**(규격 용어로는 Server)가 발행된 메시지를 받아 그 토픽을 구독한 모든 클라이언트에게 나눠 줍니다.

이 구조 덕분에 장치와 대시보드는 서로의 주소를 모릅니다. 대시보드를 두 개 띄워도 장치 코드는 그대로이고, 장치가 잠깐 꺼져 있어도 대시보드는 브로커와 연결을 유지합니다. 장치도 대시보드도 브로커 쪽으로만 연결을 열기 때문에, 장치가 공유기나 이동통신망 뒤에 있어도 문제가 되지 않습니다. 규격이 말하는 "앱끼리 서로를 몰라도 되게 한다(decoupling)"가 바로 이것입니다.

### MQTT는 왜 TCP를 요구하나

MQTT 3.1.1 4.2절은 MQTT가 쓸 네트워크를 이렇게 정합니다.

> MQTT 프로토콜은 클라이언트에서 서버로, 서버에서 클라이언트로 순서가 지켜지고(ordered) 잃어버리지 않는(lossless) 바이트 흐름을 제공하는 하위 전송 위에서 동작해야 합니다.

같은 절은 TCP/IP, TLS, WebSocket을 알맞은 전송으로 들고, 이어서 이렇게 적습니다.

> UDP 같은 비연결형 네트워크 전송은 데이터를 잃어버리거나 순서를 바꿀 수 있으므로 그 자체만으로는 알맞지 않습니다.

MQTT 5.0의 4.2절도 같은 내용입니다. MQTT는 아래 층이 순서와 전달을 지켜 준다고 **믿고** 설계되었습니다. 예를 들어 MQTT 패킷에는 순서 번호가 없습니다. 아래 TCP가 순서를 지켜 주니 필요 없기 때문입니다. UDP 위에 MQTT를 그대로 얹으면 이 믿음이 깨집니다.

그렇다고 MQTT가 TCP에만 묶여 있지는 않습니다. 규격이 요구하는 것은 "순서가 지켜지고 잃어버리지 않는 양방향 바이트 흐름"이고, 그 조건을 채우는 TLS나 WebSocket 위에서도 돕니다. 대시보드의 장치는 TLS 위에서, 브라우저는 WebSocket 위에서 MQTT를 씁니다. 두 길 모두 맨 아래는 TCP입니다.

### 패킷 생김새: 작은 고정 헤더와 길이

MQTT의 모든 제어 패킷은 같은 틀을 씁니다(3.1.1 2절).

1. **고정 헤더(fixed header).** 모든 패킷에 있고, 최소 2바이트입니다.
   - 첫 바이트의 위 4비트는 패킷 종류(CONNECT, PUBLISH, …), 아래 4비트는 종류별 플래그(PUBLISH라면 DUP, QoS, RETAIN)입니다.
   - 그다음은 **Remaining Length**, 즉 "이 뒤로 몇 바이트가 이 패킷인지"입니다. 1~4바이트를 쓰는 가변 길이 정수라서 최대 268,435,455바이트(약 256 MB)까지 나타낼 수 있습니다.
2. **가변 헤더(variable header).** 일부 패킷에만 있습니다. PUBLISH의 토픽 이름과 Packet Identifier 같은 것이 여기 들어갑니다.
3. **payload.** 일부 패킷에만 있습니다. PUBLISH라면 실제 메시지 내용입니다.

앞의 TCP 절에서 "TCP 위 프로토콜은 메시지를 어디서 자를지 스스로 정해야 한다"고 했습니다. MQTT에서는 Remaining Length가 그 일을 합니다. 받는 쪽은 첫 바이트로 종류를 보고, Remaining Length만큼 바이트가 모일 때까지 기다렸다가 패킷 하나를 꺼냅니다.

헤더가 얼마나 작은지는 예시에서 직접 보낸 바이트로 확인할 수 있습니다. 연결 수락(CONNACK)은 `20 02 00 00` 4바이트, 생존 확인 요청(PINGREQ)은 `C0 00` 2바이트, 그 응답(PINGRESP)은 `D0 00` 2바이트입니다. 규격이 "전송 오버헤드가 작다"고 말하는 근거입니다.

MQTT 3.1.1의 제어 패킷은 14가지입니다.

| 패킷 | 방향 | 하는 일 |
|---|---|---|
| `CONNECT` / `CONNACK` | 클라이언트 → 서버 / 반대 | 연결 요청과 수락 |
| `PUBLISH` | 양쪽 | 메시지 발행·전달 |
| `PUBACK` | 양쪽 | QoS 1 확인 |
| `PUBREC` / `PUBREL` / `PUBCOMP` | 양쪽 | QoS 2의 네 단계 중 2~4단계 |
| `SUBSCRIBE` / `SUBACK` | 클라이언트 → 서버 / 반대 | 구독 요청과 수락(허락된 QoS) |
| `UNSUBSCRIBE` / `UNSUBACK` | 클라이언트 → 서버 / 반대 | 구독 취소 |
| `PINGREQ` / `PINGRESP` | 클라이언트 → 서버 / 반대 | 생존 확인 |
| `DISCONNECT` | 클라이언트 → 서버 | 정상 종료 인사 |

MQTT 5.0에는 인증을 주고받는 `AUTH`가 더해지고, 서버도 `DISCONNECT`를 보낼 수 있게 됩니다.

### 연결: CONNECT와 CONNACK

TCP(와 TLS) 연결이 열리면 클라이언트는 맨 먼저 `CONNECT`를 보냅니다. 여기에 이 연결의 성격이 거의 다 들어갑니다.

- **Client Identifier.** 브로커가 이 클라이언트를 알아보는 이름입니다. 세션도 이 이름에 묶입니다.
- **Clean Session 플래그**(5.0에서는 Clean Start). 지난 세션을 이어 쓸지 버릴지.
- **Keep Alive.** 몇 초마다 생존을 알릴지.
- **Will.** 비정상으로 끊기면 브로커가 대신 발행할 메시지(토픽, 내용, QoS, retain).
- **사용자 이름·비밀번호**(선택).

브로커는 `CONNACK`으로 수락하거나 거절합니다. 실무에서 중요한 규칙이 하나 있습니다. **CONNACK을 받기 전에는 다른 패킷을 보내지 않는 편이 안전합니다.** MQTT 3.1.1 규격(3.1.4절)은 클라이언트가 CONNECT 직후 CONNACK을 기다리지 않고 다른 패킷을 보내도 된다고 적지만, AWS IoT Core 문서는 규격과의 차이로 "클라이언트는 다른 제어 패킷이나 연결 종료 요청을 보내기 전에 CONNACK을 기다려야 한다"고 적어 둡니다. 실제로 이 대시보드를 만들 때, 연결 직후 다른 스레드의 PUBLISH가 CONNECT 바로 뒤에 붙어 나가면 AWS IoT Core가 응답 없이 연결을 닫는 일을 여러 번 겪었습니다. 클라이언트 쪽에는 "원인 모를 끊김"으로만 보여서 찾기 어려웠습니다. 그 뒤로는 연결 콜백(`on_connect`) 안이나 연결 상태가 참일 때만 발행합니다.

### 토픽과 와일드카드

토픽은 `/`로 단계(level)를 나눈 문자열입니다. 브로커가 미리 만들어 둘 필요 없이, 발행하는 순간 그 이름의 토픽이 생깁니다. 구독할 때는 **토픽 필터**를 쓰고, 여기에 와일드카드 두 가지를 쓸 수 있습니다(3.1.1 4.7절).

- **`+`** 는 한 단계를 대신합니다.
- **`#`** 는 그 아래 여러 단계를 대신하고, 필터의 맨 끝에만 올 수 있습니다. 규격상 **부모 단계도 포함**합니다.

| 필터 | `devices/dev1/position` | `devices/dev2/status` | `devices/dev1` | `devices` |
|---|---|---|---|---|
| `devices/dev1/position` | ✓ | ✗ | ✗ | ✗ |
| `devices/+/position` | ✓ | ✗ | ✗ | ✗ |
| `devices/+/+` | ✓ | ✓ | ✗ | ✗ |
| `devices/+` | ✗ | ✗ | ✓ | ✗ |
| `devices/#` | ✓ | ✓ | ✓ | ✓ (규격) |

마지막 줄의 `devices/#`가 `devices` 자체에도 맞는 것이 규격의 동작입니다(3.1.1 규격의 예: `sport/#`는 `sport`에도 맞음). 반대로 `+`는 빈 단계 하나에도 맞기 때문에 `sport/+`는 `sport`에는 맞지 않지만 `sport/`에는 맞습니다. 그리고 와일드카드로 **시작하는** 필터(`#`, `+/…`)는 `$`로 시작하는 토픽(`$SYS/…`처럼 브로커가 쓰는 토픽)에 맞지 않습니다.

토픽 설계에서 자주 쓰는 습관은 "큰 범주에서 작은 범주로" 이름을 짓는 것입니다. `devices/{장치 ID}/{종류}`로 지으면 장치 하나의 모든 것(`devices/dev1/#`)이나 모든 장치의 위치(`devices/+/position`)를 필터 하나로 받을 수 있습니다.

### QoS 0, 1, 2

QoS(Quality of Service)는 "메시지 하나를 얼마나 확실하게 전달할지"를 정하는 약속입니다. 3.1.1 4.3절은 세 단계를 정합니다.

**QoS 0: 많아야 한 번(at most once).** 보내는 쪽은 PUBLISH를 한 번 보내고 끝입니다. 받는 쪽은 응답하지 않고, 보내는 쪽은 다시 보내지 않습니다. 규격은 "메시지는 한 번 도착하거나 아예 도착하지 않는다"고 하고, 쓰임새로 "다음 측정값이 곧 나올 주변 센서 데이터"를 예로 듭니다. 초당 5번 오는 위치가 딱 이 경우입니다.

여기서 흔히 하는 오해가 있습니다. **QoS 0이 "UDP처럼 버려도 되는 전송"은 아닙니다.** MQTT 층에서 확인과 재전송을 하지 않는다는 뜻일 뿐, 아래 TCP는 연결이 살아 있는 동안 QoS 0 메시지도 순서대로 빠짐없이 전하려고 애씁니다. QoS 0 메시지가 사라지는 것은 주로 연결이 끊길 때입니다. 송신 버퍼에 있던 것, 전송 중이던 것, 브로커가 아직 나눠 주지 못한 것은 확인할 방법 없이 사라질 수 있습니다.

**QoS 1: 적어도 한 번(at least once).** 보내는 쪽은 PUBLISH에 **Packet Identifier**(1~65535의 번호)를 붙여 보내고, 받는 쪽은 같은 번호로 **PUBACK**을 돌려보냅니다. 보내는 쪽은 PUBACK을 받을 때까지 그 메시지를 "확인되지 않음"으로 들고 있다가, 필요하면 다시 보냅니다. 다시 보낼 때는 DUP 플래그를 켭니다. 메시지는 반드시 도착하지만, PUBACK이 오는 길에 사라지면 보내는 쪽이 다시 보내므로 **두 번 이상 도착할 수 있습니다.** 규격은 받는 쪽이 PUBACK을 보낸 뒤 같은 번호로 다시 온 PUBLISH를 DUP 플래그와 상관없이 **새 메시지로** 다뤄야 한다고 정합니다. 중복을 걸러 주지 않는다는 뜻입니다.

**QoS 2: 정확히 한 번(exactly once).** 네 단계로 주고받습니다.

1. 보내는 쪽 → `PUBLISH` (번호 붙임)
2. 받는 쪽 → `PUBREC` (받았다, 이 번호는 기억해 둔다)
3. 보내는 쪽 → `PUBREL` (이제 그 번호를 놓아도 된다)
4. 받는 쪽 → `PUBCOMP` (끝)

받는 쪽이 2단계부터 4단계까지 번호를 기억하고 있기 때문에, 그사이 같은 번호의 PUBLISH가 다시 와도 두 번 넘기지 않습니다. 규격은 쓰임새로 "중복이나 손실이 받아들여지지 않는 과금 시스템"을 듭니다. 대가는 왕복이 두 번이라는 것과 양쪽이 상태를 더 오래 들고 있어야 한다는 것입니다.

| QoS | 이름 | 주고받는 패킷 | 손실 | 중복 |
|---|---|---|---|---|
| 0 | at most once | PUBLISH | 있을 수 있음 | 없음 |
| 1 | at least once | PUBLISH → PUBACK | 없음(세션이 이어지는 한) | 있을 수 있음 |
| 2 | exactly once | PUBLISH → PUBREC → PUBREL → PUBCOMP | 없음 | 없음 |

### QoS는 끝에서 끝이 아니라 구간마다

QoS에서 가장 헷갈리는 점은 **누구와 누구 사이의 약속인가**입니다. 3.1.1 4.3절은 이렇게 적습니다.

> 전달 프로토콜은 한 보내는 쪽에서 한 받는 쪽으로 애플리케이션 메시지를 전달하는 일만 다룹니다. 서버가 여러 클라이언트에게 메시지를 전달할 때는 각 클라이언트를 독립적으로 다룹니다. 밖으로 나가는 전달에 쓰는 QoS는 들어올 때의 QoS와 다를 수 있습니다.

메시지는 "장치 → 브로커"와 "브로커 → 대시보드"라는 **두 구간**을 따로 지납니다. 장치가 QoS 1로 발행해 받은 PUBACK은 **브로커**가 받았다는 뜻이지, 대시보드가 받았다는 뜻이 아닙니다. 그리고 브로커가 대시보드로 보낼 때 쓰는 QoS는 발행 QoS와 구독할 때 허락된 QoS 중 **낮은 쪽**입니다(3.1.1 3.8.4절). 장치가 QoS 1로 보내도 대시보드가 QoS 0으로 구독했다면 두 번째 구간은 QoS 0입니다.

<figure class="diagram">
{% include figures/mqtt-tcp-udp/qos-per-hop.svg %}
<figcaption>장치가 받은 PUBACK은 첫 구간(장치 → 브로커)의 확인이다. 브로커는 구독 QoS와 비교해 낮은 쪽으로 다시 보내므로, 대시보드가 QoS 0으로 구독했다면 두 번째 구간에는 확인이 없다</figcaption>
</figure>

그래서 "대시보드가 이 명령을 정말 받아서 처리했는지"를 알고 싶다면 QoS만으로는 부족합니다. 받는 쪽이 처리한 뒤 **응답 메시지**를 따로 발행해야 합니다. 이 대시보드에서 명령마다 `cmd_id`를 붙이고, 장치가 같은 `cmd_id`로 결과를 따로 발행하게 한 이유입니다.

### TCP가 이미 보장하는데 QoS 1은 왜 있나

TCP가 빠짐없이 순서대로 전한다면 MQTT가 PUBACK을 또 주고받는 것은 낭비처럼 보입니다. 답은 **TCP의 보장은 연결 하나 안에서만 유효하다**는 데 있습니다.

TCP 연결이 끊기는 순간을 생각해 봅시다. 앱이 `send()`로 넘긴 바이트 중 일부는 아직 송신 버퍼에 있었고, 일부는 망 위에 있었고, 일부는 상대 운영체제까지 갔지만 상대 앱이 읽기 전이었을 수 있습니다. 연결이 끊기면 앱은 **어디까지 갔는지 알 수 없습니다.** 새 TCP 연결은 이전 연결의 바이트에 대해 아무것도 모릅니다.

QoS 1은 이 빈틈을 **앱 층에서** 메웁니다. PUBACK은 "브로커의 MQTT가 이 메시지를 받아 책임지기로 했다"는 앱 수준의 확인이고, 받지 못한 메시지는 클라이언트가 들고 있습니다. 그리고 다시 연결할 때 세션을 이어 쓰면(Clean Session = 0) 확인받지 못한 메시지를 다시 보냅니다. MQTT 3.1.1 4.4절은 이것이 규격이 **요구하는 유일한 재전송**이라고 정합니다. 같은 절의 참고 문구는 예전 TCP 망에서는 연결 안에서의 재전송도 필요했던 역사가 있다고 덧붙입니다. MQTT 5.0의 4.4절은 더 분명해서, Clean Start = 0으로 다시 연결했을 때만 다시 보내고 "그 밖의 때에는 다시 보내서는 안 된다(MUST NOT)"고 정합니다. 즉 **연결이 살아 있는 동안의 신뢰성은 TCP가, 연결이 끊기고 다시 붙는 사이의 신뢰성은 QoS 1이** 맡는 분업입니다.

대가는 중복입니다. 브로커가 메시지를 받아 PUBACK을 보냈는데 그 PUBACK이 오는 길에 연결이 끊기면, 클라이언트는 다시 연결한 뒤 같은 메시지를 또 보냅니다. 그래서 QoS 1 메시지를 받는 쪽은 **같은 메시지를 두 번 받아도 괜찮게**(멱등하게) 만들어야 합니다. 메시지에 `seq`나 `cmd_id` 같은 고유 번호를 넣고, 이미 처리한 번호면 무시하는 식입니다.

paho-mqtt 문서도 같은 맥락의 주의를 줍니다. `on_publish` 콜백은 QoS 0의 경우 "메시지가 클라이언트를 떠났다는 뜻일 뿐"이고, QoS 1·2일 때만 확인 흐름이 끝났다는 뜻입니다. `publish()`가 성공을 돌려줬다고 해서 메시지가 망을 건넜다는 뜻도 아닙니다.

### 순서는 어디까지 지켜지나

MQTT 3.1.1 4.6절은 순서 규칙을 몇 가지 정합니다. 다시 보낼 때는 원래 보낸 순서대로 보내고, PUBACK도 받은 순서대로 보내고, 서버는 토픽을 기본으로 "순서가 있는 토픽(Ordered Topic)"으로 다뤄야 합니다. 그래서 TCP 연결 하나 위에서 한 클라이언트가 한 토픽에 보낸 메시지는 대체로 순서대로 도착합니다.

그래도 QoS 1에서는 중복 때문에 순서가 "되감길" 수 있습니다. 규격의 참고 문구는 앞선 메시지를 다시 보내는 과정에서 1, 2, 3, 4로 보낸 메시지를 구독자가 `1, 2, 3, 2, 3, 4` 순서로 받을 수 있다고 설명합니다. 확인받기 전에는 다음 메시지를 보내지 않도록, 즉 전송 중인 메시지를 한 번에 1개로 제한하면 `1, 2, 3, 3, 4`처럼 바로 앞 것만 다시 올 수 있고 `1, 2, 3, 2, 3, 4`는 생기지 않습니다. 위치 같은 데이터라면 받는 쪽이 `seq`나 시각을 보고 **이미 받은 것보다 옛 값이면 버리는** 처리를 해 두는 것이 안전합니다. 뒤에서 보듯 AWS IoT Core는 메시지 순서를 아예 보장하지 않는다고 적어 두기 때문에 더욱 그렇습니다.

### retained 메시지: 늦게 온 구독자에게 마지막 값을

평범한 MQTT 메시지는 발행하는 순간 구독 중인 클라이언트에게만 갑니다. 대시보드를 지금 막 열었다면, 다음 메시지가 올 때까지 아무것도 모릅니다. 상태처럼 드물게 바뀌는 값은 몇 분을 기다려야 할 수도 있습니다.

PUBLISH의 **RETAIN 플래그**가 이 문제를 풉니다(3.1.1 3.3.1.3절). RETAIN = 1로 발행하면 브로커는 그 메시지를 **토픽마다 마지막 하나** 저장해 두고, 나중에 그 토픽을 구독하는 클라이언트에게 바로 보내 줍니다. 받는 쪽에서는 RETAIN 플래그가 켜진 채로 와서, "지금 막 일어난 일"이 아니라 "저장되어 있던 마지막 값"임을 구분할 수 있습니다. 내용이 0바이트인 retained 메시지를 발행하면 그 토픽의 저장된 값이 지워집니다.

retain은 "지금 상태"를 담는 토픽에 어울립니다. 장치의 온라인 여부나 현재 모드 같은 값입니다. 반대로 초당 여러 번 갱신되는 위치에 retain을 켜면, 장치가 꺼진 지 한참 지나도 마지막 위치가 "방금 온 값"처럼 보일 위험이 있습니다. 이 대시보드는 위치에는 retain을 쓰지 않았습니다.

### Last Will: 인사 없이 끊기면 브로커가 대신 알린다

장치의 전원이 나가거나 망이 끊기면 장치는 "이제 오프라인이다"라는 메시지를 보낼 기회가 없습니다. **Last Will**(Will 메시지)은 이것을 브로커에게 미리 맡겨 두는 장치입니다(3.1.1 3.1.2.5절).

클라이언트는 CONNECT에 Will 토픽, 내용, QoS, retain 여부를 담아 둡니다. 브로커는 그 연결이 아래 같은 이유로 끝나면 클라이언트 대신 그 메시지를 발행합니다.

- 브로커가 입출력 오류나 네트워크 장애를 알아챘을 때
- keepalive 시간 안에 클라이언트가 아무것도 보내지 않았을 때
- 클라이언트가 DISCONNECT 없이 연결을 닫았을 때
- 프로토콜 오류로 브로커가 연결을 닫았을 때

반대로 클라이언트가 **DISCONNECT를 보내고 정상으로 끊으면** 브로커는 Will을 지우고 발행하지 않습니다. "인사하고 나간 것"과 "말없이 사라진 것"을 구분해 주는 셈입니다.

흔히 쓰는 짝이 **retain + Last Will**입니다. 장치는 연결하자마자 상태 토픽에 `{"online": true}`를 retain으로 발행하고, Will로는 같은 토픽에 `{"online": false}`를 retain으로 걸어 둡니다. 그러면 장치가 말없이 사라졌을 때 브로커가 `false`를 발행하고, 그 값이 retain으로 남아 나중에 들어온 대시보드도 "이 장치는 오프라인"을 바로 압니다. 아래 예시에서 이 흐름을 그대로 돌려 봅니다.

### keepalive: TCP가 못 하는 생존 확인

앞에서 TCP는 그 자체로 상대가 살아 있는지 모른다고 했습니다. MQTT의 **Keep Alive**가 이 일을 맡습니다(3.1.1 3.1.2.10절).

- Keep Alive는 CONNECT에 담는 16비트 초 단위 값입니다.
- 클라이언트는 제어 패킷을 보내는 간격이 이 값을 넘지 않게 해야 하고, 보낼 것이 없으면 **PINGREQ**(2바이트)를 보냅니다. 브로커는 **PINGRESP**(2바이트)로 답합니다.
- 브로커는 Keep Alive의 **1.5배** 동안 그 클라이언트에게서 아무 패킷도 받지 못하면 연결을 끊어야 합니다. 이때 Will이 발행됩니다.
- Keep Alive를 0으로 두면 이 장치가 꺼집니다.

즉 Keep Alive를 30초로 두면, 장치가 말없이 사라진 뒤 브로커가 알아채기까지 최대 45초쯤 걸릴 수 있습니다. 짧게 잡을수록 빨리 알아채지만 PINGREQ가 자주 오갑니다. 메시지를 꾸준히 보내는 장치라면 그 메시지 자체가 생존 신호가 되므로 PINGREQ는 거의 나가지 않습니다.

### 세션: 끊겼다 다시 붙어도 이어지는 것

MQTT의 **세션**은 연결이 끊긴 뒤에도 남는 상태입니다(3.1.1 3.1.2.4절). 브로커 쪽 세션에는 구독 목록, 보냈지만 확인받지 못한 QoS 1·2 메시지, 클라이언트가 없는 동안 쌓인 QoS 1·2 메시지 등이 들어갑니다.

- **Clean Session = 1**이면 연결할 때 이전 세션을 버리고 새로 시작하며, 끊길 때도 버립니다. 다시 연결하면 구독부터 다시 해야 합니다.
- **Clean Session = 0**이면 같은 Client Identifier로 다시 연결했을 때 이전 세션을 이어 씁니다. 구독이 남아 있고, 그동안 쌓인 QoS 1·2 메시지를 받고, 확인받지 못한 메시지를 다시 주고받습니다.

세션이 Client Identifier에 묶이기 때문에 **같은 ID로 두 클라이언트가 접속하면** 곤란해집니다. 규격상 브로커는 이미 접속한 같은 ID의 클라이언트를 끊습니다. 대시보드 탭을 두 개 띄웠는데 서로를 번갈아 끊는다면 ID가 겹치지 않았는지 먼저 확인할 만합니다.

### MQTT 5.0에서 달라진 것

MQTT 5.0은 3.1.1의 구조를 그대로 두고, 실무에서 아쉬웠던 점을 많이 채웠습니다. 규격 부록 C의 목록 중 실시간 데이터와 관련 깊은 것을 골라 보면 이렇습니다.

| 기능 | 무엇이 달라졌나 |
|---|---|
| Clean Start + Session Expiry Interval | "세션을 버릴지"와 "끊긴 뒤 얼마나 남길지"를 따로 정한다 |
| Message Expiry Interval | 메시지에 유효 시간을 붙여, 시간이 지나면 브로커가 전달하지 않고 버린다 |
| Reason Code | 모든 ACK와 DISCONNECT에 이유 코드가 붙어 왜 거절·종료됐는지 알 수 있다 |
| 서버의 DISCONNECT | 브로커도 이유와 함께 연결 종료를 알릴 수 있다 |
| Topic Alias | 긴 토픽 이름 대신 2바이트 번호를 써서 반복 전송량을 줄인다 |
| Receive Maximum | 확인 없이 동시에 받을 QoS 1·2 메시지 수를 정해 흐름을 조절한다 |
| Shared Subscription | 같은 그룹의 구독자 여럿이 메시지를 나눠 받는다(부하 분산) |
| Request/Response | Response Topic과 Correlation Data로 요청과 응답을 짝짓는다 |
| User Property | 메시지에 이름·값 쌍을 자유롭게 붙인다 |
| Subscription Options | 내가 보낸 것을 안 받기(No Local), 구독 시 retained 받는 방식 등 |
| Will Delay Interval | 끊긴 뒤 바로가 아니라 잠시 기다렸다 Will을 발행한다 |

이 중 **Message Expiry Interval**은 "늦게 온 위치는 쓸모없다"는 문제와 바로 닿아 있습니다. 위치 메시지에 짧은 유효 시간을 붙이면, 브로커가 오래 붙잡고 있던 옛 위치를 구독자에게 보내지 않고 버립니다. 다만 이것은 **브로커에 도착한 뒤**의 이야기라서, 보내는 쪽 송신 버퍼나 TCP에 쌓여 있는 옛 위치까지 없애 주지는 않습니다.

### 브라우저에서는 MQTT over WebSocket

브라우저 JavaScript는 TCP 소켓을 직접 열 수 없습니다. 그래서 브라우저는 **WebSocket** 위에 MQTT를 얹습니다. MQTT 3.1.1 6절은 이 방식을 이렇게 정합니다.

- MQTT 패킷은 WebSocket **바이너리 프레임**으로 보낸다(텍스트 프레임이 오면 연결을 닫는다).
- WebSocket 프레임 하나에 MQTT 패킷이 여러 개 들어 있거나 일부만 들어 있을 수 있다. 즉 프레임 경계와 MQTT 패킷 경계는 상관없다.
- WebSocket 하위 프로토콜 이름은 `mqtt`다.

층으로 보면 브라우저는 MQTT / WebSocket / TLS / TCP / IP 순서로 쌓입니다. WebSocket이 한 층 더 있을 뿐 맨 아래는 여전히 TCP라서, head-of-line blocking 같은 TCP의 성질도 그대로 따라옵니다.

### 포트

| 포트 | 쓰임 |
|---|---|
| 1883 | MQTT, 암호화 없음(IANA 등록) |
| 8883 | MQTT over TLS(IANA 등록) |
| 443 | HTTPS 포트. MQTT over WebSocket(WSS)이나, ALPN으로 MQTT를 구분해 받는 서비스에서 씀 |

1883은 로컬 실험이나 닫힌 망에서만 쓰고, 인터넷을 건널 때는 8883이나 443 위의 TLS를 씁니다. 443을 쓰는 이유는 대개 방화벽입니다. 회사나 공공 망은 443 말고는 막아 두는 경우가 많습니다.

### AWS IoT Core에서 달라지는 것

AWS IoT Core의 메시지 브로커는 MQTT 3.1.1과 5.0을 바탕으로 하지만, 규격과 다르게 동작하는 부분을 문서에 따로 정리해 두었습니다. 받는 프로토콜과 포트부터 봅시다. "Device communication protocols" 문서는 MQTT, MQTT over WebSocket Secure(WSS), HTTPS(발행만), 그리고 직접 메시지 API를 듭니다.

| 프로토콜 | 인증 | 포트 |
|---|---|---|
| MQTT | X.509 클라이언트 인증서 | 8883, 또는 443 + ALPN `x-amzn-mqtt-ca` |
| MQTT | 사용자 지정 인증(custom auth) | 443 + ALPN `mqtt` |
| MQTT over WSS | SigV4 또는 사용자 지정 인증 | 443 |
| HTTPS (발행만) | SigV4 또는 사용자 지정 인증 | 443 |
| HTTPS (발행만) | X.509 클라이언트 인증서 | 8443, 또는 443 + ALPN `x-amzn-http-ca` |

이 표에 UDP나 MQTT-SN은 없습니다. 즉 **AWS IoT Core에 UDP 위 MQTT로 붙는 길은 없습니다.** 브라우저 WSS 주소는 `wss://{엔드포인트}/mqtt` 꼴이고, TLS 1.2와 1.3을 지원합니다. 문서는 연결이 영원히 유지된다고 보장하지 않으며, 인증 방식에 따라 최대 연결 시간이 있다고 적습니다(예: SigV4는 최대 24시간). 장치든 브라우저든 **다시 연결하는 코드는 필수**입니다.

MQTT 규격과의 차이 중 이 글의 내용과 닿는 것을 골랐습니다.

- **QoS 2가 없습니다.** QoS 0과 1만 지원하고, PUBREC·PUBREL·PUBCOMP를 쓰지 않습니다. QoS 2로 발행하거나 구독하려 하면 PUBACK·SUBACK을 보내지 않습니다.
- **QoS 0 구독은 "0번 이상"** 전달될 수 있다고 적혀 있습니다. 즉 QoS 0이라도 두 번 올 수 있습니다.
- **CONNACK을 기다려야 합니다.** 앞에서 본 대로, 다른 패킷을 보내기 전에 CONNACK을 받아야 합니다.
- **`sensor/#`는 `sensor`에 맞지 않습니다.** 규격과 반대입니다. 부모 토픽까지 받으려면 따로 구독해야 합니다.
- **와일드카드 구독은 구독 시점에 retained 메시지를 받지 않습니다.** 늦게 들어온 대시보드가 retained 상태를 바로 받으려면 정확한 토픽 이름으로 구독해야 합니다.
- **같은 Client ID로 새로 접속하면** 새 연결을 받고 기존 연결을 끊습니다.
- **메시지와 ACK의 순서를 보장하지 않습니다.** DUP 플래그도 쓰지 않습니다.
- **Last Will은** 클라이언트가 DISCONNECT로 정상 종료하면 발행되지 않고, retain으로 걸 수 있습니다. 문서는 연결 상태를 확실히 알고 싶다면 수명 주기 이벤트(lifecycle events)를 함께 쓰라고 권합니다.
- **지속 세션은** 확인받지 못한 QoS 1 메시지와 없는 동안 온 QoS 1 메시지를 저장했다가, 다시 연결하면 최대 초당 10개 속도로 보냅니다. MQTT 3의 세션 유지 기본값은 1시간이고 바꿀 수 있습니다.
- **retained 메시지는** 토픽마다 하나이고, 0바이트로 발행하면 지워지며, 저장에 따로 비용이 듭니다.
- **MQTT 5 기능은** Shared Subscription, Clean Start와 Session Expiry, 모든 ACK의 Reason Code, Topic Alias, Message Expiry 등을 지원합니다. Message Expiry는 최소 1초, 최대 604800초(7일)로 맞춰집니다.

한도(AWS General Reference의 IoT Core quotas)도 설계에 바로 영향을 줍니다. 값은 바뀔 수 있으니 쓰기 전에 문서를 다시 확인하는 것이 좋습니다.

| 항목 | 한도 |
|---|---|
| 메시지 크기 | 128 KB (조정 불가) |
| Keep Alive | 30초보다 작으면 30초로, 0이거나 1200초보다 크면 1200초로 맞춤 |
| 지속 세션 유지 시간 | 3600초 (조정 가능) |
| 토픽 이름 | 256바이트, `/` 7개 이하 |
| Client ID | 128바이트 |
| 연결당 발행 요청 | 초당 100 |
| 연결당 구독 수 | 50 |
| Client ID당 CONNECT | 초당 1 |
| 연결당 처리량 | 초당 512 KB |

Keep Alive 0이 "끄기"가 아니라 1200초로 바뀐다는 점, 토픽 단계가 8단계(슬래시 7개)를 넘을 수 없다는 점, 같은 Client ID로 1초에 한 번 넘게 접속할 수 없다는 점은 재접속 코드를 짤 때 특히 눈여겨볼 만합니다. 재접속을 너무 빨리 반복하면 한도에 걸릴 수 있습니다.

### UDP용 변형: MQTT-SN

"그래도 UDP 위에서 MQTT를 쓰고 싶다면?"에 대한 답으로 **MQTT-SN**(MQTT for Sensor Networks)이 있습니다. mqtt.org는 MQTT-SN을 "Zigbee처럼 TCP/IP가 아닌 망 위의 임베디드 장치를 위한 것"이라고 소개합니다. MQTT-SN 1.2 규격은 그 이유를 이렇게 적습니다. MQTT는 TCP/IP처럼 순서가 지켜지고 잃어버리지 않는 연결을 주는 하위 망을 요구하는데, 아주 단순한 작은 장치에게는 그것이 너무 복잡하다는 것입니다.

그래서 MQTT-SN은 하위 망에 대해 거의 요구하지 않습니다. 규격은 MQTT-SN이 하위 망 서비스에 구애받지 않으며, 장치와 게이트웨이 사이에 양방향 데이터 전송을 해 주는 망이면 지원할 수 있다고 적습니다. 처음에는 ZigBee의 APS 층 위에서 돌도록 설계되었고, 보통 **게이트웨이**가 MQTT-SN을 일반 MQTT로 바꿔 브로커에 이어 줍니다. 규격의 예는 "보내는 쪽이 특정 목적지로 데이터 메시지를 보낼 수 있는 단순한 데이터그램 서비스"이고, 특정 프로토콜 이름을 정하지는 않습니다. UDP는 이런 데이터그램 서비스의 대표적인 예입니다.

다만 앞의 표처럼 AWS IoT Core는 MQTT-SN을 직접 받지 않습니다. 쓰려면 MQTT-SN 게이트웨이를 따로 두고, 게이트웨이에서 일반 MQTT로 바꿔 보내야 합니다. 결국 클라우드 구간은 다시 TCP입니다.

## 실제 사례에 적용하기: 토픽마다 QoS를 다르게

이 원리들이 대시보드의 메시지 설계에 어떻게 쓰였는지 일반화해 정리하면 이렇습니다. 토픽 이름은 이 글을 위해 새로 지었습니다.

| 흐름 | 토픽(예) | 길 | QoS | retain | 이유 |
|---|---|---|---|---|---|
| 위치 (초당 5번) | `devices/dev1/position` | MQTT / TCP | 0 | 안 씀 | 곧 다음 값이 온다. 빠져도 다음 값이 덮는다. 옛 위치가 retain으로 남으면 오해를 부른다 |
| 배터리 등 주기 측정 | `devices/dev1/battery` | MQTT / TCP | 0 | 안 씀 | 위치와 같은 이유 |
| 상태 (변할 때 + 주기) | `devices/dev1/status` | MQTT / TCP | 1 | 씀 + Last Will | 늦게 열린 대시보드도 지금 상태를 바로 알아야 한다. 말없이 끊기면 브로커가 `online:false`를 남긴다 |
| 명령 | `devices/dev1/cmd` | MQTT / TCP | 1 | 안 씀 | 빠지면 안 된다. 중복될 수 있으니 `cmd_id`로 한 번만 처리한다 |
| 명령 결과 | `devices/dev1/cmd/ack` | MQTT / TCP | 1 | 안 씀 | QoS는 구간마다라서 "처리됐다"는 끝단 확인을 메시지로 따로 받는다 |
| 카메라 영상 | (MQTT 아님) | WebRTC / UDP | — | — | 늦은 프레임은 쓸모없다. 손실은 영상 쪽에서 감당한다 |

이 표를 보면 처음 질문의 답이 한 번 더 분명해집니다. 같은 장치라도 흐름마다 다른 길과 다른 약속을 씁니다. "TCP냐 UDP냐"는 장치 단위가 아니라 **데이터 단위**로 정하는 문제였습니다.

## "UDP였으면 안 끊겼을까?"에 대한 정직한 답

처음 질문으로 돌아가 봅시다. 위치를 UDP 같은 전송으로 보냈다면 아이콘이 멈췄다 뛰는 일은 없었을까요?

**일부는 그렇습니다.** 위치처럼 최신 값만 의미 있는 데이터를, 옛 것을 다시 보내지 않는 전송으로 보내면 손실이 생겼을 때 "한동안 멈춤 + 한꺼번에 점프"가 "한 칸 가볍게 건너뜀"으로 바뀔 수 있습니다. 빠진 값 때문에 뒤 값이 기다리지 않기 때문입니다.

**하지만 세 가지는 그대로입니다.**

1. **망 자체의 문제는 남습니다.** 무선 신호가 끊기거나 대역이 모자라면 UDP라도 데이터가 오지 않습니다. 멈춤이 "건너뜀"으로 모양만 바뀔 뿐, 데이터가 오지 않는 시간이 없어지지는 않습니다.
2. **AWS IoT Core는 UDP 위 MQTT를 받지 않습니다.** 앞의 표대로 MQTT, WSS, HTTPS만 받습니다. MQTT 규격도 UDP만으로는 맞지 않는다고 적습니다. UDP로 가려면 브로커부터 바꾸거나 MQTT-SN 게이트웨이를 따로 둬야 합니다.
3. **브라우저까지 UDP로 가려면 일이 커집니다.** 브라우저가 쓸 수 있는 UDP 기반 길은 사실상 WebRTC 데이터 채널(`ordered: false`, `maxRetransmits: 0` 또는 `maxPacketLifeTime`)입니다. 시그널링, NAT 통과, 인증, 보안 검토까지 별도의 경로를 새로 만들어야 합니다.

그래서 전송을 바꾸는 것은 마지막 수단으로 두고, TCP 위에서 먼저 풀었습니다. 망이 느려지면 보내는 쪽 송신 버퍼와 큐에 옛 위치가 쌓이고, 망이 풀리는 순간 그 옛 위치들이 한꺼번에 흘러가 화면이 뛰었습니다. 그래서 위치처럼 최신 값만 의미 있는 데이터는 보내는 쪽이 밀린 옛 것을 버리고 **가장 새 것 하나만** 보내도록 바꿨습니다. 이 "최신 것만 보내기"의 측정과 구현은 따로 정리할 계획이고, 여기서는 "전송 층을 바꾸기 전에 TCP 위에서 할 수 있는 일이 있다"는 점만 적어 둡니다.

## 직접 해 보기

아래 예시는 모두 이 글을 위해 새로 쓴 최소 예시이고, 노트북(macOS, Python 3.10)의 `127.0.0.1` 안에서만 돌렸습니다. 클라우드나 AWS에는 접속하지 않았습니다. 출력은 실제로 돌린 결과입니다.

### (가) UDP: 연결 없이 보내고, 보낸 단위 그대로 받는다

```python
# udp_demo.py: UDP는 연결 없이 보내고, 보낸 단위(데이터그램) 그대로 받는다
import socket

recv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
recv.bind(("127.0.0.1", 0))              # 빈 포트 아무거나
addr = recv.getsockname()

send = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for msg in [b"pos seq=1", b"pos seq=2", b"pos seq=3"]:
    send.sendto(msg, addr)               # connect() 없이 바로 보낸다

recv.settimeout(1.0)
for _ in range(3):
    data, src = recv.recvfrom(2048)      # 한 번에 데이터그램 하나
    print("받음:", data)

# 아무도 듣지 않는 포트로 보내도 sendto는 그냥 성공한다(상대가 있는지 모른다)
nobody = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
nobody.bind(("127.0.0.1", 0))
dead = nobody.getsockname(); nobody.close()
n = send.sendto(b"hello?", dead)
print("듣는 쪽이 없는 포트로 보낸 바이트 수:", n)
```

```text
받음: b'pos seq=1'
받음: b'pos seq=2'
받음: b'pos seq=3'
듣는 쪽이 없는 포트로 보낸 바이트 수: 6
```

`sendto()` 세 번이 `recvfrom()` 세 번으로 하나씩 나옵니다. 경계가 지켜집니다. 그리고 아무도 듣지 않는 포트로 보내도 `sendto()`는 6바이트를 보냈다고 답합니다. UDP는 받는 쪽이 있는지 확인하지 않기 때문입니다. 같은 컴퓨터 안이라 손실이나 순서 바뀜은 일어나지 않았습니다. 그런 일은 실제 무선망에서 일어납니다.

### (나) TCP: send 두 번이 recv 한 번에 붙어 온다

```python
# tcp_stream.py: TCP에서는 send() 두 번이 recv() 한 번에 붙어 올 수 있다
import socket, threading, time

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.bind(("127.0.0.1", 0)); srv.listen(1)
addr = srv.getsockname()

def client():
    c = socket.create_connection(addr)   # 여기서 3-way handshake
    c.sendall(b"pos seq=1;")
    c.sendall(b"pos seq=2;")
    c.close()

threading.Thread(target=client).start()
conn, _ = srv.accept()
time.sleep(0.2)                          # 받는 쪽이 조금 늦게 읽으면
chunks = []
while True:
    data = conn.recv(4096)
    if not data:
        break
    chunks.append(data)
print("recv 호출로 받은 덩어리:", chunks)
```

```text
recv 호출로 받은 덩어리: [b'pos seq=1;pos seq=2;']
```

다섯 번 돌려 다섯 번 모두 이렇게 나왔습니다. 받는 쪽이 0.2초 늦게 읽는 사이 두 메시지가 수신 버퍼에 이어 붙었고, `recv()` 한 번이 그것을 통째로 가져왔습니다. 받는 쪽은 `;`를 보고 직접 잘라야 합니다. 받는 쪽이 늦게 읽지 않으면 둘이 따로 올 수도 있습니다. 어느 쪽이든 **경계를 믿을 수 없다**는 것이 요점입니다.

TCP 위 프로토콜이 쓰는 방법은 길이를 앞에 붙이는 것입니다. MQTT의 Remaining Length와 같은 생각을 2바이트 길이로 줄여 보면 이렇습니다.

```python
# framing.py: 바이트 흐름 위에서 메시지를 다시 자르는 법. 길이를 앞에 붙인다
import struct

def frame(payload: bytes) -> bytes:
    return struct.pack("!H", len(payload)) + payload   # 2바이트 길이 + 내용

def unframe(buf: bytearray):
    msgs = []
    while len(buf) >= 2:
        (n,) = struct.unpack("!H", buf[:2])
        if len(buf) < 2 + n:
            break                                      # 아직 덜 왔다: 다음 recv를 기다린다
        msgs.append(bytes(buf[2:2 + n]))
        del buf[:2 + n]
    return msgs

stream = frame(b"pos seq=1") + frame(b"pos seq=2")
buf = bytearray()
for piece in [stream[:5], stream[5:14], stream[14:]]:  # 아무렇게나 잘려 도착했다고 치자
    buf += piece
    print("도착", piece, "→ 꺼낸 메시지", unframe(buf))
```

```text
도착 b'\x00\tpos' → 꺼낸 메시지 []
도착 b' seq=1\x00\tp' → 꺼낸 메시지 [b'pos seq=1']
도착 b'os seq=2' → 꺼낸 메시지 [b'pos seq=2']
```

`\x00\t`는 길이 9(`pos seq=1`의 길이)를 뜻하는 2바이트입니다. 바이트가 아무렇게나 잘려 와도, 길이만큼 모일 때까지 기다렸다가 꺼내면 메시지가 정확히 나옵니다.

### (다) MQTT: retain, Last Will, QoS 0·1을 로컬 브로커로

로컬에 mosquitto가 없어서, Python으로 된 MQTT 3.1.1 브로커인 **amqtt 0.12.1**을 임시 가상 환경에 설치해 `127.0.0.1:1883`에 띄웠습니다. 클라이언트는 **paho-mqtt 2.1.0**입니다. 브로커 설정은 로컬 실험용으로 익명 접속만 열어 둔 최소 설정입니다.

```yaml
# broker.yaml: 로컬 실험 전용(익명 허용, 127.0.0.1만)
listeners:
  default:
    type: tcp
    bind: 127.0.0.1:1883
plugins:
  amqtt.plugins.authentication.AnonymousAuthPlugin:
    allow_anonymous: true
  amqtt.plugins.sys.broker.BrokerSysPlugin:
    sys_interval: 0
```

```bash
python -m venv .venv && . .venv/bin/activate
pip install paho-mqtt==2.1.0 amqtt==0.12.1
amqtt -c broker.yaml &
```

대시보드 역할의 구독자는 위치를 QoS 0, 상태를 QoS 1로 구독합니다. 구독은 `on_connect` 안에서 합니다. 다시 연결할 때마다 구독이 다시 걸리게 하려는 것입니다.

```python
# sub.py: 구독자. 위치는 QoS 0, 상태는 QoS 1로 구독한다
import paho.mqtt.client as mqtt

def on_connect(client, userdata, flags, reason_code, properties):
    print("CONNACK:", reason_code)
    client.subscribe([("devices/+/position", 0), ("devices/+/status", 1)])

def on_message(client, userdata, msg):
    print(f"{msg.topic} qos={msg.qos} retain={int(msg.retain)} {msg.payload.decode()}")

client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="dashboard-1")
client.on_connect = on_connect
client.on_message = on_message
client.connect("127.0.0.1", 1883, keepalive=30)
client.loop_forever()
```

장치 역할의 발행자는 Last Will을 걸고 접속한 뒤, CONNACK을 받으면 상태를 retain으로 발행하고, 위치를 0.2초마다 5번 보낸 다음 **DISCONNECT 없이** 프로세스를 끝냅니다. 전원이 갑자기 나간 장치를 흉내 낸 것입니다.

```python
# pub.py: 장치. Last Will을 걸고 접속 → 상태(retain, QoS 1) → 위치(QoS 0) 5번 → 비정상 종료
import json, os, time
import paho.mqtt.client as mqtt

DEV = "dev1"
STATUS = f"devices/{DEV}/status"

client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=DEV)
# 브로커가 "이 장치가 인사 없이 끊겼다"고 판단하면 대신 발행할 메시지
client.will_set(STATUS, json.dumps({"online": False}), qos=1, retain=True)

def on_connect(client, userdata, flags, reason_code, properties):
    # CONNACK을 받은 뒤에만 발행한다
    info = client.publish(STATUS, json.dumps({"online": True}), qos=1, retain=True)
    print("status 발행, mid =", info.mid)

def on_publish(client, userdata, mid, reason_code, properties):
    print("on_publish mid =", mid)   # QoS 1이면 PUBACK을 받았다는 뜻, QoS 0이면 클라이언트를 떠났다는 뜻

client.on_connect = on_connect
client.on_publish = on_publish
client.connect("127.0.0.1", 1883, keepalive=30)
client.loop_start()
time.sleep(0.5)

for seq in range(1, 6):
    pos = {"seq": seq, "x": seq * 0.5, "y": 0.0, "ts": int(time.time() * 1000)}
    client.publish(f"devices/{DEV}/position", json.dumps(pos), qos=0)
    time.sleep(0.2)                  # 초당 5번

time.sleep(0.5)
print("DISCONNECT 없이 프로세스를 끝낸다(전원이 나간 것처럼)")
os._exit(1)
```

구독자를 먼저 띄우고 발행자를 돌린 결과입니다. 브로커를 새로 띄운 첫 실행의 출력이고, 위치의 `ts` 값은 길어서 줄였습니다(실제 간격은 약 200 ms씩).

```text
# pub.py
status 발행, mid = 1
on_publish mid = 1
on_publish mid = 2
on_publish mid = 3
on_publish mid = 4
on_publish mid = 5
on_publish mid = 6
DISCONNECT 없이 프로세스를 끝낸다(전원이 나간 것처럼)

# sub.py
CONNACK: Success
devices/dev1/status qos=1 retain=0 {"online": true}
devices/dev1/position qos=0 retain=0 {"seq": 1, "x": 0.5, "y": 0.0, "ts": …}
devices/dev1/position qos=0 retain=0 {"seq": 2, "x": 1.0, "y": 0.0, "ts": …}
devices/dev1/position qos=0 retain=0 {"seq": 3, "x": 1.5, "y": 0.0, "ts": …}
devices/dev1/position qos=0 retain=0 {"seq": 4, "x": 2.0, "y": 0.0, "ts": …}
devices/dev1/position qos=0 retain=0 {"seq": 5, "x": 2.5, "y": 0.0, "ts": …}
devices/dev1/status qos=1 retain=0 {"online": false}
```

읽을 거리가 몇 가지 있습니다.

- 발행자가 DISCONNECT 없이 사라지자 **마지막 줄의 `{"online": false}`가 왔습니다.** 장치가 보낸 것이 아니라 브로커가 Last Will을 대신 발행한 것입니다.
- 구독 중이던 클라이언트에게는 retain 메시지도 `retain=0`으로 옵니다. "지금 막 발행된 메시지"로 전달되기 때문입니다(3.1.1 3.3.1.3절).
- `on_publish`는 QoS 0 위치 다섯 개에 대해서도 불렸습니다. paho 문서대로 QoS 0에서는 "클라이언트를 떠났다"는 뜻일 뿐, 구독자가 받았다는 뜻이 아닙니다.

이제 장치가 사라진 뒤 대시보드를 새로 연다고 생각하고, 상태 토픽을 정확한 이름으로 구독해 봅니다.

```python
# late_sub.py: 늦게 들어온 구독자. retained 상태를 바로 받는지 본다
import time
import paho.mqtt.client as mqtt

def on_connect(c, u, f, rc, p):
    c.subscribe("devices/dev1/status", 1)

def on_message(c, u, m):
    print(f"늦은 구독자: {m.topic} retain={int(m.retain)} {m.payload.decode()}")

c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="late-viewer")
c.on_connect = on_connect
c.on_message = on_message
c.connect("127.0.0.1", 1883)
c.loop_start(); time.sleep(1.0); c.disconnect(); c.loop_stop()
```

```text
늦은 구독자: devices/dev1/status retain=1 {"online": false}
```

장치는 이미 없지만, 구독하자마자 Will이 남긴 `{"online": false}`를 받았습니다. 이번에는 `retain=1`입니다. "저장되어 있던 마지막 값"이라는 표시입니다. retain + Last Will 조합이 의도대로 동작합니다. 같은 실험을 브로커를 끄지 않고 여러 번 되풀이했을 때는 같은 retained 메시지를 **두 번** 받은 적도 있었습니다. 원인은 따로 확인하지 않았지만, QoS 1과 retained 전달에서 받는 쪽이 중복에 견뎌야 한다는 점을 다시 보여 줍니다. 그리고 AWS IoT Core라면 이 늦은 구독자가 `devices/+/status` 같은 **와일드카드**로 구독했을 때 retained 메시지를 받지 못한다는 점도 기억해 둘 만합니다.

### (라) 지금 이 연결이 TCP인지 보기

MQTT 클라이언트가 연결된 동안 `lsof`로 1883번 포트의 TCP 연결을 보면 이렇습니다(PID 등은 줄였습니다).

```bash
lsof -nP -iTCP:1883
```

```text
COMMAND   ...  TYPE  NAME
python3.1 ...  IPv4  TCP 127.0.0.1:1883 (LISTEN)
python3.1 ...  IPv4  TCP 127.0.0.1:1883->127.0.0.1:53977 (ESTABLISHED)
python3.1 ...  IPv4  TCP 127.0.0.1:53977->127.0.0.1:1883 (ESTABLISHED)
```

첫 줄은 브로커가 연결을 기다리는 소켓, 아래 두 줄은 같은 TCP 연결을 브로커 쪽과 클라이언트 쪽에서 본 모습입니다. "MQTT로 보낸다"는 말 아래에 실제로 TCP 연결이 있다는 것을 운영체제가 보여 줍니다. 실제 서비스에 붙은 장치라면 같은 방법으로 원격 포트가 8883이나 443인 `ESTABLISHED` 연결을 찾을 수 있습니다(`lsof -nP -iTCP:8883`, `lsof -nP -iTCP:443`). 이 부분은 AWS에 접속하지 않기 위해 이번에 돌리지 않았습니다. 리눅스에서는 `ss -tnp`로 비슷하게 볼 수 있습니다.

### (마) MQTT 바이트를 손으로 보내 보기

라이브러리 없이 TCP 소켓에 MQTT 3.1.1 바이트를 직접 써 보면 헤더가 얼마나 작은지 실감이 납니다.

```python
# raw_bytes.py: TCP 소켓에 MQTT 3.1.1 패킷을 직접 써 본다
import socket
s = socket.create_connection(("127.0.0.1", 1883))
# CONNECT: 프로토콜 이름 "MQTT", 레벨 4(3.1.1), Clean Session=1, Keep Alive=60초, Client ID="raw1"
var = b"\x00\x04MQTT" + b"\x04" + b"\x02" + b"\x00\x3c"
payload = b"\x00\x04raw1"
body = var + payload
s.sendall(bytes([0x10, len(body)]) + body)  # 0x10 = CONNECT, 그 뒤가 Remaining Length
print("CONNACK:", s.recv(16).hex(" "))
s.sendall(b"\xc0\x00")                      # PINGREQ
print("PINGRESP:", s.recv(16).hex(" "))
s.sendall(b"\xe0\x00")                      # DISCONNECT
s.close()
```

```text
CONNACK: 20 02 00 00
PINGRESP: d0 00
```

`20`은 CONNACK 종류, `02`는 뒤로 2바이트가 더 있다는 Remaining Length, `00 00`은 "이전 세션 없음"과 "수락"입니다. PINGREQ(`c0 00`)와 PINGRESP(`d0 00`)는 고정 헤더 2바이트가 전부입니다. keepalive가 망을 거의 쓰지 않는 이유입니다.

## 주의할 점

- **"MQTT냐 TCP냐"로 묻지 않습니다.** 층이 다릅니다. 고를 수 있는 것은 같은 층 안에서입니다(전송: TCP·UDP·QUIC, 응용: MQTT·HTTP·WebRTC).
- **QoS 0을 UDP로 생각하지 않습니다.** 아래 TCP는 연결이 살아 있는 동안 재전송과 순서 맞춤을 합니다. 손실은 주로 연결이 끊길 때 생깁니다.
- **QoS 1은 끝단 확인이 아닙니다.** PUBACK은 구간 하나의 확인입니다. 처리됐는지 알고 싶으면 응답 메시지를 따로 설계합니다.
- **QoS 1 메시지는 중복될 수 있습니다.** 받는 쪽은 `seq`나 `cmd_id`로 멱등하게 처리하고, 위치처럼 순서가 중요한 값은 옛 값이 늦게 오면 버립니다. AWS IoT Core는 순서도 보장하지 않습니다.
- **CONNACK 전에는 발행하지 않습니다.** AWS IoT Core는 이를 요구하고, 어기면 원인 모를 끊김으로 보입니다.
- **retain은 "지금 상태"에만 씁니다.** 자주 바뀌는 측정값에 retain을 켜면 오래된 값이 새 값처럼 보일 수 있습니다.
- **Last Will은 정상 종료(DISCONNECT) 때 나가지 않습니다.** 프로그램을 정상 종료할 때 오프라인을 알리려면 DISCONNECT 전에 직접 발행합니다.
- **Client ID를 겹치지 않게 합니다.** 같은 ID로 접속하면 먼저 붙은 쪽이 끊깁니다. 브라우저 탭마다 다른 ID를 씁니다.
- **AWS IoT Core에서는 규격과 다른 부분을 확인합니다.** QoS 2 없음, `#`의 부모 미포함, 와일드카드 구독의 retained 미전달, Keep Alive 30~1200초 보정, 128 KB, 토픽 단계 제한 같은 것들입니다.
- **다시 연결하는 코드를 반드시 둡니다.** 무선망은 끊기고, AWS IoT Core는 연결을 영원히 유지한다고 보장하지 않습니다. 재접속 간격은 Client ID당 초당 1회 한도를 넘지 않게 늘려 가며 잡습니다.

## 정리

| 질문 | 답 |
|---|---|
| MQTT와 TCP는 어떤 관계인가 | 고르는 관계가 아니라 위아래 관계. MQTT(응용)가 TCP(전송) 위에서 돈다 |
| TCP가 약속하는 것 | 연결, 신뢰, 순서, 흐름·혼잡 제어. 대신 메시지 경계가 없고 앞이 빠지면 뒤가 기다린다 |
| UDP가 약속하는 것 | 데이터그램 경계와 작은 헤더(8바이트)뿐. 도착·순서·중복은 위에서 해결한다 |
| UDP 위에 신뢰성을 다시 만든 것 | QUIC(HTTP/3), WebRTC 데이터 채널(SCTP/DTLS) |
| MQTT가 UDP 위에서 돌 수 있나 | 규격은 UDP만으로는 맞지 않다고 적는다. UDP용으로는 MQTT-SN이 있고 게이트웨이를 둔다 |
| MQTT의 핵심 | 브로커 중심 publish/subscribe, 토픽과 와일드카드, QoS 0·1·2, retained, Last Will, keepalive, 세션 |
| QoS 1이 TCP 위에서 필요한 이유 | TCP의 보장은 연결 하나 안에서만. 끊겼다 다시 붙는 사이를 PUBACK과 세션이 메운다. 대가는 중복 |
| QoS는 어디서 어디까지인가 | 구간마다 따로. 장치 → 브로커, 브로커 → 구독자. 실제 QoS는 발행·구독 중 낮은 쪽 |
| AWS IoT Core에서 다른 점 | MQTT·WSS·HTTPS만, 8883/443, QoS 2 없음, `#` 부모 미포함, 와일드카드 retained 미전달, 순서 보장 없음, 128 KB |
| 흐름별 배치 | 위치 QoS 0, 상태 QoS 1 + retain + Last Will, 명령·결과 QoS 1, 영상 WebRTC/UDP |
| UDP였으면 안 끊겼을까 | 멈춤+점프가 건너뜀으로 바뀔 수는 있지만 망 문제는 남고, AWS IoT Core는 UDP를 받지 않는다. TCP 위에서 최신 것만 보내기로 먼저 푼다 |

처음의 두 질문은 결국 "층이 다르다"는 한 문장으로 풀렸습니다. 그리고 그 한 문장을 받아들이고 나니, 왜 위치는 QoS 0이고 상태는 retain과 Last Will을 쓰는지, 왜 명령에는 결과 메시지가 따로 있는지, 왜 영상만 다른 길로 가는지가 한 줄로 이어졌습니다. 아이콘이 멈췄다 뛰는 것을 다시 본다면 이제는 "MQTT 탓인가 TCP 탓인가"가 아니라 "어느 층의 어느 약속이 지금 이 데이터와 맞지 않는가"를 먼저 물을 것 같습니다.

## 참고

- [RFC 9293: Transmission Control Protocol (TCP)](https://www.rfc-editor.org/rfc/rfc9293)
- [RFC 768: User Datagram Protocol](https://www.rfc-editor.org/rfc/rfc768)
- [RFC 8085: UDP Usage Guidelines](https://www.rfc-editor.org/rfc/rfc8085)
- [RFC 9000: QUIC: A UDP-Based Multiplexed and Secure Transport](https://www.rfc-editor.org/rfc/rfc9000)
- [RFC 9114: HTTP/3](https://www.rfc-editor.org/rfc/rfc9114)
- [RFC 1035: Domain Names - Implementation and Specification](https://www.rfc-editor.org/rfc/rfc1035)
- [RFC 8831: WebRTC Data Channels](https://www.rfc-editor.org/rfc/rfc8831)
- [W3C: WebRTC: Real-Time Communication in Browsers (RTCDataChannelInit)](https://www.w3.org/TR/webrtc/)
- [OASIS: MQTT Version 3.1.1](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html)
- [OASIS: MQTT Version 5.0](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html)
- [MQTT-SN Protocol Specification Version 1.2](https://groups.oasis-open.org/higherlogic/ws/public/download/66091/MQTT-SN_spec_v1.2.pdf)
- [mqtt.org: MQTT Specification](https://mqtt.org/mqtt-specification/)
- [AWS IoT Core: Device communication protocols](https://docs.aws.amazon.com/iot/latest/developerguide/protocols.html)
- [AWS IoT Core: MQTT](https://docs.aws.amazon.com/iot/latest/developerguide/mqtt.html)
- [AWS IoT Core: Lifecycle events](https://docs.aws.amazon.com/iot/latest/developerguide/life-cycle-events.html)
- [AWS General Reference: AWS IoT Core endpoints and quotas](https://docs.aws.amazon.com/general/latest/gr/iot-core.html)
- [Eclipse Paho MQTT Python Client 문서](https://eclipse.dev/paho/files/paho.mqtt.python/html/client.html)
