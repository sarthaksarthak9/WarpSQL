ARG PG_VERSION
ARG PREV_IMAGE
ARG TS_VERSION
############################
# Build tools binaries in separate image
############################
ARG GO_VERSION=1.18.7
FROM golang:${GO_VERSION}-alpine AS tools

ENV TOOLS_VERSION 0.8.1

RUN apk update && apk add --no-cache git gcc musl-dev \
    && go install github.com/timescale/timescaledb-tune/cmd/timescaledb-tune@latest \
    && go install github.com/timescale/timescaledb-parallel-copy/cmd/timescaledb-parallel-copy@latest

############################
# Grab old versions from previous version
############################
ARG PG_VERSION
ARG PREV_IMAGE
FROM ${PREV_IMAGE} AS oldversions
# Remove update files, mock files, and all but the last 5 .so/.sql files
RUN rm -f $(pg_config --sharedir)/extension/timescaledb*mock*.sql \
    && if [ -f $(pg_config --pkglibdir)/timescaledb-tsl-1*.so ]; then rm -f $(ls -1 $(pg_config --pkglibdir)/timescaledb-tsl-1*.so | head -n -5); fi \
    && if [ -f $(pg_config --pkglibdir)/timescaledb-1*.so ]; then rm -f $(ls -1 $(pg_config --pkglibdir)/timescaledb-*.so | head -n -5); fi \
    && if [ -f $(pg_config --sharedir)/extension/timescaledb--1*.sql ]; then rm -f $(ls -1 $(pg_config --sharedir)/extension/timescaledb--1*.sql | head -n -5); fi

############################
# Now build image and copy in tools
############################
ARG PG_VERSION
FROM postgres:${PG_VERSION}-alpine3.18
ARG OSS_ONLY

LABEL maintainer="Timescale https://www.timescale.com"

