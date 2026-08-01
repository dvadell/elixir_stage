ARG ELIXIR_VERSION=1.20.2
ARG OTP_VERSION=29.0.4
ARG DEBIAN_VERSION=bookworm-20260713-slim
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# install build dependencies
RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
COPY config config
COPY apps apps
RUN mix deps.get --only $MIX_ENV

# compile dependencies
RUN mix deps.compile

# build assets
WORKDIR /app/apps/soundpanel
RUN mix assets.deploy

# compile and build release
RUN mix release --overwrite

# start a new build stage so that the final image contains only the compiled release and other runtime necessities
FROM ${BUILDER_IMAGE}

RUN apt-get update -y && \
  apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

WORKDIR /app

# Set runtime ENV
ENV MIX_ENV="prod" \
    PHX_SERVER="true"

# Only copy the final release from the build stage
COPY --from=builder /app/_build/prod/rel/soundpanel ./

# set the command to run on container start
CMD ["/app/bin/soundpanel", "start"]
