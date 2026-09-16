# Lobster Input · 龙虾输入法

[English](README.md) · [简体中文](README.zh-CN.md) · [한국어](README.ko.md) · [Русский](README.ru.md)

> **공식 웹사이트: [lobster-input.com](https://lobster-input.com)** · **QQ 커뮤니티 그룹: 925395991**
>
> 웹사이트를 방문하고 사용 경험과 의견을 나누며 개발에 참여해 주세요.

Lobster Input은 여러 플랫폼을 지원하는 음성 입력 및 중국어 키보드 프로젝트입니다. 이 통합 저장소에는 macOS, Windows, iOS, Android, HarmonyOS 클라이언트와 공통 백엔드, 관리자 콘솔, API 키 풀 관리 서비스, 결제 서비스, 웹사이트가 포함되어 있습니다.

음성 인식, 텍스트 처리, 사용자 사전, 입력 기록, 실시간 오디오 상호작용 및 플랫폼 간 계정 서비스를 지원합니다. 모바일 클라이언트에는 로컬 병음 키보드도 포함되어 있습니다. 플랫폼별 완성도와 지원 기능은 각 구성 요소의 구현 및 문서를 확인해 주세요. 메모와 사용자 센터 프로젝트는 현재 기본 골격만 갖춘 상태입니다.

이 저장소는 자체 호스팅과 개발을 위한 것입니다. 배포 주소는 `example.com` 같은 예시 도메인과 `192.0.2.0/24` 문서용 IP 주소로 대체되어 있습니다. 실행 전에 실제 사용할 주소로 변경해야 합니다. 운영 인프라, 계정, 데이터베이스 내용 및 외부 API 사용 크레딧은 제공하지 않습니다.

## 관리자 콘솔

[![관리자 콘솔](docs/images/admin/01-dashboard.png)](docs/admin-showcase.ko.md)

**[관리자 페이지 25개 전체 보기 →](docs/admin-showcase.ko.md)**

## 개발자 및 연락처

**shaohua.sun, yaqiong.xu, xun.li**가 공동으로 개발하고 오픈 소스로 공개했습니다.

| shaohua.sun | yaqiong.xu | xun.li |
| :---: | :---: | :---: |
| <img src="docs/images/authors/shaohua-sun.png" width="104" alt="shaohua.sun"> | <img src="docs/images/authors/yaqiong-xu.png" width="104" alt="yaqiong.xu"> | <img src="docs/images/authors/xun-li.png" width="104" alt="xun.li"> |
| [shaohua.sun.main@gmail.com](mailto:shaohua.sun.main@gmail.com) | [simpleeve007@gmail.com](mailto:simpleeve007@gmail.com) | [Haiyi.Thai@gmail.com](mailto:Haiyi.Thai@gmail.com) |

**QQ 커뮤니티 그룹: 925395991**. 그룹이나 이메일을 통해 의견과 협업 제안을 보내 주세요. 재현 가능한 버그와 기능 제안은 GitHub Issue로 등록할 수 있습니다. 보안 문제는 [보안 정책](SECURITY.md)에 따라 비공개로 알려 주세요.

## AI 활용 개발

이 프로젝트의 약 **99.9%**는 **Claude 4.6**과 **GPT-5.5**를 활용해 개발했습니다. Claude가 개발 작업의 약 **95%**를 담당했으며, GPT-5.5는 주로 대규모 언어 모델용 프롬프트 작성을 맡았습니다. **수작업으로 조정한 비율은 0.1% 미만입니다.**

## 저장소 구성

| 디렉터리 | 용도 | 기술 |
| --- | --- | --- |
| [lobster-input-front](lobster-input-front/README.md) | macOS 클라이언트(standard 버전) | Swift, SwiftUI, Sparkle |
| [lobster-input-win](lobster-input-win/) | Windows 클라이언트 | C#, WPF, .NET |
| [lobster-input-ios](lobster-input-ios/) | iOS 앱 및 키보드 확장 | Swift, SwiftUI, UIKit |
| [lobster-input-android](lobster-input-android/README.md) | Android 앱 및 입력기 | Kotlin, Compose |
| [lobster-input-harmony](lobster-input-harmony/PORTING_GUIDE.md) | HarmonyOS 앱 및 입력기 | ArkTS |
| [lobster-input-backend](lobster-input-backend/README.md) | 공통 애플리케이션 백엔드 | Python, FastAPI, MongoDB, Redis |
| [lobster-input-admin](lobster-input-admin/README.md) | 관리자 콘솔 | FastAPI, Vue |
| [lobster-input-api-manage](lobster-input-api-manage/) | API 키 풀 관리 서비스 | FastAPI, Vue |
| [lobster-input-payment](lobster-input-payment/README.md) | 결제 서비스 | Python, FastAPI |
| [lobster-input-landing](lobster-input-landing/) | 제품 웹사이트 | Vue, FastAPI |
| [lobster-ucenter](lobster-ucenter/README.md) | 사용자 센터 기본 골격 | FastAPI |
| [lobster-note](lobster-note/README.md) | 메모 프로젝트 기본 골격 | FastAPI, Vue |

## 로컬 개발

1. 대상 플랫폼의 도구를 설치합니다. 백엔드는 Python 3.12+와 uv, 웹 프런트엔드는 Node.js(버전 조건은 각 `package.json` 참조), Apple 클라이언트는 Xcode, Android는 JDK 17과 Android SDK, Windows는 프로젝트에서 요구하는 .NET SDK, HarmonyOS는 DevEco 도구가 필요합니다.
2. [설정 및 개발 가이드](docs/GETTING_STARTED.md)를 읽고 필요한 구성 요소의 `.env.example`을 `.env`로 복사합니다. 직접 생성한 인증 키와 서비스 설정을 입력합니다.
3. 로컬 MongoDB와 Redis를 실행하고 키 풀, 관리자 콘솔, 결제 서비스, 애플리케이션 백엔드를 설정합니다. 클라우드 ASR/LLM 기능을 사용하려면 키 풀과 관리자 콘솔에 본인의 공급자 설정을 등록해야 합니다.
4. 클라이언트의 API 주소를 본인의 백엔드로 변경합니다. 실제 기기에서는 `localhost`로 개발 컴퓨터에 접근할 수 없습니다.

백엔드 실행:

```bash
cp lobster-input-backend/backend/.env.example lobster-input-backend/backend/.env
# 실행 전에 .env의 키와 서비스 주소를 설정하세요.
bash lobster-input-backend/scripts/restart.sh
```

macOS 클라이언트 빌드 및 실행:

```bash
export DEVELOPMENT_TEAM="YOUR_APPLE_TEAM_ID"
bash lobster-input-front/scripts/restart.sh --build
```

iOS App Group, Bundle ID, 개발자 팀 및 각 플랫폼의 서명 정보와 업데이트 주소는 본인의 설정으로 변경해야 합니다. [배포 가이드](docs/RELEASING.md)를 참고하세요.

루트 README는 네 가지 언어로 제공됩니다. 개별 구성 요소의 문서와 개발 가이드는 현재 대부분 중국어로 작성되어 있습니다.

## 사전 및 리소스

모바일 클라이언트에는 기본 병음 리소스가 포함되어 있습니다. 각각 약 39 MB였던 선택적 확장 사전 `custom_dict.txt`는 작은 예제로 대체되어 확장 후보 범위가 줄었습니다. 실행 시 기본 사전은 계속 사용할 수 있습니다. 확장 사전 생성 도구는 Android의 `tools/keyboard-verify`에 있습니다. [외부 리소스 안내](THIRD_PARTY_NOTICES.md)를 확인하고 재배포 시 관련 라이선스를 유지해 주세요.

데이터베이스 백업, 사용자 녹음, 운영 데이터, 비밀 키, 빌드 산출물, 설치 패키지 및 로컬 의존성은 소스 배포에 포함되지 않습니다.

## 기여

[기여 가이드](CONTRIBUTING.md), [행동 강령](CODE_OF_CONDUCT.md), [보안 정책](SECURITY.md)을 읽어 주세요. 커밋 전에 다음 명령을 실행합니다.

```bash
python3 scripts/check_public_repo.py
```

## 라이선스

프로젝트의 자체 작성 코드는 [MIT License](LICENSE)로 배포됩니다. 외부 의존성, 글꼴, 사전 및 기타 리소스에는 각자의 라이선스가 적용됩니다. MIT는 이러한 라이선스를 대체하지 않으며 프로젝트 상표나 외부 서비스의 사용 권한을 부여하지 않습니다.
