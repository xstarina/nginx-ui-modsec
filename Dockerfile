# syntax=docker/dockerfile:1.7
#
# ModSecurity v3 + OWASP CRS поверх официального образа uozi/nginx-ui.
#
# Версия nginx НЕ задаётся руками: она читается из ENV NGINX_VERSION базового
# образа на этапе сборки. Рассинхрон "модуль собран под другой nginx"
# становится невозможен by construction.
#
# База пинится дайджестом, а не только тегом: теги на Docker Hub мутабельны,
# и обновление nginx внутри может приехать перезаливкой того же тега.
#
# Текущий дайджест:
#   ./build.sh --check

# Все значения приходят из .env через build.sh / docker compose build.
# Дефолты здесь только чтобы `docker build .` без аргументов не падал молча.
ARG NGINX_UI_IMAGE=uozi/nginx-ui
ARG NGINX_UI_TAG=latest
ARG NGINX_UI_DIGEST=sha256:54d6b3b01e5243e8b410ed176877328a895cc50cddb75f5725a1f28e8e46f551

ARG BUILDER_BASE=debian:trixie-slim
ARG MODSEC_VERSION=v3.0.14
ARG MODSEC_NGINX_VERSION=v1.0.3
ARG CRS_VERSION=4.20.0


# ------------------------------------------------------------------- base ---
# Снимаем с базового образа всё, что нужно сборщику, и проверяем пригодность.
FROM ${NGINX_UI_IMAGE}:${NGINX_UI_TAG}@${NGINX_UI_DIGEST} AS base

# Снимаем с базы: версию nginx (из её собственного ENV) и кодовое имя
# дистрибутива — сборщик обязан совпадать по glibc и gcc.
# Без --with-compat вся затея не работает: модуль не загрузится.
RUN set -eux; \
    mkdir -p /probe; \
    printf '%s' "$NGINX_VERSION" > /probe/nginx_version; \
    . /etc/os-release; printf '%s' "$VERSION_CODENAME" > /probe/codename; \
    nginx -V 2>&1 | grep -q -- '--with-compat' \
        || { echo "БАЗА СОБРАНА БЕЗ --with-compat, динамический модуль невозможен"; exit 1; }; \
    cat /probe/nginx_version /probe/codename


# ---------------------------------------------------------------- builder ---
FROM ${BUILDER_BASE} AS builder

ARG MODSEC_VERSION
ARG MODSEC_NGINX_VERSION

COPY --from=base /probe/ /probe/

# Сборщик и база должны быть на одном релизе Debian.
RUN set -eux; \
    . /etc/os-release; \
    want="$(cat /probe/codename)"; \
    [ "$VERSION_CODENAME" = "$want" ] \
        || { echo "СБОРЩИК=$VERSION_CODENAME, БАЗА=$want — поправьте BUILDER_BASE"; exit 1; }

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates git curl pkgconf \
        autoconf automake libtool \
        libpcre2-dev libxml2-dev libyajl-dev liblmdb-dev \
        libcurl4-openssl-dev libmaxminddb-dev libssl-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# --- libmodsecurity ---
RUN git clone --depth 1 -b "${MODSEC_VERSION}" --recursive \
        https://github.com/owasp-modsecurity/ModSecurity /src/modsecurity
WORKDIR /src/modsecurity
# --enable-static обязателен: коннектор в ряде версий линкуется именно
# со статической libmodsecurity.a, а не с .so.
RUN ./build.sh \
    && ./configure \
        --prefix=/usr/local/modsecurity \
        --with-pcre2 \
        --with-lmdb \
        --with-maxmind \
        --enable-shared --enable-static \
        --disable-doxygen-doc --disable-doxygen-html --disable-examples \
    && make -j"$(nproc)" \
    && make install \
    && ldconfig

# Проверяем, что установилось именно туда, где коннектор будет искать.
# Без этого несовпадение путей всплывёт позже как невнятное
# "cannot find ModSecurity there".
RUN set -eux; \
    echo '--- содержимое /usr/local/modsecurity ---'; \
    find /usr/local/modsecurity -maxdepth 3 \
        \( -name 'libmodsecurity*' -o -name 'modsecurity.h' -o -name '*.pc' \) -print; \
    test -f /usr/local/modsecurity/include/modsecurity/modsecurity.h \
        || { echo 'ЗАГОЛОВКИ НЕ ТАМ: modsecurity.h не найден в include/modsecurity/'; exit 1; }; \
    ls /usr/local/modsecurity/lib/libmodsecurity.so >/dev/null 2>&1 \
        || ls /usr/local/modsecurity/lib/libmodsecurity.a >/dev/null 2>&1 \
        || { echo 'БИБЛИОТЕКА НЕ СОБРАЛАСЬ: нет ни .so, ни .a в lib/'; exit 1; }

