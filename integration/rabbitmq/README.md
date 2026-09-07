# RabbitMQ integration suite

The suite targets the pinned
[official RabbitMQ 4 image](https://hub.docker.com/_/rabbitmq) in `compose.yml`
and a disposable `opal_test` vhost. Start it from the repository root:

```bash
docker compose -f integration/rabbitmq/compose.yml up -d --wait
```

Run the real-broker specs:

```bash
OPAL_RABBITMQ_TEST_URL='amqp://opal:opal@127.0.0.1:5673/opal_test' \
  crystal spec integration/rabbitmq_spec.cr --no-color
```

Then remove the broker and its durable test resources:

```bash
docker compose -f integration/rabbitmq/compose.yml down -v
```

Without `OPAL_RABBITMQ_TEST_URL`, the file compiles but reports one pending
integration requirement. Unit specs use an injected session and do not require
Docker.

The automated live cases cover startup/declarations, end-to-end RPC replies,
delayed retry, mandatory unroutable publication, inequivalent queue arguments,
and deleted exclusive reply routes. Broker restart remains an orchestrated
test: stop the Compose service after a confirmed request, start it again, call
`RPCClient#reconnect`, and verify that the accepted correlation becomes
outcome-unknown and is never republished.
