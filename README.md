# Omnichannel Customer Support Command Center (OCSCC)

> A production-grade AI-powered customer support automation hub built for real-world deployment and client sales.

**Brand:** Innovexa Solution  
**Course:** Ostad AI Automation — Batch 7 (Group Assignment)  
**Team:**
- **Robin (Hafizul Haider)** — System architecture, n8n workflow logic, bug fixing, Supabase schema design
- **Jamilur Reza Razib** — Collaboration and project contribution

---

## What is OCSCC?

OCSCC is a fully automated omnichannel customer support system that unifies customer messages from multiple channels into a single platform. It uses AI to triage, classify, and respond to customer messages automatically — and escalates to human agents when needed.

Instead of separate inboxes for email, WhatsApp, Telegram, and web forms, everything lands in one place. Agents manage all support from a single React dashboard.

---

## System Architecture

```
Customer Channels (Email, WhatsApp, Telegram, Messenger, Web Form)
        ↓
Ingestion Buffer (Supabase — idempotent, deduplication)
        ↓
n8n Automation Engine (12 workflows)
        ↓
AI Layer (OpenRouter — Gemini Flash / Nemotron)
        ↓
Supabase Database (single source of truth)
        ↓
React Dashboard (agent workspace, analytics, admin)
```

---

## Tech Stack

| Layer | Technology |
|---|---|
| Automation | n8n (self-hosted on Hostinger) |
| Database | Supabase (PostgreSQL, REST API, Realtime) |
| AI | OpenRouter (Gemini Flash, Nemotron 550B) |
| Channels | Gmail API, Meta Cloud API, Telegram Bot API |
| Frontend | React + Vite + Tailwind (built separately) |
| Notifications | Telegram Bot |

---

## Channels Supported

| Channel | Status | Method |
|---|---|---|
| Email (Gmail) | ✅ Live | Gmail OAuth trigger |
| Website form | ✅ Live | n8n webhook |
| Telegram | ✅ Live | Telegram Bot API |
| WhatsApp | ⏳ Pending | Meta Cloud API (approval pending) |
| Facebook Messenger | ⏳ Pending | Meta Cloud API (approval pending) |

---

## n8n Workflows (12 total)

### Group 1 — Intake (channel-specific triggers)

| Workflow | Function |
|---|---|
| WF01 — Website Form Intake | Catches webhook submissions, normalizes, writes to buffer |
| WF02 — Email Intake | Gmail trigger, normalizes email data, writes to buffer |
| WF03 — Telegram Intake | Telegram Bot trigger, normalizes, writes to buffer |
| WF04 — WhatsApp Intake | Meta webhook, normalizes, writes to buffer |
| WF05 — Facebook Messenger Intake | Meta webhook, normalizes, writes to buffer |

### Group 2 — Core Engine

| Workflow | Function |
|---|---|
| WF06 — AI Triage | Reads buffer → AI classifies → creates ticket → checks for existing thread |
| WF07 — Auto Reply Telegram | Sends billing info request or AI reply back to customer via Telegram |
| WF08 — Auto Reply Email | Sends AI reply back to customer via Gmail |
| WF09 — Escalation | Alerts agent when AI confidence < 80% |
| WF12 — Agent Reply Dispatcher | Dispatches agent replies back to customer via original channel |

### Group 3 — Background Jobs

| Workflow | Function |
|---|---|
| WF10 — SLA Monitor | Runs every 30 min, alerts agent on breaching tickets |
| WF11 — Daily Report | Sends 8am Telegram digest with previous day stats |

---

## AI Triage Output

Every incoming message is analyzed by GPT-4o / Gemini Flash and produces:

```json
{
  "category": "billing | technical | general | complaint",
  "priority": "high | medium | low",
  "sentiment": "positive | neutral | negative",
  "confidence": 85,
  "ai_summary": "Customer requests refund for damaged item.",
  "ai_reply_draft": "Hi Sarah, I understand you received a damaged item..."
}
```

- **Confidence ≥ 80%** → auto-reply sent to customer automatically
- **Confidence < 80%** → escalated to human agent with full context

---

## Supabase Schema

### Tables

| Table | Purpose |
|---|---|
| `ingestion_buffer` | Raw incoming messages, deduplication via idempotency key |
| `customers` | Unified customer profiles across all channels |
| `tickets` | Support tickets with AI triage fields, SLA, status |
| `messages` | Full conversation thread per ticket |
| `ticket_events` | Complete audit trail of all ticket actions |
| `reply_templates` | Pre-built response templates for common scenarios |
| `routing_rules` | Rules for routing tickets to agents/departments |
| `sla_policies` | SLA deadlines by priority level |
| `agent_users` | Agent accounts with roles |

