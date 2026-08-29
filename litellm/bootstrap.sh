#!/usr/bin/env bash
# =========================================================
# LiteLLM bootstrap — สร้าง/อัปเดต 3 tiers (admin/user/guest) + virtual keys
#
# ✅ idempotent: รันซ้ำได้ปลอดภัย — ถ้า team มีอยู่แล้วจะ "อัปเดต" limit
#    (ไม่สร้างซ้ำ), key ที่มี alias เดิมแล้วจะข้าม (ใช้ key เดิม)
# ✅ รองรับ SERVER_ROOT_PATH: ใช้ curl -L ตาม redirect + admin API ตอบที่ root
#
# รันหลัง `docker compose up -d` เสร็จและ LiteLLM healthy แล้ว
#
# usage:
#   export $(grep -v '^#' .env | xargs)      # load .env
#   ./litellm/bootstrap.sh
#
# หรือ:
#   LITELLM_MASTER_KEY=sk-... ./litellm/bootstrap.sh
#
# ปรับ base ได้ถ้าจำเป็น (ปกติ root ใช้ได้แม้ตั้ง SERVER_ROOT_PATH):
#   LITELLM_BASE=http://localhost:4000/litellm ./litellm/bootstrap.sh
# =========================================================

set -euo pipefail

BASE="${LITELLM_BASE:-http://localhost:4000}"
KEY="${LITELLM_MASTER_KEY:?LITELLM_MASTER_KEY required}"
MODELS_JSON='["gemma-4-31b","gemma-4-31b-fast"]'

command -v jq  >/dev/null || { echo "!! ต้องมี jq (apt install jq)"  >&2; exit 1; }
command -v curl >/dev/null || { echo "!! ต้องมี curl" >&2; exit 1; }

# -L = ตาม redirect (เผื่อ SERVER_ROOT_PATH), -sS = เงียบแต่โชว์ error
api() {
    local method="$1" path="$2" data="${3:-}"
    if [[ -n "$data" ]]; then
        curl -sSL -X "$method" "$BASE$path" \
            -H "Authorization: Bearer $KEY" \
            -H "Content-Type: application/json" -d "$data"
    else
        curl -sSL -X "$method" "$BASE$path" \
            -H "Authorization: Bearer $KEY"
    fi
}

# /team/list อาจคืน [ ... ] หรือ { "teams": [ ... ] } — รองรับทั้งคู่
list_teams() { api GET /team/list | jq -c 'if type=="array" then . else .teams end'; }

team_id_by_alias() {
    list_teams | jq -r --arg a "$1" '.[] | select(.team_alias==$a) | .team_id' | head -1
}

# ────────────────────────────────────────────────────────
# upsert_team ALIAS TPM RPM BUDGET DURATION  → echo team_id
#   - มี team อยู่แล้ว → /team/update (อัปเดต limit)
#   - ยังไม่มี        → /team/new
# ────────────────────────────────────────────────────────
upsert_team() {
    local alias="$1" tpm="$2" rpm="$3" budget="$4" dur="$5"
    local tid; tid="$(team_id_by_alias "$alias")"

    if [[ -n "$tid" ]]; then
        echo "→ update team: $alias ($tid)  tpm=$tpm rpm=$rpm budget=\$$budget/$dur" >&2
        local payload
        payload="$(jq -n --arg t "$tid" --argjson tpm "$tpm" --argjson rpm "$rpm" \
            --argjson b "$budget" --arg d "$dur" --argjson m "$MODELS_JSON" \
            '{team_id:$t,tpm_limit:$tpm,rpm_limit:$rpm,max_budget:$b,budget_duration:$d,models:$m}')"
        api POST /team/update "$payload" >/dev/null
    else
        echo "→ create team: $alias  tpm=$tpm rpm=$rpm budget=\$$budget/$dur" >&2
        local payload
        payload="$(jq -n --arg a "$alias" --argjson tpm "$tpm" --argjson rpm "$rpm" \
            --argjson b "$budget" --arg d "$dur" --argjson m "$MODELS_JSON" \
            '{team_alias:$a,tpm_limit:$tpm,rpm_limit:$rpm,max_budget:$b,budget_duration:$d,models:$m}')"
        tid="$(api POST /team/new "$payload" | jq -r '.team_id')"
    fi
    echo "$tid"
}

