---
title: "TLS 정리: 핸드셰이크, 인증서, 그리고 IoT 장치가 쓰는 mTLS"
date: 2026-11-12 18:50:00 +0900
categories: [네트워크, 프로토콜]
tags: [tls, tls-1-3, x509, mtls, certificate, sni, alpn, aws-iot-core]
description: "TLS가 지켜 주는 기밀성·무결성·인증, TLS 1.3 핸드셰이크 한 바퀴, 인증서와 호스트 이름 검증, IoT 장치가 쓰는 mTLS, SNI·ALPN, 사내 프록시의 TLS 가로채기가 mTLS를 깨는 이유를 localhost 실험 결과와 함께 정리합니다."
---

실시간 위치 대시보드를 AI 에이전트와 함께 만들었습니다. 장치가 자기 위치를 클라우드의 MQTT 브로커(AWS IoT Core)로 보내고, 브라우저 화면이 그 값을 받아 지도 위에 그립니다. 만드는 동안 "인증서", "TLS", "mTLS", "8883", "443" 같은 말을 정말 자주 봤습니다. 그런데 돌아보니 같은 시스템 안에서 TLS(와 UDP용 친척인 DTLS)가 **여러 군데에서 서로 다른 모양으로** 쓰이고 있었습니다.

| 어디서 | 길 | TLS가 하는 일 | "누구냐"는 어떻게 증명하나 |
|---|---|---|---|
| 장치 → MQTT 브로커 | MQTT over TLS, 포트 8883 | 암호화 + 서버 확인 + **장치 확인** | 장치 인증서와 개인키로 TLS 안에서 증명(mTLS) |
| 브라우저 → MQTT 브로커 | MQTT over WebSocket(WSS), 포트 443 | 암호화 + 서버 확인 | 로그인으로 받은 임시 권한으로 만든 SigV4 서명 URL(TLS 위 응용 층) |
| 장치 → 자격 증명 공급자 | HTTPS, 포트 443 | 암호화 + 서버 확인 + 장치 확인 | 같은 장치 인증서로 mTLS → 1시간짜리 임시 AWS 권한을 받음 |
| 영상: 피어 사이 미디어 | WebRTC, UDP 위 DTLS-SRTP | 암호화 + 상대 확인 | DTLS 인증서 지문을 시그널링으로 미리 건넴 |
| 영상: UDP가 막힐 때의 대체 경로 | 클라이언트 ↔ TURN 서버, TLS over TCP 443 | 이 구간 암호화 + TURN 서버 확인 | 미디어는 이 길 안에서도 여전히 DTLS-SRTP로 보호 |

> 모두 "TLS를 쓴다"는데 무엇이 같고 무엇이 다른가? 인증서는 왜 서버만 내기도 하고 장치도 내기도 하나? 옛 사내 PC에서는 왜 443 연결만 인증서 오류가 나고 8883은 멀쩡했나?

이 글은 그 질문을 다시 짚는 정리입니다. TLS가 무엇을 약속하는지, TLS 1.3 핸드셰이크가 한 바퀴 도는 동안 무슨 일이 일어나는지, 인증서 검증이 정확히 무엇을 확인하는지, 장치가 인증서를 내는 mTLS가 어떻게 동작하는지를 RFC와 AWS 공식 문서로 봅니다. 그리고 localhost에서 실험용 CA를 만들어 **검증 실패, mTLS 실패, 가로채기 프록시가 mTLS를 깨는 장면**을 직접 재현한 결과를 붙입니다.

## 이 글에서 따라갈 길

긴 글이라 결론의 뼈대를 먼저 적습니다.

1. **TLS는 세 가지를 약속합니다.** 엿볼 수 없게(기밀성), 바꾸면 들키게(무결성), 상대가 맞는지 확인되게(인증). 인증은 보통 서버만 하고, 클라이언트 인증은 선택입니다. 데이터 길이, 접속 IP, 많은 경우 접속하려는 이름(SNI)은 숨기지 않습니다.
2. **TLS 1.3 전체 핸드셰이크는 왕복 한 번입니다**(TCP 연결 뒤, 인증서 기반, HelloRetryRequest·0-RTT 제외). 첫 메시지에 키 교환 재료를 미리 실어 보내기 때문입니다. TLS 1.2의 전체 핸드셰이크는 두 번이었습니다.
3. **인증서 검증은 두 가지 확인입니다.** "믿는 CA까지 서명이 이어지는가(체인)"와 "이 인증서가 내가 접속하려던 이름의 것인가(호스트 이름)". 둘 중 하나라도 빼면 검증이 아닙니다.
4. **mTLS는 같은 확인을 반대 방향으로도 합니다.** 장치는 인증서를 보내고, 그 인증서의 개인키로 핸드셰이크 기록에 서명해 "이 인증서의 주인이 나"임을 증명합니다. 개인키 자체는 전선 위로 나가지 않습니다.
5. **장치의 개인키나 서명 권한이 없는 가로채기 프록시가 TLS를 두 연결로 끊으면, 서버 확인만 하는 TLS는 통과할 수 있지만 mTLS는 깨집니다.** 그 프록시는 서버와의 핸드셰이크에서 장치로서 서명할 수 없기 때문입니다.

## TLS가 약속하는 것과 약속하지 않는 것

### 세 가지 약속

TLS 1.3 명세(RFC 8446)는 첫 절에서 TLS가 안전한 통로에 기대하는 성질을 세 가지로 적습니다.

- **인증(authentication):** 서버 쪽은 항상 인증됩니다. 클라이언트 쪽은 선택(optional)입니다. 인증은 비대칭 암호(RSA, ECDSA, EdDSA 서명)나 미리 나눈 키(PSK)로 합니다.
- **기밀성(confidentiality):** 연결이 맺어진 뒤 오가는 데이터는 양 끝만 볼 수 있습니다.
- **무결성(integrity):** 공격자가 중간에서 데이터를 바꾸면 들킵니다.

일상의 말로 바꾸면 이렇습니다.

| 약속 | 막아 주는 일 | TLS 안에서 맡는 부분 |
|---|---|---|
| 기밀성 | 카페 Wi-Fi 옆자리, 공유기, 통신사 장비가 내용을 읽는 것 | 핸드셰이크로 나눈 키 + 대칭 암호(AES-GCM 등) |
| 무결성 | 중간 장비가 몰래 한 글자 바꾸는 것 | AEAD 암호의 인증 태그 |
| 인증 | 엉뚱한 서버가 진짜인 척하는 것(DNS가 속았거나 중간에서 가로챈 경우) | 인증서 + 개인키 서명 |

셋 중 가장 덜 눈에 띄지만 가장 중요한 것은 **인증**입니다. 아무리 강한 암호로 잠가도, 잠긴 통로의 반대편이 공격자라면 소용이 없습니다. 이 글에서 겪고 재현한 오류도 암호보다는 인증서, 즉 "상대가 맞는가"에 몰려 있었습니다.

### 약속하지 않는 것

RFC 8446은 TLS가 숨기지 않는 것도 분명히 적습니다. "TLS는 보내는 데이터의 길이를 숨기지 않는다"는 문장이 있고, 길이를 감추고 싶으면 패딩을 따로 써야 한다고 설명합니다. 그 밖에도 TLS가 해 주지 않는 일을 정리하면 이렇습니다.

- **상대가 "좋은 사람"인지는 모릅니다.** 인증서는 "이 서버가 그 이름의 주인이다"까지만 말합니다. 그 이름의 주인이 악성 사이트여도 TLS는 정상입니다.
- **빨리 오게 해 주지 않습니다.** 오히려 연결마다 핸드셰이크 왕복이 더해집니다. 이 글 뒤에서 재연결 한 번의 왕복 수를 셉니다.
- **메타데이터는 남습니다.** 어떤 IP의 몇 번 포트로 붙는지는 그 아래 IP·TCP 층에 그대로 보입니다. 그리고 **접속하려는 이름(SNI)은 TLS 1.3에서도 기본적으로 평문**입니다. 2026년 3월에 나온 ECH(Encrypted Client Hello, RFC 9849)는 TLS 1.3에서도 SNI가 평문으로 남는다는 점을 "암호화되지 않은 채 남은 정보 중 아마 가장 민감한 것"이라고 부르며, 실제 목적지 이름(SNI)과 ALPN 등을 담은 안쪽 ClientHello(ClientHelloInner)를 암호화해, 공개해도 되는 정보만 담은 바깥 ClientHello(ClientHelloOuter) 안에 실어 보내는 방법을 정의합니다. 평문 ClientHello가 아예 사라지는 것이 아니라, 진짜 내용이 암호화된 안쪽으로 옮겨 가는 구조입니다. 다만 ECH를 써도 DNS 조회와 서버 IP로 상대를 짐작할 여지는 남는다고 같은 문서가 적고 있습니다. ECH는 양쪽이 지원해야 쓰는 확장이라 이 글의 예시에서는 다루지 않습니다.

## 층에서의 자리: TCP 위, 응용 아래

TLS는 TCP 위에 얹혀서 응용 프로토콜에 "암호화된 바이트 흐름"을 건네줍니다. 응용 쪽은 TLS가 없을 때와 거의 같은 코드로 읽고 쓰고, 그 아래에서 TLS가 잠그고 풉니다. 그래서 이름도 "무엇 over TLS"로 붙습니다.

| 이름 | 실체 | 흔한 포트 |
|---|---|---|
| HTTPS | HTTP over TLS | 443 |
| MQTTS | MQTT over TLS | 8883 |
| WSS | WebSocket over TLS (WebSocket은 HTTP로 시작해 업그레이드) | 443 |
| DTLS | UDP 위에서 쓰도록 바꾼 TLS | 응용마다 다름 |
| QUIC | UDP 위 전송 프로토콜, 핸드셰이크에 TLS 1.3을 품음 | 443 (HTTP/3) |

MQTT 5 명세는 TCP/IP 포트 8883과 1883이 IANA에 각각 TLS를 쓰는 MQTT(`secure-mqtt`)와 쓰지 않는 MQTT용으로 등록되어 있다고 적습니다. 포트 번호는 관례이자 등록일 뿐이고 TLS를 강제하지는 않습니다. 같은 8883에 평문 MQTT를 띄울 수도 있고, 443에서 MQTT를 받는 서비스도 있습니다. 실제로 이 글 뒤에서 AWS IoT Core가 443 한 포트에서 HTTPS와 MQTT를 가르는 방법을 봅니다.

**DTLS**는 UDP처럼 순서가 바뀌고 잃어버릴 수 있는 길 위에서 TLS와 같은 보안을 주려고 만든 변형입니다(DTLS 1.3은 RFC 9147). WebRTC 영상은 이 DTLS로 키를 나누고 SRTP로 영상을 보냅니다. DTLS 핸드셰이크와 "인증서 지문"으로 상대를 확인하는 방식은 [WebRTC 암호화와 브라우저 보안: DTLS-SRTP, 그리고 CSP]({% post_url 2026-11-10-webrtc-dtls-srtp-csp %})에서 자세히 다뤘습니다. 이 글은 TCP 위 TLS에 집중합니다.

**QUIC**은 TLS를 바깥에 덧씌우지 않고 안에 품습니다. RFC 9001은 QUIC이 TLS 1.3의 핸드셰이크로 키를 정하되, 레코드 보호는 QUIC 자기 방식으로 한다고 설명합니다. 그래서 HTTP/3에서는 QUIC의 전송 연결 수립과 TLS 1.3 핸드셰이크가 하나로 통합되고, 따로 TCP 핸드셰이크를 하지 않습니다.

