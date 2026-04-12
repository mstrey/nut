# 🔋 Infraestrutura Raspberry Pi + Nobreak SMS

Docker para gerenciar energia fornecida por um Nobreak SMS via NUT (Network UPS Tools).

## 📌 Lógica de Sobrevivência
Para maximizar o tempo de acesso remoto ao Raspberry Pi durante quedas de energia:
- **Host (Raspberry Pi):** Permanece sempre ligado (não realiza shutdown automático).   
- **Em caso de queda (Bateria <= 20%):** Todos os containers de aplicação são interrompidos automaticamente para evitar perda de dados   
- **Energia restaurada (Bateria >= 50%):** Os containers de aplicação são reiniciados automaticamente após a bateria atingir um nível seguro.   

## 🚀 Como Implantar

1. **Clone o repositório:**
   ```bash
   git clone <url-do-seu-repo>
   cd <nome-da-pasta>
   ```

2. Configure as Variáveis de Ambiente:
Crie o arquivo `.env` baseado no modelo fornecido:

```bash
cp .env.example .env
```
Edite o arquivo .env inserindo sua senha segura para o serviço NUT.

3. Permissões de USB:
Certifique-se de que o usuário do docker tem acesso à porta serial.

```bash
sudo usermod -a -G dialout $USER
```

4. Inicie o serviço de energia:

```bash
docker-compose up -d nut-server
```

5. Configure o Automador (Cron):
Dê permissão de execução ao script de gerenciamento:

```bash
chmod +x scripts/ups_manager.sh
```
Adicione o script ao crontab do usuário root para ser avaliado a cada minuto:

```bash
sudo crontab -e
# Adicione a linha:
# * * * * * /caminho/completo/para/scripts/ups_manager.sh
```