# ────────────────────────────────────────────────────────
# ensure_key TEAM_ID KEY_ALIAS
#   - key alias นี้ (ใน team นี้) มีแล้ว → ข้าม (key เดิมใช้ต่อได้)
#   - ยังไม่มี                          → /key/generate แล้วโชว์ key (โชว์ครั้งเดียว!)
#
#   NOTE: ใช้ /key/list (return_full_object) ในการ dedupe —
#         /team/info ของ LiteLLM รุ่นนี้คืน keys=[] ไม่ครบ เชื่อไม่ได้
# ────────────────────────────────────────────────────────
ensure_key() {
    local tid="$1" key_alias="$2"
    local exists
    exists="$(api GET '/key/list?return_full_object=true&size=100' \
        | jq -r --arg k "$key_alias" --arg t "$tid" \
            '(.keys // .)[]? | select((.key_alias==$k) and (.team_id==$t)) | .key_alias' \
        | head -1)"

    if [[ -n "$exists" ]]; then
        echo "  ✓ key '$key_alias' มีอยู่แล้ว — ข้าม (ใช้ key เดิมใน LiteLLM UI / .env)"
    else
        echo "  + สร้าง key '$key_alias':"
        api POST /key/generate \
            "$(jq -n --arg t "$tid" --arg k "$key_alias" --argjson m "$MODELS_JSON" \
                '{team_id:$t,key_alias:$k,models:$m}')" \
            | jq -r 'if .key then "    key: \(.key)   ← จดไว้! โชว์ครั้งเดียว" else "    !! สร้างไม่สำเร็จ: \(.error // .detail // .)" end'
    fi
}

# ────────────────────────────────────────────────────────
# Tier definitions  (tpm, rpm, budget USD, reset cycle)
#   cost 0.000001/token → $1 = 1M tokens
#   Admin : ~ไม่จำกัด (งานภายใน)     100M tokens/month
#   User  : พนักงาน/สมาชิก           10M tokens/day
#   Guest : สาธารณะ/ทดลอง             1M tokens/day
# ────────────────────────────────────────────────────────
echo "=== Upsert teams (idempotent) ==="
ADMIN_TID="$(upsert_team admin 500000 200 100 "30d")"
USER_TID="$( upsert_team user   50000  30  10 "24h")"
GUEST_TID="$(upsert_team guest  10000  10   1 "24h")"

echo ""
echo "=== Ensure virtual keys ==="
echo "[admin]"; ensure_key "$ADMIN_TID" "openwebui-admin"
echo "[user]";  ensure_key "$USER_TID"  "openwebui-user"
echo "[guest]"; ensure_key "$GUEST_TID" "openwebui-guest"

echo ""
echo "=== Done ==="
cat <<'NEXT'
ถ้ามี key ใหม่พ่นออกมาด้านบน เอาไปใส่ Open WebUI:
  Admin > Settings > Connections > + Add Connection
    API Base URL: http://litellm:4000/v1
    API Key:      <key ของแต่ละ tier>
  แล้วผูก connection กับ User Group ใน Admin > Users > Groups

⚠️  ตอนนี้ OWUI น่าจะยังต่อด้วย MASTER key (ไม่มี limit) —
    ต้องเปลี่ยนเป็น virtual key ต่อ tier ข้างบน daily limit ถึงจะมีผล

ดู/แก้ผ่าน LiteLLM UI: https://llm.example.com/litellm/ui  (login: admin / UI_PASSWORD)
NEXT
