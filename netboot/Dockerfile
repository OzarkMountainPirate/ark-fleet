FROM debian:trixie-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends dnsmasq \
 && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["dnsmasq","-k","--log-facility=-","--conf-file=/etc/dnsmasq.conf"]
