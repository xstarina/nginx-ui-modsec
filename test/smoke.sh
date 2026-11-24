#!/usr/bin/env bash
# Дымовой тест собранного образа: модуль грузится, CRS реально срабатывает.
#   ./test/smoke.sh nginx-ui-modsec:candidate
set -euo pipefail

IMAGE="${1:?укажите образ}"
HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="modsec-smoke-$$"
PORT=18081
fail=0

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --name "$NAME" \
    --entrypoint nginx \
    -v "${HERE}/smoke.conf:/tmp/smoke.conf:ro" \
    -v "${HERE}/smoke-rules.conf:/tmp/smoke-rules.conf:ro" \
    -v "${HERE}/www:/tmp/www:ro" \
    -p "127.0.0.1:${PORT}:8081" \
    "$IMAGE" -c /tmp/smoke.conf -g 'daemon off;' >/dev/null

for _ in $(seq 30); do
    curl -fsS -o /dev/null -H 'Host: smoke.test' "http://127.0.0.1:${PORT}/" 2>/dev/null && break
    sleep 1
done

check() {
    local want="$1" url="$2" label="$3" got
    got=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: smoke.test' "$url" || echo 000)
    if [ "$got" = "$want" ]; then
        printf '  ok    %s (%s)\n' "$label" "$got"
    else
        printf '  ПРОВАЛ %s: ожидался %s, получен %s\n' "$label" "$want" "$got"
        fail=1
    fi
}

echo "дымовой тест ${IMAGE}:"
check 200 "http://127.0.0.1:${PORT}/" "обычный запрос проходит"
check 403 "http://127.0.0.1:${PORT}/?q=%27%20OR%201%3D1--" "SQLi блокируется (CRS 942xxx)"
check 403 "http://127.0.0.1:${PORT}/?q=%3Cscript%3Ealert(1)%3C/script%3E" "XSS блокируется (CRS 941xxx)"

if docker logs "$NAME" 2>&1 | grep -q '"transaction"'; then
    printf '  ok    аудит-лог пишется в JSON\n'
else
    printf '  ПРОВАЛ аудит-лог пуст или не в JSON\n'
    fail=1
fi

if [ "$fail" != 0 ]; then
    echo
    echo "--- последние 30 строк из контейнера ---"
    docker logs "$NAME" 2>&1 | tail -30
    echo "---"
    echo "подсказки:"
    echo "  200 на атаки, лог ПУСТ      -> правила не выполняются: в конфиге"
    echo "                                 return/rewrite обрывает запрос до"
    echo "                                 фазы preaccess, где работает WAF"
    echo "  200 на атаки, в логе Warning -> движок в DetectionOnly, а не On"
    echo "  лог не в JSON               -> SecAuditLogFormat не применился"
fi

exit $fail
