-- ============================================================
-- OCSCC — Omnichannel Customer Support Command Center
-- Supabase / PostgreSQL Schema
-- Brand: Innovexa Solution
-- Course: Ostad AI Automation Batch 7
-- Team: Robin (Hafizul Haider) & Jamilur Reza Razib
-- ============================================================

-- ============================================================
-- TABLE: ingestion_buffer
-- Purpose: Raw incoming messages from all channels.
--          Acts as a safe landing zone before n8n processes them.
--          Idempotency key prevents duplicate processing.
-- ============================================================
create table ingestion_buffer (
  id                  uuid primary key default gen_random_uuid(),
  source              text not null,                        -- email | form | telegram | whatsapp | messenger
  customer_name       text,
  customer_email      text,
  customer_phone      text,
  customer_channel_id text,                                 -- telegram user id, email address, whatsapp number etc
  subject             text,
  body                text not null,
  idempotency_key     text unique not null,                 -- prevents duplicate processing
  raw_payload         jsonb not null,                       -- original webhook payload stored for debugging
  status              text default 'pending',               -- pending | processing | done | failed
  received_at         timestamptz default now()
);

alter table ingestion_buffer disable row level security;

-- ============================================================
-- TABLE: customers
-- Purpose: Unified customer profiles across all channels.
--          Upserted on every new message — same customer
--          on Telegram and Email is eventually linked.
-- ============================================================
create table customers (
  id              uuid primary key default gen_random_uuid(),
  name            text,
  email           text,
  phone           text,
  telegram_id     text,
  whatsapp_id     text,
  messenger_id    text,
  first_seen_at   timestamptz default now(),
  last_seen_at    timestamptz default now(),
  total_tickets   int default 0,
  notes           text
);

alter table customers disable row level security;

-- Unique constraint required for upsert on conflict
alter table customers
  add constraint customers_email_unique unique (email);

-- ============================================================
-- TABLE: tickets
-- Purpose: Core support ticket. Created by AI triage workflow.
--          Contains AI classification fields, SLA deadline,
--          and status tracking throughout the ticket lifecycle.
-- ============================================================
create table tickets (
  id                    uuid primary key default gen_random_uuid(),
  buffer_id             uuid references ingestion_buffer(id),
  customer_id           uuid references customers(id),
  source                text,                               -- email | form | telegram | whatsapp | messenger
  customer_name         text,
  customer_email        text,
  customer_phone        text,
  customer_channel_id   text,
  subject               text,
  body                  text,
  -- AI triage fields
  category              text,                               -- billing | technical | general | complaint
  priority              text,                               -- high | medium | low
  sentiment             text,                               -- positive | neutral | negative
  confidence            int,                               -- 0-100 AI confidence score
  ai_summary            text,
  ai_reply_draft        text,
  -- Status and assignment
  status                text default 'open',
  -- Status values:
  --   open             → newly created, not yet actioned
  --   awaiting_customer → we replied, waiting for customer response
  --   awaiting_agent   → customer replied, waiting for agent action
  --   replied          → agent or AI has replied
  --   escalated        → routed to human agent (low confidence)
  --   resolved         → issue resolved
  --   closed           → ticket closed
  --   sla_breached     → SLA deadline passed without resolution
  assigned_to           text,
  sla_due_at            timestamptz,
  replied_at            timestamptz,
  -- Escalation control
  escalation_notified   boolean default false,              -- prevents repeat escalation alerts
  agent_notified        boolean default false,              -- prevents repeat agent alerts
  created_at            timestamptz default now(),
  updated_at            timestamptz default now()
);

alter table tickets disable row level security;

-- ============================================================
-- TABLE: messages
-- Purpose: Full conversation thread per ticket.
--          Every message (customer, agent, AI) is stored here.
--          Enables multi-turn conversation threading.
-- ============================================================
create table messages (
  id            uuid primary key default gen_random_uuid(),
  ticket_id     uuid references tickets(id),
  customer_id   uuid references customers(id),
  sender_type   text not null,                             -- customer | agent | ai
  sender_name   text,
  body          text not null,
  channel       text,                                      -- which channel this message was sent/received on
  sent          boolean default false,                     -- for agent/AI messages: has it been dispatched?
  sent_at       timestamptz,
  is_read       boolean default false,
  created_at    timestamptz default now()
);

alter table messages disable row level security;

