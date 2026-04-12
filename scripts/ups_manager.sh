#!/bin/bash

# Configurações
UPS_NAME="sms@localhost"
NUT_CONTAINER="nut-server"
LOG_FILE="/var/log/ups_manager.log"

# Obtém dados do nobreak
CHARGE=$(upsc $UPS_NAME battery.charge 2>/dev/null)
STATUS=$(upsc $UPS_NAME ups.status 2>/dev/null)

# Valida se conseguiu ler os dados
if [ -z "$CHARGE" ] || [ -z "$STATUS" ]; then
    exit 1
fi

# Regra 1: Bateria <= 20% e sem energia (OB - On Battery)
if [[ "$STATUS" == *"OB"* ]] || [[ "$STATUS" == *"LB"* ]]; then
    if [ "$CHARGE" -le 20 ]; then
        echo "$(date) - Energia ausente. Bateria em $CHARGE%. Parando containers..." >> $LOG_FILE
        # Lista todos os containers rodando, ignora o NUT, e para os demais
        docker ps --format "{{.Names}}" | grep -v "^${NUT_CONTAINER}$" | xargs -r docker stop >> $LOG_FILE 2>&1
    fi
    exit 0
fi

# Regra 2: Energia restaurada (OL - On Line) e Bateria >= 50%
if [[ "$STATUS" == *"OL"* ]]; then
    if [ "$CHARGE" -ge 50 ]; then
        # Verifica se há containers parados para iniciar
        PARADOS=$(docker ps -a -f "status=exited" --format "{{.Names}}")
        if [ ! -z "$PARADOS" ]; then
            echo "$(date) - Energia restaurada. Bateria segura em $CHARGE%. Iniciando containers..." >> $LOG_FILE
            # Inicia os containers que estavam parados
            docker ps -a -f "status=exited" --format "{{.Names}}" | xargs -r docker start >> $LOG_FILE 2>&1
        fi
    fi
fi
