# Caddy with the rate limit plugin, which the stock image lacks. The host
# builds it itself (ci-timing-build-caddy), so there is no registry to keep.
FROM caddy:2.11.7-builder-alpine AS build
# The commit before the plugin's metrics (mholt/caddy-ratelimit#85). They label
# series with the rate limit key, which is the client address here, and never
# drop them: Caddy grew by 200-400 MB a day until it was killed at its cap.
RUN xcaddy build --with github.com/mholt/caddy-ratelimit@b8d8c9a9d99e

FROM caddy:2.11.7-alpine
COPY --from=build /usr/bin/caddy /usr/bin/caddy