COPY docker-entrypoint-initdb.d/* /docker-entrypoint-initdb.d/
COPY --from=tools /go/bin/* /usr/local/bin/
COPY --from=oldversions /usr/local/lib/postgresql/timescaledb-*.so /usr/local/lib/postgresql/
COPY --from=oldversions /usr/local/share/postgresql/extension/timescaledb--*.sql /usr/local/share/postgresql/extension/

ARG TS_VERSION
RUN set -ex \
    && apk add libssl1.1 \
    && apk add --no-cache --virtual .fetch-deps \
                ca-certificates \
                git \
                openssl \
                openssl-dev \
                tar \
    && mkdir -p /build/ \
    && git clone https://github.com/timescale/timescaledb /build/timescaledb \
    \
    && apk add --no-cache --virtual .build-deps \
                coreutils \
                dpkg-dev dpkg \
                gcc \
                krb5-dev \
                libc-dev \
                make \
                cmake \
                util-linux-dev \
    \
    # Build current version \
    && cd /build/timescaledb && rm -fr build \
    && git checkout ${TS_VERSION} \
    && ./bootstrap -DCMAKE_BUILD_TYPE=RelWithDebInfo -DREGRESS_CHECKS=OFF -DTAP_CHECKS=OFF -DGENERATE_DOWNGRADE_SCRIPT=ON -DWARNINGS_AS_ERRORS=OFF -DPROJECT_INSTALL_METHOD="docker"${OSS_ONLY} \
    && cd build && make install \
    && cd ~ \
    \
    && if [ "${OSS_ONLY}" != "" ]; then rm -f $(pg_config --pkglibdir)/timescaledb-tsl-*.so; fi \
    && apk del .fetch-deps .build-deps \
    && rm -rf /build \
    && sed -r -i "s/[#]*\s*(shared_preload_libraries)\s*=\s*'(.*)'/\1 = 'timescaledb,\2'/;s/,'/'/" /usr/local/share/postgresql/postgresql.conf.sample


# Update to shared_preload_libraries
RUN echo "shared_preload_libraries = 'timescaledb,pg_cron'" >> /usr/local/share/postgresql/postgresql.conf.sample
# Adding PG Vector

RUN cd /tmp
RUN apk add --no-cache --virtual .build-deps \
                coreutils \
                dpkg-dev dpkg \
                gcc \
                git \
                krb5-dev \
                libc-dev \
                llvm15 \
                clang \
                clang15 \
                make \
                cmake \
                util-linux-dev \
                && git clone --branch v0.5.1 https://github.com/pgvector/pgvector.git \
                && cd /pgvector \
                && ls \
                && make \
                && make install

# Adding pg_cron 
ARG PG_CRON_VERSION

RUN set -ex \
    && cd /tmp\
    && apk add --no-cache --virtual .pg_cron-deps \
    ca-certificates \
    openssl \
    tar \
    && apk add --no-cache --virtual .pg_cron-build-deps \
    autoconf \
    automake \
    g++ \
    clang15 \
    llvm15 \
    libtool \   
    libxml2-dev \
    make \
    perl \
    && wget -O pg_cron.tar.gz "https://github.com/citusdata/pg_cron/archive/refs/tags/${PG_CRON_VERSION}.tar.gz" \
    && mkdir -p /tmp/pg_cron \
    && tar \
        --extract \
        --file pg_cron.tar.gz \
        --directory /tmp/pg_cron \
        --strip-components 1 \
    && cd /tmp/pg_cron \
    && make \
    && make install \
    # clean
    && cd / \
    && rm /tmp/pg_cron.tar.gz \
    && rm -rf /tmp/pg_cron \
    && apk del .pg_cron-deps .pg_cron-build-deps 

# Add PostGIS Extension
ARG POSTGIS_VERSION

RUN set -eux \
    && apk add --no-cache --virtual .fetch-deps \
        ca-certificates \
        openssl \
        tar \
    \
    && wget -O postgis.tar.gz "https://github.com/postgis/postgis/archive/${POSTGIS_VERSION}.tar.gz" \
    && mkdir -p /usr/src/postgis \
    && tar \
        --extract \
        --file postgis.tar.gz \
        --directory /usr/src/postgis \
        --strip-components 1 \
    && rm postgis.tar.gz \
    \
    && apk add --no-cache --virtual .build-deps \
        \
        gdal-dev \
        geos-dev \
        proj-dev \
        autoconf \
        automake \
        clang15 \
        cunit-dev \
        file \
        g++ \
        gcc \
        gettext-dev \
        git \
        json-c-dev \
        libtool \
        libxml2-dev \
        llvm15-dev \
        make \
        pcre-dev \
        perl \
        protobuf-c-dev \
    \
# build PostGIS
    \
    && cd /usr/src/postgis \
    && gettextize \
    && ./autogen.sh \
    && ./configure \
        --with-pcredir="$(pcre-config --prefix)" \
    && make -j$(nproc) \
    && make install \
    \
# add .postgis-rundeps
    && apk add --no-cache --virtual .postgis-rundeps \
        \
        gdal \
        geos \
        proj \
        \
        json-c \
        libstdc++ \
        pcre \
        protobuf-c \
        \
        ca-certificates \
# clean
    && cd / \
    && rm -rf /usr/src/postgis \
    && apk del .fetch-deps .build-deps 

ENV RUSTFLAGS="-C target-feature=-crt-static"
ARG ZOMBODB_VERSION
ARG PG_VERSION
# RUN echo ${PG_VERSION} && exit 1
RUN apk add --no-cache --virtual .zombodb-build-deps \
    git \
	curl \
	bash \
	ruby-dev \
	ruby-etc \
	musl-dev \
	make \
	gcc \
	coreutils \
	util-linux-dev \
	musl-dev \
	openssl-dev \
    clang15 \
	tar \
    && gem install --no-document fpm \
    && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | bash -s -- -y \
    && PATH=$HOME/.cargo/bin:$PATH \
    && cargo install cargo-pgrx --version 0.9.3 \
    && cargo pgrx init --pg${PG_VERSION}=$(which pg_config) \
    && git clone --depth 1 --branch ${ZOMBODB_VERSION} https://github.com/zombodb/zombodb.git \
    && cd ./zombodb \
    && cargo pgrx install --release \
    && cd .. \
    && rm -rf ./zombodb \
    && apk del .zombodb-build-deps
