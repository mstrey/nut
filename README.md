# 🔋 Infraestrutura Raspberry Pi + Nobreak SMS (Alerta Brasil)

Este projeto implementa uma arquitetura conteinerizada (Docker) para gerenciar e monitorar nobreaks da marca SMS conectados via cabo Serial/USB a um Raspberry Pi. 

Possui uma arquitetura de dois containers (Sidecar Pattern):
1. **nut-server:** Compila o driver nativo `sms_ser` a partir do código-fonte e extrai a telemetria do hardware.
2. **ups-manager:** Ouve o `nut-server` e gerencia a vida dos demais containers do host comunicando-se via Docker Socket.

## 📌 Lógica de Sobrevivência (Graceful Degradation)
- **Host (Raspberry Pi):** Permanece sempre ligado.
- **Queda (Bateria <= 20%):** Todos os containers de aplicação são interrompidos automaticamente, isolando a energia para o sistema operacional.
- **Energia restaurada (Bateria >= 50%):** Os containers de aplicação são reiniciados automaticamente.

## 🚀 Como Implantar

### 1. Clonar e Configurar
Clone o repositório, crie o arquivo de credenciais seguro:
```bash
cp .env.example .env
```
Edite o .env inserindo uma senha forte.

2. Permissões de Hardware
Permite que o usuário do host tenha acesso à porta serial (necessário para o mapeamento do device no Docker).

```bash
sudo usermod -a -G dialout $USER
```

3. Build e Execução
Como o projeto compila o driver nativo, a primeira execução exigirá o build da imagem (leva cerca de 2 minutos no Raspberry Pi 5):

```bash
docker compose up -d --build
```

O serviço `ups-manager` iniciará sozinho assim que o `nut-server` passar no healthcheck e comunicar com o Nobreak. Nenhuma configuração de cron no host é necessária.

🛠️ Monitoramento
Para verificar os logs de decisão de energia em tempo real:

```bash
docker logs ups-manager -f
```
