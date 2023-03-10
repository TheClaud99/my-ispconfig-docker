FROM debian:bullseye-slim

ENV BUILD_PHP_VERS="8.1"

ARG HOSTNAME="server.claudiomano.duckdns.org"
ARG ISPCONFIG_MARIADB_USER="ispconfig"
ARG ISPCONFIG_MARIADB_DATABASE="dbispconfig"
ARG MARIADB_ROOT_PASSWORD="root"
ARG BUILD_PHPMYADMIN_USER="root"
ARG BUILD_PHPMYADMIN_VERSION="5.2.1"
ARG BUILD_PHPMYADMIN_PW="root"
ARG BUILD_MYSQL_REMOTE_ACCESS_HOST="172.%.%.%"
ARG BUILD_TZ="Europe/London"
ARG BUILD_ISPCONFIG_VERSION="3.2.9p1"

# --- 5 Update your Debian Installation
COPY ./build/etc/apt/sources.list /etc/apt/sources.list
COPY ./build/etc/apt/sources.list.d/php.list /etc/apt/sources.list.d/php.list


# Imposto /bin/bash come shell per i comandi docker anziché /bin/sh
# spiegazione -Eeuo: https://transang.me/best-practice-to-make-a-shell-script/
SHELL ["/bin/bash", "-Eeuo", "pipefail", "-c"]

RUN apt-get update && \
    # --- 2 Install the SSH server, Install a shell text editor
    apt-get install -y ssh openssh-server \
    borgbackup cron patch rsyslog rsyslog-relp logrotate supervisor git sendemail wget sudo curl \
    # --- 3 Install a shell text editor
    nano

# --- 5 Update your Debian Installation
# aggiungo la chiave per la repo di php
RUN wget -qO- https://packages.sury.org/php/apt.gpg | sudo tee /etc/apt/trusted.gpg.d/php.gpg

# --- 6 Change The Default Shell
RUN printf "dash  dash/sh boolean no\n" | debconf-set-selections && \
    dpkg-reconfigure dash

# --- 7 Synchronize the System Clock
RUN apt-get -y install ntp

# --- 8a Install MariaDB
# install sql client
RUN apt-get -y install mariadb-client

# # install sql server
RUN printf "mariadb-server mariadb-server/root_password password %s\n" "${MARIADB_ROOT_PASSWORD}"       | debconf-set-selections && \
    printf "mariadb-server mariadb-server/root_password_again password %s\n" "${MARIADB_ROOT_PASSWORD}" | debconf-set-selections && \
    apt-get install -y mariadb-server && \
    service mariadb start

# copy configuration files
COPY ./build/etc/mysql/debian.cnf /etc/mysql
COPY ./build/etc/mysql/50-server.cnf /etc/mysql/mariadb.conf.d/

# change sql root password
RUN sed -i "s|password =|password = ${MARIADB_ROOT_PASSWORD}|" /etc/mysql/debian.cnf

# To prevent the error 'Error in accept: Too many open files' we will set higher open file limits for MariaDB now
RUN printf "mysql soft nofile 65535\nmysql hard nofile 65535\n" >> /etc/security/limits.conf && \
    mkdir -p /etc/systemd/system/mysql.service.d/ && \
    printf "[Service]\nLimitNOFILE=infinity\n" >> /etc/systemd/system/mysql.service.d/limits.conf && \
    service mariadb restart && \
    # Set the password authentication method in MariaDB to native so we can use PHPMyAdmin later to connect as root user
    # with this method https://gist.github.com/rohsyl/e1d459ccd582774e594e3ff3358528d5?permalink_comment_id=4164553#gistcomment-4164553
    printf "SET PASSWORD = PASSWORD('%s');\n" "${MARIADB_ROOT_PASSWORD}" | mysql -h localhost -uroot -p${MARIADB_ROOT_PASSWORD};

