# Transport 443 mux

Экспериментальная надстройка для `setup-remna-node`, позволяющая использовать один внешний порт `443` для нескольких клиентских транспортов Remnawave.

## Схема

- TCP/443: Nginx `stream` + `ssl_preread` распределяет соединения по SNI.
- UDP/443: Hysteria2 слушает напрямую в Xray.
- Внутренние TCP inbound Xray:
  - Vision: `127.0.0.1:10443`
  - XHTTP: `127.0.0.1:11443`
  - gRPC: `127.0.0.1:12443`

Для TCP-транспортов требуются разные SNI, например:

- `vision.node.example.com`
- `xhttp.node.example.com`
- `grpc.node.example.com`

Все записи могут указывать на один IP.

## Безопасность

Скрипт:

- не открывает наружу внутренние TCP-порты;
- открывает только `443/tcp` и `443/udp`;
- проверяет занятость внутренних TCP-портов;
- делает резервные копии предыдущих transport443-файлов;
- проверяет `docker compose config` и `nginx -t` до применения;
- не изменяет Config Profile Remnawave автоматически.

## Применение

После обычной установки ноды:

```bash
sudo bash /path/to/setup-remna-node/transport443/install.sh
```

После этого Config Profile в Remnawave должен использовать внутренние порты, а Host — внешний порт `443`.

## Важно

Это отдельная feature-ветка для тестирования. Не сливайте её в production до проверки на тестовой ноде.
