# FooBar Swift (i-foo-flo)

Нативний macOS-плеєр на Swift + AppKit + AVPlayer — заміна PyQt+VLC версії
(`~/dev/foobar-qt`). ~40 MB RAM замість ~220 MB.

## Збірка

```bash
./build.sh        # → FooBarSwift.app (підписаний "FooBar Dev Code Signing")
open FooBarSwift.app
```

Вимоги: macOS 14+, Swift toolchain (Xcode CLI). Жодних зовнішніх залежностей.

## Можливості

- Бібліотека: локальні теки + SFTP через `ssh` (find по серверу), статус SSH
  у нижній панелі з реконектом одним кліком
- Стрімінг з сервера: loopback HTTP-проксі (206 Partial Content) годує
  AVPlayer Range-запитами — файл не качається цілком
- Групування по папках з підзаголовками, сортування кліком по колонках
  (назва / артист / альбом / час / плейкаунти / лайки)
- Назви: ID3 (`AVAsset.commonMetadata`), фолбек — ім'я файлу без розширення;
  серверний формат `<Artist>,<Title>.mp3`, префікси `07 - ` і `(1991)` чистяться
- Тексти пісень: LRCLIB (синхронізовані, авто-скрол) + Genius фолбек, тогл 📜
- Last.fm: скроблінг, now-playing, love/unlove, **плейкаунти** — все через
  локальний SQLite-кеш (`~/Library/Application Support/FooBarSwift/fmcache.db`,
  ревалідація раз на тиждень) + фоновий бекфілл усієї бібліотеки + імпорт
  лайкнутих (`user.getLovedTracks`)
- 🔀 рандомний порядок, ♡ лайк, 📜 тексти, медіа-клавіші + Now Playing
- Налаштування: бібліотека, ластфм (з кнопкою імпорту лайків), тексти;
  конфіг імпортується одного разу з `~/dev/foobar-qt/config.json`
- Рескан / перепід'єднання SSH — контекстне меню таблиці

## Структура

| Файл | Призначення |
|---|---|
| `Sources/main.swift` | UI, таблиця з групуванням, транспорт, бекфілл |
| `Sources/Player.swift` | AVPlayer + періодичний time observer |
| `Sources/Library.swift` | скан локальний/SFTP, парсинг назв |
| `Sources/Sftp.swift` | `ssh` раннер + loopback HTTP-проксі |
| `Sources/Lyrics.swift` | LRCLIB/Genius, LRC-парсер |
| `Sources/LastFM.swift` | API v2 (api_sig, authToken-логін) |
| `Sources/FmCache.swift` | SQLite-кеш статистики |
| `Sources/Settings.swift` | вікно налаштувань |
| `build.sh` | білд + іконка + стабільний підпис |

## Підпис і дозволи

Подпис `FooBar Dev Code Signing` (self-signed, login keychain) — TCC-дозволи
пам'ятаються між збірками. Ключ: SHA-1 `7B228DEF19A88C43B09524F85DA99C9AB55E16EC`.