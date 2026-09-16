# Lobster Input · 龙虾输入法

[English](README.md) · [简体中文](README.zh-CN.md) · [한국어](README.ko.md) · [Русский](README.ru.md)

> **Официальный сайт: [lobster-input.com](https://lobster-input.com)** · **Группа сообщества в QQ: 925395991**
>
> Заходите на сайт, делитесь опытом и участвуйте в разработке.

Lobster Input — кроссплатформенный проект голосового ввода и китайской клавиатуры. Монорепозиторий включает клиенты для macOS, Windows, iOS, Android и HarmonyOS, общий бэкенд, панель управления, менеджер пула API-ключей, платёжный сервис и сайт.

Проект поддерживает распознавание речи, обработку текста, пользовательские словари, историю ввода, взаимодействие с аудио в реальном времени и сервисы учётных записей для разных платформ. Мобильные клиенты также содержат локальную клавиатуру пиньинь. Степень готовности и набор функций зависят от платформы; подробности приведены в коде и документации компонентов. Проекты заметок и пользовательского центра пока представляют собой базовые заготовки.

Репозиторий предназначен для самостоятельного развёртывания и разработки. Адреса инфраструктуры заменены доменами вроде `example.com` и IP-адресами из диапазона `192.0.2.0/24`, предназначенного для документации. Перед запуском замените их своими адресами. Рабочая инфраструктура, учётные записи, содержимое баз данных и кредиты сторонних API не предоставляются.

## Панель управления

[![Панель управления](docs/images/admin/01-dashboard.png)](docs/admin-showcase.ru.md)

**[Все 25 страниц панели управления →](docs/admin-showcase.ru.md)**

## Авторы и контакты

Проект совместно разработали и опубликовали с открытым исходным кодом **shaohua.sun, yaqiong.xu и xun.li**.

| shaohua.sun | yaqiong.xu | xun.li |
| :---: | :---: | :---: |
| <img src="docs/images/authors/shaohua-sun.png" width="104" alt="shaohua.sun"> | <img src="docs/images/authors/yaqiong-xu.png" width="104" alt="yaqiong.xu"> | <img src="docs/images/authors/xun-li.png" width="104" alt="xun.li"> |
| [shaohua.sun.main@gmail.com](mailto:shaohua.sun.main@gmail.com) | [simpleeve007@gmail.com](mailto:simpleeve007@gmail.com) | [Haiyi.Thai@gmail.com](mailto:Haiyi.Thai@gmail.com) |

**Группа в QQ: 925395991**. Присоединяйтесь к группе или пишите нам по электронной почте, чтобы поделиться отзывом или предложить сотрудничество. Воспроизводимые ошибки и предложения функций можно оформить в GitHub Issues. Об уязвимостях сообщайте приватно в соответствии с [политикой безопасности](SECURITY.md).

## Структура репозитория

| Каталог | Назначение | Технологии |
| --- | --- | --- |
| [lobster-input-front](lobster-input-front/README.md) | Клиент macOS, редакция standard | Swift, SwiftUI, Sparkle |
| [lobster-input-win](lobster-input-win/) | Клиент Windows | C#, WPF, .NET |
| [lobster-input-ios](lobster-input-ios/) | Приложение iOS и расширение клавиатуры | Swift, SwiftUI, UIKit |
| [lobster-input-android](lobster-input-android/README.md) | Приложение Android и метод ввода | Kotlin, Compose |
| [lobster-input-harmony](lobster-input-harmony/PORTING_GUIDE.md) | Приложение HarmonyOS и метод ввода | ArkTS |
| [lobster-input-backend](lobster-input-backend/README.md) | Общий бэкенд | Python, FastAPI, MongoDB, Redis |
| [lobster-input-admin](lobster-input-admin/README.md) | Панель управления | FastAPI, Vue |
| [lobster-input-api-manage](lobster-input-api-manage/) | Менеджер пула API-ключей | FastAPI, Vue |
| [lobster-input-payment](lobster-input-payment/README.md) | Платёжный сервис | Python, FastAPI |
| [lobster-input-landing](lobster-input-landing/) | Сайт продукта | Vue, FastAPI |
| [lobster-ucenter](lobster-ucenter/README.md) | Заготовка пользовательского центра | FastAPI |
| [lobster-note](lobster-note/README.md) | Заготовка проекта заметок | FastAPI, Vue |

## Локальная разработка

1. Установите инструменты для нужной платформы: Python 3.12+ и uv для бэкенда; Node.js для веб-интерфейсов (требования к версии указаны в соответствующих `package.json`); Xcode для клиентов Apple; JDK 17 и Android SDK для Android; .NET SDK версии, требуемой проектом Windows; инструменты DevEco для HarmonyOS.
2. Прочитайте [руководство по настройке и разработке](docs/GETTING_STARTED.md). Скопируйте нужные файлы `.env.example` в `.env`, укажите самостоятельно созданные секреты и параметры своих сервисов.
3. Запустите локальные MongoDB и Redis, затем настройте пул ключей, панель управления, платёжный сервис и бэкенд. Для облачных функций ASR/LLM необходимо добавить собственные настройки провайдеров в пул ключей и панель управления.
4. Укажите в клиенте адрес своего бэкенда. Физическое устройство не может обращаться к компьютеру разработчика через `localhost`.

Запуск бэкенда:

```bash
cp lobster-input-backend/backend/.env.example lobster-input-backend/backend/.env
# Перед запуском укажите секреты и адреса сервисов в .env.
bash lobster-input-backend/scripts/restart.sh
```

Сборка и запуск клиента macOS:

```bash
export DEVELOPMENT_TEAM="YOUR_APPLE_TEAM_ID"
bash lobster-input-front/scripts/restart.sh --build
```

Настройте собственные App Group, Bundle ID и команду разработчика для iOS, а также подписи и источники обновлений для каждой платформы. См. [руководство по выпуску](docs/RELEASING.md).

Корневой README доступен на четырёх языках. Документация компонентов и руководства по разработке пока преимущественно написаны на китайском языке.

## Словари и ресурсы

Базовые ресурсы пиньинь сохранены в мобильных клиентах. Необязательные расширенные словари `custom_dict.txt`, ранее занимавшие около 39 МБ каждый, заменены небольшими примерами, поэтому охват дополнительных вариантов ввода уменьшен. Базовые словари по-прежнему доступны во время работы. Инструменты построения расширений находятся в Android-каталоге `tools/keyboard-verify`. Ознакомьтесь с [уведомлениями о сторонних ресурсах](THIRD_PARTY_NOTICES.md) и сохраняйте соответствующие лицензии при распространении.

Резервные копии баз данных, записи пользователей, рабочие данные, секреты, результаты сборки, установщики и локальные зависимости не входят в публикацию исходного кода.

## Участие в разработке

Прочитайте [руководство для участников](CONTRIBUTING.md), [кодекс поведения](CODE_OF_CONDUCT.md) и [политику безопасности](SECURITY.md). Перед коммитом выполните:

```bash
python3 scripts/check_public_repo.py
```

## Лицензия

Оригинальный код проекта распространяется по [лицензии MIT](LICENSE). Сторонние зависимости, шрифты, словари и другие ресурсы сохраняют собственные лицензии. MIT не заменяет эти лицензии и не предоставляет права на товарные знаки проекта или использование сторонних сервисов.
