# syntax=docker/dockerfile:experimental

#####################
### Scratch image ###
#####################
FROM php:8.2.12-fpm-alpine3.18 AS scratch

RUN set -x \
    && apk add --no-cache --virtual .build-deps icu-dev \
    && docker-php-ext-install -j$(nproc) intl \
    && apk add --no-cache icu-libs \
    && apk del .build-deps

RUN docker-php-ext-install -j$(nproc) pcntl

ENV MONGODB_VERSION 1.16.2
RUN set -x \
    && apk add --no-cache --virtual .build-deps openssl-dev \
    && mkdir -p /usr/src/php/ext/mongodb \
    && curl "https://pecl.php.net/get/mongodb/${MONGODB_VERSION}" \
        | tar xvz --directory=/usr/src/php/ext/mongodb --strip=1 \
    && docker-php-ext-install -j$(nproc) mongodb \
    && rm -rf /usr/src/php/ext/mongodb \
    && apk del .build-deps

WORKDIR /var/www/html

######################
### Composer image ###
######################
FROM scratch AS composer

# Setup Composer authentetication (https://getcomposer.org/doc/03-cli.md#composer-auth)
ARG COMPOSER_AUTH

ENV COMPOSER_VERSION 2.6.5
RUN set -x \
    && curl --silent --show-error --location --retry 5 https://getcomposer.org/installer --output /tmp/installer.php \
    && php /tmp/installer.php --install-dir=/usr/local/bin --filename=composer --version=${COMPOSER_VERSION} \
    && rm -f /tmp/installer.php

CMD ["composer"]

########################
### Production image ###
########################
FROM scratch AS production

RUN cp ${PHP_INI_DIR}/php.ini-production ${PHP_INI_DIR}/php.ini

# https://symfony.com/doc/current/performance.html#configure-the-php-realpath-cache
RUN echo realpath_cache_size=4096K >> ${PHP_INI_DIR}/conf.d/php.ini \
    && echo realpath_cache_ttl=600 >> ${PHP_INI_DIR}/conf.d/php.ini

#################
### App image ###
#################
FROM composer as composer_dependencies
COPY . /var/www/html
RUN --mount=type=cache,target=/root/.composer/cache composer install --no-dev --classmap-authoritative --no-scripts --no-progress

FROM production as app

COPY --from=composer_dependencies /var/www/html/vendor /var/www/html/vendor
COPY --from=composer_dependencies /var/www/html/webroot ./webroot
COPY --from=composer_dependencies /var/www/html/external ./external
COPY --from=composer_dependencies /var/www/html/templates ./templates
COPY --from=composer_dependencies /var/www/html/src ./src
COPY --from=composer_dependencies /var/www/html/config ./config

###################
### Nginx image ###
###################
FROM nginx:1.25.3-alpine AS nginx

RUN rm /etc/nginx/conf.d/default.conf

COPY config/nginx.conf /etc/nginx/conf.d/default.conf
# COPY devops/docker/nginx/templates/status.conf.template /etc/nginx/templates/

RUN sed -i 's/worker_processes  1/worker_processes  auto/g' /etc/nginx/nginx.conf \
    && sed -i 's/worker_connections  1024/worker_connections  4096;\n    multi_accept on/g' /etc/nginx/nginx.conf \
    && sed -i 's/#tcp_nopush     on/tcp_nopush      on;\n    tcp_nodelay     on;\n    server_tokens   off/g' /etc/nginx/nginx.conf \
    && sed -i 's/#gzip  on/gzip on;\n    gzip_disable  "msie6";\n    gzip_types text\/plain text\/css application\/json text\/javascript application\/javascript text\/xml application\/xml image\/svg+xml/g' /etc/nginx/nginx.conf

RUN sed -i '/default_type/a \\n    map $http_x_request_id $proxied_request_id {\n        default   $http_x_request_id;\n        ""        $request_id;\n    }' /etc/nginx/nginx.conf \
    && sed -i 's/"$http_x_forwarded_for"/"$http_x_forwarded_for" $proxied_request_id/g' /etc/nginx/nginx.conf \
    && echo "fastcgi_param  HTTP_REQUEST_ID    \$proxied_request_id;" >> /etc/nginx/fastcgi_params

ENV SERVER_NAME localhost
ENV FASTCGI_HOST php
ENV FASTCGI_PORT 9000

COPY ./webroot /var/www/html/webroot