버전도 정리해 둡니다. TLS 1.0과 1.1은 RFC 8996으로 공식 폐기되었습니다. 지금 쓰는 것은 TLS 1.2와 1.3이고, AWS IoT Core도 문서에서 TLS 1.2와 1.3을 지원한다고 적습니다. Python `ssl` 모듈은 3.10부터 기본 최소 버전이 TLS 1.2입니다.

## TLS 1.3 핸드셰이크 한 바퀴

TLS 연결은 두 부분으로 나뉩니다. 처음에 상대를 확인하고 키를 정하는 **핸드셰이크**, 그다음 그 키로 데이터를 잠가 보내는 **레코드** 부분입니다. 핸드셰이크가 끝나면 남은 일은 정해진 키로 대칭 암호를 돌리는 것뿐이라, 이해해야 할 내용은 거의 다 핸드셰이크에 있습니다.

<figure class="diagram">
{% include figures/tls-basics/tls13-handshake.svg %}
<figcaption>TLS 1.3 전체 핸드셰이크(TCP 연결 뒤, 인증서 기반, HelloRetryRequest·0-RTT 제외). ServerHello 다음부터는 전부 암호화되고, 클라이언트는 왕복 한 번 뒤 응용 데이터를 보낼 수 있다. 별표 메시지는 mTLS일 때만 더해지며 왕복 수는 늘지 않는다</figcaption>
</figure>

RFC 8446은 이 과정을 세 단계로 나눕니다. 키 교환(ClientHello, ServerHello), 서버 매개변수(EncryptedExtensions, CertificateRequest), 인증(Certificate, CertificateVerify, Finished)입니다. 하나씩 봅니다.

### 1. ClientHello: "이런 걸 할 수 있고, 키 재료는 미리 보낼게"

클라이언트가 먼저 보냅니다. 여기에는 이런 것이 들어 있습니다.

- **지원하는 버전**(supported_versions 확장): TLS 1.3을 할 수 있다고 알립니다.
- **암호 묶음 목록**(cipher suites): 데이터 보호에 쓸 대칭 암호와 해시의 조합 후보.
- **key_share:** 키 교환에 쓸 공개값. 서버가 어떤 그룹(타원곡선 등)을 고를지 모르니, 쓸 만한 그룹 한두 개에 대해 미리 만들어 보냅니다. **TLS 1.3이 왕복 한 번으로 줄어든 비결이 이것**입니다.
- **SNI**(server_name): 접속하려는 서버 이름. 한 IP에 서버가 여럿일 때 서버가 어느 인증서를 낼지 고르는 데 씁니다.
- **ALPN:** TLS 위에서 쓰고 싶은 응용 프로토콜 목록(예: `h2`, `http/1.1`).

### 2. ServerHello: 키가 정해지는 순간

서버는 클라이언트가 보낸 후보 중에서 버전, 암호 묶음, 키 교환 그룹을 고르고 **자기 key_share**를 돌려줍니다. 이제 양쪽은 각자 가진 비밀값과 상대 공개값으로 **같은 공유 비밀**을 계산합니다(ECDHE). 이 비밀은 전선 위로 한 번도 지나가지 않았습니다. 엿보는 쪽은 공개값 두 개만 봤고, 그것만으로는 공유 비밀을 계산할 수 없습니다.

다만 이 공유 비밀이 곧바로 AES 키가 되는 것은 아닙니다. RFC 8446 7.1절의 키 스케줄은 HKDF라는 키 파생 함수로 공유 비밀과 그때까지의 핸드셰이크 기록(transcript)을 섞어, 핸드셰이크용과 응용 데이터용, 그리고 클라이언트가 보낼 때와 서버가 보낼 때 쓸 키를 따로따로 만들어 냅니다.

여기서부터가 TLS 1.3의 큰 변화입니다. RFC 8446은 **ServerHello 다음의 모든 핸드셰이크 메시지가 암호화된다**고 적습니다. TLS 1.2에서는 서버 인증서가 평문으로 지나갔기 때문에 중간에서 누구나 어떤 인증서가 오가는지 볼 수 있었습니다. TLS 1.3에서는 서버 인증서도 암호화된 채로 갑니다.

### 3. 서버의 나머지 묶음: 확장, 인증서, 서명, Finished

서버는 ServerHello에 이어 한 번에 몰아 보냅니다.

- **EncryptedExtensions:** 키 교환과 무관한 나머지 결정. ALPN으로 고른 프로토콜이 여기에 담깁니다.
- **CertificateRequest:** mTLS일 때만. "너도 인증서를 내라."
- **Certificate:** 서버 인증서와, 신뢰하는 루트까지 이어 줄 중간 인증서들.
- **CertificateVerify:** 서버가 **인증서의 개인키로, 지금까지 오간 핸드셰이크 전체에 대해 만든 서명**입니다. 인증서는 공개 문서라 누구나 복사해 보낼 수 있습니다. 그 인증서의 개인키를 가진 쪽만 이 서명을 만들 수 있으므로, 이 서명이 "인증서의 주인이 지금 이 연결의 상대"라는 증거가 됩니다. 서명 대상에 이번 연결의 무작위값과 키 교환 값이 다 들어 있어서, 예전 연결의 서명을 다시 써먹을 수도 없습니다.
- **Finished:** 핸드셰이크 전체에 대한 MAC입니다. MAC은 **같은 비밀키를 가진 쪽만 만들고 확인할 수 있는 검증값**이고, 여기서 쓰는 키는 방금 나눈 공유 비밀에서 파생한 것이라 두 끝만 가지고 있습니다. 중간에서 누가 목록 하나를 지우거나 바꿨다면 양쪽의 기록이 달라져 여기서 맞지 않게 됩니다.

서명과 MAC을 둘 다 보내는 이유도 여기서 보입니다. 서명(CertificateVerify)은 개인키 주인만 만들 수 있고 공개키로 누구나 확인할 수 있어서 "이 인증서의 주인이 나"를 증명합니다. MAC(Finished)은 키를 나눈 두 끝만 만들고 확인할 수 있어서 "키를 나눈 상대와 내가 본 핸드셰이크 기록이 똑같다"를 확인합니다.

### 4. 클라이언트의 확인과 Finished

클라이언트는 서버 인증서를 검증하고(체인과 이름, 아래에서 자세히), CertificateVerify 서명과 Finished를 확인합니다. 다 맞으면 자기 Finished를 보냅니다. mTLS라면 그 앞에 자기 Certificate와 CertificateVerify를 붙입니다. 그리고 곧바로 응용 데이터를 보낼 수 있습니다.

정리하면 TCP 연결이 맺어진 뒤 클라이언트가 첫 응용 데이터를 보내기까지 **왕복 한 번(1-RTT)**입니다(HelloRetryRequest가 없을 때). 클라이언트 인증 메시지는 원래 보내야 하는 Finished와 같은 묶음에 실려 가므로 **mTLS를 해도 TLS 1.3의 왕복 수는 늘지 않습니다.**

### 실제 사이트에서 보기

`openssl s_client`로 공개 사이트 하나에 붙어 보면 이 결과가 그대로 보입니다(OpenSSL 4.1.0, 출력 중 필요한 줄만).

```bash
echo | openssl s_client -connect example.com:443 -servername example.com -verify_hostname example.com -alpn h2,http/1.1
```

```text
depth=3 C=US, O=SSL Corporation, CN=SSL.com TLS ECC Root CA 2022
depth=2 C=US, O=SSL Corporation, CN=SSL.com TLS Transit ECC CA R2
depth=1 C=US, O=SSL Corporation, CN=Cloudflare TLS Issuing ECC CA 3
depth=0 CN=example.com
Peer signature type: ecdsa_secp256r1_sha256
Negotiated TLS1.3 group: X25519MLKEM768
New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
ALPN protocol: h2
Verify return code: 0 (ok)
```

- `depth=0`부터 `depth=3`까지가 서버 인증서에서 루트 CA까지의 체인입니다.
- `Peer signature type`은 CertificateVerify 서명 방식입니다. 서버 인증서가 P-256 타원곡선 키라 ECDSA 서명이 왔습니다.
- `Negotiated TLS1.3 group`은 key_share로 고른 키 교환 그룹입니다. 이름에 X25519와 ML-KEM768이 함께 들어 있는 것이 보입니다. 이 그룹의 표준화 상태는 이 글에서 따로 확인하지 않았기 때문에, 관찰된 이름만 적어 둡니다.
- `TLS_AES_256_GCM_SHA384`가 실제 데이터를 지키는 암호 묶음, `h2`가 ALPN으로 고른 HTTP/2입니다.
- `Verify return code: 0`이 이름 확인까지 포함하려면 `-verify_hostname`을 줘야 합니다. `-servername`은 SNI로 보낼 이름일 뿐 호스트 이름 검증 옵션이 아닙니다.

### 키 교환과 전방 비밀성

TLS 1.3이 키를 나누는 방법은 (EC)DHE, 즉 **매 연결마다 새로 만든 임시 키**로 하는 디피-헬만 교환입니다(또는 PSK, 아래에서). RFC 8446은 TLS 1.2까지 있던 정적 RSA 키 교환과 정적 DH 방식을 없앴고, 그래서 공개키 기반 키 교환은 모두 **전방 비밀성(forward secrecy)**을 준다고 적습니다.

전방 비밀성이 왜 중요한지는 옛 방식과 비교하면 보입니다. 정적 RSA 키 교환에서는 클라이언트가 세션 키 재료를 **서버 인증서의 공개키로 암호화해서** 보냈습니다. 그러면 누군가 오늘 오간 패킷을 전부 녹화해 두었다가 몇 년 뒤 서버 개인키를 손에 넣으면, 녹화본을 전부 풀 수 있습니다. ECDHE에서는 서버 개인키가 **서명에만** 쓰이고, 세션 키는 연결이 끝나면 버리는 임시 키에서 나옵니다. 나중에 서버 개인키가 새어도 지난 대화는 풀리지 않습니다.

그래서 TLS 1.3에서는 역할이 깔끔하게 나뉩니다.

| 무엇 | 하는 일 | 오래 쓰나 |
|---|---|---|
| 인증서의 개인키 | CertificateVerify 서명 = "내가 이 인증서의 주인" | 인증서 유효 기간 동안 |
| (EC)DHE 임시 키 | 공유 비밀 계산 = 이번 연결의 키 | 연결 하나 동안만 |
| 대칭 키 | 실제 데이터 암호화·무결성 | 연결 하나 동안만(중간에 갱신 가능) |

### 대칭 암호와 AEAD

키가 정해지면 실제 데이터는 대칭 암호로 보호합니다. TLS 1.3은 **AEAD**(암호화와 변조 검사를 한 번에 하는 방식)만 씁니다. 암호문과 함께 인증 태그가 붙어서, 한 비트라도 바뀌면 복호화가 실패합니다. 앞에서 본 "무결성" 약속이 여기서 지켜집니다.

RFC 8446 9.1절은 구현이 반드시(MUST) 지원할 암호 묶음으로 `TLS_AES_128_GCM_SHA256`을, 지원해야 하는(SHOULD) 것으로 `TLS_AES_256_GCM_SHA384`와 `TLS_CHACHA20_POLY1305_SHA256`을 적습니다. 키 교환은 secp256r1(P-256)을 반드시, X25519를 지원해야 하는 것으로 둡니다.

