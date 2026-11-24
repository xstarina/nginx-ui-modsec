# Сторонние компоненты

Образ использует стороннее программное обеспечение. Его правообладатели и
лицензии сохраняются; MIT-лицензия этого репозитория не заменяет их условия.

| Компонент | Источник | Лицензия |
|---|---|---|
| Nginx UI и базовый образ `uozi/nginx-ui` | [исходный код](https://github.com/0xJacky/nginx-ui), [образ](https://hub.docker.com/r/uozi/nginx-ui) | [AGPL-3.0](https://github.com/0xJacky/nginx-ui/blob/dev/LICENSE) |
| nginx | [исходный код](https://github.com/nginx/nginx) | [BSD-2-Clause](https://github.com/nginx/nginx/blob/master/LICENSE) |
| ModSecurity v3 | [исходный код](https://github.com/owasp-modsecurity/ModSecurity) | [Apache-2.0](https://github.com/owasp-modsecurity/ModSecurity/blob/v3/master/LICENSE) |
| ModSecurity-nginx | [исходный код](https://github.com/owasp-modsecurity/ModSecurity-nginx) | [Apache-2.0](https://github.com/owasp-modsecurity/ModSecurity-nginx/blob/master/LICENSE) |
| OWASP Core Rule Set | [исходный код](https://github.com/coreruleset/coreruleset) | [Apache-2.0](https://github.com/coreruleset/coreruleset/blob/main/LICENSE) |
| Debian и пакеты | [Debian](https://www.debian.org/) | Различные лицензии; сведения о пакетах находятся в `/usr/share/doc/` образа |

Коннектор ModSecurity-nginx при сборке может изменяться: в его `config`
добавляется `#include <stdio.h>`, если эта строка отсутствует. Версии
зависимостей и дайджест базового образа указаны в `.env` и Dockerfile.
При сборке копии лицензий ModSecurity и коннектора, а также их файлы NOTICE,
если они присутствуют, помещаются в `/usr/share/doc/nginx-ui-modsec/`.
Файлы лицензии и уведомления CRS остаются в `/opt/owasp-crs/`.

При распространении образа необходимо соблюдать лицензии всех включённых
компонентов, включая требования к уведомлениям и предоставлению исходного
кода, когда они применимы. В частности, проверьте условия AGPL для Nginx UI и
соответствующий исходный код именно той версии базового образа, которую вы
распространяете. Ссылки на проекты сами по себе не заменяют эти требования.
