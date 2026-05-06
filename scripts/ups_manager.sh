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
THRESHOLD_VOLTAGE="11.90"
LAST_STATUS=""
LAST_CHARGE=""
LAST_VOLTAGE=""

enviar_email_critical_halt() {
    local charge="$1"
    local volt="$2"
    local status="$3"
    local subject="[ALERTA CRÍTICO UPS] Desligando Servidor"
    local body="Bateria atingiu nível crítico: ${charge}% (${volt}V) \n Status: $status. Desligando sistema e UPS."
    enviar_email "$body" "$subject"
}

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

    echo "$(date) - [EMAIL] Tentando enviar: $subject"

    if [ ! -z "$EMAIL_DESTINO" ] && [ ! -z "$SES_SMTP_USER" ] && [ ! -z "$SES_SMTP_PASS" ]; then
        local PROTO="smtp"
        if [ "$SES_SMTP_PORT" = "465" ]; then PROTO="smtps"; fi

        local PAYLOAD="From: ${SES_FROM_EMAIL}\nTo: ${EMAIL_DESTINO}\nSubject: ${subject}\n\n${body}"

        # Captura o output e o código de status do curl para log
        RESPONSE=$(echo -e "$PAYLOAD" | curl --url "$PROTO://$SES_SMTP_HOST:$SES_SMTP_PORT" \
            --ssl-reqd \
            --mail-from "$SES_FROM_EMAIL" \
            --mail-rcpt "$EMAIL_DESTINO" \
            --user "$SES_SMTP_USER:$SES_SMTP_PASS" \
            -T - 2>&1)
        
        local EXIT_CODE=$?

        if [ $EXIT_CODE -eq 0 ]; then
            echo "$(date) - [EMAIL] Enviado com sucesso."
            return 0
        fi
        echo "$(date) - [EMAIL] ERRO ao enviar. Código Curl: $EXIT_CODE. Resposta: $RESPONSE"
        return 1
    fi
    echo "$(date) - [EMAIL] Falha: Variáveis de configuração de e-mail incompletas."
    return 2
}

encerrar_sistemas() {
    echo "$(date) - [STOP] Parando containers..."
    # docker stop $(docker ps -q) -t 30
    
    echo "$(date) - [FS] Sincronizando discos e desmontando /mnt/storage"
    # sync && umount /mnt/storage
    
    echo "$(date) - [UPS] Enviando KILL POWER"
    # docker exec nut-server upsdrvctl shutdown
    
    echo "$(date) - [HALT] Desligando SO."
    # /sbin/shutdown -h +0
}

restaurar_sistemas() {
    local charge="$1"

    local PARADOS=$(docker ps -a -f "status=exited" --format "{{.Names}}")

    if [ ! -z "$PARADOS" ]; then
        echo "$(date) - Energia restaurada. Subindo serviços..."
        enviar_email_startup "$charge" "$PARADOS"
        for c in $PARADOS; do 
            docker start "$c"; 
        done
    fi

}

atigiu_nivel_critico() {
    local charge="$1"
    local voltage="$2"
    local status="$3"
    
    if [[ "$status" == *"OL"* ]] then
        return $false
    fi

    if [[ "$status" == *"LB"* ]] then
        echo "$(date) - [FATAL] Status LOW BATTERY atingido: Charge=${charge}% - Volt=${voltage}V"
        enviar_email_critical_halt "$charge" "$voltage" "$status"
        return $true
    fi

    if [ "$charge" -le "$THRESHOLD_HALT" ]; then
        echo "$(date) - [FATAL] Limite de carga atingido! Motivo: Charge=${charge}%"
        enviar_email_critical_halt "$charge" "$voltage" "$status"
        return $true
    fi

    if [ "$voltage" -le "$THRESHOLD_VOLTAGE" ]; then
        echo "$(date) - [FATAL] Limite de voltagem atingido! Motivo: Volt=${voltage}V"
        enviar_email_critical_halt "$charge" "$voltage" "$status"
        return $true
    fi

    return $false
}

echo "$(date) - Iniciando monitoramento contínuo do Nobreak SMS..."

while true; do
    CHARGE=$(upsc $UPS_NAME battery.charge 2>/dev/null | grep -oE '[0-9]+' | head -1)
    VOLTAGE=$(upsc $UPS_NAME battery.voltage 2>/dev/null)
    STATUS=$(upsc $UPS_NAME ups.status 2>/dev/null)

    if [ "$STATUS" != "$LAST_STATUS" ] || [ "$CHARGE" != "$LAST_CHARGE" ] || [ "$VOLTAGE" != "$LAST_VOLTAGE" ]; then
        echo "$(date) - Status: $STATUS | Bateria: $CHARGE% | Voltagem: ${VOLTAGE}V"
        LAST_STATUS="$STATUS"
        LAST_CHARGE="$CHARGE"
        LAST_VOLTAGE="$VOLTAGE"
    fi

    if [[ "$STATUS" == *"OB"* ]]; then
        echo "$(date) - Status ON BATTERY desativando beeper..."
        docker exec nut-server upscmd sms@localhost beeper.disable
    fi

    if [ ! -z "$VOLTAGE" ] && [ ! -z "$STATUS" ]; then
        if atigiu_nivel_critico "$CHARGE" "$VOLTAGE" "$STATUS"; then
            encerrar_sistemas
            exit 0
        fi
    fi

    if [ ! -z "$CHARGE" ] && [[ "$STATUS" == *"OB"* ]]; then
        if [ "$CHARGE" -le 20 ]; then
             CONTAINERS_TO_STOP=$(docker ps --format "{{.Names}}" | grep -vE "$IGNORE_PATTERN")
             if [ ! -z "$CONTAINERS_TO_STOP" ]; then
                echo "$(date) - Falta de energia. Parando não-críticos..."
                enviar_email_shutdown "$CHARGE" "$CONTAINERS_TO_STOP"
                for c in $CONTAINERS_TO_STOP; do 
                    docker stop "$c" -t 30; 
                done
             fi
        fi
    fi

    if [[ "$STATUS" == *"OL"* ]] && [ "$CHARGE" -gt 50 ]; then
        restaurar_sistemas $CHARGE
    fi

    sleep 10
done
