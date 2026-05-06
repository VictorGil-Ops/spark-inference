# spark-inference

Stack de inferencia personal para NVIDIA DGX Spark (GB10 / SM12.1 Blackwell).
Construido sobre [eugr/spark-vllm-docker](https://github.com/eugr/spark-vllm-docker).

## Hardware
- GPU: NVIDIA GB10 (SM12.1, Blackwell)
- Memoria: 128 GB unificada
- CPU: ARM Grace 20 núcleos (aarch64)
- CUDA: 13.2

---

## Orden de instalación

Sigue estos pasos en orden:

### Paso 1 — Construir el contenedor base (una vez, ~8 min)

```bash
git clone https://github.com/eugr/spark-vllm-docker.git ~/repos/spark-vllm-docker
cd ~/repos/spark-vllm-docker && ./build-and-copy.sh
```

### Paso 2 — Clonar este repo

```bash
git clone https://github.com/VictorGil-Ops/spark-inference.git ~/repos/spark-inference
```

### Paso 3 — Lanzar el panel de control

Desde aquí puedes instalar y gestionar todo el stack:

```bash
cd ~/repos/spark-inference
./spark.sh
```

Muestra un banner con el flujo lógico (vLLM → LiteLLM → IronClaw → WebUI), el estado en tiempo real del sistema y un menú que delega en cada sub-script:

```
  ╔══════════════════════════════════════════════════════════════╗
  ║           DGX Spark — Personal Inference Stack              ║
  ║     NVIDIA GB10 · 128 GB unified · SM12.1 Blackwell         ║
  ╚══════════════════════════════════════════════════════════════╝

  System    57GB / 122GB RAM used  (65GB free)
  Models    vllm_nemotron3_nano_nvfp4_w4a16
  LiteLLM   running
  IronClaw  running
  WebUI     running  → http://localhost:3000
  Watchdog  enabled  (fires 5 min after boot)

  [1] Recovery & Watchdog   start-all.sh
  [2] Models                run.sh  (launch · unload · download)
  [3] Benchmark             benchmark.sh
  [4] Open WebUI            webui.sh
  [5] IronClaw Setup        setup.sh  (install · change model)
  [6] Reset IronClaw        reset-ironclaw.sh
```

### Paso 4 — Instalar IronClaw (agente + Telegram)

Desde el panel de control selecciona **[5] IronClaw Setup**, luego **[1] Install IronClaw**. El asistente pide:

- Token del bot de Telegram y tu ID de usuario numérico
- Usuario / contraseña de DB (por defecto: `ironclaw_user` / `ironclaw`)
- Modelo por defecto (lista los disponibles en la config de LiteLLM)

Tras el primer arranque, aprueba el código de emparejamiento de Telegram:
```bash
ironclaw pairing approve telegram <CÓDIGO>
```

### Paso 5 — Instalar el proxy LiteLLM (enrutamiento multi-modelo)

```bash
bash ~/repos/spark-inference/ironclaw/litellm/install.sh
```

Registra el proxy como servicio systemd del usuario en el puerto 4000. Una vez en marcha, puedes cambiar de modelo en cualquier momento desde el panel de control: **[5] IronClaw Setup → [2] Change default model**.

### Paso 6 — Arrancar los modelos

> ⚠️ Todas las recetas están diseñadas para **modo multi-modelo** (2-3 modelos simultáneos, ~102GB total).
> Si necesitas máxima calidad para una tarea concreta, usa el **Modo Single Powerful** (ver más abajo).

```bash
cd ~/repos/spark-inference
./scripts/run.sh
```

`run.sh` muestra todas las recetas disponibles con RAM estimada, tok/s, longitud de contexto y `●` junto a los modelos en ejecución:

```
=== DGX Spark — Model Launcher ===
Memory: 57GB used / 122GB total  (65GB free)

  #       Recipe                              Port     RAM   tok/s    ctx
  ---  --  ----------------------------------  -----  -----  ------  -----
  1    ●   nemotron-3-nano-nvfp4               8000     35GB   50-58    32k
  2        nemotron3-nano-nvfp4-w4a16          8004     35GB   45-52    32k
  3    ●   qwen3.6-35b-fp8                     8001     45GB   28-30    32k
  4        single-nemotron-super-120b          8100     87GB   17-20   128k ⚠

  ● running   ✓ cached locally   ⚠ exceeds free RAM

  [x <num>]  Unload from memory (stop container)
  [h <num>]  Download from HuggingFace
  [d <num>]  Delete from local cache

Select model (1-4):
```

---

## Arquitectura (Modo Multi-Modelo)

```
Telegram / CLI
│
▼
IronClaw → Proxy LiteLLM (puerto 4000)
│
┌──────────┼──────────┐
▼          ▼          ▼
puerto 8000 puerto 8001 puerto 8002
Nemotron-Nano Qwen3.6   Llama-primus
(orquestador) (código)  (razonamiento)
~32GB       ~45GB      ~35GB
```

### Enrutamiento de modelos

| Modelo | Formato | Puerto | tok/s | RAM | Modo | Rol |
|--------|---------|--------|-------|-----|------|-----|
| Nemotron-3-Nano-30B NVFP4 | NVFP4 | 8000 | 41.5 / 58.6* | ~32GB | Eager | Orquestador |
| Qwen3.6-35B-A3B | FP8 | 8001 | 28.6 | ~45GB | Eager | Código + Visión |
| Llama-Primus-Reasoning 8B | BF16 | 8002 | 14.4 | ~35GB | Eager | Pentest + Reasoning |
| Foundation-Sec-8B-Instruct | BF16 | 8002 | 14.5 | ~35GB | Eager | CVE / MITRE / SOC |
| Nemotron-3-Nano-30B W4A16 | INT4 | 8004 | ~42 | ~18GB | Eager | Orquestador bajo RAM |
| Nemotron-3-Super-120B | NVFP4 | 8100 | ~17-20 | ~87GB | CUDA graphs | Modo Single Powerful |

\* 58.6 tok/s con CUDA graphs (modelo único). Eager obligatorio con 3+ modelos simultáneos (~116GB total).

Datos completos de benchmark: [docs/benchmarks.md](docs/benchmarks.md)

Cambiar modelo desde el panel de control: `./spark.sh → [5] IronClaw Setup → [2] Change default model`

---

## Modo Single Powerful

Para un análisis profundo, CTF complejos, código extenso o tareas que requieren máxima calidad:
para los tres agentes y arranca un único modelo con toda la RAM disponible.

```bash
# Parar el stack multi-modelo primero
docker stop vllm_nemotron_nano vllm_qwen36 2>/dev/null || true

# Opción A — Nemotron-3-Super-120B (mejor para reasoning + agentic)
# RAM: ~87GB | tok/s: ~17-20 | Contexto: 131k
./scripts/run.sh single-nemotron-super-120b -d

```

Volver al modo multi-modelo:
```bash
docker stop vllm_nemotron_super 2>/dev/null || true
./scripts/run.sh nemotron-3-nano-nvfp4 -d
./scripts/run.sh qwen3.6-35b-fp8 -d
```

---

## Recuperación y watchdog

### Recuperación interactiva (tras reinicio)

```bash
bash ~/repos/spark-inference/scripts/start-all.sh
# o desde el panel de control: ./spark.sh → [1]
```

El menú muestra la memoria actual, el último modelo y el estado del watchdog, y ofrece:
- **[1] Recover** — arranca el último modelo + LiteLLM + IronClaw
- **[2] Launch model** — abre el selector interactivo de `run.sh`
- **[3] LiteLLM only**
- **[4] IronClaw only**
- **[5] Instalar / eliminar watchdog**

### Watchdog (recuperación automática al arranque)

Un timer systemd del usuario (`spark-watchdog.timer`) que se dispara 5 minutos después del arranque y ejecuta `start-all.sh --auto`.

```bash
# Instalar (desde el menú [5], o directamente)
bash ~/repos/spark-inference/scripts/start-all.sh --install-watchdog

# Eliminar
bash ~/repos/spark-inference/scripts/start-all.sh --uninstall-watchdog
```

Qué hace `--auto` en orden:
1. Verifica la red — reconecta vía `nmcli` si es necesario
2. Lanza `~/.ironclaw/last_model` — **omite** si el modelo requiere > 97% de la RAM total
3. Arranca LiteLLM (espera al health endpoint)
4. Arranca IronClaw

Habilitar lingering para que el timer se dispare sin sesión activa:
```bash
sudo loginctl enable-linger $USER
```

El último modelo lanzado se guarda automáticamente en `~/.ironclaw/last_model` por `run.sh` y `setup.sh model`.

```bash
# Estado del watchdog
systemctl --user status spark-watchdog.timer
journalctl --user -u spark-watchdog.service -n 50 --no-pager
```

### Servicios que arrancan solos (sin watchdog)

```bash
# IronClaw y LiteLLM — servicios systemd del usuario
systemctl --user is-enabled ironclaw litellm   # debe mostrar "enabled"

# PostgreSQL
sudo systemctl is-enabled postgresql           # debe mostrar "enabled"
```

---

## Hallazgos clave en SM12.1

- CUDA graphs: **5.4x de aceleración** vs modo eager (58.6 vs 10.9 tok/s)
- `gpu_memory_utilization 0.25` ahorra ~60GB frente al valor por defecto (ver [post de sggin1](https://forums.developer.nvidia.com/t/364886))
- Backend de atención FlashInfer requerido (FlashAttn no soporta SM12.1)
- `VLLM_FLASHINFER_MOE_BACKEND=latency` requerido (el backend throughput crashea)
- Los kernels FP4 de CUTLASS caen a Marlin en SM12.1
- `--enforce-eager` ahorra 13GB con solo un 3% de pérdida de tok/s en uso individual
- Compresión KV TurboQuant: PR #38479 aún no integrado

---

## Gestión y solución de problemas

### Docker — contenedores de modelos

```bash
# Ver contenedores activos
docker ps

# Ver todos los contenedores (incluidos parados)
docker ps -a

# Parar un modelo
docker stop vllm_nemotron_nano
docker stop vllm_qwen36

# Parar todos los modelos
docker stop vllm_nemotron_nano vllm_qwen36 2>/dev/null || true

# Levantar un contenedor parado
docker start vllm_nemotron_nano

# Ver todos los contenedores parados
docker ps -a --filter "status=exited"

# Levantar todos los contenedores de modelos parados de una vez
docker ps -a --filter "status=exited" --format "{{.Names}}" | xargs docker start

# Logs en tiempo real
docker logs -f vllm_nemotron_nano

# Últimas 50 líneas de logs
docker logs --tail 50 vllm_nemotron_nano

# Uso de memoria por contenedor
docker stats --no-stream

# Memoria del sistema (nvidia-smi no funciona en GB10)
watch -n1 "awk '/MemTotal/{t=\$2}/MemAvailable/{a=\$2}END{printf \"Usado: %.1f GB / %.1f GB\n\",(t-a)/1048576,t/1048576}' /proc/meminfo"
```

### Open WebUI

Interfaz web de chat conectada al proxy LiteLLM (puerto 4000). Puerto persistido en `~/.ironclaw/webui.conf`.

```bash
# Menú interactivo (instalar · arrancar · parar · cambiar puerto · actualizar · eliminar)
bash ~/repos/spark-inference/scripts/webui.sh
# o desde el panel de control: ./spark.sh → [4]

# Comandos directos
bash ~/repos/spark-inference/scripts/webui.sh install
bash ~/repos/spark-inference/scripts/webui.sh start
bash ~/repos/spark-inference/scripts/webui.sh stop
bash ~/repos/spark-inference/scripts/webui.sh restart
bash ~/repos/spark-inference/scripts/webui.sh port 3001   # cambia el puerto (recrea el contenedor)
bash ~/repos/spark-inference/scripts/webui.sh update      # descarga la última imagen
bash ~/repos/spark-inference/scripts/webui.sh status
bash ~/repos/spark-inference/scripts/webui.sh remove      # para + elimina contenedor (volumen de datos conservado)
```

Puerto por defecto: 3000. El volumen de datos (`open-webui`) se conserva al eliminar o actualizar.

### vLLM — salud y rendimiento

```bash
# Verificar que un modelo está listo
curl -sf http://localhost:8000/health && echo "OK" || echo "NO LISTO"

# Listar modelos cargados
curl -s http://localhost:8000/v1/models | python3 -m json.tool

# Benchmark tok/s — interactivo (elige entre los modelos en ejecución)
bash ~/repos/spark-inference/scripts/benchmark.sh

# Benchmark en un puerto específico
bash ~/repos/spark-inference/scripts/benchmark.sh 8000

# Test rápido
curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-NVFP4","messages":[{"role":"user","content":"hola"}],"max_tokens":20}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])"
```

### IronClaw

```bash
# Estado
systemctl --user status ironclaw

# Iniciar / Parar / Reiniciar
systemctl --user start ironclaw
systemctl --user stop ironclaw
systemctl --user restart ironclaw

# Logs en tiempo real
journalctl --user -u ironclaw -f

# Últimas 50 líneas
journalctl --user -u ironclaw -n 50 --no-pager

# Cambiar modelo de forma interactiva (muestra todos los modelos LiteLLM, marca el actual)
bash ~/repos/spark-inference/ironclaw/setup.sh model

# O cambiar directamente
ironclaw models set nemotron-nano
ironclaw models set qwen36

# Modo CLI interactivo
export $(cat ~/.ironclaw/.env | grep -v "^#" | xargs)
ironclaw run --no-onboard
```

#### ⚠️ Solución de problemas con IronClaw

Si IronClaw no responde, se cae o devuelve errores del LLM, lanza el script de reset:

```bash
bash ~/repos/spark-inference/scripts/reset-ironclaw.sh
```

El script corrige automáticamente:

| Problema | Corrección |
|---|---|
| PID file obsoleto (otra instancia corriendo) | Elimina el PID file y mata procesos huérfanos |
| Jobs atascados en `running`/`pending` | Los marca como `failed` |
| Pairing requests expiradas | Las elimina |
| Conexiones idle acumuladas en el pool | Termina conexiones por encima del umbral |
| `activated_channels` ausente en la DB | Inserta `["telegram"]` |
| Nombre de modelo no reconocido por LiteLLM | Fija `selected_model` al primer modelo disponible |
| Proxy LiteLLM caído | Lo reinicia antes de arrancar IronClaw |

Errores comunes y lo que corrige el script:

```
Connection pool error: error performing TLS handshake  → pool colgado, se resuelve reiniciando
LLM error: No connected db                             → nombre de modelo o API key incorrectos
No channels started successfully                       → activated_channels ausente en la DB
Another IronClaw instance is already running           → PID file obsoleto
```

### LiteLLM proxy

```bash
# Estado
systemctl --user status litellm

# Reiniciar (tras cambios en config)
systemctl --user restart litellm

# Logs en tiempo real
journalctl --user -u litellm -f

# Listar modelos registrados
curl -s http://127.0.0.1:4000/v1/models \
  -H "Authorization: Bearer sk-spark-local" | \
  python3 -c "import sys,json; [print(m['id']) for m in json.load(sys.stdin)['data']]"
```

### PostgreSQL (base de datos de IronClaw)

```bash
# Estado
sudo systemctl status postgresql

# Conectar a la DB de IronClaw
psql "postgres://user:passwd@localhost:5432/ironclaw?sslmode=disable"
```

### Limpiar caché de memoria (antes de lanzar modelos)

```bash
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
```