# --- коннектор -> динамический модуль ---
RUN git clone --depth 1 -b "${MODSEC_NGINX_VERSION}" \
        https://github.com/owasp-modsecurity/ModSecurity-nginx /src/modsecurity-nginx

# GCC 14 сделал implicit function declaration ошибкой (было предупреждением).
# Тест-снипет в config коннектора вызывает printf, не подключая stdio.h,
# поэтому проверка "есть ли ModSecurity" падает на компиляции — и configure
# сообщает, что библиотеки нет, хотя она на месте.
# Добавляем недостающий заголовок. Проверка на grep делает шаг идемпотентным:
# когда коннектор починят в апстриме, sed просто не сработает.
RUN set -eux; \
    cfg=/src/modsecurity-nginx/config; \
    if ! grep -q '#include <stdio.h>' "$cfg"; then \
        sed -i 's|#include <modsecurity/modsecurity.h>|#include <stdio.h>\n#include <modsecurity/modsecurity.h>|' "$cfg"; \
        echo 'в config коннектора добавлен stdio.h'; \
    else \
        echo 'stdio.h уже присутствует, патч не нужен'; \
    fi; \
    grep -n 'ngx_feature_incs' -A3 "$cfg" || true

ENV MODSECURITY_INC=/usr/local/modsecurity/include \
    MODSECURITY_LIB=/usr/local/modsecurity/lib

# --with-cc-opt со снятым -Werror — вторая линия обороны на случай, если
# патч config не сработал: nginx прокидывает эти флаги и в тесты configure.
# При неудаче configure печатает лишь общее "cannot find ModSecurity",
# поэтому настоящую причину достаём из objs/autoconf.err.
RUN set -eux; \
    ver="$(cat /probe/nginx_version)"; \
    echo "собираю модуль под nginx ${ver}"; \
    curl -fsSL "https://nginx.org/download/nginx-${ver}.tar.gz" | tar -xz -C /src; \
    cd "/src/nginx-${ver}"; \
    if ! ./configure --with-compat \
            --with-cc-opt='-Wno-error=implicit-function-declaration -Wno-implicit-function-declaration' \
            --add-dynamic-module=/src/modsecurity-nginx; then \
        echo '=================== objs/autoconf.err ==================='; \
        tail -n 60 objs/autoconf.err 2>/dev/null || echo '(файл отсутствует)'; \
        echo '========================================================'; \
        echo "MODSECURITY_INC=${MODSECURITY_INC}"; ls -la "${MODSECURITY_INC}" || true; \
        echo "MODSECURITY_LIB=${MODSECURITY_LIB}"; ls -la "${MODSECURITY_LIB}" || true; \
        exit 1; \
    fi; \
    make -j"$(nproc)" modules; \
    mkdir -p /out/lib; \
    cp objs/ngx_http_modsecurity_module.so /out/; \
    cp /usr/local/modsecurity/lib/libmodsecurity.so.3.* /out/lib/; \
    for component in modsecurity modsecurity-nginx; do \
        mkdir -p "/out/licenses/$component"; \
        cp "/src/$component/LICENSE" "/out/licenses/$component/"; \
        if [ -f "/src/$component/NOTICE" ]; then cp "/src/$component/NOTICE" "/out/licenses/$component/"; fi; \
    done; \
    ls -la /out /out/lib


# -------------------------------------------------------------------- crs ---
FROM ${BUILDER_BASE} AS crs

ARG CRS_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL "https://github.com/coreruleset/coreruleset/archive/refs/tags/v${CRS_VERSION}.tar.gz" \
       | tar -xz -C /opt \
    && mv "/opt/coreruleset-${CRS_VERSION}" /opt/owasp-crs \
    && cp /opt/owasp-crs/crs-setup.conf.example /opt/owasp-crs/crs-setup.conf \
    && rm -rf /opt/owasp-crs/tests /opt/owasp-crs/util /opt/owasp-crs/.github


