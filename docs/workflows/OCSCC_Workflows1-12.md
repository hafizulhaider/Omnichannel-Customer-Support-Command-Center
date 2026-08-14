# OCSCC — Workflow Documentation

> Omnichannel Customer Support Command Center  
> Brand: Innovexa Solution | Course: Ostad AI Automation Batch 7  
> Team: Robin (Hafizul Haider) & Jamilur Reza Razib

---

## Overview

The system has 12 n8n workflows split into 3 groups:

- **Group 1 — Intake** (WF01–WF05): One per channel. Catches raw messages, normalizes, writes to ingestion buffer.
- **Group 2 — Core Engine** (WF06–WF09, WF12): Processes tickets, replies, escalates, dispatches agent replies.
- **Group 3 — Background Jobs** (WF10–WF11): Scheduled monitoring and reporting.

---

## Standard normalized message format

Every intake workflow converts its raw payload into this exact shape before writing to Supabase:

```json
{
  "source": "telegram",
  "customer_name": "John Doe",
  "customer_email": "john@example.com",
  "customer_phone": "01711000000",
  "customer_channel_id": "1096690284",
  "subject": "Telegram message",
  "body": "I want a refund",
  "idempotency_key": "telegram_12345678",
  "raw_payload": { "...original webhook data..." }
}
```

The `idempotency_key` prevents duplicate processing if the same message fires twice.

---

## WF01 — Website Form Intake

**Trigger:** Webhook (POST)  
**Webhook URL:** `https://n8n.srv1106977.hstgr.cloud/webhook/website-form`  
**Schedule:** Real-time (fires on form submission)

### What it does
Catches form submissions from the website contact form, normalizes the payload, checks for duplicates, and writes to `ingestion_buffer`.

### Nodes
1. **Webhook** — listens for POST at `/webhook/website-form`, responds immediately
2. **Edit Fields (Set)** — normalizes raw form data to standard format
3. **HTTP Request (GET)** — checks `ingestion_buffer` for existing `idempotency_key`
4. **IF** — if duplicate: stop. If new: continue
5. **HTTP Request (POST)** — writes normalized record to `ingestion_buffer` with `status: pending`

### Idempotency key format
```
form_{email}_{timestamp}
```

### Expected input payload
```json
{
  "name": "John Doe",
  "email": "john@example.com",
  "phone": "01711000000",
  "subject": "Order not delivered",
  "message": "I placed an order 3 days ago..."
}
```

### Output
New row in `ingestion_buffer` with `status: pending`

---

## WF02 — Email Intake

**Trigger:** Gmail node (polls every minute)  
**Schedule:** Every 1 minute  
**Credential:** Gmail OAuth2

### What it does
Polls the connected Gmail inbox for new emails, normalizes the email data, deduplicates using the Gmail message ID, and writes to `ingestion_buffer`.

### Nodes
1. **Gmail Trigger** — polls inbox every minute for unread emails
2. **Set** — normalizes email fields to standard format
3. **HTTP Request (GET)** — checks for existing idempotency key in buffer
4. **IF** — duplicate check
5. **HTTP Request (POST)** — writes to `ingestion_buffer`

### Idempotency key format
```
email_{gmail_message_id}
```

### Field mapping
| Standard field | Gmail source |
|---|---|
| `customer_name` | Parsed from `From` header |
| `customer_email` | Parsed from `From` header |
| `subject` | `Subject` header |
| `body` | `text` or `snippet` field |
| `customer_channel_id` | Customer email address |

### Output
New row in `ingestion_buffer` with `status: pending`

---

## WF03 — Telegram Intake

**Trigger:** Telegram Trigger node (webhook-based)  
**Schedule:** Real-time (fires instantly on message)  
**Credential:** Telegram Bot API token

### What it does
Listens for messages sent to the Telegram bot. Normalizes the Telegram message object and writes to `ingestion_buffer`. The Telegram node automatically registers the webhook with Telegram when the workflow is activated.

### Nodes
1. **Telegram Trigger** — listens for `message` updates
2. **Set** — normalizes Telegram message to standard format
3. **HTTP Request (GET)** — idempotency check
4. **IF** — duplicate check
5. **HTTP Request (POST)** — writes to `ingestion_buffer`

### Idempotency key format
```
telegram_{message_id}
```

### Field mapping
| Standard field | Telegram source |
|---|---|
| `customer_name` | `message.from.first_name + last_name` |
| `customer_channel_id` | `message.from.id` (numeric Telegram user ID) |
| `body` | `message.text` |
| `subject` | Fixed: `"Telegram message"` |

### Output
New row in `ingestion_buffer` with `status: pending`

---

## WF04 — WhatsApp Intake

