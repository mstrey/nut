#!/bin/bash

# Comunica direto com o container nut-server pela rede interna do Docker
UPS_NAME="sms@nut-server"

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

# Constrói a regex dinamicamente com base na lista de exclusão
IGNORE_PATTERN="^($(IFS='|'; echo "${IGNORED_CONTAINERS[*]}"))$"

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
    CHARGE=$(upsc $UPS_NAME battery.charge 2>/dev/null)
    CHARGE="${CHARGE%.*}"
    STATUS=$(upsc $UPS_NAME ups.status 2>/dev/null)

    echo "$(date) - Bateria com $CHARGE% de carga e status $STATUS."
    # Aguarda 60 segundos até a próxima checagem
    sleep 60
    if [ ! -z "$CHARGE" ] && [ ! -z "$STATUS" ]; then
        if [[ "$CHARGE" -gt 55 ]]; then
            echo "$(date) - Carga maior que 55%"
            continue
        fi        
        if nobreak_sem_energia "$STATUS" "$CHARGE"; then
            echo "$(date) - Energia ausente. Bateria em $CHARGE%. Parando containers..."
            # Ignora os containers definidos na lista no topo deste script
            CONTAINERS_TO_STOP=$(docker ps --format "{{.Names}}" | grep -vE "$IGNORE_PATTERN")
            if [ ! -z "$CONTAINERS_TO_STOP" ]; then
                for container_name in $CONTAINERS_TO_STOP; do
                    echo "$(date) - Parando container: $container_name"
                    docker stop "$container_name" >/dev/null
                done
            fi
            continue
        fi    

        if nobreak_com_energia "$STATUS" "$CHARGE"; then
            PARADOS=$(docker ps -a -f "status=exited" --format "{{.Names}}")
            if [ ! -z "$PARADOS" ]; then
                echo "$(date) - Energia restaurada. Bateria segura em $CHARGE%. Iniciando containers..."
                for container_name in $PARADOS; do
                    echo "$(date) - Iniciando container: $container_name"
                    docker start "$container_name" >/dev/null
                done
            fi
        fi
    fi
done
