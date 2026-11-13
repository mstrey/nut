#!/bin/bash

# Configuração de logs
LOG_DIR="/home/mstrey/git_rasp/nut/logs"
mkdir -p "$LOG_DIR"

# Função para obter o arquivo de log atual (um por hora)
get_log_file() {
    local timestamp=$(date +%Y%m%d%H)
    echo "${LOG_DIR}/${timestamp}.log"
}

# Função de logging que escreve tanto no stdout quanto no arquivo de log
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_entry="${timestamp} - [${level}] ${message}"
    
    # Escreve no stdout (para compatibilidade com docker logs)
    echo "$log_entry"
    
    # Escreve no arquivo de log da hora atual
    echo "$log_entry" >> "$(get_log_file)"
}

# Função para logging de erro com stack trace
log_error() {
    local message="$1"
    local line_number="${2:-$LINENO}"
    local func_name="${3:-${FUNCNAME[1]:-main}}"
    log_message "ERRO" "${message} (função: ${func_name}, linha: ${line_number})"
}

# Simulação de try/catch para bash
# Uso: try { comando; } catch { tratamento_erro; }
try() {
    local try_block="$1"
    local catch_block="$2"
    
    # Executa o bloco try
    eval "$try_block"
    local exit_code=$?
    
    # Se houve erro, executa o bloco catch
    if [ $exit_code -ne 0 ]; then
        # Define variáveis de erro para uso no catch
        TRY_ERROR_CODE=$exit_code
        TRY_ERROR_LINE=$LINENO
        eval "$catch_block"
        return $exit_code
    fi
    return 0
}

# Wrapper para executar comandos com captura de erro
execute_with_error_handling() {
    local command="$1"
    local error_message="$2"
    local line_number="${3:-$LINENO}"
    
    eval "$command"
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        log_error "${error_message} (código de saída: $exit_code)" "$line_number" "${FUNCNAME[1]}"
        return $exit_code
    fi
    return 0
}

UPS_NAME="sms@nut-server"
CONTAINERS_STOPPED=()

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
    local duracao="$2"

    local subject="[ALERTA CRÍTICO UPS] Desligando Servidor"
    local body="Bateria atingiu nível crítico após ${duracao} sem energia.\nCarga: ${charge}%.\nDesligando sistema e UPS imediatamente."
    
    try 'enviar_email "$body" "$subject"' 'log_error "Falha ao enviar email de alerta crítico: ${TRY_ERROR_CODE}"'
}

enviar_email_shutdown() {
    local charge_level="$1"

    local subject="[ALERTA UPS] Falta de energia"
    local body="A energia do servidor caiu. O Nobreak está atualmente com a bateria em ${charge_level}%."
    
    try 'enviar_email "$body" "$subject"' 'log_error "Falha ao enviar email de shutdown: ${TRY_ERROR_CODE}"'
}

enviar_email_startup() {
    local charge_level="$1"
    local duracao="$2"

    local subject="[ALERTA UPS] Energia Restaurada"
    local body="A energia retornou. O nobreak ficou sem energia por: ${duracao}.\nBateria atual em ${charge_level}%."
    
    try 'enviar_email "$body" "$subject"' 'log_error "Falha ao enviar email de startup: ${TRY_ERROR_CODE}"'
}

enviar_email() {
    local body="$1"
    local subject="$2"

    log_message "EMAIL" "Tentando enviar: $subject"

    if [ ! -z "$EMAIL_DESTINO" ] && [ ! -z "$SES_SMTP_USER" ] && [ ! -z "$SES_SMTP_PASS" ]; then
        local PROTO="smtp"
        if [ "$SES_SMTP_PORT" = "465" ]; then PROTO="smtps"; fi

        local PAYLOAD="From: ${SES_FROM_EMAIL}\nTo: ${EMAIL_DESTINO}\nSubject: ${subject}\n\n${body}"

        try 'RESPONSE=$(echo -e "$PAYLOAD" | curl --url "$PROTO://$SES_SMTP_HOST:$SES_SMTP_PORT" \
            --ssl-reqd \
            --mail-from "$SES_FROM_EMAIL" \
            --mail-rcpt "$EMAIL_DESTINO" \
            --user "$SES_SMTP_USER:$SES_SMTP_PASS" \
            -T - 2>&1)' 'log_error "Erro ao executar curl para envio de email: ${TRY_ERROR_CODE}"; return 1'
        
        local EXIT_CODE=$?

        if [ $EXIT_CODE -eq 0 ]; then
            log_message "EMAIL" "Enviado com sucesso."
            return 0
        fi
        log_error "ERRO ao enviar. Código Curl: $EXIT_CODE. Resposta: $RESPONSE"
        return 1
    fi
    log_error "Falha: Variáveis de configuração de e-mail incompletas."
    return 2
}