**Trigger:** Webhook (POST) — Meta Cloud API  
**Webhook URL:** `https://n8n.srv1106977.hstgr.cloud/webhook/whatsapp`  
**Status:** Built — pending Meta Business approval  
**Credential:** Meta Cloud API access token

### What it does
Two webhook paths on the same URL:
- **GET** `/webhook/whatsapp` — handles Meta verification challenge (responds with `hub.challenge`)
- **POST** `/webhook/whatsapp` — receives incoming WhatsApp messages

### Nodes
1. **Webhook (GET)** — Meta verification handler, echoes `hub.challenge`
2. **Respond to Webhook** — returns challenge value for Meta verification
3. **Webhook (POST)** — receives live WhatsApp messages
4. **Set** — normalizes Meta payload to standard format
5. **HTTP Request (GET)** — idempotency check
6. **IF** — duplicate check
7. **HTTP Request (POST)** — writes to `ingestion_buffer`

### Idempotency key format
```
whatsapp_{wamid}
```

### Field mapping
| Standard field | WhatsApp source |
|---|---|
| `customer_name` | `entry[0].changes[0].value.contacts[0].profile.name` |
| `customer_channel_id` | `entry[0].changes[0].value.messages[0].from` |
| `body` | `entry[0].changes[0].value.messages[0].text.body` |

### Output
New row in `ingestion_buffer` with `status: pending`

---

## WF05 — Facebook Messenger Intake

**Trigger:** Webhook (POST) — Meta Cloud API  
**Status:** Built — pending Meta Business approval  
**Credential:** Meta Cloud API access token

### What it does
Same pattern as WhatsApp intake. Receives Facebook Page messages via Meta webhook, normalizes, and writes to buffer.

### Idempotency key format
```
messenger_{message_id}
```

### Output
New row in `ingestion_buffer` with `status: pending`

---

## WF06 — AI Triage

**Trigger:** Schedule (every 1 minute)  
**Schedule:** Every 1 minute  
**AI Model:** OpenRouter (Gemini Flash / Nemotron 550B)

### What it does
The core intelligence workflow. Reads pending messages from `ingestion_buffer`, sends them to the AI for classification, then either creates a new ticket or appends to an existing conversation thread.

### Nodes
1. **Schedule Trigger** — every 1 minute
2. **HTTP Request (read buffer)** — fetches `status=pending` records from `ingestion_buffer`
3. **AI Agent** — sends message to OpenRouter with triage system prompt
4. **Code (JavaScript)** — parses AI JSON response, handles errors, calculates SLA deadline
5. **check thread (Code)** — checks if customer already has an open ticket (conversation threading)
6. **is existing ticket (IF)** — routes to thread append or new ticket creation

**True branch (existing ticket):**
7a. **add message to thread** — inserts message into `messages` table
7b. **update to awaiting agent** — PATCHes ticket status
7c. **log ticket event** — inserts `customer_replied` event
7d. **update buffer status** — marks buffer record as `done`

**False branch (new ticket):**
8a. **find or create customer** — upserts customer record in `customers` table
8b. **create ticket in Supabase** — creates ticket with all AI triage fields
8c. **insert message** — stores first message in `messages` table
8d. **insert ticket event** — logs `created` event in `ticket_events`
8e. **update buffer status to done** — marks buffer record as `done`

### AI system prompt
```
You are a customer support triage AI for a helpdesk system.
Analyze the customer message and respond ONLY with a valid JSON object.
No extra text, no markdown, no code blocks. Just raw JSON.

Return exactly this structure:
{
  "category": "billing|technical|general|complaint",
  "priority": "high|medium|low",
  "sentiment": "positive|neutral|negative",
  "confidence": <number between 0 and 100>,
  "ai_summary": "<one sentence summary of the issue>",
  "ai_reply_draft": "<professional, empathetic reply to the customer>"
}
```

### AI output fields
| Field | Values | Purpose |
|---|---|---|
| `category` | billing, technical, general, complaint | Routing and template selection |
| `priority` | high, medium, low | SLA deadline calculation |
| `sentiment` | positive, neutral, negative | Urgency indicator |
| `confidence` | 0–100 | Auto-reply vs escalation decision |
| `ai_summary` | text | One-line summary for agents |
| `ai_reply_draft` | text | Ready-to-send customer reply |

### SLA calculation
| Priority | SLA deadline |
|---|---|
| high | now + 1 hour |
| medium | now + 4 hours |
| low | now + 24 hours |

### Confidence routing
- **≥ 80%** → auto-reply workflows pick up the ticket
- **< 80%** → WF09 escalation alerts the agent

### Error handling
If AI model is rate-limited or unavailable:
- Sets `confidence: 0`
- Sets `ai_reply_draft` to generic holding message
- Ticket is still created
- Triggers escalation automatically
- Sends Telegram alert to operator

