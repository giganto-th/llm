"""
title: Chat Stats (tokens · time · context)
author: local-llm-stack
version: 0.1.0
required_open_webui_version: 0.5.0
description: >
  แสดงสถานะใต้ทุกคำตอบ: เวลาประมวลผล, tokens/s, จำนวน token (in/out/total),
  cached tokens, และ % ของ context window ที่ใช้ไป.
  (daily-limit % จะเพิ่มใน phase 2 เมื่อเปิดระบบ tier/team budget ของ LiteLLM แล้ว)
"""

import time
from pydantic import BaseModel, Field


class Filter:
    class Valves(BaseModel):
        context_window: int = Field(
            default=32768,
            description="ขนาด context window ของ backend (ตรงกับ llama.cpp -c). ใช้คำนวณ ctx%",
        )
        show_cached: bool = Field(
            default=True, description="แสดง cached prompt tokens ถ้ามี"
        )
        show_tps: bool = Field(
            default=True, description="แสดง tokens/second"
        )
        priority: int = Field(default=100)

    def __init__(self):
        self.valves = self.Valves()
        # เก็บเวลาเริ่มต่อ (user, chat) เพื่อคำนวณ elapsed ตอน outlet
        self._start = {}

    # ---- helpers -------------------------------------------------------
    def _key(self, body: dict, __user__: dict = None) -> str:
        meta = body.get("metadata") or {}
        cid = (
            body.get("chat_id")
            or meta.get("chat_id")
            or body.get("id")
            or meta.get("message_id")
            or ""
        )
        uid = (__user__ or {}).get("id", "")
        return f"{uid}:{cid}"

    def _find_usage(self, body: dict) -> dict:
        # ลองหลายตำแหน่งที่ OWUI อาจเก็บ usage ไว้
        for m in reversed(body.get("messages", []) or []):
            if m.get("role") != "assistant":
                continue
            for cand in (
                m.get("usage"),
                (m.get("info") or {}).get("usage"),
                m.get("info"),
            ):
                if isinstance(cand, dict) and (
                    "total_tokens" in cand
                    or "completion_tokens" in cand
                    or "eval_count" in cand
                ):
                    return cand
            break
        # เผื่อ OWUI แนบ usage ระดับ body
        u = body.get("usage")
        return u if isinstance(u, dict) else {}

    # ---- hooks ---------------------------------------------------------
    async def inlet(self, body: dict, __user__: dict = None) -> dict:
        self._start[self._key(body, __user__)] = time.time()
        # บังคับให้ stream คืน usage (LiteLLM รองรับ)
        so = body.get("stream_options") or {}
        so["include_usage"] = True
        body["stream_options"] = so
        return body

    async def outlet(
        self, body: dict, __event_emitter__=None, __user__: dict = None
    ) -> dict:
        start = self._start.pop(self._key(body, __user__), None)
        elapsed = (time.time() - start) if start else None

        u = self._find_usage(body)
        # รองรับทั้งชื่อ OpenAI และ Ollama
        pin = u.get("prompt_tokens", u.get("prompt_eval_count"))
        pout = u.get("completion_tokens", u.get("eval_count"))
        total = u.get("total_tokens")
        if total is None and pin is not None and pout is not None:
            total = pin + pout
        cached = (u.get("prompt_tokens_details") or {}).get("cached_tokens")

        parts = []
        if elapsed is not None:
            parts.append(f"⏱ {elapsed:.1f}s")
            if self.valves.show_tps and pout and elapsed > 0:
                parts.append(f"{pout / elapsed:.0f} tok/s")
        if total is not None:
            seg = f"🔢 {total} tok"
            if pin is not None and pout is not None:
                seg += f" ({pin} in / {pout} out)"
            parts.append(seg)
        if self.valves.show_cached and cached:
            parts.append(f"♻ cached {cached}")
        if pin is not None and self.valves.context_window > 0:
            pct = 100.0 * pin / self.valves.context_window
            parts.append(f"📏 ctx {pct:.0f}% ({pin}/{self.valves.context_window})")

        if parts and __event_emitter__:
            await __event_emitter__(
                {
                    "type": "status",
                    "data": {"description": "   ·   ".join(parts), "done": True},
                }
            )
        return body
