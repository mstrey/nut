#!/bin/bash

exec 1> >(stdbuf -oL cat)
exec 2> >(stdbuf -oL cat)

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
LAST_STATUS=""
LAST_CHARGE=""
POWER_FAILURE_START=0
IS_NIVEL_CRITICO=false

formatar_tempo() {
    local segundos=$1
    printf '%02dh %02dm %02ds\n' $((segundos/3600)) $((segundos%3600/60)) $((segundos%60))
}

enviar_email_critical_halt() {
    local charge="$1"
    local status="$2"
    local duracao="$3"

    local subject="[ALERTA CRÍTICO UPS] Desligando Servidor"
    local body="Bateria atingiu nível crítico após ${duracao} sem energia.\\nCarga: ${charge}%.\\nStatus: $status.\\nDesligando sistema e UPS imediatamente."
    
    enviar_email "$body" "$subject"
}

enviar_email_shutdown() {
    local charge_level="$1"

    local subject="[ALERTA UPS] Falta de energia"
    local body="A energia do servidor caiu. O Nobreak está atualmente com a bateria em ${charge_level}%."

    enviar_email "$body" "$subject"
}

enviar_email_startup() {
    local charge_level="$1"
    local duracao="$2"

    local subject="[ALERTA UPS] Energia Restaurada"
    local body="A energia retornou. O nobreak ficou sem energia por: ${duracao}.\\nBateria atual em ${charge_level}%."
    
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
    local containers_to_stop=()
    for c in $(docker ps --format '{{.Names}}'); do
        local ignored=false
        for ic in "${IGNORED_CONTAINERS[@]}"; do
            if [ "$c" = "$ic" ]; then
                ignored=true
                break
            fi
        done
        if [ "$ignored" = false ]; then
            containers_to_stop+=("$c")
        fi
    done

    if [ ${#containers_to_stop[@]} -gt 0 ]; then
        docker stop "${containers_to_stop[@]}" -t 30
    fi
    
    echo "$(date) - [FS] Sincronizando discos e desmontando /mnt/storage"
    sync && umount /mnt/storage
    
}

reiniciar_containers() {
    echo "$(date) - [START] Reiniciando containers..."
    docker start "${containers_to_stop[@]}"
    echo "$(date) - [START] Montando /mnt/storage"
    fstab -a
}

atigiu_nivel_critico() {
    local charge="$1"
    local status="$2"
    
    if [[ "$status" == *"OL"* ]]; then
        return 1
    fi

    if [[ "$status" == *"LB"* ]]; then
        echo "$(date) - [FATAL] Status LOW BATTERY atingido: Charge=${charge}%"
        IS_NIVEL_CRITICO=true
        return 0
    fi

    if [ ! -z "$charge" ]; then
        if [ "$charge" -le "$THRESHOLD_HALT" ]; then
            echo "$(date) - [FATAL] Limite de carga atingido! Motivo: Charge=${charge}%"
            IS_NIVEL_CRITICO=true
            return 0
        fi
    fi

    return 1
}

echo "$(date) - Iniciando monitoramento contínuo do Nobreak SMS..."

while true; do
    sleep 10
    DATA=$(upsc $UPS_NAME 2>/dev/null)
    CHARGE=$(echo "$DATA" | grep "battery.charge:" | awk '{print $2}' | cut -d. -f1)
    STATUS=$(echo "$DATA" | grep "ups.status:" | awk '{print $2}')
    
    if [ -z "$DATA" ]; then
        echo "$(date) - [ERRO] Falha ao comunicar com nut-server. Tentando novamente..."
        sleep 5
        continue
    fi

    if [ "$STATUS" != "$LAST_STATUS" ] || [ "$CHARGE" != "$LAST_CHARGE" ]; then
        echo "$(date) - Status: $STATUS | Carga: $CHARGE%"
        LAST_STATUS="$STATUS"
        LAST_CHARGE="$CHARGE"
    fi

    if [[ "$LAST_STATUS" == *"OL"* ]] && [[ "$STATUS" != *"OL"* ]]; then
        POWER_FAILURE_START=$(date +%s)
        echo "$(date) - Queda de energia detectada. Iniciando contagem de tempo."
        enviar_email_shutdown "$CHARGE" "$STATUS"
        continue
    fi
      
    if [[ "$LAST_STATUS" != *"OL"* ]] && [[ "$STATUS" == *"OL"* ]]; then
        SEC_DIFF=$(( $(date +%s) - POWER_FAILURE_START ))
        DURACAO_TOTAL=$(formatar_tempo $SEC_DIFF)
        
        echo "$(date) - Energia restaurada após $DURACAO_TOTAL."

        POWER_FAILURE_START=0
        if [ "$IS_NIVEL_CRITICO" = true ]; then
            IS_NIVEL_CRITICO=false
            reiniciar_containers
        fi

        enviar_email_startup "$CHARGE" "$DURACAO_TOTAL"

        continue
    fi

    if [ "$IS_NIVEL_CRITICO" = true ]; then
        continue
    fi
    
    if [ ! -z "$STATUS" ] && [[ "$STATUS" != *"OL"* ]]; then
        if atigiu_nivel_critico "$CHARGE" "$STATUS"; then
            DURACAO_TOTAL="Desconhecida"
            if [ "$POWER_FAILURE_START" -ne 0 ]; then
                SEC_DIFF=$(( $(date +%s) - POWER_FAILURE_START ))
                DURACAO_TOTAL=$(formatar_tempo $SEC_DIFF)
            fi
            enviar_email_critical_halt "$CHARGE" "$STATUS" "$DURACAO_TOTAL"
            encerrar_sistemas
        fi
    fi

done
