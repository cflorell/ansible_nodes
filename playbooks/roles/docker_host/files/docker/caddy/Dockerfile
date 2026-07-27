FROM caddy:2-builder AS builder
# porkbun:     DNS-01 solver for the *.<domain> wildcard certificate.
# ratelimit:   throttles the login endpoints of the services

RUN xcaddy build \
    --with github.com/caddy-dns/porkbun \
    --with github.com/mholt/caddy-ratelimit

FROM caddy:2-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
