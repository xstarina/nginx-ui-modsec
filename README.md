# nginx-ui + ModSecurity v3 + OWASP CRS

Надстройка над официальным образом `uozi/nginx-ui`: тот же nginx, та же панель,
те же сертификаты из UI — плюс динамический модуль ModSecurity с OWASP CRS.

Собирается и запускается на одной машине, без реестра и CI.

## Почему это работает

Образ `uozi/nginx-ui` собран из пакета nginx.org для Debian 13 с флагом
`--with-compat`. Это официальный механизм бинарной совместимости динамических
модулей: модуль, собранный из исходников той же версии nginx с тем же флагом,
загрузится независимо от остальных опций сборки. Повторять весь километровый
`configure` из `nginx -V` не нужно.

Версия nginx нигде не задаётся руками — она читается из `ENV NGINX_VERSION`
базового образа прямо во время сборки. Собрать модуль «не под ту базу»
физически невозможно.

## Состав архива

Распакуйте так, чтобы `Dockerfile` оказался в корне рабочего каталога:

```
Dockerfile                сборка модуля + наложение на образ nginx-ui
.dockerignore             рантайм-каталоги не попадают в контекст сборки
.env                      версии, дайджест базы, текущий тег образа
build.sh                  сборка -> дымовой тест -> простановка тега
docker-compose.yml        запуск
modsec/main.conf          цепочка include для ModSecurity
modsec/custom/before/     исключения до правил CRS
modsec/custom/after/      исключения после правил CRS
test/smoke.sh             дымовой тест собранного образа
test/smoke.conf           конфиг для него
```

Каталоги `nginx/`, `nginx-ui/`, `www/`, `logs/` создаются при первом запуске
и в контекст сборки не попадают.

Если разворачиваете поверх существующего каталога, где уже лежат `nginx/`
и `nginx-ui/` с данными панели — они сохранятся, заменять нужно только файлы
из списка выше.

## Требования к машине

Нужны только `docker`, `bash`, `sed` и сеть до Docker Hub. `buildx` и плагин
`docker compose` **не требуются** — скрипт обходится без них.

Проверить, что видит скрипт:

```bash
chmod +x build.sh test/smoke.sh    # после копирования файлов
./build.sh --doctor
```

Пример вывода на VMware Photon OS 4.0 с Docker 24:

```
окружение:
  docker            24.0.5
  buildx            нет (не требуется)
  билдер            legacy (buildx не нужен)
  compose           docker-compose
  curl              есть (дайджест без скачивания образа)
```

Замечания по такой конфигурации:

- **Команда compose.** Если плагина нет, везде ниже вместо `docker compose`
  используйте `docker-compose` — скрипт определяет это сам и подсказывает
  правильную команду в конце сборки.
- **Билдер.** В Docker 23+ переменная `DOCKER_BUILDKIT=1` не включает BuildKit
  внутри демона, а перенаправляет сборку в buildx; без установленного buildx
  это даёт ошибку `BuildKit is enabled but the buildx component is missing`.
  Поэтому `build.sh` сам выбирает: есть buildx — BuildKit, нет — legacy-билдер.
  Dockerfile собирается обоими: `ARG` перед `FROM`, `COPY --from` и
  многостадийность legacy умеет, строка `# syntax=` для него просто комментарий.
  Единственное, чего legacy не умеет, — `--platform`, поэтому с непустым
  `PLATFORM` скрипт остановится и скажет об этом.

  Если buildx всё же нужен (кэш сборки, кросс-платформа), это один бинарник:

  ```bash
  mkdir -p ~/.docker/cli-plugins
  # актуальную версию взять на github.com/docker/buildx/releases
  curl -SL https://github.com/docker/buildx/releases/download/vX.Y.Z/buildx-vX.Y.Z.linux-amd64 \
      -o ~/.docker/cli-plugins/docker-buildx
  chmod +x ~/.docker/cli-plugins/docker-buildx
  docker buildx version
  ```
- **Дайджест базы** определяется запросом к registry API через `curl`, без
  скачивания образа. Если `curl` нет — скрипт откатывается на `docker pull`
  и читает `RepoDigests`.

## Первый запуск

```bash
chmod +x build.sh test/smoke.sh
./build.sh
docker-compose up -d          # либо docker compose up -d, если есть плагин
```

`build.sh` собирает образ, прогоняет дымовой тест и только после этого
помечает образ рабочим тегом и прописывает его в `.env`. Если тест не прошёл —
тег не проставляется, и `docker-compose up` продолжит работать на предыдущем
образе.

Сборка падает сама, если что-то не сходится:

| Слой | Что проверяет |
|---|---|
| `base` | в базовом образе есть `--with-compat` |
| `builder` | релиз Debian сборщика совпадает с базой (glibc, gcc) |
| `final` | `nginx -t` реально грузит собранный модуль |

Первая сборка занимает минут 10–15 (компиляция libmodsecurity) и оставляет
около 1.5 ГБ промежуточных слоёв. Почистить: `docker builder prune`.

