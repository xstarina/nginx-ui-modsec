#!/usr/bin/env bash
#
# Локальная сборка образа nginx-ui с ModSecurity.
#
#   ./build.sh            собрать, протестировать, проставить IMAGE_TAG в .env
#   ./build.sh --check    только проверить, не изменился ли базовый образ
#   ./build.sh --update   подтянуть новый дайджест базы в .env и собрать
#   ./build.sh --doctor   показать, что найдено в системе
#
# Зависимости: docker, bash, sed. buildx и docker-compose-плагин НЕ требуются.
#
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] || { echo "нет .env рядом со скриптом"; exit 1; }
set -a; . ./.env; set +a

MODE="${1:-build}"

if [ -t 1 ]; then
    c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
else
    c_ok=''; c_warn=''; c_err=''; c_dim=''; c_off=''
fi
say()  { printf '%s\n' "$*"; }
dim()  { printf '%s%s%s\n' "$c_dim" "$*" "$c_off"; }
ok()   { printf '%s+%s %s\n' "$c_ok" "$c_off" "$*"; }
warn() { printf '%s!%s %s\n' "$c_warn" "$c_off" "$*"; }
die()  { printf '%s-%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }

command -v docker >/dev/null || die "docker не найден"

# ---------------------------------------------------------------------------
# Окружение: что доступно на этой машине
# ---------------------------------------------------------------------------
HAVE_BUILDX=0
docker buildx version >/dev/null 2>&1 && HAVE_BUILDX=1

HAVE_CURL=0
command -v curl >/dev/null 2>&1 && HAVE_CURL=1

COMPOSE=""
if docker compose version >/dev/null 2>&1; then
    COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE="docker-compose"
fi

# Выбор билдера.
# В Docker 23+ CLI переменная DOCKER_BUILDKIT=1 НЕ включает BuildKit внутри
# демона — она перенаправляет сборку в buildx. Если buildx не установлен,
# docker build падает с "BuildKit is enabled but the buildx component is
# missing". Поэтому без buildx осознанно уходим на legacy-билдер: этому
# Dockerfile его возможностей хватает (ARG перед FROM, COPY --from, многостадийность).
if [ -n "${DOCKER_BUILDKIT+x}" ]; then
    : # значение задано снаружи — уважаем
elif [ "$HAVE_BUILDX" = 1 ]; then
    DOCKER_BUILDKIT=1
else
    DOCKER_BUILDKIT=0
fi
export DOCKER_BUILDKIT

if [ "$DOCKER_BUILDKIT" = "1" ] && [ "$HAVE_BUILDX" = 0 ]; then
    die "DOCKER_BUILDKIT=1 задан, но buildx не установлен.
   Уберите переменную (скрипт выберет legacy-билдер сам)
   или поставьте buildx как cli-plugin."
fi

doctor() {
    say "окружение:"
    dim  "  docker            $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')"
    if [ "$HAVE_BUILDX" = 1 ]; then
        dim "  buildx            есть"
    else
        dim "  buildx            нет (не требуется)"
    fi
    if [ "$DOCKER_BUILDKIT" = "1" ]; then
        dim "  билдер            buildkit (через buildx)"
    else
        dim "  билдер            legacy (buildx не нужен)"
    fi
    if [ -n "$COMPOSE" ]; then
        dim "  compose           ${COMPOSE}"
    else
        dim "  compose           не найден"
    fi
    if [ "$HAVE_CURL" = 1 ]; then
        dim "  curl              есть (дайджест без скачивания образа)"
    else
        dim "  curl              нет (дайджест через docker pull)"
    fi
    if [ -n "${PLATFORM:-}" ] && [ "$DOCKER_BUILDKIT" != "1" ]; then
        warn "PLATFORM=${PLATFORM} задан, но собирать будет legacy-билдер — он не умеет --platform."
        warn "Уберите PLATFORM из .env (сборка пойдёт под архитектуру этой машины)"
        warn "или поставьте buildx."
    fi
}

# ---------------------------------------------------------------------------
# Дайджест базового образа в реестре.
# Три способа по убыванию дешевизны; buildx среди них не обязателен.
# ---------------------------------------------------------------------------
remote_digest_via_registry() {
    [ "$HAVE_CURL" = 1 ] || return 1

    local repo="$NGINX_UI_IMAGE" tag="$NGINX_UI_TAG" token digest
    # официальные образы живут в library/
    case "$repo" in */*) ;; *) repo="library/$repo" ;; esac

    token=$(curl -fsSL --max-time 20 \
        "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" \
        2>/dev/null | sed -n 's/.*"token":"\([^"]*\)".*/\1/p') || return 1
    [ -n "$token" ] || return 1

    digest=$(curl -fsSL --max-time 20 -I \
        -H "Authorization: Bearer ${token}" \
        -H 'Accept: application/vnd.oci.image.index.v1+json' \
        -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
        -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
        "https://registry-1.docker.io/v2/${repo}/manifests/${tag}" 2>/dev/null \
        | tr -d '\r' | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: //p') || return 1

    [ -n "$digest" ] && printf '%s' "$digest"
}

remote_digest_via_buildx() {
    [ "$HAVE_BUILDX" = 1 ] || return 1
    docker buildx imagetools inspect "${NGINX_UI_IMAGE}:${NGINX_UI_TAG}" \
        --format '{{.Manifest.Digest}}' 2>/dev/null
}

remote_digest_via_pull() {
    docker pull "${NGINX_UI_IMAGE}:${NGINX_UI_TAG}" >/dev/null 2>&1 || return 1
    docker image inspect "${NGINX_UI_IMAGE}:${NGINX_UI_TAG}" \
        --format '{{index .RepoDigests 0}}' 2>/dev/null | sed 's/.*@//'
}

remote_digest() {
    local d
    d=$(remote_digest_via_registry) && [ -n "$d" ] && { printf '%s' "$d"; return 0; }
    d=$(remote_digest_via_buildx)   && [ -n "$d" ] && { printf '%s' "$d"; return 0; }
    warn "определяю дайджест через docker pull (скачается базовый образ)" >&2
    d=$(remote_digest_via_pull)     && [ -n "$d" ] && { printf '%s' "$d"; return 0; }
    return 1
}

check_base() {
    say "проверяю ${NGINX_UI_IMAGE}:${NGINX_UI_TAG} ..."
    local remote
    if ! remote="$(remote_digest)"; then
        warn "дайджест получить не удалось (нет сети до Docker Hub?)"
        return 2
    fi

    if [ "$remote" = "$NGINX_UI_DIGEST" ]; then
        ok "базовый образ не менялся"
        return 0
    fi

    warn "базовый образ обновился"
    say  "   было:  ${NGINX_UI_DIGEST}"
    say  "   стало: ${remote}"
    say  ""
    say  "Внутри мог смениться nginx — тогда нужен новый модуль."
    say  "Версия подтянется из образа автоматически:  ./build.sh --update"
    return 1
}

update_base() {
    local remote
    remote="$(remote_digest)" || die "не удалось получить дайджест"
    if [ "$remote" != "$NGINX_UI_DIGEST" ]; then
        sed -i.bak "s|^NGINX_UI_DIGEST=.*|NGINX_UI_DIGEST=${remote}|" .env
        ok "дайджест базы обновлён в .env (бэкап: .env.bak)"
        NGINX_UI_DIGEST="$remote"
    else
        ok "дайджест базы уже актуален"
    fi
}

# ---------------------------------------------------------------------------
build_image() {
    local args=()
    if [ -n "${PLATFORM:-}" ]; then
        [ "$DOCKER_BUILDKIT" = "1" ] \
            || die "PLATFORM=${PLATFORM} требует buildx; уберите PLATFORM из .env или поставьте buildx"
        args+=(--platform "$PLATFORM")
    fi

    if [ "$DOCKER_BUILDKIT" = "1" ]; then
        say "сборка ${IMAGE_NAME}:candidate (buildkit) ..."
    else
        say "сборка ${IMAGE_NAME}:candidate (legacy-билдер) ..."
    fi
    docker build \
        "${args[@]}" \
        --build-arg "NGINX_UI_IMAGE=${NGINX_UI_IMAGE}" \
        --build-arg "NGINX_UI_TAG=${NGINX_UI_TAG}" \
        --build-arg "NGINX_UI_DIGEST=${NGINX_UI_DIGEST}" \
        --build-arg "BUILDER_BASE=${BUILDER_BASE}" \
        --build-arg "MODSEC_VERSION=${MODSEC_VERSION}" \
        --build-arg "MODSEC_NGINX_VERSION=${MODSEC_NGINX_VERSION}" \
        --build-arg "CRS_VERSION=${CRS_VERSION}" \
        -t "${IMAGE_NAME}:candidate" \
        .
    ok "образ собран"
}

# ---------------------------------------------------------------------------
promote() {
    local nginx_ver crs_ver tag prev
    nginx_ver=$(docker image inspect "${IMAGE_NAME}:candidate" \
        --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^NGINX_VERSION=//p')
    crs_ver=$(docker image inspect "${IMAGE_NAME}:candidate" \
        --format '{{index .Config.Labels "modsec.crs.version"}}')
    tag="nginx${nginx_ver}-crs${crs_ver}-$(date +%Y%m%d)"

    docker tag "${IMAGE_NAME}:candidate" "${IMAGE_NAME}:${tag}"
    docker rmi "${IMAGE_NAME}:candidate" >/dev/null 2>&1 || true

    prev="${IMAGE_TAG:-}"
    sed -i.bak "s|^IMAGE_TAG=.*|IMAGE_TAG=${tag}|" .env

    ok "готов образ ${IMAGE_NAME}:${tag}"
    say ""
    if [ -n "$COMPOSE" ]; then
        say "запустить:   ${COMPOSE} up -d"
    else
        warn "compose не найден: поставьте docker-compose или плагин docker compose"
    fi
    if [ -n "$prev" ] && [ "$prev" != "$tag" ]; then
        say "откатиться:  IMAGE_TAG=${prev} в .env, затем ${COMPOSE:-docker-compose} up -d"
    fi
    say ""
    dim "старые образы остаются локально:  docker images ${IMAGE_NAME}"
}

# ---------------------------------------------------------------------------
case "$MODE" in
    --doctor)
        doctor
        ;;
    --check)
        doctor; say ""
        check_base
        ;;
    --update)
        update_base
        build_image
        ./test/smoke.sh "${IMAGE_NAME}:candidate" || die "дымовой тест не прошёл, образ не помечен"
        promote
        ;;
    build)
        # расхождение дайджеста и отсутствие сети — не повод не собирать
        check_base || warn "собираю на дайджесте, зафиксированном в .env"
        build_image
        ./test/smoke.sh "${IMAGE_NAME}:candidate" || die "дымовой тест не прошёл, образ не помечен"
        promote
        ;;
    *)
        die "неизвестный режим: $MODE (build | --check | --update | --doctor)"
        ;;
esac