encerrar_sistemas() {
    log_message "STOP" "Parando containers..."
    CONTAINERS_STOPPED=()
    
    try 'CONTAINERS_LIST=$(docker ps --format "{{.Names}}")' 'log_error "Falha ao listar containers: ${TRY_ERROR_CODE}"; return 1'
    
    for c in $CONTAINERS_LIST; do
        local ignored=false
        for ic in "${IGNORED_CONTAINERS[@]}"; do
            if [ "$c" = "$ic" ]; then
                ignored=true
                break
            fi
        done
        if [ "$ignored" = false ]; then
            CONTAINERS_STOPPED+=("$c")
        fi
    done

    if [ ${#CONTAINERS_STOPPED[@]} -gt 0 ]; then
        log_message "STOP" "Containers a serem parados: ${CONTAINERS_STOPPED[*]}"
        try 'docker stop "${CONTAINERS_STOPPED[@]}"' 'log_error "Falha ao parar containers: ${TRY_ERROR_CODE}"'
    else
        log_message "STOP" "Nenhum container adicional para parar."
    fi
    
    log_message "FS" "Sincronizando discos e desmontando /mnt/storage"
    try 'sync && umount /mnt/storage' 'log_error "Falha ao sincronizar/desmontar discos: ${TRY_ERROR_CODE}"'
}

reiniciar_containers() {
    log_message "START" "Montando /mnt/storage"
    try 'mount -a' 'log_error "Falha ao montar /mnt/storage: ${TRY_ERROR_CODE}"'

    if [ ${#CONTAINERS_STOPPED[@]} -gt 0 ]; then
        log_message "START" "Reiniciando containers que foram suspensos: ${CONTAINERS_STOPPED[*]}"
        try 'docker start "${CONTAINERS_STOPPED[@]}"' 'log_error "Falha ao reiniciar containers: ${TRY_ERROR_CODE}"'
        CONTAINERS_STOPPED=()
    else
        log_message "START" "Nenhum container registrado para reiniciar."
    fi
}

atigiu_nivel_critico() {
    local charge="$1"
    local status="$2"
    
    if [[ "$status" == *"OL"* ]]; then
        return 1
    fi

    if [[ "$status" == *"LB"* ]]; then
        log_message "FATAL" "Status LOW BATTERY atingido: Charge=${charge}%"
        IS_NIVEL_CRITICO=true
        return 0
    fi

    if [ ! -z "$charge" ]; then
        if [ "$charge" -le "$THRESHOLD_HALT" ]; then
            log_message "FATAL" "Limite de carga atingido! Motivo: Charge=${charge}%"
            IS_NIVEL_CRITICO=true
            return 0
        fi
    fi

    return 1
}

# Função principal de monitoramento
monitor_ups() {
    log_message "INFO" "Iniciando monitoramento contínuo do Nobreak SMS..."
    
    while true; do
        # Tenta obter dados do UPS com tratamento de erro
        try 'DATA=$(upsc $UPS_NAME 2>/dev/null)' 'log_error "Falha ao comunicar com nut-server. Tentando novamente..."; sleep 5; continue'
        
        sleep 10
        
        try 'DATA=$(upsc $UPS_NAME 2>/dev/null)' 'log_error "Falha ao comunicar com nut-server. Tentando novamente..."; sleep 5; continue'
        
        if [ -z "$DATA" ]; then
            log_error "Falha ao comunicar com nut-server. Tentando novamente..."
            sleep 5
            continue
        fi
        
        try 'CHARGE=$(echo "$DATA" | grep "battery.charge:" | awk "{print \$2}" | cut -d. -f1)' 'log_error "Falha ao extrair carga da bateria: ${TRY_ERROR_CODE}"; sleep 5; continue'
        try 'STATUS=$(echo "$DATA" | grep "ups.status:" | awk "{print \$2}")' 'log_error "Falha ao extrair status do UPS: ${TRY_ERROR_CODE}"; sleep 5; continue'

        if [ "$STATUS" != "$LAST_STATUS" ] || [ "$CHARGE" != "$LAST_CHARGE" ]; then
            log_message "STATUS" "Status: $STATUS | Carga: $CHARGE%"
            LAST_STATUS="$STATUS"
            LAST_CHARGE="$CHARGE"
        fi

        if [[ "$LAST_STATUS" == *"OL"* ]] && [[ "$STATUS" != *"OL"* ]]; then
            POWER_FAILURE_START=$(date +%s)
            log_message "POWER" "Queda de energia detectada. Iniciando contagem de tempo."
            try 'enviar_email_shutdown "$CHARGE" "$STATUS"' 'log_error "Falha ao notificar queda de energia: ${TRY_ERROR_CODE}"'
            continue
        fi
        
        if [[ "$LAST_STATUS" != *"OL"* ]] && [[ "$STATUS" == *"OL"* ]]; then
            SEC_DIFF=$(( $(date +%s) - POWER_FAILURE_START ))
            DURACAO_TOTAL=$(formatar_tempo $SEC_DIFF)
            
            log_message "POWER" "Energia restaurada após $DURACAO_TOTAL."
            
            POWER_FAILURE_START=0
            if [ "$IS_NIVEL_CRITICO" = true ]; then
                IS_NIVEL_CRITICO=false
                try 'reiniciar_containers' 'log_error "Falha ao reiniciar containers após restauração de energia: ${TRY_ERROR_CODE}"'
            fi
            
            try 'enviar_email_startup "$CHARGE" "$DURACAO_TOTAL"' 'log_error "Falha ao notificar restauração de energia: ${TRY_ERROR_CODE}"'
            
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
                try 'enviar_email_critical_halt "$CHARGE" "$DURACAO_TOTAL"' 'log_error "Falha ao enviar alerta crítico: ${TRY_ERROR_CODE}"'
                try 'encerrar_sistemas' 'log_error "Falha ao encerrar sistemas: ${TRY_ERROR_CODE}"'
            fi
        fi
    done
}

# Captura sinais para cleanup
cleanup() {
    log_message "INFO" "Recebido sinal de término. Finalizando monitoramento..."
    exit 0
}

trap cleanup SIGTERM SIGINT

# Inicia o monitoramento
try 'monitor_ups' 'log_error "Erro fatal no monitoramento: ${TRY_ERROR_CODE}"; exit 1'
