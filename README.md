# anytype-publish-server

Сервер для публичной публикации объектов AnyType в веб (фича «Publish to Web»).

Одно бинарное приложение — узел сети any-sync, который принимает команды публикации/отмены
публикации от клиентов AnyType, хранит контент опубликованных объектов в S3-совместимом хранилище
и сам отдаёт готовый HTML-сайт опубликованных страниц по HTTP.

## Как это работает

### Приложение запускает собственные HTTP-серверы

Да, сервер **сам слушает** сетевые адреса — ему не нужен nginx, который «отдаёт содержимое».
Nginx (или любой reverse proxy) ставится перед ним лишь для TLS-терминации и доменных имён.

Запускаются три слушателя (значения по умолчанию из `etc/anytype-publish-server.yml`):

| Адрес   | Протокол     | Назначение                                                                                                                                    |
|---------|--------------|----------------------------------------------------------------------------------------------------------------------------------------------|
| `:8380` | HTTP         | **Gateway** (публичная часть). Отдаёт страницы `https://<domain>/<identity>/<uri>` и `https://<domain>/name/<name>/<uri>` (URI может быть многоуровневым path). HTML рендерится из файлов в S3 через пакет `anytype-publish-renderer`, результат кэшируется в Redis. При `gateway.serveStatic: true` статические файлы раздаются из каталога `./static`. |
| `:8383` | HTTP         | **API загрузки** (`publish.uploadUrlPrefix`). Принимает файл публикации: `POST /api/upload/<publishId>/<uploadKey>` (тело запроса — `tar`-архив). |
| `:4940` | yamux (DRPC) | Сетевой порт узла any-sync — сюда подключаются клиенты AnyType.                                                                                 |

Типичная схема развёртывания с nginx:

```nginx
# публичные страницы опубликованных объектов
server {
    listen 443 ssl;
    server_name publish.example.com;
    # ssl_certificate ...;

    location / {
        proxy_pass http://127.0.0.1:8380;
    }
}

# загрузка публикаций клиентом
server {
    listen 80;
    server_name uploads.example.com;
    location / {
        client_max_body_size 0;
        proxy_pass http://127.0.0.1:8383;
    }
}
```

Порт `4940` проксировать через http-proxy нельзя — это TCP-транспорт (yamux/DRPC),
поэтому он должен быть напрямую доступен клиенту AnyType (открытый порт, VPN, SSH-туннель и т.п.).

### Сценарий публикации (по шагам)

1. Пользователь в клиенте AnyType публикует объект и задаёт URI. Клиент вызывает DRPC-метод
   `Publish` через any-sync (yamux, порт `4940`). Идентичность автора берётся из TLS-публичного
   ключа соединения, а не из тела сообщения — клиент не может публиковать «от чужого имени».
2. Узел создаёт запись публикации в MongoDB (`publish/publishrepo`), генерирует `uploadKey` и
   возвращает клиенту ссылку загрузки: `<publish.uploadUrlPrefix>/<publishId>/<uploadKey>`.
3. Клиент упаковывает объект (заметки, файлы, состояние спейса) в `tar`-архив и шлёт его
   POST-ом на эту ссылку (порт `8383`).
4. Узел распаковывает архив и записывает каждый файл в S3 под ключом `<publishId>/<path>`.
   Общий размер ограничен: 10 Мб по умолчанию; если идентификатор зарегистрирован в any NS —
   100 Мб; для имён из env `INCREASED_LIMIT_NAMES` (anytype-внутренние) — 6000 Мб.
5. Публикация помечается как «опубликована», узел инвалидирует кэш, клиент получает итоговый
   URL: `https://<gateway.domain>/<identity>/<uri>`.
6. При обращении к gateway (`:8380`) узел сначала проверяет Redis-кэш, затем Mongo
   (и any NS, если URL задан через имя), после чего рендерит HTML. В сгенерированной
   разметке файлы самой публикации и статические assets ссылаются на `gateway.publishFilesUrl`
   (S3) и `gateway.staticFilesUrl` (CDN) — контент загружается браузером напрямую,
   а не через узел.
7. Если `publish.cleanupOn: true`, каждые 5 минут узел удаляет из Mongo и S3 публикации,
   которым больше часа (отменённые публикации, устаревшие версии).

Схематично:

```
браузер ──GET /<identity>/<uri>────────► nginx(:443) ──► gateway :8380 ──► HTML
браузер ──GET assets/файлы публикации──────────────────► S3 (publishFilesUrl) и CDN
клиент  ──Publish/UnPublish/... (DRPC over yamux)──────► :4940
клиент  ──POST tar────────────────────────────► nginx ──► upload API :8383 ──► S3
```
## Зависимости

| Зависимость | Назначение | Раздел конфига |
|-------------|------------|----------------|
| Go | сборка (версия указана в `go.mod`) | — |
| MongoDB | метаданные публикаций и объектов | `mongo` |
| Redis | кэш отрендеренных страниц и его инвалидация (опционально, дефолт `redis://127.0.0.1:6379`) | `redis` |
| S3-совместимое хранилище | файлы опубликованных объектов | `s3Store` |
| Сеть any-sync (координаторы + any NS) | подключение клиентов, разрешение имён | `network`, `yamux` |
| Статические файлы фронтенда | assets рендерера, берутся из `./static` относительно cwd | `gateway.staticFilesUrl`, `gateway.serveStatic` |

Для работы узел должен иметь исходящий доступ к координаторам any-sync
(адреса в секции `network` примера конфига: `*.anyclub.org:443/1443/5430` и т.д.).

## Сборка

```sh
make deps     # go mod download + сборка govvv и protoc-плагинов в deps/
make build    # -> bin/anytype-publish-server
make test     # go test ./... --cover
```