# ------------------------------------------------------------------ final ---
FROM ${NGINX_UI_IMAGE}:${NGINX_UI_TAG}@${NGINX_UI_DIGEST}

ARG MODSEC_VERSION
ARG MODSEC_NGINX_VERSION
ARG CRS_VERSION

# В trixie libcurl4 переименован в libcurl4t64 (time_t transition).
RUN apt-get update && apt-get install -y --no-install-recommends \
        libyajl2 liblmdb0 libxml2 libmaxminddb0 libpcre2-8-0 libcurl4t64 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /out/ngx_http_modsecurity_module.so /usr/lib/nginx/modules/
COPY --from=builder /out/lib/ /usr/local/lib/
COPY --from=builder /out/licenses/ /usr/share/doc/nginx-ui-modsec/
COPY LICENSE THIRD_PARTY.md /usr/share/doc/nginx-ui-modsec/
COPY --from=builder /src/modsecurity/unicode.mapping /etc/modsecurity.d/
COPY --from=builder /src/modsecurity/modsecurity.conf-recommended /etc/modsecurity.d/modsecurity.conf

COPY --from=crs /opt/owasp-crs /opt/owasp-crs
COPY modsec/main.conf /etc/modsecurity.d/main.conf

RUN set -eux; \
    real="$(basename /usr/local/lib/libmodsecurity.so.3.*)"; \
    ln -sf "$real" /usr/local/lib/libmodsecurity.so.3; \
    ln -sf libmodsecurity.so.3 /usr/local/lib/libmodsecurity.so; \
    ldconfig; \
    ldconfig -p | grep libmodsecurity; \
    mkdir -p /etc/modsecurity.d/custom/before /etc/modsecurity.d/custom/after; \
    printf '# Заглушка: ModSecurity падает, если Include с маской ничего не нашёл.\n# Удалять не нужно, свои правила кладите рядом отдельными файлами.\n' \
        > /etc/modsecurity.d/custom/before/00-placeholder.conf; \
    cp /etc/modsecurity.d/custom/before/00-placeholder.conf \
        /etc/modsecurity.d/custom/after/00-placeholder.conf; \
    printf '%s\n' \
        '' \
        '# --- Переопределения образа -----------------------------------------' \
        '# Дописаны в конец намеренно: в modsecurity.conf-recommended часть этих' \
        '# директив отсутствует, и sed по шаблону молча ничего бы не заменил.' \
        '# У ModSecurity выигрывает последнее вхождение директивы.' \
        'SecRuleEngine DetectionOnly' \
        'SecAuditEngine RelevantOnly' \
        'SecAuditLog /dev/stdout' \
        'SecAuditLogType Serial' \
        'SecAuditLogFormat JSON' \
        'SecAuditLogParts ABIJDEFHZ' \
        'SecUnicodeMapFile /etc/modsecurity.d/unicode.mapping 20127' \
        >> /etc/modsecurity.d/modsecurity.conf; \
    tail -12 /etc/modsecurity.d/modsecurity.conf; \
    f=/usr/local/etc/nginx/nginx.conf; \
    if [ -f "$f" ] && ! grep -q modsecurity_module "$f"; then \
        sed -i '1i load_module /usr/lib/nginx/modules/ngx_http_modsecurity_module.so;' "$f"; \
    fi

# Проверка на этапе сборки: модуль реально грузится этим nginx.
RUN set -eux; \
    printf 'load_module /usr/lib/nginx/modules/ngx_http_modsecurity_module.so;\nevents{}\nhttp{ modsecurity on; modsecurity_rules_file /etc/modsecurity.d/main.conf; server{listen 8081;} }\n' \
      > /tmp/t.conf; \
    nginx -t -c /tmp/t.conf; \
    rm -f /tmp/t.conf

ARG VERSION=dev
ARG COMMIT_SHA=

LABEL org.opencontainers.image.title="nginx-ui-modsec" \
      org.opencontainers.image.description="nginx-ui with ModSecurity v3 and OWASP Core Rule Set" \
      org.opencontainers.image.vendor="xstarina" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${COMMIT_SHA}" \
      org.opencontainers.image.source="https://github.com/xstarina/nginx-ui-modsec" \
      modsec.modsecurity.version="${MODSEC_VERSION}" \
      modsec.connector.version="${MODSEC_NGINX_VERSION}" \
      modsec.crs.version="${CRS_VERSION}"
