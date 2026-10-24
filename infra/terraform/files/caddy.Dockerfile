# Caddy with the rate limit plugin, which the stock image lacks. The host
# builds it itself (ci-timing-build-caddy), so there is no registry to keep.
FROM caddy:2.11.7-builder-alpine AS build
RUN xcaddy build --with github.com/mholt/caddy-ratelimit@5625512f24f6

FROM caddy:2.11.7-alpine
COPY --from=build /usr/bin/caddy /usr/bin/caddy
