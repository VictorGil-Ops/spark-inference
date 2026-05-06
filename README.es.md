# dev-private-spark-inference

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
git clone https://github.com/VictorGil-Ops/dev-private-spark-inference.git ~/repos/dev-private-spark-inference
```

### Paso 3 — Instalar IronClaw (agente + Telegram)

```bash
bash ~/repos/dev-private-spark-inference/ironclaw/install.sh <telegram_bot_token> <telegram_user_id>
```

Tras el primer arranque, aprueba el código de emparejamiento de Telegram:
```bash
ironclaw pairing approve telegram <CÓDIGO>
```

### Paso 4 — Instalar el proxy LiteLLM (enrutamiento multi-modelo)

```bash
bash ~/repos/dev-private-spark-inference/ironclaw/litellm/install.sh
```

Luego apunta IronClaw al proxy:
```bash
ironclaw onboard --step provider
# Selecciona: OpenAI-compatible
# URL: http://127.0.0.1:4000/v1
# API key: sk-spark-local
# Model: nemotron-nano
```

### Paso 5 — Arrancar los modelos

> ⚠️ Todas las recetas están diseñadas para **modo multi-modelo** (3 modelos simultáneos, ~102GB total).
> Si necesitas máxima calidad para una tarea concreta, usa el **Modo Single Powerful** (ver más abajo).

```bash
cd ~/repos/dev-private-spark-inference

# Arrancar los tres modelos
./scripts/run.sh nemotron-3-nano-nvfp4 -d    # orquestador   — puerto 8000, ~32GB
./scripts/run.sh qwen3.6-35b-fp8 -d          # código+visión — puerto 8001, ~45GB
./scripts/run.sh deepseek-r1-32b-fp8 -d      # razonamiento  — puerto 8002, ~25GB

# Verificar
./scripts/benchmark.sh 8000
```

`run.sh` también funciona en modo interactivo — ejecútalo sin argumentos para elegir de un menú con todas las recetas disponibles, RAM estimada, tok/s, longitud de contexto y `●` junto a los modelos que ya están corriendo:

```
./scripts/run.sh

=== DGX Spark — Model Launcher ===
Memory: 57GB used / 122GB total  (65GB free)

  #       Recipe                              Port     RAM   tok/s    ctx
  ---  --  ----------------------------------  -----  -----  ------  -----
  1    ●   deepseek-r1-32b-fp8                 8002     25GB   20-25    32k
  2    ●   nemotron-3-nano-nvfp4               8000     32GB   50-58    32k
  3        nemotron3-nano-nvfp4-w4a16          8000     18GB      42    32k
  4    ●   qwen3.6-35b-fp8                     8001     45GB   28-30    32k
  5        single-nemotron-super-120b          8000     87GB   17-20   128k ⚠
  6        single-qwen3-235b-int4              8000    115GB   15-18    32k ⚠

Select model (1-6):
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
Nemotron-Nano Qwen3.6   DeepSeek-R1
(orquestador) (código)  (razonamiento)
~32GB       ~45GB      ~25GB
```

### Enrutamiento de modelos

| Nombre modelo | Puerto | RAM | Mejor para |
|---------------|--------|-----|------------|
| `nemotron-nano` | 8000 | ~32GB | Respuestas rápidas, decisiones de routing |
| `qwen36` | 8001 | ~45GB | Generación de código, visión, agentes complejos |
| `deepseek-r1` | 8002 | ~25GB | Razonamiento profundo, pentest, OSINT |

Cambiar modelo manualmente:
```bash
ironclaw models set qwen36
ironclaw models set nemotron-nano
```

---

## Modo Single Powerful

Para un análisis profundo, CTF complejos, código extenso o tareas que requieren máxima calidad:
para los tres agentes y arranca un único modelo con toda la RAM disponible.

```bash
# Parar el stack multi-modelo primero
docker stop vllm_nemotron_nano vllm_qwen36 vllm_deepseek_r1 2>/dev/null || true

# Opción A — Nemotron-3-Super-120B (mejor para reasoning + agentic)
# RAM: ~87GB | tok/s: ~17-20 | Contexto: 131k
./scripts/run.sh single-nemotron-super-120b -d

# Opción B — Qwen3-235B-A22B FP8 (mejor para coding + agentes)
# RAM: ~115GB | tok/s: ~15-18 | Contexto: 32k
./scripts/run.sh single-qwen3-235b-int4 -d
```

Volver al modo multi-modelo:
```bash
docker stop vllm_nemotron_super vllm_qwen3_235b 2>/dev/null || true
./scripts/run.sh nemotron-3-nano-nvfp4 -d
./scripts/run.sh qwen3.6-35b-fp8 -d
./scripts/run.sh deepseek-r1-32b-fp8 -d
```

---

## Persistencia tras reinicio

### Modelos vLLM

Los modelos NO arrancan automáticamente tras un reinicio. Usa el script:
```bash
bash ~/repos/dev-private-spark-inference/scripts/start-all.sh
```

Arranque automático al hacer login:
```bash
echo 'bash ~/repos/dev-private-spark-inference/scripts/start-all.sh' >> ~/.bashrc
```

### IronClaw (systemd — arranca automáticamente tras reinicio)
```bash
systemctl --user is-enabled ironclaw   # debe mostrar "enabled"
systemctl --user status ironclaw       # verificar tras reinicio
```

Habilitar lingering (arrancar sin sesión activa):
```bash
sudo loginctl enable-linger $USER
```

### PostgreSQL (arranca automáticamente tras reinicio)
```bash
sudo systemctl is-enabled postgresql   # debe mostrar "enabled"
```

### Recuperación rápida tras reinicio
```bash
bash ~/repos/dev-private-spark-inference/scripts/start-all.sh
systemctl --user status ironclaw
curl http://localhost:8000/health
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

## Benchmarks

| Modelo | Modo | tok/s | RAM |
|--------|------|-------|-----|
| Nemotron-3-Nano NVFP4 | CUDA graphs | **58.6** | ~32GB |
| Nemotron-3-Nano NVFP4 | Eager | ~42 | ~18GB |
| Qwen3.6-35B-A3B FP8 | CUDA graphs | **33.9** | ~45GB |

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
docker stop vllm_deepseek_r1

# Parar todos los modelos
docker stop vllm_nemotron_nano vllm_qwen36 vllm_deepseek_r1 2>/dev/null || true

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

### vLLM — salud y rendimiento

```bash
# Verificar que un modelo está listo
curl -sf http://localhost:8000/health && echo "OK" || echo "NO LISTO"

# Listar modelos cargados
curl -s http://localhost:8000/v1/models | python3 -m json.tool

# Benchmark tok/s
bash ~/repos/dev-private-spark-inference/scripts/benchmark.sh 8000

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

# Ver modelo activo
ironclaw models status

# Cambiar modelo
ironclaw models set nemotron-nano
ironclaw models set qwen36
ironclaw models set deepseek-r1

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
psql "postgres://victorgil:ironclaw@localhost:5432/ironclaw?sslmode=disable"
```

### Limpiar caché de memoria (antes de lanzar modelos)

```bash
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
```