TLS 1.3의 암호 묶음 이름에는 키 교환과 서명 방식이 들어 있지 않습니다. 그 둘은 key_share와 서명 알고리즘 확장으로 따로 고르기 때문입니다. TLS 1.2는 이름에 다 들어 있었습니다.

### TLS 1.2와 비교: 왕복 두 번

같은 사이트에 TLS 1.2로만 붙어 보면 이름 모양이 다릅니다.

```bash
echo | openssl s_client -connect example.com:443 -servername example.com -tls1_2
```

```text
New, TLSv1.2, Cipher is ECDHE-ECDSA-CHACHA20-POLY1305
```

`ECDHE`(키 교환) `ECDSA`(서명) `CHACHA20-POLY1305`(데이터 암호)가 한 이름에 들어 있습니다.

TLS 1.2의 전체 핸드셰이크(RFC 5246 그림 1)는 이렇게 흘러갑니다.

1. 클라이언트 → ClientHello (키 교환 재료 없음)
2. 서버 → ServerHello, Certificate, ServerKeyExchange, (CertificateRequest), ServerHelloDone
3. 클라이언트 → (Certificate), ClientKeyExchange, (CertificateVerify), ChangeCipherSpec, Finished
4. 서버 → ChangeCipherSpec, Finished
5. 이제 응용 데이터

클라이언트는 서버가 무엇을 고를지 들은 다음에야 키 교환 값을 보낼 수 있었고, 서버의 Finished까지 받아야 데이터를 보냈습니다. 그래서 **왕복 두 번(2-RTT)**입니다. TLS 1.3은 1단계에서 key_share를 "추측해서" 미리 보내는 것으로 이 한 번을 줄였습니다. 서버가 그 추측에 없는 그룹을 원하면 HelloRetryRequest로 다시 요청하는데, 그때는 왕복이 하나 더 듭니다.

### 재개(PSK)와 0-RTT

TLS 1.3은 한 번 붙었던 서버에 다시 붙을 때를 위한 길도 둡니다. 핸드셰이크가 끝나면 서버가 NewSessionTicket을 보내 주고, 양쪽은 이번 연결의 비밀(resumption_master_secret)과 티켓에 붙은 값(ticket_nonce)에서 **PSK**를 각자 파생해 보관합니다. 티켓은 그 PSK를 가리키는 이름표이지 PSK 자체가 아닙니다. 다음 연결에서 클라이언트는 ClientHello에 티켓을 넣어 "그때의 PSK로 하자"고 알리고, 그 PSK로 계산한 **binder** 값을 붙여 PSK를 실제로 가지고 있음을 증명합니다. 그러면 인증서 검증을 다시 하지 않고 재개할 수 있습니다.

RFC 8446은 PSK를 쓰는 방식을 둘로 나눕니다. PSK만 쓰는 방식(psk_ke)은 전방 비밀성이 없고, PSK와 (EC)DHE를 함께 쓰는 방식(psk_dhe_ke)은 전방 비밀성을 줍니다. 왕복 수는 어느 쪽이든 1-RTT입니다.

여기에 **0-RTT**(early data)라는 선택이 더 있습니다. 재개할 때 ClientHello와 함께 응용 데이터를 바로 실어 보내는 방식입니다. 대신 RFC 8446은 분명한 경고를 붙입니다. 0-RTT 데이터는 **전방 비밀성이 없고**, **연결 사이의 재전송(replay)을 막아 준다는 보장이 없습니다.** 공격자가 0-RTT로 온 "송금해 줘" 요청을 녹화해 다른 연결에 다시 보낼 수 있다는 뜻입니다. 그래서 0-RTT는 몇 번 반복돼도 괜찮은 요청에만 쓰라고 하고, 8절에서 재전송을 줄이는 방법을 따로 다룹니다. 장치가 명령을 보내는 길에서는 쓰지 않는 편이 맞습니다.

### 재연결 한 번은 왕복 몇 번인가

이 원리를 가지고 장치가 MQTT 연결을 잃었다가 다시 붙을 때의 비용을 세어 볼 수 있습니다. 측정값이 아니라 **프로토콜이 요구하는 왕복 수**입니다. TLS는 인증서 기반 전체 핸드셰이크로 보고, HelloRetryRequest·재전송·처리 시간은 뺐습니다(DNS 조회가 새로 필요하면 그만큼 더 듭니다).

| 단계 | 왕복 | 메모 |
|---|---|---|
| TCP 연결(SYN → SYN-ACK → ACK) | 1 | ACK와 함께 ClientHello를 바로 보낼 수 있다 |
| TLS 1.3 핸드셰이크 | 1 | TLS 1.2면 2 |
| MQTT CONNECT → CONNACK | 1 | 브로커가 접속을 받아들였다는 확인 |
| **합계(CONNACK까지)** | **3** | TLS 1.2 전체 핸드셰이크면 4 |

MQTT 5 명세는 클라이언트가 CONNECT를 보낸 직후 CONNACK을 기다리지 않고 다른 패킷을 보내도 된다고 적습니다. 그래서 첫 PUBLISH는 왕복 두 번 뒤에 CONNECT와 함께 출발할 수 있습니다. 다만 브로커가 접속을 거절하면 그 PUBLISH는 버려지므로, "제대로 붙었다"를 확인하는 시점은 여전히 왕복 세 번 뒤입니다.

왕복 시간이 50 ms인 길이라면 계산상 150 ms 남짓을 재연결에 쓰는 셈입니다. 연결이 자주 끊기는 장치라면 이 비용이 끊길 때마다 더해집니다. AWS IoT Core 문서는 MQTT 연결 지속 시간을 보장하지 않습니다. 최대 지속 시간 표에 X.509 인증서 방식 1~2주, SigV4 방식 24시간이 있지만 이것도 보장값이 아니라고 표시하고, 실제로는 몇 분 만에 끊길 수도 있으니 장치가 다시 연결하도록 만들라고 안내합니다. 재연결은 드문 사고가 아니라 설계에 넣어야 하는 일입니다.

## 인증서와 신뢰: 무엇을 확인하나

### 인증서는 서명된 신분증

X.509 인증서(RFC 5280)는 대략 이런 내용을 담은 문서에 발급자(CA)가 서명한 것입니다.

- **주체의 공개키:** 이 키에 맞는 개인키를 가진 쪽이 주인입니다.
- **이름:** 요즘 서버 인증서에서 의미 있는 이름은 Subject Alternative Name(SAN) 확장에 들어 있습니다(`DNS:example.com` 같은 꼴).
- **발급자:** 누가 서명했나.
- **유효 기간:** notBefore부터 notAfter까지.
- **용도 확장:** CA인가 아닌가(basicConstraints), 서명용인가(keyUsage), 서버용인가 클라이언트용인가(extendedKeyUsage) 등.

서버 인증서를 발급한 CA의 인증서는 다시 상위 CA가 서명하고, 맨 위에는 스스로 서명한 **루트 CA**가 있습니다. 클라이언트는 운영체제나 프로그램이 가진 **신뢰 저장소**에 루트 CA 목록을 들고 있다가, 서버가 보낸 체인을 거슬러 올라가 그 목록 중 하나에 닿으면 믿습니다. 앞의 `depth=0`~`depth=3` 출력이 바로 그 체인입니다.

이 신뢰 사슬, 프로그램마다 다른 신뢰 저장소(OS, Python `certifi`, Node 내장 목록 등), 그리고 `ca_bundle` 설정은 [AWS CLI CERTIFICATE_VERIFY_FAILED 해결기]({% post_url 2026-10-14-aws-cli-certificate-verify-failed %})에서 그림과 함께 자세히 정리했습니다. 이 글에서는 그 글에 없는 두 가지, **호스트 이름 확인**과 **유효 기간과 시계**를 더 봅니다.

### 호스트 이름 확인이 왜 필수인가

체인 검증만 하고 이름을 보지 않으면 어떻게 될까요? 공격자가 자기 도메인 `attacker.example`의 인증서를 정상적으로 발급받습니다. 이 인증서도 믿는 루트 CA까지 서명이 완벽하게 이어집니다. 그리고 DNS를 속이거나 중간에서 가로채 `api.example.com`으로 가는 연결에 그 인증서를 냅니다. 체인만 보는 클라이언트는 통과시킵니다. **"믿을 만한 누군가의 인증서"가 아니라 "내가 가려던 그 이름의 인증서"인지를 확인해야** 인증이 됩니다.

RFC 9525는 DNS 이름으로 접속할 때는 인증서 SAN의 DNS 이름(dNSName)과, IP 주소를 직접 지정해 접속할 때는 SAN의 IP 주소(iPAddress)와 대조하도록 정리합니다. 옛날처럼 Subject의 Common Name(CN)을 서비스 식별에 쓰면 안 된다(MUST NOT)고도 적습니다. 그래서 요즘 인증서를 직접 만들 때는 SAN을 꼭 넣어야 합니다. 이 글의 실험 서버 인증서에 `DNS:localhost`와 `IP:127.0.0.1`을 함께 넣은 것도 그래서입니다.

`openssl s_client`로도 이 확인이 보입니다. 같은 example.com 인증서를 받으면서 "나는 다른 이름에 접속하려 했다"고 알려 주면 이렇게 됩니다.

```bash
echo | openssl s_client -connect example.com:443 -servername example.com -verify_hostname not-example.org
```

```text
verify error:num=62:hostname mismatch
Verify return code: 62 (hostname mismatch)
```

`openssl s_client`는 검증에 실패해도 기본으로는 연결을 끊지 않고 결과만 알려 줍니다. 시험용 도구라서 그렇습니다. 실패하면 바로 끊게 하려면 `-verify_return_error`를 더합니다. 위 명령에 이 옵션을 붙이면 `certificate verify failed` 오류와 함께 종료 코드 1로 끝났습니다. 프로그램에서 쓰는 라이브러리는 이런 실패에서 연결을 끊어야 합니다.

### 유효 기간과 장치 시계

유효 기간 검사는 **클라이언트의 현재 시각**과 인증서의 notBefore·notAfter를 비교합니다(RFC 5280의 경로 검증). 그래서 장치 시계가 틀리면 멀쩡한 인증서도 "만료됨" 또는 "아직 유효하지 않음"이 됩니다. 배터리 없는 보드가 부팅 직후 1970년이나 펌웨어 빌드 날짜로 시작하는 경우가 대표적입니다. 장치에서 TLS를 쓰려면 NTP 같은 방법으로 시계를 먼저 맞추는 순서를 챙겨야 합니다.

서버 쪽 인증서만이 아니라 **루트 CA 인증서도 만료**됩니다. AWS IoT Core의 서버 인증 문서는 장치에 Amazon Root CA를 넣으라고 하면서, CA 인증서도 만료일이 있으니 장치가 신뢰할 CA를 갱신할 수 있게 만들어 두라고 권합니다. 또 인증서 전체를 고정(pinning)하는 방식은 권장하지 않습니다. 서버 인증서가 바뀌는 순간 장치가 붙지 못하게 되기 때문입니다. RSA용 Amazon Root CA 1과 ECC용 Amazon Root CA 3을 둘 다 넣어 두라는 안내도 같은 이유입니다.

## mTLS: 클라이언트도 인증서를 낸다

### 무엇이 더해지나

보통의 TLS에서는 서버만 인증서를 냅니다. 브라우저가 웹사이트에 붙을 때 브라우저는 인증서가 없고, 사용자 확인은 TLS가 끝난 뒤 로그인으로 따로 합니다. **mTLS(상호 TLS)**는 서버가 클라이언트에게도 인증서를 요구하는 방식입니다. 앞의 핸드셰이크 그림에서 별표가 붙은 세 메시지가 그 차이입니다.

