FROM debian:bullseye-slim

ENV BUILD_PHP_VERS="8.1"

ARG HOSTNAME="server.claudiomano.duckdns.org"
ARG ISPCONFIG_MARIADB_USER="ispconfig"
ARG ISPCONFIG_MARIADB_DATABASE="dbispconfig"
ARG MARIADB_ROOT_PASSWORD="root"
ARG BUILD_MYSQL_REMOTE_ACCESS_HOST="172.%.%.%"
ARG BUILD_TZ="Europe/London"

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
COPY ./build/etc/default/pure-ftpd-common /etc/default/pure-ftpd-common
RUN apt-get -y install pure-ftpd-common pure-ftpd-mysql quota quotatool && \
    openssl dhparam -out /etc/ssl/private/pure-ftpd-dhparams.pem 2048 && \
    echo 1 > /etc/pure-ftpd/conf/TLS && \
    mkdir -p /etc/ssl/private/ && \
    yes "" | openssl req -x509 -nodes -days 7300 -newkey rsa:2048 -keyout /etc/ssl/private/pure-ftpd.pem -out /etc/ssl/private/pure-ftpd.pem && \
    chmod 600 /etc/ssl/private/pure-ftpd.pem && \
    service pure-ftpd-mysql restart