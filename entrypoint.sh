#!/bin/bash

# Configura o timezone do sistema baseado na variável de ambiente
if [ ! -z "$TZ" ]; then
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone
fi

# Desbloqueia o daemon do Debian
echo "MODE=netserver" > /etc/nut/nut.conf

# Injeta a senha do .env
sed -i "s|\${NUT_PASSWORD}|$NUT_PASSWORD|g" /etc/nut/upsd.users

# Garante que o hardware mapeado tenha as permissões corretas dentro do container
chmod 660 /dev/ttyUSB0
chown root:dialout /dev/ttyUSB0

# Inicia os drivers e o servidor no terminal
upsdrvctl start
exec upsd -D