1. 서버가 EncryptedExtensions 다음에 **CertificateRequest**를 보냅니다.
2. 클라이언트는 Finished 앞에 **Certificate**(장치 인증서)와 **CertificateVerify**(장치 개인키로 핸드셰이크 기록에 서명)를 붙입니다.
3. 서버는 그 인증서가 자기가 믿는 CA로 이어지는지 확인하고, 서명이 그 인증서의 공개키로 풀리는지 봅니다.

RFC 8446 4.4.2.4절은 클라이언트가 빈 Certificate를 보냈을 때 서버가 인증서 없이 계속할 수도(MAY) 있고 `certificate_required` 경고로 끊을 수도 있다고 적습니다. 장치 인증이 목적인 서버는 끊는 쪽을 고릅니다.

### 개인키는 전선 위로 나가지 않는다

mTLS가 IoT 장치의 신원 확인에 많이 쓰이는 이유가 여기 있습니다. 비밀번호나 API 키(bearer token)는 **그 값 자체를 보내서** 증명합니다. 한 번 새면 누구나 그 값을 다시 보낼 수 있습니다. 인증서 방식에서 보내는 것은 공개 문서인 인증서와, **이번 연결의 핸드셰이크 기록에 대한 서명**뿐입니다. 서명은 연결마다 내용이 달라서 녹화해 둬도 다른 연결에서 쓸 수 없고, 서명을 만든 개인키는 장치 밖으로 나간 적이 없습니다.

AWS IoT Core의 X.509 클라이언트 인증서 문서도 같은 점을 듭니다. 개인키가 장치를 떠나지 않으므로 사용자 이름·비밀번호나 bearer token보다 강한 인증이라고 설명합니다.

### AWS IoT Core가 인증서를 다루는 흐름

AWS IoT Core 문서에 적힌 흐름을 순서대로 정리하면 이렇습니다.

1. **TLS 단계:** 장치가 붙으면 AWS IoT가 클라이언트 인증서를 요구하고, 인증서가 등록되어 있는지, 상태가 무엇인지, 어느 AWS 계정의 것인지 레지스트리에서 확인합니다. 그리고 개인키를 가지고 있는지 증명을 요구합니다(앞의 CertificateVerify). 인증서는 **등록되어 있고, ACTIVE 상태이고, 만료되지 않았어야** 합니다. SNI는 일반 연결에서는 필수가 아니지만 강하게 권장되고, 몇몇 기능에서는 반드시 보내야 합니다(아래 SNI 절).
2. **권한 단계:** 인증서에 붙은 **IoT 정책**이 그 장치가 무엇을 할 수 있는지 정합니다. 어떤 접속 이름(client id)으로 붙을 수 있는지, 어떤 토픽에 게시·구독할 수 있는지가 여기서 정해집니다.

제 시스템에서는 장치 인증서의 정책을 이렇게 좁혀 두었습니다(이름은 일반화).

| 동작 | 허용 범위 |
|---|---|
| 접속 | 자기 장치 이름과 같은 client id로만 |
| 게시 | 자기 장치의 위치 토픽에만 |
| 구독·수신 | 자기 장치의 명령 토픽에만 |

TLS가 "이 장치가 그 인증서의 주인이 맞다"를 확인하고, 정책이 "그 인증서의 주인은 여기까지만 할 수 있다"를 정합니다. 인증과 권한이 다른 층에서 따로 이뤄지는 구조입니다. 그래서 장치 하나의 키가 새어도 **MQTT 쪽** 접근은 그 장치의 client id와 토픽 안으로 좁혀집니다. 다만 이것이 피해의 전부는 아닙니다. 바로 다음에 볼 것처럼 같은 인증서로 임시 AWS 권한도 받게 해 두었다면, 그 IAM 역할이 가진 권한까지 피해 범위에 들어갑니다.

인증서를 막는 방법도 두 단계입니다. AWS 문서에 따르면 AWS IoT는 연결을 인증할 때 인증서가 활성 상태인지 확인합니다. **비활성화(deactivate)**는 일시적으로 쓰지 못하게 하는 것이고 다시 활성화할 수 있습니다. **폐기(revoke)**는 이후의 모든 사용을 막습니다.

지원하는 키는 RSA 2048비트 이상과 ECC P-256·P-384·P-521이고, AWS IoT가 만들어 준 인증서는 2049년 12월 31일에 만료됩니다. 만료가 먼 만큼 AWS 문서는 주기적인 인증서 교체(rotation)를 권합니다.

### 같은 인증서로 임시 AWS 권한 받기

장치가 MQTT 말고 다른 AWS 서비스(영상 스트리밍 같은 것)도 불러야 할 때가 있습니다. 가장 쉬운 방법은 장치에 IAM 액세스 키를 넣는 것이지만, 그러면 장치마다 오래 사는 비밀이 하나씩 생깁니다. AWS IoT Core의 **자격 증명 공급자(credentials provider)**는 이 문제를 mTLS로 풉니다.

1. 장치가 자기 계정의 자격 증명 공급자 주소로 **같은 장치 인증서를 써서 mTLS HTTPS 요청**을 보냅니다. 경로에는 미리 만들어 둔 **역할 별칭(role alias)** 이름이 들어갑니다.
2. 공급자는 인증서가 유효한지 확인하고(유효하지 않으면 예외를 돌려줌), 그 인증서에 붙은 IoT 정책이 해당 역할 별칭에 대해 `iot:AssumeRoleWithCertificate`를 허용하는지 봅니다. 인증서가 유효하기만 하면 역할을 맡을 수 있는 것이 아닙니다.
3. 역할 별칭이 가리키는 IAM 역할은 자격 증명 공급자 서비스(`credentials.iot.amazonaws.com`)를 신뢰하도록 설정되어 있어야 합니다. 조건이 맞으면 공급자가 그 역할을 대신 맡아 **임시 자격 증명**(accessKeyId, secretAccessKey, sessionToken, expiration)을 돌려줍니다.
4. 유효 시간은 기본 3600초(1시간)이고 900~43200초 사이로 정할 수 있습니다. 단, 역할 별칭이 참조하는 IAM 역할의 최대 세션 시간을 넘을 수 없습니다.

AWS 문서는 이 방식으로 장치에 AWS 액세스 키를 저장할 필요가 없어진다고 설명합니다. 장치가 오래 보관하는 비밀은 여전히 개인키 하나입니다. 다만 받아 온 secretAccessKey와 sessionToken도 유효 시간 동안은 비밀이므로 같은 원칙으로 다뤄야 합니다. 인증서를 비활성화하면 그 인증서로는 새 임시 권한을 받지 못합니다. 이미 받아 둔 임시 권한이 만료 전에 어떻게 되는지는 이 글에서 따로 확인하지 않았습니다.

### 브라우저는 다르게 증명한다

반대로 브라우저 화면은 장치 인증서가 없습니다. 제 시스템에서 브라우저가 쓴 길은 AWS IoT Core 문서의 포트·프로토콜 표 중 **MQTT over WebSocket(WSS), 443, SigV4 인증** 줄에 해당합니다. 여기서 TLS는 **서버만** 확인합니다. 브라우저의 신원은 로그인으로 받은 임시 권한으로 WebSocket 주소에 SigV4 서명을 붙여서, 즉 TLS 위 응용 층에서 증명합니다.

| | 장치 | 브라우저 |
|---|---|---|
| TLS | mTLS (서버도 장치도 인증서) | 서버만 인증서 |
| 신원 증명 | TLS 핸드셰이크 안에서 개인키 서명 | TLS 위에서 SigV4 서명 URL |
| 가진 비밀 | 장치 개인키 (오래 씀) | 로그인으로 받은 임시 권한 (짧게 씀) |

둘 다 "TLS를 쓴다"지만, TLS가 신원 확인까지 맡느냐, 암호화와 서버 확인만 맡고 신원은 그 위에서 따로 하느냐가 다릅니다. 이 차이가 다음에 볼 가로채기 프록시 문제에서 결과를 가릅니다.

### 개인키를 다루는 법

mTLS에서는 개인키가 곧 장치의 신분입니다. 제 시스템에서는 이렇게 다뤘습니다.

- 개인키와 인증서 파일은 **저장소(git)에서 제외**하고, 파일은 `600`(나만 읽고 쓰기), 폴더는 `700`으로 둡니다.
- AWS도 개인키를 다시 내줄 수 없습니다. 개인키는 만든 쪽에만 있기 때문입니다. **잃어버리면 새 인증서를 발급하고 옛 인증서는 폐기**합니다. 새 PC로 옮길 때도 같은 원칙으로, 옮기기보다 새로 발급하고 옛 것을 폐기하는 쪽을 택했습니다.
- 로그나 보고서에 인증서·키 내용을 찍지 않습니다. 이 글의 실험도 키는 임시 폴더에만 만들고 글에는 만드는 명령만 적었습니다.

## SNI와 ALPN: 한 주소에서 여러 서비스를 가르기

### SNI: 어느 이름으로 왔나

한 IP에 웹사이트가 여럿 있으면, 서버는 TLS 핸드셰이크 때 어느 사이트의 인증서를 내야 할지 알아야 합니다. 그런데 HTTP의 `Host` 헤더는 TLS가 끝난 뒤에야 옵니다. 그래서 ClientHello에 이름을 미리 적어 보내는 확장이 **SNI**입니다. RFC 6066은 SNI가 한 네트워크 주소에서 여러 "가상" 서버를 운영할 수 있게 하려고 있다고 설명하고, 이름 자리에 IP 주소 리터럴은 넣을 수 없다고 정합니다. RFC 8446 9.2절은 서버가 server_name을 요구할 수 있다(MAY)고 적습니다.

AWS IoT Core의 Transport security 문서는 SNI 전송이 필수는 아니지만 강하게 권장한다고 적고, 다중 계정 등록·사용자 지정 도메인·VPC 엔드포인트·TLS 정책 설정 같은 기능을 쓰려면 SNI에 전체 엔드포인트 주소를 넣어야 한다고 적습니다. 자격 증명 공급자 문서도 SNI에 전체 엔드포인트 주소를 넣으라고 적습니다. AWS 문서 중 X.509 클라이언트 인증서 페이지는 SNI를 요구한다(requires)고 쓰고 있어 페이지마다 표현이 조금 다릅니다. 그래서 장치에서는 늘 정확한 엔드포인트 이름으로 SNI를 보내는 쪽이 안전합니다.

Python에서는 이 글처럼 `create_default_context()`로 인증서 검증과 `check_hostname`을 켜 둔 경우, `wrap_socket(..., server_hostname="이름")` 하나가 두 일을 같이 합니다. 그 이름을 **SNI로 보내고**, 받은 인증서를 **그 이름과 대조**합니다. `check_hostname`이 꺼져 있으면 이름 대조는 하지 않습니다. 이 글의 실험에서 실제 접속 주소는 `127.0.0.1`로 두고 `server_hostname`만 바꿔 이름 확인을 시험한 것도 이 때문입니다.

### ALPN: TLS 위에서 무엇을 말할 건가

**ALPN**(RFC 7301)은 TLS 핸드셰이크 안에서 "그 위에 어떤 응용 프로토콜을 올릴지"를 정합니다. 클라이언트가 선호 순으로 목록을 보내면 서버가 **하나를** 고릅니다. 웹에서는 HTTP/2(`h2`)와 HTTP/1.1을 고르는 데 씁니다. 겹치는 것이 없으면 서버가 `no_application_protocol` 경고로 끊는 것이 명세상 동작입니다.

