# Lobster Input · 龙虾输入法

[English](README.md) · [简体中文](README.zh-CN.md) · [한국어](README.ko.md) · [Русский](README.ru.md)

> **Website: [lobster-input.com](https://lobster-input.com)** · **QQ community group: 925395991**
>
> Visit the website, share feedback, and join the community.

Lobster Input is a cross-platform voice input and Chinese keyboard project. This monorepo includes macOS, Windows, iOS, Android, and HarmonyOS clients, a shared backend, an admin console, an API key pool manager, a payment service, and a website.

Features include speech recognition, text processing, user dictionaries, input history, real-time audio interaction, and account services across platforms. Mobile clients also include a local Pinyin keyboard. Platform maturity varies; see each component's implementation and documentation. The notes and user center projects are currently scaffolds.

This repository is intended for self-hosting and development. Deployment addresses have been replaced with domains such as `example.com` and documentation IPs in `192.0.2.0/24`. Replace these placeholders before running the services. Production infrastructure, accounts, database contents, and third-party API credits are not included.

## Admin Console

[![Admin Console](docs/images/admin/01-dashboard.png)](docs/admin-showcase.md)

**[Explore all 25 admin pages →](docs/admin-showcase.md)**

## Authors and contact

Created and open-sourced by **shaohua.sun, yaqiong.xu, and xun.li**.

| shaohua.sun | yaqiong.xu | xun.li |
| :---: | :---: | :---: |
| <img src="docs/images/authors/shaohua-sun.png" width="104" alt="shaohua.sun"> | <img src="docs/images/authors/yaqiong-xu.png" width="104" alt="yaqiong.xu"> | <img src="docs/images/authors/xun-li.png" width="104" alt="xun.li"> |
| [shaohua.sun.main@gmail.com](mailto:shaohua.sun.main@gmail.com) | [simpleeve007@gmail.com](mailto:simpleeve007@gmail.com) | [Haiyi.Thai@gmail.com](mailto:Haiyi.Thai@gmail.com) |

**QQ community group: 925395991**. Join the group or contact us by email for feedback and collaboration. Use GitHub Issues for reproducible bugs and feature requests. Report security issues privately as described in [SECURITY.md](SECURITY.md).

## Repository layout

| Directory | Purpose | Stack |
| --- | --- | --- |
| [lobster-input-front](lobster-input-front/README.md) | macOS client (standard edition) | Swift, SwiftUI, Sparkle |
| [lobster-input-win](lobster-input-win/) | Windows client | C#, WPF, .NET |
| [lobster-input-ios](lobster-input-ios/) | iOS app and keyboard extension | Swift, SwiftUI, UIKit |
| [lobster-input-android](lobster-input-android/README.md) | Android app and input method | Kotlin, Compose |
| [lobster-input-harmony](lobster-input-harmony/PORTING_GUIDE.md) | HarmonyOS app and input method | ArkTS |
| [lobster-input-backend](lobster-input-backend/README.md) | Shared application backend | Python, FastAPI, MongoDB, Redis |
| [lobster-input-admin](lobster-input-admin/README.md) | Admin console | FastAPI, Vue |
| [lobster-input-api-manage](lobster-input-api-manage/) | API key pool manager | FastAPI, Vue |
| [lobster-input-payment](lobster-input-payment/README.md) | Payment service | Python, FastAPI |
| [lobster-input-landing](lobster-input-landing/) | Product website | Vue, FastAPI |
| [lobster-ucenter](lobster-ucenter/README.md) | User center scaffold | FastAPI |
| [lobster-note](lobster-note/README.md) | Notes project scaffold | FastAPI, Vue |

## Local development

1. Install the toolchain for your target platform: Python 3.12+ and uv for the backend; Node.js for web frontends (see each `package.json` for version requirements); Xcode for Apple clients; JDK 17 and Android SDK for Android; the .NET SDK required by the Windows project; or the DevEco toolchain for HarmonyOS.
2. Read the [configuration and development guide](docs/GETTING_STARTED.md). Copy the relevant `.env.example` to `.env`, then supply your own generated secrets and service settings.
3. Start local MongoDB and Redis, then configure the key pool, admin console, payment service, and application backend. Cloud ASR/LLM features require your own provider configuration in the key pool and admin console.
4. Point the client at your backend. A physical device cannot reach your development computer through `localhost`.

Start the backend:

```bash
cp lobster-input-backend/backend/.env.example lobster-input-backend/backend/.env
# Edit secrets and service URLs in .env before starting.
bash lobster-input-backend/scripts/restart.sh
```

Build and start the macOS client:

```bash
export DEVELOPMENT_TEAM="YOUR_APPLE_TEAM_ID"
bash lobster-input-front/scripts/restart.sh --build
```

Configure your own iOS App Group, Bundle ID, developer team, signing credentials, and update sources for each platform. See the [release guide](docs/RELEASING.md).

The root README is available in four languages. Component documentation and development guides are currently mainly in Chinese.

## Dictionaries and resources

Base Pinyin resources remain included in the mobile clients. The optional `custom_dict.txt` files, previously about 39 MB each, have been replaced with small samples, reducing extended candidate coverage. The base dictionaries remain available at runtime. Tools for building extensions are under Android's `tools/keyboard-verify`. See [third-party notices](THIRD_PARTY_NOTICES.md) and preserve the relevant licenses when redistributing resources.

Database backups, user recordings, production data, secrets, build outputs, installers, and local dependencies are excluded from source releases.

## Contributing

Read the [contribution guide](CONTRIBUTING.md), [code of conduct](CODE_OF_CONDUCT.md), and [security policy](SECURITY.md). Before committing, run:

```bash
python3 scripts/check_public_repo.py
```

## License

Original project code is licensed under the [MIT License](LICENSE). Third-party dependencies, fonts, dictionaries, and other resources retain their own licenses. MIT does not replace those licenses or grant rights to project trademarks or third-party services.
