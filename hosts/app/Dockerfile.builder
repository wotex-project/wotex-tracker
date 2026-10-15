FROM hexpm/elixir@sha256:94157a01ad1a93a419cd9824df3b8dcc6af35afba3e6b57467a87b540968f449

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && mix local.hex 2.5.3 --force \
 && mix local.rebar --force

ENV MIX_ENV=prod
WORKDIR /build/host
