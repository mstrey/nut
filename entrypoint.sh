#!/bin/bash

# 1. Desbloqueia o daemon do Debian
echo "MODE=netserver" > /etc/nut/nut.conf

# 2. Injeta a senha do .env
sed -i "s/\${NUT_PASSWORD}/$NUT_PASSWORD/g" /etc/nut/upsd.users

# 3. Garante que o hardware mapeado tenha as permissões corretas dentro do container
chmod 660 /dev/ttyUSB0
chown root:dialout /dev/ttyUSB0

# 4. Inicia os drivers e o servidor no terminal
upsdrvctl start
exec upsd -D