다만 실제 서버는 모르는 ALPN을 그냥 무시하기도 합니다. example.com에 `mqtt`라는 ALPN만 보내 봤더니 이렇게 나왔습니다.

```bash
echo | openssl s_client -connect example.com:443 -servername example.com -alpn mqtt
```

```text
New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
No ALPN negotiated
```

연결은 그대로 맺어지고 ALPN만 정해지지 않았습니다. 서버마다 다르게 처리하므로 "ALPN이 안 맞으면 반드시 끊긴다"고 기대하면 안 됩니다.

### AWS IoT Core: 443 하나로 MQTT와 HTTPS 가르기

AWS IoT Core는 같은 엔드포인트에서 포트, 인증 방식, ALPN 조합으로 프로토콜을 가릅니다. "Device communication protocols" 문서의 표에서 이 글과 관련된 줄만 옮기면 이렇습니다. 이 표는 데이터 통신 엔드포인트 기준이고, 앞에서 본 자격 증명 공급자는 별도의 엔드포인트를 씁니다.

| 프로토콜 | 인증 | 포트 | ALPN |
|---|---|---|---|
| MQTT | X.509 클라이언트 인증서 | 8883 | 필요 없음 |
| MQTT | X.509 클라이언트 인증서 | 443 | `x-amzn-mqtt-ca` |
| MQTT | 사용자 지정 인증 | 443 | `mqtt` |
| MQTT over WSS | SigV4 | 443 | 필요 없음 |
| HTTPS | X.509 클라이언트 인증서 | 8443 | 필요 없음 |
| HTTPS | X.509 클라이언트 인증서 | 443 | `x-amzn-http-ca` |
| HTTPS | SigV4 | 443 | 필요 없음 |

이 표가 실제로 쓸모 있는 장면은 **8883이 막힌 망**입니다. 회사나 공공 Wi-Fi는 443(HTTPS)만 열어 두고 나머지 포트를 막는 경우가 많습니다. 그러면 인증서를 쓰는 장치는 443으로 붙되, ALPN에 `x-amzn-mqtt-ca`를 넣어 "이 443 연결은 HTTPS가 아니라 인증서 기반 MQTT"라고 알려야 합니다. 문서는 443의 클라이언트 인증서 방식에 ALPN이 필요한 것이 기본 엔드포인트 설정 기준이라고 덧붙입니다(도메인 설정을 따로 하면 달라질 수 있음).

### 8883이 막혔을 때와 TLS가 가로채일 때는 다른 문제

이 표로 해결되는 것은 "포트가 막힌" 경우입니다. 443이 열려 있어도 그 443을 **가로채는** 망이라면 이야기가 달라집니다. 바로 다음 절의 주제입니다.

## TLS 가로채기: 사내 프록시가 하는 일과 mTLS가 깨지는 이유

### 가로채기의 동작

회사 망에는 보안 검사를 위해 암호화된 연결을 열어 보는 프록시가 있는 경우가 있습니다. 동작은 한 문장으로 요약됩니다. **연결을 중간에서 둘로 끊고, 각각 따로 TLS를 맺습니다.** PC 쪽에는 **사내 루트 CA**로 서명한 "그 사이트인 척" 인증서를 즉석에서 만들어 내고, 진짜 서버 쪽에는 프록시가 클라이언트가 되어 따로 붙습니다. 두 연결 사이, 프록시 안에서는 평문이 보입니다.

회사 PC의 OS 신뢰 저장소에는 사내 루트 CA가 깔려 있어 브라우저는 문제없이 붙습니다. 자기 신뢰 저장소를 따로 들고 다니는 프로그램(AWS CLI의 Python 묶음, Node 등)은 사내 CA를 모르니 `CERTIFICATE_VERIFY_FAILED`를 냅니다. 신뢰 저장소의 차이와 CLI 쪽 해결 과정은 [AWS CLI CERTIFICATE_VERIFY_FAILED 해결기]({% post_url 2026-10-14-aws-cli-certificate-verify-failed %})에서 자세히 썼으니, 이 글은 그 글에 없던 mTLS 쪽에 집중합니다.

<figure class="diagram">
{% include figures/tls-basics/intercept-vs-mtls.svg %}
<figcaption>장치 개인키나 서명 권한이 없는 가로채기 프록시가 연결을 둘로 끊는 경우. 서버만 확인하는 TLS는 PC가 사내 CA를 믿으면 통과하지만, mTLS에서는 서버와 TLS를 맺는 프록시가 장치 개인키로 만든 서명을 낼 수 없어 연결이 끊긴다</figcaption>
</figure>

### 왜 CA를 더하고, 검증을 끄지 않나

옛 사내 PC에서는 사내 루트 CA를 각 프로그램에 알려 주는 것으로 풀었습니다. AWS CLI의 `ca_bundle`은 기본 묶음을 **대신하고**, Node의 `NODE_EXTRA_CA_CERTS`는 기본 목록에 **더한다**는 차이만 짚어 둡니다(자세한 내용은 위 CLI 글). `--no-verify-ssl`, `strict-ssl=false`, Python의 `CERT_NONE` 같은 검증 끄기는 쓰지 않았습니다. 세 약속 중 "인증"을 버려서, 사내 프록시뿐 아니라 그 길에 끼어든 아무나의 인증서를 받아들이게 되기 때문입니다.

### 왜 mTLS는 깨지나

여기서 말하는 프록시는 **장치의 개인키나 서명 권한을 받지 않은 채 TLS를 두 연결로 끊는** 일반적인 가로채기 프록시입니다. 장치 키를 위임받은 TLS 종단, 서버가 프록시 자체의 신원을 믿도록 따로 설계한 게이트웨이, TLS를 열지 않고 바이트만 넘기는 터널은 이 설명에 들어가지 않습니다.

이런 프록시 앞에서 서버만 확인하는 TLS는 PC가 사내 CA를 믿기만 하면 통과합니다. 서버 쪽에서 보면 프록시는 "평범한 클라이언트 하나"일 뿐이니까요. mTLS는 다릅니다.

1. 진짜 서버가 CertificateRequest로 클라이언트 인증서를 요구합니다.
2. 그런데 진짜 서버와 TLS를 맺는 쪽은 장치가 아니라 **프록시**입니다.
3. 이 프록시에는 장치의 개인키가 없습니다. 장치 인증서(공개 문서)를 어떻게든 옮겨 보낸다 해도, CertificateVerify는 **프록시와 서버 사이 핸드셰이크 기록**에 대한 서명이어야 합니다. 장치가 서명한 것은 장치와 프록시 사이 기록이라 쓸 수 없고, 새 서명은 개인키 없이 만들 수 없습니다.
4. 서버는 인증서 없이 온 클라이언트를 끊습니다.

이것은 버그가 아니라 mTLS가 막으려는 바로 그 상황입니다. 가로채기 프록시는 구조상 "중간자"이고, mTLS는 중간자가 장치인 척하지 못하게 하는 장치입니다. 그래서 해결은 TLS 설정이 아니라 **길**에서 해야 합니다. 그 주소를 가로채기 예외로 두거나, 프록시 없는 길로 직접 연결하는 것입니다. 제 경우에는 프록시가 없는 Mac 환경으로 옮긴 뒤 직접 연결로 장치 시뮬레이터의 mTLS가 통과했습니다.

### 그때 8883이 멀쩡했던 이유

옛 사내 PC에서는 443 연결은 인증서 오류가 났는데 8883 MQTT 연결은 영향이 없었습니다. 그 환경의 프록시가 **443만 열어 보고 8883은 열어 보지 않았기** 때문입니다. 이것은 그 망의 설정이지 일반 법칙이 아닙니다. 8883을 아예 막는 망도 있고, 모든 포트를 검사하는 망도 있습니다. "8883은 가로채기에 안전하다"고 기대하면 안 됩니다.

영상 쪽도 같은 위험을 짐작할 수 있습니다. 이 시스템에서 UDP가 막히면 대체 경로는 클라이언트와 TURN 서버 사이의 TLS over TCP 443이고, 미디어는 그 안에서도 DTLS-SRTP로 따로 보호됩니다([TURN과 ICE]({% post_url 2026-11-10-webrtc-turn-ice %}) 참고). 이 443이 가로채진다면 클라이언트와 TURN 사이 구간이 영향을 받을 수 있습니다. 다만 저는 이것을 실제로 시험하지 않았으므로 가능성으로만 적어 둡니다.

## 자주 보는 오류와 원인

아래 문구는 Python `ssl`(OpenSSL)에서 이 글의 실험으로 직접 본 것입니다. 원인을 하나로 정할 수 있는 것과, 여러 원인이 같은 모양으로 보이는 것을 나눠 적습니다.

| 보이는 문구 | 확인하는 것 | 흔한 원인 |
|---|---|---|
| `unable to get local issuer certificate` | 체인이 믿는 루트까지 이어지나 | 신뢰 저장소에 그 루트가 없음(사내 CA, 자체 CA), 서버가 중간 인증서를 안 보냄 |
| `Hostname mismatch, certificate is not valid for '…'` | SAN에 접속 이름이 있나 | 다른 이름으로 접속, IP로 접속, 인증서에 SAN이 없음 |
| `certificate has expired` | 현재 시각이 유효 기간 안인가 | 정말 만료, 또는 **장치 시계가 틀림** |
| `TLSV13_ALERT_CERTIFICATE_REQUIRED` | (서버가 보낸 경고) 클라이언트 인증서가 왔나 | mTLS 서버에 인증서 없이 접속(가로채기 프록시가 중간에 있으면 프록시가 이 경고를 받음) |
| `TLSV1_ALERT_UNKNOWN_CA` | (상대가 보낸 경고) 내 인증서의 CA를 상대가 믿나 | 상대가 모르는 CA로 발급된 인증서를 냄 |
| `HANDSHAKE_FAILURE` | 버전·암호·인증 조건이 맞나 | 공통 버전·암호 묶음이 없음, TLS 1.2 mTLS에서 인증서를 안 냄 등 여러 원인이 같은 모양 |
| `KEY_VALUES_MISMATCH` | (연결 전, 내 쪽) 인증서와 개인키가 짝인가 | 다른 장치의 키 파일, 재발급 뒤 옛 키를 씀 |

`ALERT`가 들어 있는 문구는 **상대가 보낸 경고**라는 점을 기억하면 방향을 잡기 쉽습니다. 내 쪽에서 상대를 거절했는지(`verify failed` 계열), 상대가 나를 거절했는지(`ALERT` 계열)가 갈립니다.

AWS IoT Core에서는 TLS가 인증서를 확인한 다음 정책이 권한을 따로 정하므로, TLS를 통과한 뒤 권한 단계에서 거절될 수도 있습니다. 예를 들어 인증서는 맞지만 정책이 그 client id의 접속을 허용하지 않는 경우입니다. 이 경우는 이 글에서 재현하지 않았고 클라이언트에 어떤 모양으로 보이는지도 확인하지 않았지만, TLS 문제와 권한 문제를 나눠서 볼 필요가 있다는 점만 적어 둡니다.

## 직접 해 보기: localhost에서 TLS와 mTLS 재현

AWS에 접속하지 않고, 내 컴퓨터 안에서 실험용 CA를 만들어 위의 상황을 재현해 봤습니다. 서버, 클라이언트, 가로채기 프록시를 전부 Python 표준 `ssl` 모듈로 새로 짰습니다. Python 3.10.13(OpenSSL 3.1.4)과 Python 3.14.10(OpenSSL 4.1.0) 두 환경에서 같은 결과가 나왔고, 오류 이름만 버전에 따라 조금 달랐습니다. 본문에는 결과를 가르는 설정 몇 줄과 출력만 옮기고, 스크립트 다섯 개의 전문은 이 절 끝에 접어 두었습니다.