### Output
- New row in `tickets` with full AI classification
- New row in `messages` with customer's first message
- New row in `ticket_events` with `created` event
- `ingestion_buffer` record updated to `status: done`

---

## WF07 — Auto Reply Telegram

**Trigger:** Schedule (every 1 minute)  
**Schedule:** Every 1 minute  
**Credential:** Telegram Bot API

### What it does
Reads open Telegram tickets with AI confidence ≥ 80 and sends the appropriate reply back to the customer. Billing tickets get a structured info-request message. All other tickets get the AI drafted reply.

### Nodes
1. **Schedule Trigger** — every 1 minute
2. **read open telegram tickets (HTTP GET)** — fetches `source=telegram, status=open or awaiting_agent, confidence≥80`
3. **has tickets (IF)** — stops if no tickets found
4. **is billing (IF)** — checks `category = billing`

**True branch (billing):**
5a. **send info request (Telegram)** — sends structured message asking for phone, order number, order date, issue description

**False branch (non-billing):**
5b. **send ai reply (Telegram)** — sends `ai_reply_draft` from triage

**Both branches converge:**
6. **update status (HTTP PATCH)** — sets `status: awaiting_customer`, `replied_at: now()`
7. **log reply message (HTTP POST)** — inserts sent message into `messages` table
8. **log reply event (HTTP POST)** — inserts `replied` event into `ticket_events`

### Billing info request message
```
Hi {customer_name}, thank you for reaching out about your refund request.

To process this for you, we need a few details:

1️⃣ Your phone number
2️⃣ Order number
3️⃣ Order date
4️⃣ Brief description of the issue

Please reply with these and we'll get started right away!
```

### Ticket status after reply
`open` → `awaiting_customer`

This prevents WF07 from replying to the same ticket again on the next run.

---

## WF08 — Auto Reply Email

**Trigger:** Schedule (every 1 minute)  
**Schedule:** Every 1 minute  
**Credential:** Gmail OAuth2

### What it does
Same as WF07 but for email tickets. Reads open email tickets with confidence ≥ 80 and sends the AI reply back via Gmail.

### Nodes
1. **Schedule Trigger**
2. **read email tickets (HTTP GET)** — `source=email, status=open, confidence≥80`
3. **IF** — stops if no tickets
4. **Gmail** — sends reply to `customer_email` with subject `Re: {original subject}`
5. **mark as replied (HTTP PATCH)** — sets `status: replied`
6. **insert message (HTTP POST)** — logs sent message
7. **log ticket event (HTTP POST)** — logs `replied` event

### Output
Customer receives email reply. Ticket status → `replied`.

---

## WF09 — Escalation

**Trigger:** Schedule (every 5 minutes)  
**Schedule:** Every 5 minutes  
**Credential:** Telegram Bot API

### What it does
Finds open tickets where AI confidence is below 80% and alerts the support agent via Telegram. Uses `escalation_notified` flag to ensure each ticket only triggers one alert.

### Nodes
1. **Schedule Trigger** — every 5 minutes
2. **read escalations (HTTP GET)** — `status=open, confidence<80, escalation_notified=false`
3. **IF** — stops if no tickets found
4. **HTTP PATCH** — sets `status: escalated`, `escalation_notified: true` (BEFORE Telegram to preserve data context)
5. **Telegram** — sends escalation alert to agent

### Escalation alert format
```
🚨 ESCALATION ALERT

Ticket needs human attention:

From: {customer_name}
Channel: {source}
Category: {category}
Priority: {priority}
Sentiment: {sentiment}
Confidence: {confidence}%

Message:
{body}

AI Summary:
{ai_summary}
```

### Key design decision
The PATCH node runs BEFORE the Telegram node. This ensures `$json` still contains ticket data when marking as escalated, avoiding the upstream reference problem.

### `escalation_notified` flag
Set to `true` after first alert. Prevents the scheduler from sending repeat alerts for the same ticket on subsequent runs.

---

## WF10 — SLA Monitor

**Trigger:** Schedule (every 30 minutes)  
**Schedule:** Every 30 minutes  
**Credential:** Telegram Bot API

### What it does
Checks all open tickets against their SLA deadline. Alerts the agent for any ticket whose deadline is within the next 30 minutes or already breached. Marks breached tickets as `sla_breached`.

### Nodes
1. **Schedule Trigger** — every 30 minutes
2. **read tickets (HTTP GET)** — `status=open, sla_due_at<now()+30min` using `encodeURIComponent($now.plus(30, 'minutes').toISO())`
3. **IF** — stops if no breaching tickets
4. **Telegram** — sends SLA alert to agent
5. **HTTP PATCH** — sets `status: sla_breached`

