FROM php:8.4-cli
RUN apt-get update && apt-get install -y --no-install-recommends git unzip libzip-dev libpng-dev libicu-dev libssl-dev default-mysql-client $PHPIZE_DEPS && rm -rf /var/lib/apt/lists/*
RUN docker-php-ext-install pdo_mysql mysqli bcmath zip gd exif pcntl sockets intl
RUN pecl install mongodb redis && docker-php-ext-enable mongodb redis
RUN echo "memory_limit=4G" > /usr/local/etc/php/conf.d/mem.ini
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
WORKDIR /app
