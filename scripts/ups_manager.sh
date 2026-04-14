#!/bin/bash

# Comunica direto com o container nut-server pela rede interna do Docker
UPS_NAME="sms@nut-server"
NUT_CONTAINER="nut-server"
MANAGER_CONTAINER="ups-manager"

nobreak_sem_energia() {
    local status="$1"
    local charge="$2"
    
    if [[ "$charge" -gt 20 ]]; then
        return 0
    fi

    if [[ "$status" == *"OB"* ]]; then
        return 1
    fi

    if [[ "$status" == *"LB"* ]]; then
        return 1
    fi

    return 0
}

nobreak_com_energia() {
    local status="$1"
    local charge="$2"
    
    if [[ "$status" == *"OL"* ]]; then
        if [[ "$charge" -gt 50 ]]; then
            return 1
        fi
    fi

    return 0
}

echo "Iniciando monitoramento contínuo do Nobreak SMS..."

while true; do
    CHARGE=$(upsc $UPS_NAME battery.charge 2>/dev/null)
    CHARGE="${CHARGE%.*}"
    STATUS=$(upsc $UPS_NAME ups.status 2>/dev/null)

    echo "$(date) - Bateria com $CHARGE% de carga e status $STATUS."
    # Aguarda 60 segundos até a próxima checagem
    sleep 60
    if [ ! -z "$CHARGE" ] && [ ! -z "$STATUS" ]; then
        if [[ "$charge" -gt 55 ]]; then
            continue
        fi        
        if nobreak_sem_energia "$STATUS" "$CHARGE"; then
            echo "$(date) - Energia ausente. Bateria em $CHARGE%. Parando containers..."
            # Ignora o NUT e este próprio container gerenciador
            #docker ps --format "{{.Names}}" | grep -vE "^(${NUT_CONTAINER}|${MANAGER_CONTAINER})$" | xargs -r docker stop
        fi    

        if nobreak_com_energia "$STATUS" "$CHARGE"; then
            PARADOS=$(docker ps -a -f "status=exited" --format "{{.Names}}")
            if [ ! -z "$PARADOS" ]; then
                echo "$(date) - Energia restaurada. Bateria segura em $CHARGE%. Iniciando containers..."
                #docker ps -a -f "status=exited" --format "{{.Names}}" | xargs -r docker start
            fi
        fi
    fi
done
