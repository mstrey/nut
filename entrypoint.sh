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

# Inicia o driver SMS diretamente (evita warning do upsdrvctl em containers sem systemd)
# O upsdrvctl emite warning em sistemas sem systemd, então usamos o driver diretamente
# Usa -a sms para ler a seção [sms] do ups.conf
/lib/nut/sms_ser -a sms -D -u root -g dialout &
DRIVER_PID=$!

# Aguarda o driver inicializar
sleep 2

# Verifica se o driver está rodando
if ! kill -0 $DRIVER_PID 2>/dev/null; then
    echo "ERRO: Driver SMS falhou ao iniciar"
    exit 1
fi

echo "Driver SMS iniciado com PID $DRIVER_PID"

# Inicia o upsd em foreground (este será o processo principal do container)
exec upsd -D
