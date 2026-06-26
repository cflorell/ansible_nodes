FROM alpine:3.20

COPY run.sh /usr/local/bin/run.sh
RUN chmod 0755 /usr/local/bin/run.sh \
    && addgroup -S app \
    && adduser -S -G app app \
    && apk add --no-cache curl=8.14.1-r2 libnatpmp=20230423-r0

USER app
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD test -f /tmp/natpmp-keeper.heartbeat || exit 1
ENTRYPOINT ["/usr/local/bin/run.sh"]
