#!/bin/bash

# Comunica direto com o container nut-server pela rede interna do Docker
UPS_NAME="sms@nut-server"

EMAIL_DESTINO="${EMAIL_DESTINO:-}"
SES_SMTP_USER="${SES_SMTP_USER:-}"
SES_SMTP_PASS="${SES_SMTP_PASS:-}"
SES_SMTP_HOST="${SES_SMTP_HOST:-email-smtp.sa-east-1.amazonaws.com}"
SES_SMTP_PORT="${SES_SMTP_PORT:-587}"
SES_FROM_EMAIL="${SES_FROM_EMAIL:-sms@strey.net.br}"

# Lista de containers que não devem ser interrompidos
IGNORED_CONTAINERS=(
    "nut-server"
    "ups-manager"
    "portainer"
    "traefik"
    "cloudflared"
    "crowdsec"
    "ms-rasp-dc"
)

THRESHOLD_HALT=15 
THRESHOLD_VOLTAGE="11.80"

enviar_email_critical_halt() {
    local charge="$1"
    local volt="$2"
    local subject="[ALERTA CRÍTICO UPS] Desligando Servidor"
    local body="Bateria atingiu nível crítico: ${charge}% (${volt}V). Desligando sistema e UPS."
    enviar_email "$body" "$subject"
}

# Constrói a regex dinamicamente com base na lista de exclusão
IGNORE_PATTERN="^($(IFS='|'; echo "${IGNORED_CONTAINERS[*]}"))$"

enviar_email_shutdown() {
    local charge_level="$1"
    local containers="$2"

    local subject="[ALERTA UPS] Falta de energia - Parando containers"
    local body="A energia do servidor caiu. O Nobreak está atualmente com a bateria em ${charge_level}%.\n\nParando containers:\n${containers}"

    enviar_email "$body" "$subject"
}

enviar_email_startup() {
    local charge_level="$1"
    local containers="$2"

    local subject="[ALERTA UPS] Retorno de energia - Iniciando containers"
    local body="A energia do servidor voltou. O Nobreak está atualmente com a bateria em ${charge_level}%.\n\nIniciando containers:\n${containers}"

    enviar_email "$body" "$subject"
}

enviar_email() {
    local body="$1"
    local subject="$2"

    if [ ! -z "$EMAIL_DESTINO" ] && [ ! -z "$SES_SMTP_USER" ] && [ ! -z "$SES_SMTP_PASS" ]; then
        local PROTO="smtp"
        if [ "$SES_SMTP_PORT" = "465" ]; then PROTO="smtps"; fi

        local PAYLOAD="From: ${SES_FROM_EMAIL}\nTo: ${EMAIL_DESTINO}\nSubject: ${subject}\n\n${body}"

        echo -e "$PAYLOAD" | curl --url "$PROTO://$SES_SMTP_HOST:$SES_SMTP_PORT" \
            --ssl-reqd \
            --mail-from "$SES_FROM_EMAIL" \
            --mail-rcpt "$EMAIL_ALERTA" \
            --user "$SES_SMTP_USER:$SES_SMTP_PASS" \
            -T - >/dev/null 2>&1 || true
    fi
}

nobreak_sem_energia() {
    local status="$1"
    local charge="$2"
    
    if [[ "$charge" -gt 20 ]]; then
        echo "$(date) - Carga maior que 20%"
        return 0
    fi

    if [[ "$status" == *"OB"* ]]; then
        echo "$(date) - Usando bateria"
        return 1
    fi

    if [[ "$status" == *"LB"* ]]; then
        echo "$(date) - Bateria em nível crítico"
        return 1
    fi

    return 0
}

nobreak_com_energia() {
    local status="$1"
    local charge="$2"
    
    if [[ "$status" == *"OL"* ]]; then
        echo "$(date) - Rede externa OnLine"
        if [[ "$charge" -gt 50 ]]; then
            echo "$(date) - Carga maior que 50%"  
            return 1
        fi
    fi

    return 0
}

echo "Iniciando monitoramento contínuo do Nobreak SMS..."

while true; do
    CHARGE=$(upsc $UPS_NAME battery.charge 2>/dev/null | grep -oE '[0-9]+' | head -1)
    VOLTAGE=$(upsc $UPS_NAME battery.voltage 2>/dev/null)
    STATUS=$(upsc $UPS_NAME ups.status 2>/dev/null)

    if [[ "$STATUS" == *"OB"* ]]; then
        upscmd $UPS_NAME beeper.disable >/dev/null 2>&1
    fi

    echo "$(date) - Status: $STATUS | Bateria: $CHARGE% | Voltagem: ${VOLTAGE}V"

    VOLT_CRITICAL=$(echo "$VOLTAGE < $THRESHOLD_VOLTAGE" | bc -l 2>/dev/null)

    if [[ "$STATUS" == *"OB"* ]] && ([ "$CHARGE" -le "$THRESHOLD_HALT" ] || [ "$VOLT_CRITICAL" -eq 1 ]); then
        echo "$(date) - [CRÍTICO] Iniciando sequência de Power Off."
        enviar_email_critical_halt "$CHARGE" "$VOLTAGE"
        
        docker stop $(docker ps -q) -t 30 >/dev/null 2>&1
        
        sync
        umount /mnt/storage >/dev/null 2>&1
        
        echo "$(date) - Enviando comando KILL POWER para o Nobreak..."
        docker exec nut-server upsdrvctl shutdown
        
        echo "$(date) - Desligando Sistema Operacional."
        /sbin/shutdown -h +0
        exit 0
    fi

    if [ ! -z "$CHARGE" ] && [[ "$STATUS" == *"OB"* ]]; then
        if [ "$CHARGE" -le 20 ]; then
             CONTAINERS_TO_STOP=$(docker ps --format "{{.Names}}" | grep -vE "$IGNORE_PATTERN")
             if [ ! -z "$CONTAINERS_TO_STOP" ]; then
                echo "$(date) - Falta de energia. Parando não-críticos..."
                enviar_email_shutdown "$CHARGE" "$CONTAINERS_TO_STOP"
                for c in $CONTAINERS_TO_STOP; do docker stop "$c" -t 30; done
             fi
        fi
    fi

    if [[ "$STATUS" == *"OL"* ]] && [ "$CHARGE" -gt 50 ]; then
        PARADOS=$(docker ps -a -f "status=exited" --format "{{.Names}}")
        if [ ! -z "$PARADOS" ]; then
            echo "$(date) - Energia restaurada. Subindo serviços..."
            enviar_email_startup "$CHARGE" "$PARADOS"
            for c in $PARADOS; do docker start "$c"; done
        fi
    fi

    sleep 60
done