### 실행 전제와 방법 (macOS)

- **OpenSSL:** 인증서 생성 스크립트는 Homebrew의 OpenSSL 4.1.0으로 확인했습니다. 먼저 `openssl version`을 봅니다. `LibreSSL …`로 나오면 macOS 기본 `/usr/bin/openssl`이고, 이 스크립트는 LibreSSL 3.3.6에서 `ca.srl: No such file or directory`로 실패했습니다. 그래서 스크립트가 처음에 버전을 확인하고 OpenSSL이 아니면 멈춥니다.
- **쉘:** 스크립트는 파일로 저장한 뒤 `sh 파일이름`으로 실행합니다. 내용을 zsh 창에 그대로 붙여 넣으면 `$EC` 변수가 sh처럼 공백에서 나뉘지 않아 실패합니다. 첫 줄의 `#!/bin/sh`는 붙여 넣은 쉘을 바꿔 주지 않습니다.
- **Python:** `python3`가 3.10 이상이어야 합니다. 포트 7443, 7883, 8443, 8883, 9443이 비어 있어야 합니다.
- **폴더:** 스크립트 다섯 개는 한 폴더에 두고, 인증서는 빈 임시 폴더에 만듭니다. 실험이 끝나면 임시 폴더째 지웁니다.

```sh
openssl version                          # OpenSSL 4.1.0에서 확인 (LibreSSL이면 Homebrew openssl을 PATH 앞에)
cd "$(mktemp -d)"                        # 인증서·개인키는 빈 임시 폴더에
sh "<스크립트 폴더>/make_certs.sh"
sh "<스크립트 폴더>/run_all.sh" "<스크립트 폴더>"
```

`run_all.sh`는 **출력을 눈으로 보는 관찰용**이지 자동 합격 테스트가 아닙니다. 실패를 재현하는 경우에도 클라이언트는 오류 문구를 찍고 정상 종료합니다. 대신 인자가 없거나, 스크립트·인증서 파일이 없거나, 서버가 5초 안에 듣기 시작하지 않으면 종료 코드 1로 멈춥니다. 경로는 모두 따옴표로 감싸 두어, 공백이 들어간 폴더에서 돌려도 같은 결과가 나오는 것을 확인했습니다.

### 만든 인증서

| 파일 | 역할 |
|---|---|
| `ca` | 서버와 장치를 둘 다 서명하는 "우리" CA |
| `server` | `localhost`용 서버 인증서(SAN에 `localhost`, `127.0.0.1`) |
| `device` | 장치 인증서 `device-001`(클라이언트 인증 용도) |
| `other-ca`, `rogue` | 서버가 모르는 CA와 그 CA가 발급한 장치 인증서 |
| `proxy-ca`, `proxy-localhost` | 가로채기 프록시가 쓰는 CA와 가짜 `localhost` 인증서 |
| `expired.crt` | 유효 기간이 이미 지난 서버 인증서 |

유효 기간은 7일로 짧게 두었고, 개인키가 다른 사용자에게 읽히지 않게 `umask 077`로 만듭니다.

> **확장을 빠뜨리면 Python 3.13+에서 막힙니다.** 처음에는 CA에 확장을 따로 주지 않고 만들었는데, Python 3.14에서 `CA cert does not include key usage extension`, `Missing Authority Key Identifier`로 검증이 실패했습니다. Python 3.13부터 `create_default_context()`가 엄격한 X.509 검사(`VERIFY_X509_STRICT`)를 기본으로 켜기 때문입니다. 그래서 CA에는 basicConstraints·keyUsage·subjectKeyIdentifier를, 말단 인증서에는 authorityKeyIdentifier 등을 명시했습니다. 직접 만든 사설 CA가 새 Python에서 갑자기 거절된다면 이 확장부터 확인해 볼 만합니다.
{: .prompt-tip }

### 결과를 가르는 설정 몇 줄

세 스크립트에서 TLS 동작을 정하는 줄만 모으면 이렇습니다.

```python
# 서버 (tls_server.py 중): 포트 8883은 --mtls로 띄운다
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(certfile="server.crt", keyfile="server.key")  # 서버의 신분증과 개인키
if mtls:
    ctx.verify_mode = ssl.CERT_REQUIRED          # 클라이언트 인증서를 반드시 요구
    ctx.load_verify_locations(cafile="ca.crt")   # 이 CA가 서명한 인증서만 받는다

# 클라이언트 (tls_client.py 중)
ctx = ssl.create_default_context(cafile="ca.crt")       # 검증 + 호스트 이름 확인이 켜진 상태
if cert:
    ctx.load_cert_chain(certfile=cert, keyfile=key)     # mTLS: 내 인증서와 개인키
tls = ctx.wrap_socket(raw, server_hostname=host)        # SNI로 보내고, 이름 확인 대상으로도 쓴다

# 가로채기 프록시 (intercept_proxy.py 중)
front = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)         # 클라이언트 쪽: 서버인 척
front.load_cert_chain("proxy-localhost.crt", "proxy-localhost.key")  # 클라이언트 인증서는 요청하지 않는다
back = ssl.create_default_context(cafile="ca.crt")      # 서버 쪽: 클라이언트인 척, 장치 인증서·개인키는 없다
```

- **서버를 mTLS로 바꾸는 데는 두 줄이면 됩니다.** `verify_mode = CERT_REQUIRED`로 클라이언트 인증서를 요구하고, `load_verify_locations`로 어떤 CA를 믿을지 정합니다. Python 문서도 서버 쪽 `CERT_REQUIRED`는 클라이언트 인증서 인증을 필수로 만들며, 이때 `load_verify_locations`로 CA를 알려 줘야 한다고 설명합니다.
- **클라이언트는 `ssl.create_default_context()`가 중요합니다.** Python 문서에 따르면 이 함수는 `verify_mode`를 `CERT_REQUIRED`로, `check_hostname`을 켠 상태로 돌려줍니다. 직접 `SSLContext`를 만들고 이 둘을 빠뜨리는 실수를 막아 줍니다. 실험에서는 실제 주소 `127.0.0.1`로 접속하면서 `--host`로 "접속하려는 이름"만 바꿔 이름 확인을 시험합니다.
- **프록시는 연결을 둘로 끊습니다.** 실제 사내 프록시는 사이트마다 인증서를 즉석에서 만들지만, 실험에서는 `localhost` 하나만 흉내 내면 되니 미리 만든 가짜 인증서 하나를 씁니다. 이 프록시 코드는 한 줄 응답과 인증 실패를 관찰하려는 **최소 실험 코드**라서 종료 경쟁, half-close, 타임아웃은 다루지 않습니다. 일반 용도의 프록시로 쓰면 안 됩니다.

포트 8883은 MQTTS 관례를 따라 mTLS 서버에 붙였을 뿐, 이 실험 서버는 MQTT가 아니라 한 줄 인사만 보냅니다.

### A. 서버 확인: 체인, 이름, 유효 기간

| 경우 | 클라이언트가 본 것 | 서버 로그 |
|---|---|---|
| A1 정상 | `connected: TLSv1.3 TLS_AES_256_GCM_SHA384 alpn=mqtt` | `OK ... alpn=mqtt client=(no client cert)` |
| A2 서버 CA를 모름 | `verify failed: unable to get local issuer certificate` | `TLSV1_ALERT_UNKNOWN_CA` (클라이언트가 보낸 경고) |
| A3 다른 이름으로 접속 | `verify failed: Hostname mismatch, certificate is not valid for 'device.example'.` | `BAD_CERTIFICATE` 경고 |
| A4 만료된 서버 인증서 | `verify failed: certificate has expired` | `CERTIFICATE_EXPIRED` 경고 |

A2는 사내 프록시 앞에서 CLI가 낸 오류와 같은 문구입니다. 원인도 같습니다. 클라이언트가 그 체인의 루트를 모릅니다. A3에서는 체인이 완벽해도 이름이 다르면 거절됩니다. 서버 로그를 보면 클라이언트가 거절하면서 **이유를 담은 경고를 서버에 보낸다**는 것도 보입니다.

### B. mTLS: 장치 인증서

가장 배울 것이 많은 B1의 출력입니다.

```text
## B1 mTLS no cert
connected: TLSv1.3 TLS_AES_256_GCM_SHA384 alpn=mqtt
failed: SSLError TLSV13_ALERT_CERTIFICATE_REQUIRED
```

| 경우 | 클라이언트가 본 것 | 서버 로그 |
|---|---|---|
| B1 인증서 없이 (TLS 1.3) | **일단 `connected`**, 첫 읽기에서 `CERTIFICATE_REQUIRED` | `PEER_DID_NOT_RETURN_A_CERTIFICATE` |
| B1b 인증서 없이 (TLS 1.2) | 핸드셰이크 중에 `SSLV3_ALERT_HANDSHAKE_FAILURE` | `PEER_DID_NOT_RETURN_A_CERTIFICATE` |
| B2 우리 CA의 장치 인증서 | 연결, 서버가 `hello device-001` | `OK ... client=device-001` |
| B3 모르는 CA의 인증서 | 일단 `connected`, 첫 읽기에서 `TLSV1_ALERT_UNKNOWN_CA` | `CERTIFICATE_VERIFY_FAILED` |
| B4 인증서와 다른 개인키 | 접속 전에 내 쪽 라이브러리가 `KEY_VALUES_MISMATCH`로 거절 | (연결 없음) |

Python 3.14에서는 B1b가 `TLS_ALERT_HANDSHAKE_FAILURE`로 찍혔습니다. `SSLV3_`라는 접두어가 붙어도 SSLv3로 협상했다는 뜻은 아니고, 오류 이름의 접두어가 라이브러리 버전에 따라 다를 뿐입니다.

**B1과 B3**에서 클라이언트는 `connected`를 찍은 다음에 실패했습니다. 서버가 인증서를 늦게 확인해서가 아닙니다. 서버는 클라이언트의 Certificate 메시지를 받으면 그 자리에서 체인을 검증하고, 비어 있거나 모르는 CA라면 거절 경고를 보냅니다. 차이는 **클라이언트가 실패를 알게 되는 시점**에 있습니다. TLS 1.3 그림을 다시 보면, 클라이언트의 Certificate·CertificateVerify·Finished는 한 묶음으로 나가고, 그 뒤에 핸드셰이크를 마치려고 서버가 더 보내야 하는 메시지는 없습니다. 그래서 클라이언트는 자기 Finished를 보낸 뒤 서버의 클라이언트 인증 성공 확인을 기다리지 않고 핸드셰이크를 마칠 수 있습니다. 서버가 보낸 거절 경고는 그다음 읽기·쓰기에서 받게 되고, 이 실험처럼 `connected` 뒤 실패로 보일 수 있습니다. TLS 1.2(B1b)에서는 클라이언트가 서버의 Finished까지 받아야 핸드셰이크를 마치는데, 서버는 클라이언트 인증서를 거절하면 Finished를 보내지 않으므로 핸드셰이크 도중에 실패가 드러납니다.

실무로 옮기면 이렇습니다. **TLS 1.3에서 장치 인증서 문제는 "접속 성공 직후 끊김"으로 나타날 수 있습니다.** "연결은 된다"는 로그만 보고 인증서는 괜찮다고 판단하면 안 됩니다.