Без make:

```sh
go build -o bin/anytype-publish-server ./cmd/server
```
## Конфигурация

Конфиг — YAML, путь задаётся флагом `-c` (по умолчанию `etc/anytype-publish-server.yml`).
В репозитории уже лежит рабочий пример: `etc/anytype-publish-server.yml` — его можно
использовать как шаблон, но подправить `s3Store`, `gateway` и `mongo` под себя.
Ниже — тот же пример с комментариями по каждому разделу:

```yaml
# Identity узла any-sync: peerId + base64 ed25519-ключи.
# Для локального запуска подойдёт из etc/anytype-publish-server.yml.
account:
  peerId: 12D3...
  peerKey: tfs8...==
  signingKey: tfs8...==

drpc:
  stream:
    maxMsgSizeMb: 256   # максимальный размер DRPC-сообщения (для больших space-архивов)
  snappy: true          # сжатие DRPC-потока

# MongoDB, где лежат метаданные (коллекции publish / object)
mongo:
  connect: mongodb://localhost:27017
  database: publish_test

# S3-совместимое хранилище, куда складываются файлы публикаций.
# Бакет должен давать публичное чтение (файлы отдаёт S3, а не узел),
# либо перед ним должен стоять CDN.
s3Store:
  region: "eu-central-1"
  bucket: "my-publish-bucket"
  # опционально для non-AWS (MinIO, GCS и т.п.):
  # endpoint: "http://localhost:9000"
  # credentials:
  #   accessKey: "minio"
  #   secretKey: "minio123"

# Куда кэшировать node-config сети any-sync и как часто апдейтить (сек)
networkStorePath: .
networkUpdateIntervalSec: 300

publish:
  # Публичный префикс URL, куда клиент будет грузить tar-архивы.
  # Должен быть доступен из интернета и попадать на httpApiAddr.
  uploadUrlPrefix: "https://uploads.example.com/api/upload"
  # Адрес HTTP API загрузки (порт, принимает POST /api/upload/...)
  httpApiAddr: ":8383"
  # Периодическая чистка устаревших публикаций (created > 1ч, ready-to-delete)
  cleanupOn: true

# Публичная часть: HTTP-сервер, который отдаёт HTML опубликованных страниц
gateway:
  addr: ":8380"
  # Домен, под которым доступен gateway. Итоговый URL публикации строится
  # как https://<domain>/<identity>/<uri> — обязательный параметр для продакшена.
  domain: "publish.example.com"
  # Публичный URL бакета с файлами публикаций (S3/CDN)
  publishFilesUrl: "https://my-publish-bucket.s3.eu-central-1.amazonaws.com"
  # URL статических ассетов рендерера (css/js/dll).
  # Либо ваш CDN, если serveStatic=false.
  staticFilesUrl: "https://static.example.com/publish-assets"
  # true — раздать ./static по адресу gateway/static (удобно локально)
  serveStatic: true
  # Произвольный HTML, вставляемый в каждую отрендеренную страницу
  analyticsCode: ""
  analyticsCodeMembers: ""  # для URL вида /name/<name>/<uri>

# Redis — кэш отрендеренных страниц (TTL 1ч) и инвалидация при републикации.
# Можно не указывать: дефолт redis://127.0.0.1:6379
# redis:
#   url: "redis://127.0.0.1:6379/?db=1"
#   isCluster: false

# yamux-транспорт any-sync: сюда TCP-подключаются клиенты AnyType
# (порт должен быть напрямую доступен извне — http-прокси здесь не сработает)
yamux:
  listenAddrs:
    - 0.0.0.0:4940
  writeTimeoutSec: 10
  dialTimeoutSec: 10

# Конфиг any-sync сети: networkId + списки узлов (coordinators, naming nodes any NS).
# Берите целиком из etc/anytype-publish-server.yml — узел подключается
# к этим координаторам, чтобы принимать клиентов и резолвить any NS имена.
network:
  networkId: N83gJpVd9MuNRZAuJLZ7LiMntTThhPc6DtzWWVjb1M3PouVU
  nodes:
    - peerId: ...
      addresses: [...]
      types: [coordinator]
    # ...

# метрики (gelf-адрес), опционально
# metric:
#   addr: "udp://127.0.0.1:12201"
```

## Запуск

```sh
# сборка
make build

# запуск (конфиг по умолчанию: etc/anytype-publish-server.yml)
./bin/anytype-publish-server -c etc/anytype-publish-server.yml
```

Флаги:

| Флаг      | Назначение                                          |
|-----------|-----------------------------------------------------|
| `-c <path>` | путь к config-файлу (default: `etc/anytype-publish-server.yml`) |
| `-v`      | версия и выход                                      |
| `-h`      | помощь                                              |

Переменные окружения:

| Переменная            | Назначение                                                                                   |
|-----------------------|---------------------------------------------------------------------|
| `ANYPROF`             | если задана как адрес (`:6060`), узел дополнительно поднимает pprof HTTP-сервер на этом адресе. |
| `INCREASED_LIMIT_NAMES` | список any NS-имён через `,`, для которых включён увеличенный лимит загрузки (6 Гб).    |

### Проверка работы

```sh
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8380/   # => 404 (пустой путь не матчится — норма)
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8383/   # => 404 (JSON {"error":"not found"} — норма)
# реальная страница появится только после первой публикации:
curl -I https://<gateway.domain>/<identity>/<uri>   # => 200 text/html
```

В логах после успешного старта появятся строки `http api server started` (upload API)
и `gateway server started` (gateway). Приложение работает до `SIGTERM`/`SIGINT`
(при этом gateway корректно завершает активные HTTP-соединения).
