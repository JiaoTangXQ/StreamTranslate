#!/bin/sh
set -eu
/opt/streamtranslate-certbot/bin/python3 /opt/streamtranslate-relay/certbot-with-doh.py renew --quiet --no-random-sleep-on-renew \
  --config-dir /etc/streamtranslate-certificates \
  --work-dir /var/lib/streamtranslate-certificates \
  --logs-dir /var/log/streamtranslate-certificates \
  --deploy-hook '/usr/sbin/nginx -t && /usr/bin/systemctl reload nginx'