## Подключение к nginx

### load_module

Путь **только абсолютный**. `--prefix=/etc/nginx`, а `/etc/nginx` смонтирован
томом, поэтому относительный `modules/...` на чистом томе не резолвится.

Первой строкой `nginx.conf` (правится прямо в панели, раздел Configurations):

```nginx
load_module /usr/lib/nginx/modules/ngx_http_modsecurity_module.so;
```

Для чистой инсталляции строка уже добавлена в сид-конфиг
`/usr/local/etc/nginx/nginx.conf`, который сервис `init-config` копирует
в пустой том при первом запуске. Для существующего тома — добавить вручную.

### Включение на сайтах

Глобально, в блоке `http`:

```nginx
modsecurity on;
modsecurity_rules_file /etc/modsecurity.d/main.conf;
```

Либо в каждом `server` по отдельности — аккуратнее при разнородных сайтах.
В nginx-ui для этого есть Config Template: заводится шаблон с этими двумя
строками, и каждый новый домен получает WAF автоматически, вместе
с сертификатом, из той же панели.

Отключить для конкретного location:

```nginx
location /api/upload/ {
    modsecurity off;
}
```

### Панель nginx-ui

Контейнер проксирует свой порт 80 на бэкенд панели `127.0.0.1:9000`.
CRS на админке и её API даёт много ложных срабатываний. Лучше не публиковать
панель наружу вообще — ограничить по IP или пускать через VPN, а не ослаблять
правила.

## Режимы

Стартует в `SecRuleEngine DetectionOnly`: трафик не блокируется, только
пишется аудит-лог. После пары недель наблюдения и разбора ложных срабатываний
переключить в блокирующий режим.

Настройки движка образ дописывает в конец `/etc/modsecurity.d/modsecurity.conf`
(последнее вхождение директивы у ModSecurity выигрывает):

```
SecRuleEngine DetectionOnly
SecAuditEngine RelevantOnly
SecAuditLog /dev/stdout
SecAuditLogType Serial
SecAuditLogFormat JSON
SecAuditLogParts ABIJDEFHZ
```

Чтобы переключить режим без пересборки, раскомментируйте volume
`./modsec/modsecurity.conf` в `docker-compose.yml`, скопируйте файл из образа
и правьте на хосте:

```bash
docker-compose exec nginx-ui cat /etc/modsecurity.d/modsecurity.conf \
    > modsec/modsecurity.conf
```

Альтернатива — добавить `SecRuleEngine On` последней строкой
в `modsec/custom/after/99-engine.conf`: этот каталог и так смонтирован
томом, а `after` подключается после всего остального.

## Исключения CRS

```
modsec/custom/before/*.conf   # до правил CRS — сюда ctl:ruleRemoveById
modsec/custom/after/*.conf    # после всех правил
```

В каждом каталоге есть `00-placeholder.conf` — он нужен, чтобы `Include`
с маской нашёл хотя бы один файл. Свои правила кладите рядом отдельными
файлами (`10-api-exclusions.conf` и т.п.), порядок подключения алфавитный.

Каталог смонтирован томом: правка файла + reload nginx из панели, пересборка
не нужна. Подробности и примеры — в README внутри каждого каталога.

Аудит-лог идёт в stdout контейнера в JSON:

```bash
docker-compose logs nginx-ui | grep '"transaction"' | tail -5 | python3 -m json.tool
```

## Обновления

Три источника обновлений с очень разным темпом:

| Что | Как часто | Что делать |
|---|---|---|
| Базовый образ nginx-ui (и nginx внутри) | часто, в т.ч. перезаливкой того же тега | `./build.sh --update` |
| OWASP CRS | раз в 1–2 месяца | правка `CRS_VERSION` в `.env`, `./build.sh` |
| ModSecurity и коннектор | раз в год-полтора | правка версий в `.env`, `./build.sh` |

Проверить, не уехал ли базовый образ:

```bash
./build.sh --check
```

Скрипт сравнивает дайджест в реестре с зафиксированным в `.env` и показывает
расхождение. `--update` подтягивает новый дайджест и сразу пересобирает.

### Почему дайджест, а не тег

Теги на Docker Hub мутабельны. Обновление nginx внутри nginx-ui вполне может
приехать перезаливкой существующего тега — так закрывали, например,
CVE-2026-42945 в `ngx_http_rewrite_module`. Пин по тегу такого не заметит.

### Откат

Каждая успешная сборка получает неизменяемый тег вида
`nginx1.31.3-crs4.20.0-20260808`, старые образы остаются на машине.

```bash
docker images nginx-ui-modsec        # посмотреть, что есть
# вернуть предыдущее значение в IMAGE_TAG внутри .env
docker-compose up -d
```

Пересборка при этом не нужна.

### Единственный сценарий с ручным вмешательством

Апстрим поднял nginx до версии, которую коннектор ModSecurity-nginx ещё не
поддерживает. Тогда `./build.sh --update` упадёт на `nginx -t`, `.env`
останется с рабочим `IMAGE_TAG`, прод не тронется. Ждать релиза коннектора.