### SLA alert format
```
⏰ SLA ALERT

Ticket is breaching SLA!

From: {customer_name}
Channel: {source}
Priority: {priority}
Category: {category}
SLA Due: {sla_due_at}
Status: {status}

Message:
{body}

AI Summary:
{ai_summary}
```

### Key fix
Timestamp URL encoding: `encodeURIComponent($now.plus(30, 'minutes').toISO())` prevents the `+` in timezone offset from being corrupted in the Supabase REST API URL.

---

## WF11 — Daily Report

**Trigger:** Schedule (8:00 AM daily)  
**Schedule:** Daily at 08:00  
**Credential:** Telegram Bot API

### What it does
Every morning at 8am, pulls all tickets from the previous day and sends a summary digest to the agent via Telegram.

### Nodes
1. **Schedule Trigger** — daily at 8am
2. **HTTP Request (GET)** — fetches yesterday's tickets using `encodeURIComponent` for timestamp URLs
3. **Code (JavaScript)** — aggregates stats by channel, priority, category, status
4. **Telegram** — sends formatted daily report

### Report format
```
📊 DAILY SUPPORT REPORT
Mon Aug 12 2026
━━━━━━━━━━━━━━━━━━━━

📨 Total tickets: 12

📡 By channel:
  • telegram: 5
  • email: 4
  • form: 3

🎯 By priority:
  • high: 3
  • medium: 7
  • low: 2

🗂 By category:
  • billing: 5
  • technical: 4
  • general: 3

📈 Performance:
  • AI avg confidence: 84%
  • Auto-replied: 9
  • Escalated to human: 3
  • SLA breached: 1

━━━━━━━━━━━━━━━━━━━━
Powered by OCSCC — Innovexa Solution
```

---

## WF12 — Agent Reply Dispatcher

**Trigger:** Schedule (every 1 minute)  
**Schedule:** Every 1 minute  
**Credentials:** Telegram Bot API, Gmail OAuth2

### What it does
When an agent types a reply in the dashboard, it's saved to the `messages` table with `sent: false`. WF12 picks up these unsent messages and dispatches them back to the customer through the correct channel.

### Nodes
1. **Schedule Trigger** — every 1 minute
2. **read agent messages (HTTP GET)** — `sender_type=agent, sent=false`
3. **IF** — stops if no unsent messages
4. **get ticket (HTTP GET)** — fetches the parent ticket to get `source` and `customer_channel_id`
5. **Switch** — routes by `source` field:
   - `telegram` → Telegram node
   - `email` → Gmail node
   - `whatsapp` → WhatsApp node (pending)
6. **Channel node** — sends agent message to customer
7. **mark as sent (HTTP PATCH)** — sets `sent: true`, `sent_at: now()`
8. **log reply event (HTTP POST)** — inserts `replied` event with `actor: agent`

### How to trigger (without dashboard)
Insert a message directly into Supabase:

```sql
insert into messages (ticket_id, sender_type, sender_name, body, channel, sent)
values (
  'YOUR-TICKET-ID',
  'agent',
  'Support Agent',
  'Your refund has been processed. Please allow 3-5 business days.',
  'telegram',
  false
);
```

WF12 picks it up within 1 minute and dispatches to the customer.

### `sent` flag
Prevents the same message being dispatched twice if the scheduler runs before the PATCH completes.

---

## Workflow interaction map

```
Customer message
      ↓
WF01/02/03/04/05 (intake by channel)
      ↓
ingestion_buffer (status: pending)
      ↓
WF06 (AI triage — every 1 min)
      ↓
tickets table created
      ↓
      ├── confidence ≥ 80 ──→ WF07 (Telegram reply)
      │                  ──→ WF08 (Email reply)
      │
      └── confidence < 80 ──→ WF09 (Escalation alert to agent)
                                    ↓
                              Agent reviews in dashboard
                                    ↓
                              Agent types reply
                                    ↓
                              WF12 (dispatches reply to customer)

Background (independent):
WF10 — SLA Monitor (every 30 min)
WF11 — Daily Report (8am daily)
```

---

## Common n8n patterns used

**Idempotency check pattern:**
```
HTTP GET (check exists) → IF (is empty?) → HTTP POST (insert)
```

**Status update after action:**
Always PATCH the status BEFORE sending Telegram messages to preserve `$json` data context.

**Node name references:**
When data is lost after a channel node (Telegram, Gmail), always reference the upstream node explicitly:
```
$('node-name').item.json.field
```

**Timestamp URL encoding:**
Always wrap timestamps in Supabase REST URLs:
```
encodeURIComponent($now.plus(30, 'minutes').toISO())
```

**Continue On Fail + Always Output Data:**
Enable both on any HTTP GET node that might return empty results, to prevent workflow stopping.

---

*Powered by Innovexa Solution — Built with n8n, Supabase, and OpenRouter*
