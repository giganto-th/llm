# LLM Stack — Gemma 4 31B (DGX Spark GB10)

ระบบ Local LLM สำหรับ **NVIDIA DGX Spark (GB10 / Blackwell, ARM64, sm_121a)** — OpenAI-compatible API + หน้าเว็บแชท พร้อม budget/quota ต่อผู้ใช้

- **Chat + tool calling** (Gemma 4 31B QAT + MTP speculative decoding)
- **OCR / อ่านภาพ / doc parsing** (Gemma 4 native vision)
- **Gateway + quota** — LiteLLM ออก virtual key ต่อ tier/แอป คุม budget รายวัน/เดือน + rate limit
- **เรียกใช้จากข้างนอกได้** — `https://llm.example.com/v1` (OpenAI-compatible) ด้วย virtual key

> **หมายเหตุ:** ComfyUI / image generation ถูก **ถอดออก** ด้วยเหตุผลด้านความปลอดภัย — ดู [Security](#security)

## สารบัญ

- [สถาปัตยกรรม](#สถาปัตยกรรม)
- [Security](#security)
- [ความต้องการของระบบ](#ความต้องการของระบบ)
- [โครงสร้างโปรเจกต์](#โครงสร้างโปรเจกต์)
- [การติดตั้ง](#การติดตั้ง)
- [การใช้งาน](#การใช้งาน)
- [โมเดลที่มี](#โมเดลที่มี)
- [Performance (วัดจริง)](#performance-วัดจริง)
- [Virtual keys & quota (LiteLLM)](#virtual-keys--quota-litellm)
- [Memory budget](#memory-budget)
- [Operations (day-2)](#operations-day-2)
- [Troubleshooting](#troubleshooting)

---

## สถาปัตยกรรม

| Service            | Image                                     | Host bind          | หน้าที่                                                    |
| ------------------ | ----------------------------------------- | ------------------ | --------------------------------------------------------- |
| `llama`            | `ghcr.io/ggml-org/llama.cpp:server-cuda`  | *(internal เท่านั้น)* | Inference: Gemma 4 31B QAT Q4 + MTP — chat/vision/tools    |
| `litellm-postgres` | `postgres:16-alpine`                      | *(internal)*       | DB ของ LiteLLM (spend, keys, teams, budgets)              |
| `litellm`          | `ghcr.io/berriai/litellm:main-stable`     | `127.0.0.1:4000`   | Gateway OpenAI-compat: virtual keys, budget, rate limit   |
| `openwebui`        | `ghcr.io/open-webui/open-webui:v0.11.0`   | `127.0.0.1:8002`   | หน้าเว็บแชท (Google OAuth)                                 |
| `nginx` *(host)*   | —                                         | `:443` public      | reverse proxy + TLS → OWUI / LiteLLM API / LiteLLM UI      |

ทุก service อยู่ใน docker network เดียวกัน (`llm-net`) — **ไม่มีตัวไหน publish port ออกอินเทอร์เน็ตตรงๆ** ทุก traffic เข้าผ่าน nginx (443) เท่านั้น

**Data flow:**

```
internet → nginx (llm.example.com :443)
   ├─ /            → OpenWebUI (127.0.0.1:8002)  ─┐
   ├─ /v1/         → LiteLLM API (127.0.0.1:4000) ─┤→ LiteLLM → llama.cpp (Gemma 4 31B)
   └─ /litellm/    → LiteLLM Admin UI (:4000/ui)  ─┘   (budget/quota/keys)
```

- **chat/OCR/PDF:** OWUI → LiteLLM (budget-tracked) → llama.cpp
- **external API:** client → `https://llm.example.com/v1` + virtual key → LiteLLM → llama.cpp

**ทำไมต้องใช้ image เฉพาะ?** — llama.cpp `server-cuda` build มาพร้อม CUDA รองรับ GB10 (sm_121a ผ่าน JIT); Gemma 4 31B รันแบบ **QAT Q4** (near-lossless, weights ~17.3GB) + **MTP** (drafter ~280MB) เร่งความเร็ว 1.5–2.2×

---

## Security

มาตรการด้านความปลอดภัยของ stack นี้:

- 🔒 **ทุก container bind แค่ `127.0.0.1`** — คนนอกเข้า port ตรงไม่ได้ (litellm 4000 / openwebui 8002); llama + postgres = internal only เข้าได้แค่ผ่าน **nginx :443**
- 🗑️ **ถอด ComfyUI ออกทั้งหมด** — ComfyUI รันโค้ดได้ (RCE risk สูง) + โดย default เปิด `0.0.0.0:8188` ไม่มี auth + รันเป็น root ถ้าจะใช้ image/video gen ในอนาคต **ต้องแยกเครื่อง/แยก network + non-root + auth + ไม่ expose**
- 🔑 **แจกเฉพาะ virtual key** (มี budget/rate limit) ห้ามแจก `LITELLM_MASTER_KEY`
- 👤 OWUI: ปิด local signup, บังคับ **Google OAuth** + admin approval (`DEFAULT_USER_ROLE=pending`)

> **OWUI ถูก pin ที่ `v0.11.0`** — v0.11.1 มีบั๊ก OAuth+SQLite ("int too large to convert to SQLite INTEGER" เมื่อ Google `sub` เป็นเลข > 2^63) ทำให้ login ไม่ได้ อย่าเพิ่งอัปจนกว่า upstream จะแก้

### Hardening checklist (ยังต้องทำ)

- [x] bind ทุก port เป็น `127.0.0.1` (เข้าผ่าน nginx เท่านั้น)
- [x] ถอด ComfyUI + ปิด OWUI image gen
- [x] Google OAuth + admin approval
- [ ] **rotate secrets ทั้งหมดใน `.env`** เป็นระยะ — ดู [Secrets rotation](#secrets-rotation)
- [ ] **ufw firewall** เปิดแค่ 22/80/443 (แตะ firewall ผ่าน SSH ระวังตัดตัวเอง):
  ```bash
  sudo ufw default deny incoming && sudo ufw default allow outgoing
  sudo ufw allow 22,80,443/tcp && sudo ufw enable
  ```
- [ ] **fail2ban** + ปิด SSH password auth (`PasswordAuthentication no` ใน `sshd_config`)
- [ ] ตั้ง monitoring/alert — ดู [Monitoring](#monitoring)

---

## ความต้องการของระบบ

- NVIDIA DGX Spark (GB10 / Blackwell, ARM64 / aarch64, sm_121a)
- NVIDIA Driver + CUDA 13.x + NVIDIA Container Toolkit (`runtime: nvidia`)
- Docker + Docker Compose
- Unified memory 128GB (แชร์ CPU/GPU)
- Disk: ~30GB+ สำหรับ Gemma 4 31B QAT weights (~17.3GB) + drafter
- nginx + certbot บน host (สำหรับ reverse proxy + TLS)

---

## โครงสร้างโปรเจกต์

```
llm/
├── nginx/
│   └── llm.conf                 # reverse proxy: / → OWUI, /v1 → API, /litellm → UI
├── litellm/
│   ├── config.yaml              # model_list (gemma-4-31b, gemma-4-31b-fast) + settings
│   └── bootstrap.sh             # สร้าง/อัปเดต teams + virtual keys (idempotent)
├── openwebui/
│   └── functions/
│       └── chat_stats_filter.py # Filter: โชว์ token/เวลา/context% ใต้คำตอบ
├── .env                         # secrets (ห้าม commit — อยู่ใน .gitignore)
├── .env.example
├── docker-compose.yml
└── README.md
```

---

## การติดตั้ง

### 1. สร้าง `.env`

```bash
cd ~/www/llm
cp .env.example .env
```

ตั้งค่าที่จำเป็น (สุ่มค่า secret ด้วย `openssl rand -hex 32`):

| ตัวแปร                  | ใช้ทำอะไร                                        |
| ----------------------- | ------------------------------------------------ |
| `VLLM_API_KEY`          | bearer token ระหว่าง LiteLLM ↔ llama             |
| `POSTGRES_PASSWORD`     | รหัส DB ของ LiteLLM                              |
| `LITELLM_MASTER_KEY`    | admin key ของ LiteLLM (**ห้ามแจก**)              |
| `LITELLM_SALT_KEY`      | เข้ารหัส key ใน DB                               |
| `LITELLM_UI_PASSWORD`   | รหัส login หน้า LiteLLM Admin UI (user: `admin`) |
| `GOOGLE_CLIENT_ID/SECRET` | Google OAuth (OWUI login)                      |
| `OAUTH_ALLOWED_DOMAINS` | จำกัดโดเมนอีเมล (`*` = ทุก Google account)       |
| `HF_TOKEN`              | *(optional)* เผื่อโดน HF rate limit              |

> Gemma 4 = Apache 2.0 ไม่ gated → `HF_TOKEN` ปล่อยว่างได้

### 2. Pull + start

```bash
docker compose pull
# llama โหลด weights ครั้งแรกนาน — สตาร์ตก่อนแล้วดู log
docker compose up -d llama
docker compose logs -f llama      # รอ "server is listening"
# แล้วค่อยที่เหลือ
docker compose up -d
```

### 3. สร้าง teams + virtual keys (LiteLLM)

```bash
export $(grep -v '^#' .env | xargs)
./litellm/bootstrap.sh            # idempotent — รันซ้ำได้
```

สร้าง 3 tier: `admin` ($100/30d), `user` ($10/24h), `guest` ($1/24h) พร้อม virtual key ต่อ tier

### 4. nginx + SSL (setup ครั้งเดียว)

```bash
sudo cp nginx/llm.conf /etc/nginx/sites-available/
sudo ln -sf /etc/nginx/sites-available/llm.conf /etc/nginx/sites-enabled/
sudo certbot --nginx -d llm.example.com
sudo nginx -t && sudo systemctl reload nginx
```

### 5. Google OAuth (Google Cloud Console)

OWUI ใช้ Google login แบบเดียว — ตั้งที่ [console.cloud.google.com](https://console.cloud.google.com):

1. APIs & Services → Credentials → **Create OAuth client ID** → Web application
2. **Authorized redirect URIs:** `https://llm.example.com/oauth/google/callback`
3. **Authorized JavaScript origins:** `https://llm.example.com`
4. เอา Client ID / Secret ใส่ `.env` → `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`
5. *(optional)* จำกัดโดเมน: `OAUTH_ALLOWED_DOMAINS=example.com` (ว่าง/`*` = ทุก Google account)

### 6. (Optional) Filter แสดง token/เวลา/context% ใน OWUI

Admin Panel → Functions → ➕ → วางโค้ดจาก [`openwebui/functions/chat_stats_filter.py`](openwebui/functions/chat_stats_filter.py) → Save → Enable

---

## การใช้งาน

### หน้าเว็บ (OpenWebUI)

เปิด `https://llm.example.com` → login ด้วย Google (user ใหม่ = pending, admin ต้อง approve)

- **แชท** — รองรับ 140+ ภาษารวมไทย
- **OCR / อ่านรูป** — แนบภาพ (Gemma 4 native vision: OCR, handwriting, chart, doc parsing)
- **PDF** — text-based → extract; scan → แปลงหน้าเป็นภาพส่ง Gemma (`PDF_EXTRACT_IMAGES=true`)

### LiteLLM Admin UI (จัดการ key/budget/spend)

`https://llm.example.com/litellm/ui` — login: `admin` / `LITELLM_UI_PASSWORD`

### เรียกจากข้างนอก (OpenAI-compatible)

```python
from openai import OpenAI
client = OpenAI(base_url="https://llm.example.com/v1", api_key="sk-YOUR-VIRTUAL-KEY")
r = client.chat.completions.create(
    model="gemma-4-31b-fast",                       # ดู "โมเดลที่มี"
    messages=[{"role": "user", "content": "สวัสดี"}])
print(r.choices[0].message.content)
```

```bash
curl https://llm.example.com/v1/chat/completions \
  -H "Authorization: Bearer sk-YOUR-VIRTUAL-KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma-4-31b","messages":[{"role":"user","content":"สวัสดี"}]}'
```

---

## โมเดลที่มี

กำหนดใน [`litellm/config.yaml`](litellm/config.yaml) — ทั้งคู่ชี้ llama backend เดียวกัน (Gemma 4 31B):

| model_name          | reasoning       | เหมาะกับ                                              |
| ------------------- | --------------- | ---------------------------------------------------- |
| `gemma-4-31b`       | **เปิด** (คิดก่อนตอบ) | งานที่ต้องการเหตุผล/ความแม่น (default ใน OWUI)      |
| `gemma-4-31b-fast`  | **ปิด**         | ตอบสั้น/เร็ว ประหยัด token — เหมาะกับ API/แอป         |

ตัว `-fast` ปิด thinking ด้วย `extra_body.chat_template_kwargs.enable_thinking=false` (ส่งผ่านตรงไป llama.cpp ไม่โดน `drop_params` ตัด)

**เปลี่ยน LLM backend:** แก้ `-hf ...` ใน `llama` service ของ `docker-compose.yml` (เช่น `unsloth/gemma-4-12B-it-qat-GGUF:...` ถ้าอยากเบาลง) แล้ว `docker compose up -d llama`

---

## Performance (วัดจริง)

วัดบน DGX Spark GB10 — Gemma 4 31B QAT Q4_K_XL + MTP (n_max=4), 32K ctx, 1 request, 2026-08-28

### ความเร็ว (tokens/sec)

| model                          | decode        | prompt (prefill) |
| ------------------------------ | ------------- | ---------------- |
| `gemma-4-31b` (reasoning ON)   | **~33-34 tok/s** | ~106 tok/s    |
| `gemma-4-31b-fast` (reasoning OFF) | ~28-29 tok/s | ~106 tok/s      |

> **decode tok/s ไม่ใช่ตัวตัดสิน** — `-fast` ผลิต token **น้อยกว่ามาก** (ไม่มีส่วนคิด) เช่นถาม "2+2":
> `gemma-4-31b` = 144 tokens vs `-fast` = 2 tokens → **ถึงคำตอบเร็วกว่า + ถูกกว่า ~40-70×** สำหรับงานตอบสั้น
>
> ที่ตัว reasoning มี decode tok/s สูงกว่า เพราะ **MTP speculative decoding** เดา token ที่คิด (โครงสร้างเดาง่าย) ได้แม่นกว่า → acceptance สูงกว่า

### ทรัพยากร

| สถานะ               | GPU util | Power  | Temp  | RAM used (unified 121GB) |
| ------------------- | -------- | ------ | ----- | ------------------------ |
| Idle                | 0%       | ~12 W  | 53°C  | ~39 GB (เหลือ ~82 GB)    |
| Generating (1 req)  | ~93%     | ~47 W  | 60°C  | ~40 GB                   |

**RAM ต่อ container** (`docker stats`):

| container          | mem      |
| ------------------ | -------- |
| `llama` (Gemma 31B + KV + MTP) | ~9 GB\* |
| `openwebui`        | ~1.0 GB  |
| `litellm`          | ~0.8 GB  |
| `litellm-postgres` | ~0.1 GB  |

> \*`docker stats` นับ RSS ของ container; weight ส่วนใหญ่อยู่ใน unified GPU memory — ดูตัวเลขรวมจาก `free` (idle ~39GB) แม่นกว่า

**ข้อสังเกต:** power แค่ ~47W ตอน generate (GB10 ประหยัดมาก) · RAM แทบไม่ขยับ idle→gen (KV cache จองไว้แล้ว) · เหลือ headroom **~80GB** เพิ่มโมเดล/service ได้อีกเยอะ · **คอขวดคือ memory bandwidth (273 GB/s)** สะท้อนที่ decode ~30 tok/s

### Concurrency (ยิงพร้อมกัน)

llama.cpp ตั้ง **`n_parallel=4`** (4 slots + continuous batching) — วัดยิงพร้อมกัน K requests (128 tok/req):

| K (พร้อมกัน) | aggregate tok/s | latency/req | สภาพ                                             |
| ------------ | --------------- | ----------- | ------------------------------------------------ |
| 1            | ~24             | ~5.3s       |                                                  |
| 2            | ~44             | ~5.6s       | scale เกือบเชิงเส้น                              |
| 4            | **~82**         | ~5.8s       | **เต็ม 4 slots — throughput สูงสุด, latency ยังนิ่ง** |
| 8            | ~82             | ~8.8s       | เกิน 4 → เข้าคิว: throughput ตัน, latency +~1.5×  |

**สรุป:**

- รับได้เต็มประสิทธิภาพ **~4 concurrent generations** (รวม ~82 tok/s, ต่อ req ~20 tok/s, latency ~6s)
- request ที่ **5+ เข้าคิว** (ไม่ error) รอ slot ว่าง — งานตอบสั้นคิวหมดเร็ว
- **จำนวน "ผู้ใช้แชท" รองรับได้มากกว่านั้นมาก** เพราะคนอ่าน/พิมพ์สลับกัน ไม่ได้ generate พร้อมกันตลอด → ประเมิน **~20-40 active users** สบายๆ
- LiteLLM คุม **rpm ต่อ tier** อีกชั้น (admin 200 / user 30 / guest 10 req/min)

**เพิ่ม concurrency:** ใส่ `--parallel 8` (หรือมากกว่า) ใน `llama` command — แต่ KV cache แชร์กัน (32K ÷ 8 = 4K/slot), ต่อ req ช้าลง, ใช้ memory เพิ่ม เหมาะถ้ามี user เยอะแต่ context สั้น

---

## Virtual keys & quota (LiteLLM)

`bootstrap.sh` ตั้ง tier ไว้ (แก้ตัวเลขในไฟล์แล้วรันซ้ำได้ — idempotent):

| tier  | budget       | tpm / rpm       |
| ----- | ------------ | --------------- |
| admin | $100 / 30d   | 500k / 200      |
| user  | $10 / **24h** | 50k / 30        |
| guest | $1 / **24h**  | 10k / 10        |

> cost ตั้งไว้ `0.000001/token` → **$1 = 1M tokens** (budget เป็นตัวคุมจำนวน token ต่อรอบ)

**สร้าง key ใหม่สำหรับ external app** (บน server, ใช้ master key):

```bash
docker exec -i litellm python3 - <<'PY'
import os,json,urllib.request
h={"Authorization":"Bearer "+os.environ["LITELLM_MASTER_KEY"],"Content-Type":"application/json"}
body={"key_alias":"external-app-1","models":["gemma-4-31b-fast"],
      "max_budget":5,"budget_duration":"30d","rpm_limit":60}
r=urllib.request.urlopen(urllib.request.Request("http://localhost:4000/key/generate",
    data=json.dumps(body).encode(),headers=h,method="POST"))
print("KEY:",json.loads(r.read())["key"])
PY
```

> key มี **allowed models** — ต้องใส่ model ที่จะให้ใช้ (เช่น `gemma-4-31b-fast`) ไม่งั้นโดน 403
> revoke: LiteLLM UI → Virtual Keys → Delete

**Multi-tier ใน OWUI** *(optional)*: เพิ่ม Connection ต่อ tier (Prefix ID + virtual key คนละอัน) แล้วผูก User Group + ตั้ง model access grant — ดูประวัติ setup ใน git

---

## Memory budget

DGX Spark unified 128GB — ทุกอย่างแชร์ pool เดียวกัน

| ส่วน                          | ที่กิน       | หมายเหตุ                                   |
| ----------------------------- | ------------ | ------------------------------------------ |
| Gemma 4 31B **QAT Q4** weights | ~17.3 GB    | near-lossless (ไม่ใช่ bf16 62GB)          |
| MTP drafter                   | ~0.3 GB      | speculative decoding                       |
| KV cache (32K context)        | ~10-18 GB    | hybrid attention → เล็กกว่า dense ทั่วไป   |
| LiteLLM + Postgres + OWUI     | ~2-3 GB      |                                            |
| OS + Docker + cache           | ~10-15 GB    | เผื่อไว้                                    |
| **รวม**                       | **~45-55 GB**| เหลือ headroom เยอะ                        |

**Bottleneck จริงคือ memory bandwidth (273 GB/s)** ไม่ใช่ RAM — MTP + QAT ช่วยเรื่องนี้

---

## Operations (day-2)

### Backup

สิ่งที่ต้อง backup: **`litellm-postgres`** (keys/teams/spend), **`openwebui-data`** (users/chats/config/models/grants), **`.env`** (secrets)

```bash
cd ~/www/llm && mkdir -p backup
# 1) LiteLLM DB (Postgres)
docker exec litellm-postgres pg_dump -U litellm litellm > backup/litellm-$(date +%F).sql
# 2) OpenWebUI DB (SQLite ใช้ WAL — ต้อง checkpoint ก่อน copy ไม่งั้นได้ข้อมูลไม่ครบ)
docker exec openwebui sqlite3 /app/backend/data/webui.db "PRAGMA wal_checkpoint(TRUNCATE);"
docker run --rm -v llm_openwebui-data:/d -v "$PWD/backup:/b" alpine cp /d/webui.db /b/webui-$(date +%F).db
# 3) .env (เก็บที่ปลอดภัย — มี secret)
cp .env "backup/.env-$(date +%F)"
```

> ⚠️ OWUI ใช้ SQLite **WAL mode** — `cp webui.db` เฉยๆ อาจตกข้อมูลที่ยังอยู่ใน `-wal` ต้อง `wal_checkpoint` ก่อน (หรือ stop container ก่อน copy)

### Restore

```bash
# LiteLLM DB
cat backup/litellm-YYYY-MM-DD.sql | docker exec -i litellm-postgres psql -U litellm litellm
# OpenWebUI DB (stop ก่อน + ลบ WAL/SHM เก่า)
docker compose stop openwebui
docker run --rm -v llm_openwebui-data:/d -v "$PWD/backup:/b" alpine sh -c \
  'cp /b/webui-YYYY-MM-DD.db /d/webui.db && rm -f /d/webui.db-wal /d/webui.db-shm'
docker compose start openwebui
```

### Upgrade / Rollback (service)

```bash
# 1) backup ก่อนเสมอ (ดูข้างบน)
# 2) แก้ image tag ใน docker-compose.yml — pin version เสมอ อย่าใช้ :main/:latest
docker compose pull <service>
docker compose up -d <service>
docker compose logs -f <service>          # ดู migration/error
```

- **⚠️ pin version เสมอ** — `:main`/`:latest` เสี่ยง regression (เช่น OWUI **v0.11.1** มีบั๊ก OAuth+SQLite login ไม่ได้ → pin `v0.11.0`)
- **Rollback OWUI:** เปลี่ยน tag กลับ **+ restore DB ก่อน migrate** (DB ที่ผ่าน migration ของ version ใหม่ ใช้กับ version เก่าไม่ได้ — alembic จะ error) อย่าลืมลบ `-wal`/`-shm`

### User management (OWUI)

user ใหม่ login Google = **`pending`** ต้อง admin approve ก่อนใช้งาน:

- **Admin Panel → Users** → เปลี่ยน role `pending → user` (หรือ `admin`)
- ผูก **Group** (ถ้าทำ multi-tier quota)
- คนแรกสุดที่ signup = admin อัตโนมัติ
- อยากให้ approve อัตโนมัติ → ตั้ง `DEFAULT_USER_ROLE=user` (ระวัง: ใครมี Google login ก็เข้าได้ — คู่กับ `OAUTH_ALLOWED_DOMAINS`)

### Monitoring

monitoring สำคัญ — มัลแวร์/การบุกรุกอาจซ่อนได้นานถ้าไม่มีคนเฝ้าดู อย่างน้อยควรเช็คสม่ำเสมอ:

```bash
docker compose ps                              # สถานะ container (healthy?)
docker stats --no-stream                       # CPU/mem ต่อ container
nvidia-smi                                     # GPU util/power/temp
sudo ss -tnp | grep -vE '127.0.0.1|::1'        # outbound แปลกๆ (สัญญาณผิดปกติ)
top -bn1 | head -15                            # process กิน CPU ผิดปกติ
```

- **Spend / quota:** LiteLLM UI `/litellm/ui` → Usage / Virtual Keys
- แนะนำตั้ง **cron alert** เมื่อ CPU สูงผิดปกติ หรือมี outbound connection ไป IP/port แปลก

### Secrets rotation

หมุน secret ใน `.env` เป็นระยะ (หรือเมื่อสงสัยว่ารั่ว) แล้ว recreate:

```bash
# แก้ค่าใน .env: LITELLM_MASTER_KEY, LITELLM_SALT_KEY, POSTGRES_PASSWORD,
#               VLLM_API_KEY, LITELLM_UI_PASSWORD, GOOGLE_CLIENT_SECRET
# revoke HF_TOKEN ที่ huggingface.co/settings/tokens
docker compose up -d --force-recreate
```

- เปลี่ยน `POSTGRES_PASSWORD` ต้อง `ALTER USER litellm PASSWORD '...'` ใน DB ด้วย ไม่งั้น litellm ต่อ DB ไม่ได้
- เปลี่ยน `LITELLM_MASTER_KEY` / virtual key → อย่าลืมอัปใน OWUI **Connection** (Admin → Settings → Connections)
- `LITELLM_SALT_KEY` เปลี่ยนแล้ว key เดิมใน DB ถอดรหัสไม่ได้ → ต้อง regenerate keys ใหม่

---

## Troubleshooting

### llama ไม่ start / โมเดลโหลดไม่ผ่าน

```bash
docker compose logs llama --tail 200
```
- **`no kernel image ...`** → image ไม่รองรับ sm_121a → `docker compose pull llama` เอาตัวล่าสุด
- โหลด weights ครั้งแรกจาก HF นาน — เช็ค: `du -sh ~/.cache/huggingface/hub/*gemma* `

### litellm ขึ้น `unhealthy` / worker ตายวนซ้ำ (Child process died)

- multi-worker ของ `main-stable` มีบั๊ก cold-start crash-loop → ใช้ **`--num_workers=1`** (ตั้งไว้แล้วใน compose)
- ตรวจ: `docker logs litellm --tail 20`

### LiteLLM UI (/litellm) เข้าไม่ได้ / asset 404

- `SERVER_ROOT_PATH=/litellm` ต้องตั้งใน litellm env + nginx `location /litellm/` ต้อง **`proxy_pass http://127.0.0.1:4000;`** (ห้ามมี trailing slash — ไม่งั้น strip prefix)

### Google login ไม่ได้ — `[ERROR: Error during OAuth process]`

- ถ้าเพิ่งอัปเป็น **v0.11.1** → เป็นบั๊ก OAuth+SQLite (int too large) → **pin กลับ `v0.11.0`**
- redirect URI ใน Google Cloud Console ต้องเป็น `https://llm.example.com/oauth/google/callback`

### model ไม่โผล่ / ใช้ไม่ได้ ("team not allowed to access model")

- LiteLLM เช็ค **2 ชั้น: team ∩ key** — ทั้ง team และ key ต้องมี model นั้นใน allowed models
- OWUI (v0.11.x) โชว์ model ตาม `access_grant` — model ที่ไม่มี grant = เห็นเฉพาะ admin (ต้องเพิ่ม grant `principal='*'` ให้ทุก role เห็น)

### เช็ค memory / สถานะ

```bash
nvidia-smi
docker stats llama litellm openwebui
docker compose ps
```

---

## เครดิต / ที่มา

- llama.cpp CUDA server: [github.com/ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp)
- Gemma 4 31B QAT GGUF (Unsloth): [huggingface.co/unsloth/gemma-4-31B-it-qat-GGUF](https://huggingface.co/unsloth/gemma-4-31B-it-qat-GGUF)
- LiteLLM: [github.com/BerriAI/litellm](https://github.com/BerriAI/litellm)
- Open WebUI: [github.com/open-webui/open-webui](https://github.com/open-webui/open-webui)