## Проверки на живой системе

```bash
# модуль загружен
docker-compose exec nginx-ui nginx -T | grep -c modsecurity_module

# правила подхватились, ошибок Include нет
docker-compose logs nginx-ui | grep -i modsecurity | head

# срабатывание (в DetectionOnly — без блокировки, но с записью в лог)
curl -s "https://ваш-домен/?id=1%20AND%201=1--" -o /dev/null
docker-compose logs --tail 20 nginx-ui
```

Пересобрать и протестировать образ, ничего не деплоя:

```bash
./build.sh
./test/smoke.sh nginx-ui-modsec:candidate
```

## Что перепроверить при первой сборке

Версии зависимостей меняются, а собрать и проверить эту сборку у меня
возможности не было:

- `MODSEC_NGINX_VERSION` — актуальный тег коннектора ModSecurity-nginx
- `MODSEC_VERSION` — актуальный релиз ModSecurity v3
- `CRS_VERSION` — актуальный релиз CRS
- `libcurl4t64` в Dockerfile — имя пакета libcurl в Debian trixie;
  если apt не находит, попробуйте `libcurl4`
- `--with-pcre2` — если configure ModSecurity не знает такой опции,
  уберите её (в старых версиях PCRE2 подхватывается автоматически)

## Известные грабли

Собрано по итогам первого развёртывания на VMware Photon OS 4.0 / Docker 24:

- **`BuildKit is enabled but the buildx component is missing`.** В Docker 23+
  переменная `DOCKER_BUILDKIT=1` не включает BuildKit в демоне, а передаёт
  сборку в buildx. `build.sh` определяет отсутствие buildx и уходит на
  legacy-билдер сам; не задавайте `DOCKER_BUILDKIT` вручную.
- **`configure: error: ngx_http_modsecurity_module requires the ModSecurity
  library ... we cannot find ModSecurity there`** при том, что библиотека
  на месте. Причина не в путях: тест-снипет коннектора вызывает `printf`
  без `stdio.h`, а GCC 14 (он в Debian 13) сделал неявное объявление функции
  ошибкой. Dockerfile патчит `config` коннектора и дополнительно снимает
  `-Werror` через `--with-cc-opt`.
- **`COPY failed: file not found in build context`.** Потерялись вложенные
  файлы при копировании по одному — проверьте, что на месте `modsec/main.conf`
  и `test/smoke.conf`.
- **`yaml: line 11: mapping values are not allowed in this context`.**
  Значение с `${VAR:?текст}` должно быть в кавычках, если внутри текста есть
  `: ` — YAML читает это как вложенное отображение. Та же ловушка ждёт любой
  URL или путь с двоеточием в неэкранированном скаляре.
- **`Permission denied` при запуске скриптов.** Бит исполнения теряется при
  переносе: `chmod +x build.sh test/smoke.sh`.
- **`Rules error ... /etc/modsecurity.d/custom/before/*.conf: Not able to open
  file`.** ModSecurity, в отличие от nginx, падает, если `Include` с маской
  не нашёл ни одного файла. В каждом каталоге исключений лежит
  `00-placeholder.conf` — не удаляйте его, пока там нет ваших правил.
  Заглушка нужна и на хосте: том `./modsec/custom` перекрывает содержимое
  образа.
- **Дымовой тест: 200 на атаки и пустой аудит-лог.** Признак того, что
  правила не выполнялись ни разу. Частая причина — `return 200` или `rewrite`
  в тестовом конфиге: они обрабатываются на фазе rewrite, а ModSecurity
  подключается на preaccess, которая идёт позже. Запрос завершается раньше
  проверки. В `test/smoke.conf` поэтому отдаётся реальный файл из `test/www/`.
- **Атаки получают 200, а в логе `ModSecurity: Warning`.** Правила работают,
  но движок в `DetectionOnly` — это штатный режим образа. Для блокировки
  нужен `SecRuleEngine On`. Учтите: директива `modsecurity_rules` рядом
  с `modsecurity_rules_file` переопределение НЕ гарантирует, порядок слияния
  не определён. Надёжный способ — поставить `SecRuleEngine On` последней
  строкой в самом файле правил, после всех `Include`.
- **Аудит-лог в Native вместо JSON** (разделители вида `---AbCdEf---A--`).
  В `modsecurity.conf-recommended` директивы `SecAuditLogFormat` может
  не быть, и замена по шаблону молча ничего не делает. Образ поэтому
  дописывает свои настройки в конец файла: у ModSecurity выигрывает
  последнее вхождение директивы.
- **`ldconfig: libmodsecurity.so.3 is not a symbolic link`.** `COPY` с маской
  `libmodsecurity.so*` разыменовывает симлинки и кладёт три полноценных файла
  вместо одного и двух ссылок (+114 МБ к образу). Копируется только реальный
  файл, soname-ссылки создаются в том же слое через `ln -s`.