### Ticket Status Flow

```
open → awaiting_customer → awaiting_agent → replied → resolved → closed
                                         ↓
                                     escalated
                                         ↓
                                   sla_breached
```

### SLA Policy

| Priority | Response SLA |
|---|---|
| High | 1 hour |
| Medium | 4 hours |
| Low | 24 hours |

---

## Conversation Threading

When a customer sends a follow-up message, the system:

1. Detects the customer's `channel_id` against open tickets
2. If an existing open ticket is found → attaches the message to the thread
3. Updates ticket status to `awaiting_agent`
4. Alerts the agent with full conversation context
5. New ticket is NOT created — the thread continues

This prevents duplicate tickets for the same conversation.

---

## Reply Templates

Pre-built templates stored in Supabase:

- **Request Refund Info** — asks for phone, order number, order date, issue description
- **Request Technical Info** — asks for device, browser, steps to reproduce, error messages
- **General Acknowledgement** — confirms receipt with ticket reference
- **Request Account Info** — asks for email, username, last login

---

## Key Architecture Decisions

**Separate workflows per function** — not one monolithic workflow. Each workflow has a single responsibility, making debugging easy and allowing independent scheduling and activation.

**Ingestion buffer** — all incoming messages land in a Supabase table first before n8n processes them. This means messages are never lost even if n8n is restarting or overloaded.

**Idempotency keys** — every message gets a unique key (e.g. `telegram_12345`, `email_abc123`). Duplicate messages are detected and silently discarded.

**Customer upsert** — returning customers are matched by email or channel ID. No duplicate customer records.

**AI confidence gating** — the system never sends a low-confidence reply automatically. Human agents handle anything below 80% confidence.

**Error handling** — if the AI model is rate-limited or unavailable, tickets are still created with `confidence: 0` and escalated to an agent. A Telegram alert is sent to the operator.

---

## Deployment

| Component | Host |
|---|---|
| n8n | Hostinger cloud VPS (`https://n8n.srv1106977.hstgr.cloud`) |
| Supabase | Supabase cloud free tier (`https://irznimaznybxwedndcwd.supabase.co`) |
| AI | OpenRouter API (free tier models) |

### Cost at current scale

- n8n: included in Hostinger VPS cost
- Supabase: free tier (500MB, unlimited API calls)
- OpenRouter: free models (Gemini Flash, Nemotron)
- **Total AI/DB cost: $0/month**

---

## Dashboard (React — separate build)

Built with React + Vite + Tailwind. Reads directly from Supabase via the publishable API key. Uses Supabase Realtime for live ticket updates.

**Views:**
- Ticket queue (all channels unified)
- Ticket detail with full conversation thread
- Customer profile (all tickets from same customer)
- Agent workspace (reply, assign, escalate)
- Manager analytics (volume, SLA, confidence trends)
- Admin settings (routing rules, templates, SLA policies)

---

## What makes this different from Chatwoot / Freshdesk

| Feature | OCSCC | Chatwoot | Freshdesk Free |
|---|---|---|---|
| AI triage | ✅ | ❌ | ❌ |
| Auto-reply with confidence gating | ✅ | ❌ | ❌ |
| SLA automation | ✅ | Manual | Manual |
| n8n flexibility (custom logic) | ✅ | ❌ | ❌ |
| Cost | ~$0 AI cost | Free | Free |
| Self-hosted | ✅ | ✅ | ❌ |

---

## Build Order (for reference)

1. Supabase schema setup
2. WF01 — Website form intake
3. WF02 — Email intake
4. WF03 — Telegram intake
5. WF04 — WhatsApp intake
6. WF06 — AI Triage (core engine)
7. WF07 — Auto Reply Telegram
8. WF09 — Escalation
9. WF10 — SLA Monitor
10. WF11 — Daily Report
11. WF12 — Agent Reply Dispatcher
12. WF08 — Auto Reply Email
13. Customer/messages/ticket_events schema additions
14. Conversation threading logic

---

## Project Context

This project was built as a group assignment for the **Ostad AI Automation Course, Batch 7** under the prompt of building an "Omnichannel Customer Support Command Center."

It was subsequently reframed as a real portfolio and client-ready product under the **Innovexa Solution** brand, with production-grade architecture, error handling, and multi-tenant design considerations from the ground up.

**Team roles:**
- **Robin (Hafizul Haider)** — System design, all n8n workflow implementation, Supabase schema, bug diagnosis and fixing, AI integration, architecture decisions
- **Jamilur Reza Razib** — Group collaboration and project contribution

---

*Powered by Innovexa Solution — Built with n8n, Supabase, and OpenRouter*
