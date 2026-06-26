FROM alpine:3.20
RUN apk add --no-cache libnatpmp curl
COPY run.sh /usr/local/bin/run.sh
RUN chmod +x /usr/local/bin/run.sh
ENTRYPOINT ["/usr/local/bin/run.sh"]