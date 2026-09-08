# Versioned stream-site assets

Этот каталог — постоянное место для SelfSteal/decoy стрим-сайта.

Цель: новые ноды должны получать сайт из GitHub вместе с версией установщика, а не зеркалить HTML с другой рабочей ноды.

Приоритет источников в `production/install-stream-site.sh`:

1. `assets/stream-site/` из этого репозитория;
2. локальный `STREAM_SITE_ARCHIVE=/path/site.tar.gz`;
3. пинованный `STREAM_SITE_ARCHIVE_URL` + опциональный `STREAM_SITE_SHA256`;
4. старый fetch с `https://rustream.remna.space` только при `ALLOW_LEGACY_STREAM_FETCH=1`.

В проекте `evgmahov-blip/remna-node-scripts` сам статический сайт сейчас не хранится: `install-caddy-node-reality-stream-core.sh` по умолчанию зеркалит `https://rustream.remna.space` в `/var/www/mstream`. Поэтому точный текущий snapshot сайта нужно один раз импортировать сюда (index.html + локальные CSS/JS/media), после чего legacy fetch можно окончательно убрать.

Рекомендуемая структура:

```text
assets/stream-site/
  index.html
  assets/
    *.css
    *.js
    images/*
```

Не хранить здесь секреты, сертификаты, ключи Reality или данные конкретной ноды.