# --- 8b Install Postfix, Dovecot, and Binutils
RUN printf "postfix postfix/main_mailer_type string 'Internet Site'\n" | debconf-set-selections && \
    printf "postfix postfix/mailname string %s\n" "${HOSTNAME}" | debconf-set-selections && \
    apt-get install -y postfix postfix-mysql postfix-doc getmail rkhunter binutils dovecot-imapd dovecot-pop3d dovecot-mysql dovecot-sieve dovecot-lmtpd libsasl2-modules
COPY ./build/etc/postfix/master.cf /etc/postfix/master.cf

# # --- 9 Install SpamAssassin, and ClamAV
RUN apt-get update && \
    apt-get -y install spamassassin clamav sa-compile clamav-daemon unzip bzip2 arj nomarch lzop gnupg2 cabextract p7zip p7zip-full unrar-free lrzip apt-listchanges libnet-ldap-perl libauthen-sasl-perl clamav-docs daemon libio-string-perl libio-socket-ssl-perl libnet-ident-perl zip libnet-dns-perl libdbd-mysql-perl postgrey
COPY ./build/etc/clamav/clamd.conf /etc/clamav/clamd.conf

# --- 10 Install Apache Web Server and PHP
RUN apt-get update && \
    apt-get -y install apache2 apache2-suexec-pristine apache2-utils ca-certificates dirmngr dnsutils gnupg gnupg2 haveged imagemagick libapache2-mod-fcgid libapache2-mod-passenger libapache2-mod-php${BUILD_PHP_VERS} libapache2-mod-python libruby lsb-release mcrypt memcached php${BUILD_PHP_VERS}-{cgi,cli,common,curl,fpm,gd,imagick,imap,intl,mbstring,mysql,opcache,pspell,readline,soap,sqlite3,tidy,xml,xmlrpc,xsl,yaml,zip} python software-properties-common unbound wget && \
    ln -sf /etc/php/${BUILD_PHP_VERS} /etc/php/current && \
    ln -sf /var/lib/php${BUILD_PHP_VERS}-fpm /var/lib/php-fpm && \
    rm -rf /var/lib/apt/lists/* && \
    /usr/sbin/a2enmod suexec rewrite ssl actions include dav_fs dav auth_digest cgi headers actions proxy_fcgi alias
COPY ./build/etc/apache2/httpoxy.conf /etc/apache2/conf-available/
RUN service apache2 restart

# # --- 11 Install Let's Encrypt
RUN curl https://get.acme.sh | sh -s

# # --- 12 Install Mailman
RUN apt-get update && apt-get -y install python3-pip && pip install mailman

# # --- 13 Install PureFTPd and Quota
RUN apt-get -y install pure-ftpd-common pure-ftpd-mysql quota quotatool && \
    openssl dhparam -out /etc/ssl/private/pure-ftpd-dhparams.pem 2048 && \
    echo 1 > /etc/pure-ftpd/conf/TLS && \
    mkdir -p /etc/ssl/private/ && \
    yes "" | openssl req -x509 -nodes -days 7300 -newkey rsa:2048 -keyout /etc/ssl/private/pure-ftpd.pem -out /etc/ssl/private/pure-ftpd.pem || true && \
    chmod 600 /etc/ssl/private/pure-ftpd.pem
COPY ./build/etc/default/pure-ftpd-common /etc/default/pure-ftpd-common
RUN service pure-ftpd-mysql restart

# # --- 14 Install BIND DNS Server
RUN apt-get -y install bind9 dnsutils haveged

# # --- 15 Install Webalizer, AWStats and GoAccess
RUN apt-get -y install awffull awstats goaccess geoip-database libclass-dbi-mysql-perl libtimedate-perl
COPY ./build/etc/cron.d/awstats /etc/cron.d/awstats

# # --- 16 Install Jailkit

# # --- 17 Install Jailkit
RUN touch /var/log/auth.log && \
    touch /var/log/mail.log && \
    touch /var/log/syslog && \
    apt-get -y install fail2ban ufw
COPY ./build/etc/fail2ban/jail.local /etc/fail2ban/jail.local
RUN service fail2ban restart

# --- 18 Install PHPMyAdmin Database Administration Tool
# https://www.linuxbabe.com/debian/install-phpmyadmin-apache-lamp-debian-10-buster
COPY ./build/etc/phpmyadmin/config.inc.php /tmp/phpmyadmin.config.inc.php
COPY ./build/etc/apache2/phpmyadmin.conf /etc/apache2/conf-available/phpmyadmin.conf
RUN apt-get update && \
    wget "https://files.phpmyadmin.net/phpMyAdmin/${BUILD_PHPMYADMIN_VERSION}/phpMyAdmin-${BUILD_PHPMYADMIN_VERSION}-all-languages.zip" -q -O "/tmp/phpMyAdmin-${BUILD_PHPMYADMIN_VERSION}-all-languages.zip" && \
    unzip -q "/tmp/phpMyAdmin-${BUILD_PHPMYADMIN_VERSION}-all-languages.zip" -d /usr/share/ && \
    mv "/usr/share/phpMyAdmin-${BUILD_PHPMYADMIN_VERSION}-all-languages" /usr/share/phpmyadmin && \
    chown -R www-data:www-data /usr/share/phpmyadmin && \
    service mariadb restart && \
    mysql -h localhost -uroot -p${MARIADB_ROOT_PASSWORD} -e "CREATE DATABASE phpmyadmin DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" && \
    mysql -h localhost -uroot -p${MARIADB_ROOT_PASSWORD} -e "GRANT ALL ON phpmyadmin.* TO '${BUILD_PHPMYADMIN_USER}'@'localhost' IDENTIFIED BY '${BUILD_PHPMYADMIN_PW}';" && \
    /usr/sbin/a2enconf phpmyadmin.conf && \
    mv /tmp/phpmyadmin.config.inc.php /usr/share/phpmyadmin/config.inc.php && \
    sed -i "s|\['controlhost'\] = '';|\['controlhost'\] = 'localhost';|" /usr/share/phpmyadmin/config.inc.php && \
    sed -i "s|\['controluser'\] = '';|\['controluser'\] = '${BUILD_PHPMYADMIN_USER}';|" /usr/share/phpmyadmin/config.inc.php && \
    sed -i "s|\['controlpass'\] = '';|\['controlpass'\] = '${BUILD_PHPMYADMIN_PW}';|" /usr/share/phpmyadmin/config.inc.php && \
    mkdir -p /var/lib/phpmyadmin/tmp && \
    chown www-data:www-data /var/lib/phpmyadmin/tmp && \
    service apache2 restart && \
    service apache2 reload; \
    service apache2 restart

# --- 20 Install ISPConfig 3
WORKDIR /tmp
RUN wget "https://ispconfig.org/downloads/ISPConfig-${BUILD_ISPCONFIG_VERSION}.tar.gz" -q && \
    tar xfz ISPConfig-${BUILD_ISPCONFIG_VERSION}.tar.gz

COPY ./build/autoinstall.ini /tmp/ispconfig3_install/install/autoinstall.ini
WORKDIR /tmp/ispconfig3_install/install
# hadolint ignore=SC2086
RUN touch "/etc/mailname" && \
    # preparo il file autoinstall.ini e lo passo come parametro all'installer di ispconfig
    sed -i "s/mysql_root_password=pass/mysql_root_password=${MARIADB_ROOT_PASSWORD}/" autoinstall.ini && \
    sed -i "s/mysql_database=dbispconfig/mysql_database=${ISPCONFIG_MARIADB_DATABASE}/" autoinstall.ini && \
    sed -i "s/^hostname=server1.example.com$/hostname=${HOSTNAME}/g" autoinstall.ini && \
    sed -i "s/^ssl_cert_common_name=server1.example.com$/ssl_cert_common_name=${HOSTNAME}/g" autoinstall.ini && \
    service mariadb restart && php -q install.php --autoinstall=autoinstall.ini

EXPOSE 20 21 22 53/udp 53/tcp 80 443 953 8080 30000 30001 30002 30003 30004 30005 30006 30007 30008 30009 3306