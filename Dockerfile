FROM node:16.8.0-alpine3.13 AS base
RUN apk update && \
    apk add curl && \
    mkdir -p app
ENV NODE_OPTIONS=--max-old-space-size=8192

FROM base as builder
RUN apk add autoconf automake file g++ libtool make nasm libpng-dev && \
    npm install -g xclap-cli
RUN curl -sfL https://install.goreleaser.com/github.com/tj/node-prune.sh | ash -s -- -b /usr/local/bin
COPY package.json yarn.lock ./
RUN yarn config set loglevel error && \
    yarn --silent --frozen-lockfile
COPY . ./app
WORKDIR /app
RUN yarn build && \
    NODE_ENV=production yarn --silent --frozen-lockfile --production && \
    /usr/local/bin/node-prune

FROM base as node-nginx
ENV NGINX_VERSION=1.19.6 \
    NJS_VERSION=0.5.0 \
    PKG_RELEASE=1
RUN set -x \
    # create nginx user/group first, to be consistent throughout docker variants
    && addgroup -g 101 -S nginx \
    && adduser -S -D -H -u 101 -h /var/cache/nginx -s /sbin/nologin -G nginx -g nginx nginx \
    && apkArch="$(cat /etc/apk/arch)" \
    && nginxPackages=" \
    nginx=${NGINX_VERSION}-r${PKG_RELEASE} \
    nginx-module-xslt=${NGINX_VERSION}-r${PKG_RELEASE} \
    nginx-module-geoip=${NGINX_VERSION}-r${PKG_RELEASE} \
    nginx-module-image-filter=${NGINX_VERSION}-r${PKG_RELEASE} \
    nginx-module-njs=${NGINX_VERSION}.${NJS_VERSION}-r${PKG_RELEASE} \
    " \
    && case "$apkArch" in \
    x86_64) \
    # arches officially built by upstream
    set -x \
    && KEY_SHA512="e7fa8303923d9b95db37a77ad46c68fd4755ff935d0a534d26eba83de193c76166c68bfe7f65471bf8881004ef4aa6df3e34689c305662750c0172fca5d8552a *stdin" \
    && apk add --no-cache --virtual .cert-deps \
    openssl \
    && wget -O /tmp/nginx_signing.rsa.pub https://nginx.org/keys/nginx_signing.rsa.pub \
    && if [ "$(openssl rsa -pubin -in /tmp/nginx_signing.rsa.pub -text -noout | openssl sha512 -r)" = "$KEY_SHA512" ]; then \
    echo "key verification succeeded!"; \
    mv /tmp/nginx_signing.rsa.pub /etc/apk/keys/; \
    else \
    echo "key verification failed!"; \
    exit 1; \
    fi \
    && apk del .cert-deps \
    && apk add -X "https://nginx.org/packages/mainline/alpine/v$(egrep -o '^[0-9]+\.[0-9]+' /etc/alpine-release)/main" --no-cache $nginxPackages \
    ;; \
    *) \
    # we're on an architecture upstream doesn't officially build for
    # let's build binaries from the published packaging sources
    set -x \
    && tempDir="$(mktemp -d)" \
    && chown nobody:nobody $tempDir \
    && apk add --no-cache --virtual .build-deps \
    gcc \
    libc-dev \
    make \
    openssl-dev \
    pcre-dev \
    zlib-dev \
    linux-headers \
    libxslt-dev \
    gd-dev \
    geoip-dev \
    perl-dev \
    libedit-dev \
    mercurial \
    bash \
    alpine-sdk \
    findutils \
    && su nobody -s /bin/sh -c " \
    export HOME=${tempDir} \
    && cd ${tempDir} \
    && hg clone https://hg.nginx.org/pkg-oss \
    && cd pkg-oss \
    && hg up ${NGINX_VERSION}-${PKG_RELEASE} \
    && cd alpine \
    && make all \
    && apk index -o ${tempDir}/packages/alpine/${apkArch}/APKINDEX.tar.gz ${tempDir}/packages/alpine/${apkArch}/*.apk \
    && abuild-sign -k ${tempDir}/.abuild/abuild-key.rsa ${tempDir}/packages/alpine/${apkArch}/APKINDEX.tar.gz \
    " \
    && cp ${tempDir}/.abuild/abuild-key.rsa.pub /etc/apk/keys/ \
    && apk del .build-deps \
    && apk add -X ${tempDir}/packages/alpine/ --no-cache $nginxPackages \
    ;; \
    esac \
    # if we have leftovers from building, let's purge them (including extra, unnecessary build deps)
    && if [ -n "$tempDir" ]; then rm -rf "$tempDir"; fi \
    && if [ -n "/etc/apk/keys/abuild-key.rsa.pub" ]; then rm -f /etc/apk/keys/abuild-key.rsa.pub; fi \
    && if [ -n "/etc/apk/keys/nginx_signing.rsa.pub" ]; then rm -f /etc/apk/keys/nginx_signing.rsa.pub; fi \
    # Bring in gettext so we can get `envsubst`, then throw
    # the rest away. To do this, we need to install `gettext`
    # then move `envsubst` out of the way so `gettext` can
    # be deleted completely, then move `envsubst` back.
    && apk add --no-cache --virtual .gettext gettext \
    && mv /usr/bin/envsubst /tmp/ \
    \
    && runDeps="$( \
    scanelf --needed --nobanner /tmp/envsubst \
    | awk '{ gsub(/,/, "\nso:", $2); print "so:" $2 }' \
    | sort -u \
    | xargs -r apk info --installed \
    | sort -u \
    )" \
    && apk add --no-cache $runDeps \
    && apk del .gettext \
    && mv /tmp/envsubst /usr/local/bin/ \
    # Bring in tzdata so users could set the timezones through the environment
    # variables
    && apk add --no-cache tzdata \
    # Bring in curl and ca-certificates to make registering on DNS SD easier
    && apk add --no-cache curl ca-certificates \
    # forward request and error logs to docker log collector
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log
COPY nginx.conf /etc/nginx/nginx.conf
RUN rm -rf /var/cache/apk/* && \
    apk del curl

FROM base as deployment
WORKDIR /app
COPY --from=builder ./app/node_modules ./node_modules
COPY --from=builder ./app/lib ./lib
COPY --from=builder ./app/dist ./dist
COPY --from=builder ./app/src ./src
COPY --from=builder ./app/config ./config
COPY --from=builder ./app/package.json ./package.json
COPY --from=builder ./app/.isomorphic-loader-config.json ./.isomorphic-loader-config.json

FROM node-nginx
ENV NODE_ENV=production
WORKDIR /app
COPY --from=deployment ./app ./
CMD nohup node lib/server & sleep 5; nginx -g 'daemon off;'