B4는 연결조차 하지 않았습니다. `load_cert_chain`이 인증서의 공개키와 개인키가 짝인지 먼저 확인하기 때문입니다. 인증서를 재발급하고 옛 키 파일을 그대로 둔 경우가 이 모양입니다.

### C. 가로채기 프록시

프록시 CA를 믿는 클라이언트로 붙은 C2(서버만 확인하는 TLS)와 C3(뒤쪽 서버가 mTLS)의 출력, 그리고 프록시 로그입니다.

```text
## C2 proxy, proxy CA trusted
connected: TLSv1.3 TLS_AES_256_GCM_SHA384 alpn=None
server says: hello (no client cert)
## C3 proxy + mTLS
connected: TLSv1.3 TLS_AES_256_GCM_SHA384 alpn=None
server says: (connection closed)
### p-tls.log
proxy saw plaintext: b'hello (no client cert)\n'
### p-mtls.log
proxy relay error: TLSV13_ALERT_CERTIFICATE_REQUIRED
```

| 경우 | 클라이언트가 본 것 | 프록시가 본 것 |
|---|---|---|
| C1 프록시 CA를 모름 | `unable to get local issuer certificate` | 클라이언트가 가짜 인증서를 거절(`UNKNOWN_CA`) |
| C2 프록시 CA를 믿음 | 정상 연결, 인사도 받음 | **서버의 응답을 평문으로 봄** |
| C3 프록시 CA를 믿음 + mTLS 서버 | `connected` 뒤 연결이 그냥 닫힘 | 서버에게서 `CERTIFICATE_REQUIRED`를 받음 |

C1은 사내 CA를 모르는 프로그램, C2는 사내 CA를 신뢰 목록에 넣은 프로그램입니다. C2에서 연결은 "정상"이지만 프록시는 대화 내용을 다 봅니다. 사내 CA를 믿는다는 것은 그 회사의 프록시에게 이 권한을 준다는 뜻입니다.

C3에서 장치에는 인증서와 개인키가 있었습니다. 하지만 이 실험 프록시는 앞쪽 연결에서 클라이언트 인증서를 요청하지 않으므로 장치는 인증서를 보내지 않았고, 개인키는 어떤 경우에도 TLS로 전달되지 않습니다. 뒤쪽에서 진짜 mTLS 서버와 연결하는 프록시에는 장치 자격이 없었고, 서버는 `certificate_required`로 끊었습니다. 즉 이 실험이 재현한 것은 **"앞쪽 일반 TLS는 성공했지만, 뒤쪽 mTLS에 낼 클라이언트 인증서가 없어 실패"**하는 장면입니다. 프록시가 장치 인증서를 받아 옮기더라도 CertificateVerify는 다시 쓸 수 없다는 점은 앞의 원리 설명에서 나온 결론이고, 이 실험에서 따로 재현하지는 않았습니다. 이 실험의 C3에서는 장치 쪽에서 이유를 알 수 없는 "연결 직후 닫힘"으로만 보입니다.

C2와 C3에서 `alpn=None`이 찍힌 것은 **제가 만든 실험 프록시**가 ALPN을 설정하지 않았기 때문입니다. 실제 프록시가 ALPN을 어떻게 다루는지에 대한 일반적인 결론은 아닙니다. 다만 "중간에 무언가 끼어 있으면 협상 결과가 달라질 수 있다"는 점은 기억해 둘 만합니다.

### paho-mqtt에서의 모양

실제 장치 코드에서는 MQTT 라이브러리가 이 `SSLContext` 설정을 대신해 줍니다. paho-mqtt 2.1의 `tls_set()`은 인자로 `ca_certs`, `certfile`, `keyfile`, `cert_reqs`, `tls_version`, `ciphers`, `keyfile_password`, `alpn_protocols`를 받습니다. 모양은 이렇습니다.

```python
import ssl
import paho.mqtt.client as mqtt

client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="device-001")
client.tls_set(
    ca_certs="AmazonRootCA1.pem",        # 서버를 확인할 루트 CA
    certfile="device.crt",               # 장치 인증서
    keyfile="device.key",                # 장치 개인키 (권한 600)
    cert_reqs=ssl.CERT_REQUIRED,         # 서버 인증서 검증 (기본값)
)
client.connect("<your-endpoint>", 8883, keepalive=30)

# 8883이 막힌 망에서 443으로 붙을 때
# client.tls_set(..., alpn_protocols=["x-amzn-mqtt-ca"])
# client.connect("<your-endpoint>", 443, keepalive=30)
```

이 코드로 AWS에 접속해 보지는 않았습니다. 대신 같은 `tls_set()` 호출(CA만 실험용으로 바꾸고 ALPN `mqtt`)로 앞의 localhost mTLS 서버에 붙여 봤고, 서버 로그에 `OK TLSv1.3 TLS_AES_256_GCM_SHA384 alpn=mqtt client=device-001`이 찍혔습니다. 즉 **TLS와 클라이언트 인증서까지는 이 호출로 맺어지는 것**을 확인했습니다. 실험 서버는 MQTT 브로커가 아니라서 그 뒤 MQTT 단계는 연결 끊김으로 끝났고, MQTT 동작은 시험하지 않았습니다.

### 전체 실험 스크립트

앞의 출력은 아래 다섯 파일을 그대로 돌린 결과입니다. 실행 방법은 위의 "실행 전제와 방법"을 따릅니다.

<details markdown="1">
<summary>전체 실험 스크립트 펼치기 (make_certs.sh, tls_server.py, tls_client.py, intercept_proxy.py, run_all.sh)</summary>

**make_certs.sh**

```sh
#!/bin/sh
# make_certs.sh: 실험용 CA와 인증서를 지금 폴더에 만든다 (7일짜리, 실험 뒤 폴더째 지운다)
# 실행: sh make_certs.sh  (zsh에 붙여 넣지 말 것. OpenSSL 4.1.0으로 확인, LibreSSL은 안 됨)
set -e
case "$(openssl version)" in
  OpenSSL*) ;;
  *) echo "OpenSSL이 필요합니다 (지금: $(openssl version)). Homebrew라면 brew install openssl 뒤 PATH 앞에 \$(brew --prefix openssl)/bin" >&2; exit 1 ;;
esac
umask 077                                   # 새 파일은 나만 읽고 쓰게 (개인키 보호)
EC="-newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes"

mkca() {   # 이름 CN
  openssl req -x509 $EC -keyout "$1.key" -out "$1.crt" -days 7 -subj "/CN=$2" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash"
}
mkleaf() { # 이름 CN 서명할CA 용도(serverAuth|clientAuth) [SAN]
  openssl req $EC -keyout "$1.key" -out "$1.csr" -subj "/CN=$2"
  {
    echo "basicConstraints=critical,CA:FALSE"
    echo "keyUsage=critical,digitalSignature"
    echo "extendedKeyUsage=$4"
    echo "subjectKeyIdentifier=hash"
    echo "authorityKeyIdentifier=keyid"
    [ -n "$5" ] && echo "subjectAltName=$5"
  } > "$1.ext"
  openssl x509 -req -in "$1.csr" -CA "$3.crt" -CAkey "$3.key" -days 7 -extfile "$1.ext" -out "$1.crt"
}

mkca ca "Lab Test CA"                       # 서버와 장치를 둘 다 서명하는 실험용 CA
mkleaf server localhost ca serverAuth "DNS:localhost,IP:127.0.0.1"
mkleaf device device-001 ca clientAuth      # 장치 인증서 (mTLS용)

mkca other-ca "Other CA"                    # 서버가 모르는 CA
mkleaf rogue rogue other-ca clientAuth

mkca proxy-ca "Corp Proxy CA (lab)"         # 가로채기 프록시의 CA
mkleaf proxy-localhost localhost proxy-ca serverAuth "DNS:localhost"

# 이미 만료된 서버 인증서 (같은 서버 키, 유효 기간만 과거)
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
  -not_before 20260101000000Z -not_after 20260201000000Z -extfile server.ext -out expired.crt
echo "made: $(ls *.crt | tr '\n' ' ')"
```

**tls_server.py**

```python
# tls_server.py: localhost에서 TLS(또는 mTLS) 에코 서버를 띄운다
# 사용: python3 tls_server.py <포트> [--mtls] [--cert 서버인증서]
import socket, ssl, sys

port = int(sys.argv[1])
mtls = "--mtls" in sys.argv
cert = sys.argv[sys.argv.index("--cert") + 1] if "--cert" in sys.argv else "server.crt"

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.minimum_version = ssl.TLSVersion.TLSv1_2
ctx.load_cert_chain(certfile=cert, keyfile="server.key")   # 서버의 신분증과 개인키
ctx.set_alpn_protocols(["mqtt", "http/1.1"])
if mtls:
    ctx.verify_mode = ssl.CERT_REQUIRED                    # 클라이언트 인증서를 반드시 요구
    ctx.load_verify_locations(cafile="ca.crt")             # 이 CA가 서명한 인증서만 받는다

with socket.create_server(("127.0.0.1", port)) as srv:
    print(f"listening on 127.0.0.1:{port} mtls={mtls}", flush=True)
    while True:
        raw, addr = srv.accept()
        try:
            with ctx.wrap_socket(raw, server_side=True) as tls:
                peer = tls.getpeercert()
                who = dict(x[0] for x in peer["subject"])["commonName"] if peer else "(no client cert)"
                print(f"OK {tls.version()} {tls.cipher()[0]} alpn={tls.selected_alpn_protocol()} client={who}", flush=True)
                tls.sendall(b"hello " + who.encode() + b"\n")
        except (ssl.SSLError, OSError) as e:
            print(f"FAIL {type(e).__name__}: {getattr(e, 'reason', None) or e}", flush=True)
```

**tls_client.py**

```python
# tls_client.py: 서버에 TLS로 붙어 본다
# 사용: python3 tls_client.py <포트> [--host 이름] [--ca CA파일] [--cert 인증서 --key 개인키] [--tls12]
import socket, ssl, sys

def arg(name, default=None):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default

port, host = int(sys.argv[1]), arg("--host", "localhost")
ctx = ssl.create_default_context(cafile=arg("--ca", "ca.crt"))  # 검증 켜짐 + 호스트 이름 확인 켜짐
ctx.set_alpn_protocols(["mqtt"])
if "--tls12" in sys.argv:
    ctx.maximum_version = ssl.TLSVersion.TLSv1_2                # 비교용: TLS 1.2까지만
if arg("--cert"):
    ctx.load_cert_chain(certfile=arg("--cert"), keyfile=arg("--key"))  # mTLS: 내 인증서와 개인키

try:
    with socket.create_connection(("127.0.0.1", port), timeout=5) as raw:
        with ctx.wrap_socket(raw, server_hostname=host) as tls:     # server_hostname = SNI + 이름 확인 대상
            print("connected:", tls.version(), tls.cipher()[0], "alpn=" + str(tls.selected_alpn_protocol()))
            print("server says:", tls.recv(100).decode().strip() or "(connection closed)")
except ssl.SSLCertVerificationError as e:
    print("verify failed:", e.verify_message)
except (ssl.SSLError, OSError) as e:
    print("failed:", type(e).__name__, getattr(e, "reason", None) or e)
```

**intercept_proxy.py**

