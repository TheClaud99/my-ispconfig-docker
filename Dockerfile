FROM debian:bullseye-slim

# --- 5 Update your Debian Installation
COPY ./build/etc/apt/sources.list /etc/apt/sources.list
COPY ./build/etc/apt/sources.list.d/php.list /etc/apt/sources.list.d/php.list

# Imposto /bin/bash come shell per i comandi docker anziché /bin/sh
# spiegazione -Eeuo: https://transang.me/best-practice-to-make-a-shell-script/
SHELL ["/bin/bash", "-Eeuo", "pipefail", "-c"]

RUN apt-get update && \
    # --- 2 Install the SSH server, Install a shell text editor
    apt-get install -y ssh openssh-server \
    borgbackup cron patch rsyslog rsyslog-relp logrotate supervisor git sendemail wget sudo \
    # --- 3 Install a shell text editor
    nano

# --- 6 Change The Default Shell
RUN echo "No" | dpkg-reconfigure dash

# --- 7 Synchronize the System Clock
RUN apt-get -y install ntp

# --- 8a Install MariaDB
# install sql client
RUN apt-get -y mariadb-client

# install sql server
RUN printf "mariadb-server mariadb-server/root_password password %s\n" "${MARIADB_ROOT_PASSWORD}"       | debconf-set-selections && \
    printf "mariadb-server mariadb-server/root_password_again password %s\n" "${MARIADB_ROOT_PASSWORD}" | debconf-set-selections && \
    apt-get install -y mariadb-server

# copy configuration files
COPY ./build/etc/mysql/debian.cnf /etc/mysql
COPY ./build/etc/mysql/50-server.cnf /etc/mysql/mariadb.conf.d/

# change sql root password
RUN sed -i "s|password =|password = ${MARIADB_ROOT_PASSWORD}|" /etc/mysql/debian.cnf

# To prevent the error 'Error in accept: Too many open files' we will set higher open file limits for MariaDB now
RUN printf "mysql soft nofile 65535\nmysql hard nofile 65535\n" >> /etc/security/limits.conf && \
    mkdir -p /etc/systemd/system/mysql.service.d/ && \
    printf "[Service]\nLimitNOFILE=infinity\n" >> /etc/systemd/system/mysql.service.d/limits.conf && \
    service mariadb restart

# Set the password authentication method in MariaDB to native so we can use PHPMyAdmin later to connect as root user
RUN printf "SET PASSWORD = PASSWORD('%s');\n" "${MARIADB_ROOT_PASSWORD}" | mysql -h ${MARIADB_ROOT_PASSWORD} -uroot -p${MARIADB_ROOT_PASSWORD};

# --- 8b Install Postfix, Dovecot, and Binutils
RUN apt-get install -y postfix postfix-mysql postfix-doc getmail rkhunter binutils dovecot-imapd dovecot-pop3d dovecot-mysql dovecot-sieve dovecot-lmtpd libsasl2-modules
COPY ./build/etc/postfix/master.cf /etc/postfix/master.cf