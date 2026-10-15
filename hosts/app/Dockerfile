# Package a Linux ARM64 release produced and verified by the artifact harness.
# The build context contains only the assembled release, never configuration.
FROM debian@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587

RUN apt-get update \
 && apt-get install -y --no-install-recommends libstdc++6 libssl3 libncurses6 ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 10001 tracker \
 && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin tracker \
 && mkdir -m 0700 /var/lib/wotex \
 && chown tracker:tracker /var/lib/wotex

COPY --chown=10001:10001 release/ /opt/wotex/
USER 10001:10001
WORKDIR /opt/wotex
ENV RELEASE_TMP=/tmp/wotex-runtime
ENV LANG=C.UTF-8
STOPSIGNAL SIGTERM
ENTRYPOINT ["/opt/wotex/bin/wotex_tracker", "start"]
