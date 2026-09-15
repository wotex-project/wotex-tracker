FROM hexpm/elixir@sha256:473f77ee88977dc8cc5d05fb91080a308be86be3fc27d50aef9a837d07c8268b

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential python3-venv ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && mix local.hex 2.5.1 --force \
 && mix local.rebar --force

ENV MIX_ENV=prod
WORKDIR /build/host
