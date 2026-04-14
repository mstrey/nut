FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y build-essential pkg-config \
    libusb-1.0-0-dev libssl-dev gettext-base wget docker.io

RUN rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/run/nut && chown root:dialout /var/run/nut

WORKDIR /tmp/build
RUN wget https://github.com/networkupstools/nut/releases/download/v2.8.2/nut-2.8.2.tar.gz
RUN tar -xzf nut-2.8.2.tar.gz
RUN cd nut-2.8.2 && \
    ./configure \
    --prefix=/usr \
    --sysconfdir=/etc/nut \
    --with-statepath=/var/run/nut \
    --with-drvpath=/lib/nut \
    --with-user=root \
    --with-group=dialout \
    --with-serial \
    --without-doc \
    --without-avahi \
    --without-ipmi && \
    make && make install

RUN cd / && rm -rf /tmp/build

COPY config/ /etc/nut/
COPY entrypoint.sh /usr/local/bin/

RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 3493

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]