-- ============================================================
-- TABLE: ticket_events
-- Purpose: Complete audit trail of every action on a ticket.
--          Used for compliance, debugging, and analytics.
-- ============================================================
create table ticket_events (
  id          uuid primary key default gen_random_uuid(),
  ticket_id   uuid references tickets(id),
  event_type  text not null,
  -- Event types:
  --   created          → ticket first created
  --   assigned         → ticket assigned to agent
  --   replied          → reply sent to customer
  --   customer_replied → customer sent follow-up message
  --   escalated        → escalated to human agent
  --   resolved         → ticket marked resolved
  --   closed           → ticket closed
  --   sla_breached     → SLA deadline passed
  actor       text default 'system',                       -- agent name, 'ai', or 'system'
  notes       text,
  created_at  timestamptz default now()
);

alter table ticket_events disable row level security;

-- ============================================================
-- TABLE: reply_templates
-- Purpose: Pre-built response templates for common scenarios.
--          Agents select and customize before sending.
-- ============================================================
create table reply_templates (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  category    text,                                        -- billing | technical | general
  body        text not null,                               -- supports {customer_name} and {ticket_id} placeholders
  created_at  timestamptz default now()
);

alter table reply_templates disable row level security;

-- Default templates
insert into reply_templates (name, category, body) values
(
  'Request Refund Info',
  'billing',
  'Hi {customer_name}, to process your refund we need a few details:

1. Your phone number
2. Order number
3. Order date
4. Description of the issue

Please reply with these details and we will get started right away.'
),
(
  'Request Technical Info',
  'technical',
  'Hi {customer_name}, to help resolve your technical issue we need some details:

1. What device and browser are you using?
2. When did this issue start?
3. What steps did you take before the issue occurred?
4. Any error messages you see?

Please share these and we will investigate right away.'
),
(
  'General Acknowledgement',
  'general',
  'Hi {customer_name}, thank you for reaching out.

We have received your message and a support agent will get back to you within 4 hours.

Your ticket reference is: {ticket_id}'
),
(
  'Request Account Info',
  'general',
  'Hi {customer_name}, to verify your account and assist you better, could you please provide:

1. The email address associated with your account
2. Your username or account ID
3. When you last successfully logged in

We will look into this right away.'
),
(
  'Refund Confirmed',
  'billing',
  'Hi {customer_name}, great news — your refund has been approved and initiated.

Please allow 3-5 business days for the amount to reflect in your account depending on your payment method.

If you have any further questions, do not hesitate to reach out. Thank you for your patience.'
);

-- ============================================================
-- TABLE: routing_rules
-- Purpose: Rules for routing tickets to agents or departments.
--          Matched by category and priority.
--          Not yet fully implemented — scaffolded for Phase 2.
-- ============================================================
create table routing_rules (
  id          uuid primary key default gen_random_uuid(),
  category    text,                                        -- billing | technical | general | complaint
  priority    text,                                        -- high | medium | low
  assign_to   text,                                        -- agent name or department
  created_at  timestamptz default now()
);

alter table routing_rules disable row level security;

-- ============================================================
-- TABLE: sla_policies
-- Purpose: SLA response time commitments by priority.
--          Used by AI triage to set sla_due_at on tickets.
-- ============================================================
create table sla_policies (
  id              uuid primary key default gen_random_uuid(),
  priority        text not null,                           -- high | medium | low
  response_hours  int not null,                            -- first response SLA in hours
  resolve_hours   int not null,                            -- resolution SLA in hours
  created_at      timestamptz default now()
);

alter table sla_policies disable row level security;

-- Default SLA policies
insert into sla_policies (priority, response_hours, resolve_hours) values
  ('high',   1,  8),
  ('medium', 4,  24),
  ('low',    24, 72);

-- ============================================================
-- TABLE: agent_users
-- Purpose: Agent accounts with roles.
--          Scaffolded for Phase 2 — full auth via Supabase Auth.
-- ============================================================
create table agent_users (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  email       text not null unique,
  role        text default 'agent',                        -- agent | manager | admin
  created_at  timestamptz default now()
);

alter table agent_users disable row level security;

-- ============================================================
-- NOTES
-- ============================================================
-- RLS (Row Level Security) is disabled on all tables for
-- development. Before going to production with real client data,
-- enable RLS and add appropriate policies per table.
--
-- n8n uses the Supabase service_role key for all writes.
-- The React dashboard uses the publishable key (anon key).
-- Supabase Realtime is enabled on tickets and messages tables
-- for live dashboard updates.
--
-- Idempotency key format by channel:
--   Email:     email_{gmail_message_id}
--   Form:      form_{email}_{timestamp}
--   Telegram:  telegram_{message_id}
--   WhatsApp:  whatsapp_{wamid}
--   Messenger: messenger_{message_id}
-- ============================================================