```python
# intercept_proxy.py: 사내 TLS 가로채기 프록시를 흉내 낸다 (실험용)
# 클라이언트와는 프록시 CA로 서명한 '가짜 localhost 인증서'로 TLS를 맺고,
# 원래 서버와는 따로 TLS를 맺어 그 사이에서 평문을 옮긴다.
# 사용: python3 intercept_proxy.py <듣는 포트> <원래 서버 포트>
import socket, ssl, sys, threading

listen_port, upstream_port = int(sys.argv[1]), int(sys.argv[2])

front = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)              # 클라이언트 쪽: 프록시가 서버인 척
front.load_cert_chain("proxy-localhost.crt", "proxy-localhost.key")  # 클라이언트 인증서는 요청하지 않는다
back = ssl.create_default_context(cafile="ca.crt")           # 서버 쪽: 프록시가 클라이언트인 척
# back에는 장치 인증서·개인키가 없다 (장치 키나 서명 권한을 받지 않은 가로채기 프록시).
# 한 줄 응답과 인증 실패를 보려는 최소 실험 코드다. 종료 경쟁·half-close·타임아웃은 다루지 않는다.

def pump(src, dst):
    try:
        while data := src.recv(4096):
            print("proxy saw plaintext:", data[:40], flush=True)
            dst.sendall(data)
    except (ssl.SSLError, OSError) as e:
        print("proxy relay error:", getattr(e, "reason", None) or e, flush=True)
    finally:
        for s in (src, dst):
            try: s.close()
            except OSError: pass

with socket.create_server(("127.0.0.1", listen_port)) as srv:
    print(f"proxy 127.0.0.1:{listen_port} -> {upstream_port}", flush=True)
    while True:
        raw, _ = srv.accept()
        try:
            c = front.wrap_socket(raw, server_side=True)
            u = back.wrap_socket(socket.create_connection(("127.0.0.1", upstream_port)), server_hostname="localhost")
        except (ssl.SSLError, OSError) as e:
            print("proxy handshake error:", getattr(e, "reason", None) or e, flush=True)
            raw.close(); continue
        threading.Thread(target=pump, args=(c, u), daemon=True).start()
        threading.Thread(target=pump, args=(u, c), daemon=True).start()
```

**run_all.sh**

```sh
#!/bin/sh
# run_all.sh: 모든 경우를 한 번에 돌려 출력을 본다 (자동 합격 테스트가 아니라 관찰용).
# 실행: 인증서 폴더에서  sh run_all.sh "<스크립트 폴더>"
S=${1:?스크립트 폴더를 인자로 주세요}
for f in tls_server.py tls_client.py intercept_proxy.py; do
  [ -f "$S/$f" ] || { echo "없음: $S/$f" >&2; exit 1; }
done
for f in ca.crt server.crt server.key device.crt device.key rogue.crt rogue.key other-ca.crt \
         proxy-ca.crt proxy-localhost.crt proxy-localhost.key expired.crt; do
  [ -f "$f" ] || { echo "없음: $f (먼저 sh make_certs.sh)" >&2; exit 1; }
done
PIDS=""
trap 'kill $PIDS 2>/dev/null' EXIT INT TERM
start() { # 로그파일 스크립트 인자...
  log=$1; shift
  python3 -I "$@" > "$log" 2>&1 & PIDS="$PIDS $!"
}
start s-tls.log  "$S/tls_server.py" 8443
start s-mtls.log "$S/tls_server.py" 8883 --mtls
start s-exp.log  "$S/tls_server.py" 9443 --cert expired.crt
start p-tls.log  "$S/intercept_proxy.py" 7443 8443
start p-mtls.log "$S/intercept_proxy.py" 7883 8883
for log in s-tls.log s-mtls.log s-exp.log p-tls.log p-mtls.log; do   # 모두 듣기 시작했는지 확인
  n=0
  until grep -q -e '^listening' -e '^proxy 127' "$log" 2>/dev/null; do
    n=$((n + 1)); [ $n -gt 50 ] && { echo "시작 실패: $log" >&2; cat "$log" >&2; exit 1; }
    sleep 0.1
  done
done
C="$S/tls_client.py"
echo '## A1 TLS ok';                 python3 -I "$C" 8443
echo '## A2 untrusted CA';           python3 -I "$C" 8443 --ca other-ca.crt
echo '## A3 hostname mismatch';      python3 -I "$C" 8443 --host device.example
echo '## A4 expired';                python3 -I "$C" 9443
echo '## B1 mTLS no cert';           python3 -I "$C" 8883
echo '## B1b mTLS no cert, TLS1.2';  python3 -I "$C" 8883 --tls12
echo '## B2 mTLS cert';              python3 -I "$C" 8883 --cert device.crt --key device.key
echo '## B3 mTLS other CA cert';     python3 -I "$C" 8883 --cert rogue.crt --key rogue.key
echo '## B4 mTLS cert + wrong key';  python3 -I "$C" 8883 --cert device.crt --key rogue.key 2>&1 | tail -1
echo '## C1 proxy, proxy CA unknown'; python3 -I "$C" 7443
echo '## C2 proxy, proxy CA trusted'; python3 -I "$C" 7443 --ca proxy-ca.crt
echo '## C3 proxy + mTLS';           python3 -I "$C" 7883 --ca proxy-ca.crt --cert device.crt --key device.key
sleep 0.5
for f in s-tls s-mtls s-exp p-tls p-mtls; do echo "### $f.log"; cat "$f.log"; done
```

</details>

## 복기 질문

글을 덮기 전에 스스로 답해 볼 질문과 짧은 답입니다.

**Q1. TLS가 약속하는 것과 약속하지 않는 것은?**
기밀성·무결성·인증을 약속하고, 인증은 보통 서버만 합니다. 데이터 길이, IP와 포트, 기본 설정의 SNI는 숨기지 않습니다.

**Q2. TLS 1.3 전체 핸드셰이크가 왕복 한 번인 이유와 그 전제는?**
ClientHello에 key_share를 미리 싣기 때문입니다. TCP 연결 뒤, 인증서 기반, HelloRetryRequest·0-RTT 제외일 때입니다. MQTT 재연결은 CONNACK까지 왕복 세 번이고, 끊김은 설계에 넣습니다.

**Q3. CertificateVerify와 Finished는 각각 무엇을 증명하나?**
CertificateVerify는 개인키 서명으로 "인증서의 주인이 지금 상대"를, Finished는 공유 비밀에서 HKDF로 파생한 키의 MAC으로 "두 끝이 본 핸드셰이크가 같다"를 확인합니다.

**Q4. 재개 티켓과 0-RTT에서 조심할 점은?**
티켓은 PSK의 이름표이고 binder가 보유를 증명합니다. PSK만 쓰면 전방 비밀성이 없습니다. 0-RTT 데이터는 전방 비밀성도 재전송 방지도 없으니 반복돼도 괜찮은 요청에만 씁니다.

**Q5. 인증서 검증은 무엇을 확인하고, 왜 끄면 안 되나?**
체인, SAN과 접속 이름(또는 IP), 유효 기간입니다. 장치 시계가 틀리면 만료로 보입니다. 끄면 길에 끼어든 아무나를 받아들이므로, 필요한 CA는 신뢰 목록에 더하고 그 설정이 대신하는지 더하는지 확인합니다.

**Q6. mTLS에서 장치 키가 새면 피해는 어디까지인가?**
개인키는 전선에 나가지 않지만 파일이 새면 그 장치로 행세할 수 있습니다. 정책이 MQTT 범위를 좁혀도, 같은 인증서로 임시 AWS 권한을 받게 했다면 그 IAM 역할 권한까지 포함됩니다. 잃으면 새로 발급하고 옛 인증서를 폐기합니다.

**Q7. TLS 1.3 mTLS에서 "connected"가 인증 성공이 아닌 이유는?**
서버는 클라이언트 Certificate를 받는 즉시 검증하지만, 클라이언트는 자기 Finished를 보낸 뒤 서버의 확인을 기다리지 않고 핸드셰이크를 마칠 수 있습니다. 그래서 서버의 거절 경고를 그다음 읽기·쓰기에서 받게 되고, 인증서 문제가 접속 직후 끊김으로 나타날 수 있습니다(실험 B1, B3).

**Q8. 가로채기 프록시는 왜 mTLS를 깨뜨리고, 어떻게 푸나?**
장치 개인키나 서명 권한이 없는 프록시가 TLS를 두 연결로 끊으면, 서버 쪽 핸드셰이크에서 장치로서 서명할 수 없습니다. 설정이 아니라 길의 문제라 가로채기 예외나 직접 연결로 풉니다. 어떤 포트가 검사를 피했다는 관찰은 그 망에서만 맞습니다.

같은 시스템의 연결들은 결국 "누가 누구를 어느 층에서 확인하느냐"의 차이였습니다. 장치는 TLS 안에서 인증서로, 브라우저는 TLS 위에서 서명 URL로, 영상은 DTLS 지문으로 상대를 확인합니다. 그 차이를 알고 나니, 같은 사내 프록시 아래에서 어떤 연결은 CA 하나로 풀리고 어떤 연결은 길을 바꿔야만 풀린 이유도 설명이 됐습니다.

## 참고

- [RFC 8446: The Transport Layer Security (TLS) Protocol Version 1.3](https://www.rfc-editor.org/rfc/rfc8446)
- [RFC 5246: The Transport Layer Security (TLS) Protocol Version 1.2](https://www.rfc-editor.org/rfc/rfc5246)
- [RFC 8996: Deprecating TLS 1.0 and TLS 1.1](https://www.rfc-editor.org/rfc/rfc8996)
- [RFC 5280: Internet X.509 Public Key Infrastructure Certificate and CRL Profile](https://www.rfc-editor.org/rfc/rfc5280)
- [RFC 9525: Service Identity in TLS](https://www.rfc-editor.org/rfc/rfc9525)
- [RFC 6066: TLS Extensions (Server Name Indication)](https://www.rfc-editor.org/rfc/rfc6066)
- [RFC 7301: TLS Application-Layer Protocol Negotiation Extension](https://www.rfc-editor.org/rfc/rfc7301)
- [RFC 9849: TLS Encrypted Client Hello](https://www.rfc-editor.org/rfc/rfc9849)
- [RFC 9147: The Datagram Transport Layer Security (DTLS) Protocol Version 1.3](https://www.rfc-editor.org/rfc/rfc9147)
- [RFC 9001: Using TLS to Secure QUIC](https://www.rfc-editor.org/rfc/rfc9001)
- [MQTT Version 5.0 (OASIS Standard)](https://docs.oasis-open.org/mqtt/mqtt/v5.0/mqtt-v5.0.html)
- [AWS IoT Core: Device communication protocols](https://docs.aws.amazon.com/iot/latest/developerguide/protocols.html)
- [AWS IoT Core: X.509 client certificates](https://docs.aws.amazon.com/iot/latest/developerguide/x509-client-certs.html)
- [AWS IoT Core: Activate or deactivate a client certificate](https://docs.aws.amazon.com/iot/latest/developerguide/activate-or-deactivate-device-cert.html)
- [AWS IoT Core: Authorizing direct calls to AWS services using AWS IoT Core credential provider](https://docs.aws.amazon.com/iot/latest/developerguide/authorizing-direct-aws.html)
- [AWS IoT Core: Server authentication](https://docs.aws.amazon.com/iot/latest/developerguide/server-authentication.html)
- [Python 문서: ssl — TLS/SSL wrapper for socket objects](https://docs.python.org/3/library/ssl.html)
- [OpenSSL 문서: openssl-s_client](https://docs.openssl.org/master/man1/openssl-s_client/)
- [Eclipse Paho MQTT Python Client 문서](https://eclipse.dev/paho/files/paho.mqtt.python/html/client.html)
