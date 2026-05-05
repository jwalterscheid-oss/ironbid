#!/usr/bin/env bash
# setup-mcp.sh — Run this once to configure Supabase MCP for IRONBID
# Usage: bash setup-mcp.sh

set -e

BOLD='\033[1m'
TEAL='\033[0;36m'
GREEN='\033[0;32m'
AMBER='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m'

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   IRONBID — Supabase MCP Setup           ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""

# ── Check Claude CLI is installed ──────────────────────────────────────────
if ! command -v claude &> /dev/null; then
  echo -e "${RED}✗ Claude CLI not found.${RESET}"
  echo ""
  echo "Install it first:"
  echo "  npm install -g @anthropic-ai/claude-code"
  echo ""
  exit 1
fi
echo -e "${GREEN}✓ Claude CLI found: $(claude --version)${RESET}"

# ── Check Node.js ───────────────────────────────────────────────────────────
if ! command -v node &> /dev/null; then
  echo -e "${RED}✗ Node.js not found. Install from https://nodejs.org${RESET}"
  exit 1
fi
echo -e "${GREEN}✓ Node.js: $(node --version)${RESET}"
echo ""

# ── STEP 1: Add MCP Server ──────────────────────────────────────────────────
echo -e "${BOLD}STEP 1 — Adding Supabase MCP server...${RESET}"
claude mcp add \
  --scope project \
  --transport http \
  supabase \
  "https://mcp.supabase.com/mcp?project_ref=obfqhbiglcxcwlljzqbr"

echo -e "${GREEN}✓ MCP server registered in .claude/mcp.json${RESET}"
echo ""

# ── STEP 2: Authenticate ────────────────────────────────────────────────────
echo -e "${BOLD}STEP 2 — Authenticating with Supabase MCP...${RESET}"
echo ""
echo -e "${AMBER}ACTION REQUIRED:${RESET}"
echo "  This will open an interactive authentication flow."
echo "  1. Select 'supabase' from the server list"
echo "  2. Choose 'Authenticate'"
echo "  3. Complete the browser OAuth flow"
echo ""
read -p "Press ENTER to start authentication... "
claude /mcp
echo ""

# ── STEP 3: Install Agent Skills ────────────────────────────────────────────
echo -e "${BOLD}STEP 3 — Installing Supabase Agent Skills...${RESET}"
npx --yes skills add supabase/agent-skills
echo -e "${GREEN}✓ Agent skills installed${RESET}"
echo ""

# ── STEP 4: Install npm dependencies ────────────────────────────────────────
echo -e "${BOLD}STEP 4 — Installing npm dependencies...${RESET}"
npm install
echo -e "${GREEN}✓ Dependencies installed${RESET}"
echo ""

# ── STEP 5: Check .env.local ────────────────────────────────────────────────
echo -e "${BOLD}STEP 5 — Checking environment variables...${RESET}"
if [ ! -f ".env.local" ]; then
  cp env.example .env.local
  echo -e "${AMBER}⚠  Created .env.local from env.example${RESET}"
  echo -e "${AMBER}   IMPORTANT: Fill in all values before continuing.${RESET}"
  echo ""
  echo "Required keys:"
  echo "  DATABASE_URL              — from Supabase project settings"
  echo "  NEXT_PUBLIC_SUPABASE_URL  — https://obfqhbiglcxcwlljzqbr.supabase.co"
  echo "  NEXT_PUBLIC_SUPABASE_ANON_KEY"
  echo "  SUPABASE_SERVICE_ROLE_KEY"
  echo "  STRIPE_SECRET_KEY"
  echo "  CLERK_SECRET_KEY"
  echo "  ABLY_API_KEY"
  echo "  SLACK_BOT_TOKEN"
  echo "  REDIS_URL"
  echo ""
  read -p "Press ENTER once you've filled in .env.local... "
else
  echo -e "${GREEN}✓ .env.local exists${RESET}"
fi
echo ""

# ── STEP 6: Push schema to Supabase ─────────────────────────────────────────
echo -e "${BOLD}STEP 6 — Pushing database schema to Supabase...${RESET}"
echo -e "${AMBER}This will create all 12 IRONBID tables.${RESET}"
read -p "Press ENTER to run db:push... "
npm run db:push
echo -e "${GREEN}✓ Schema pushed${RESET}"
echo ""

# ── STEP 7: Create Supabase SQL functions ────────────────────────────────────
echo -e "${BOLD}STEP 7 — Supabase SQL functions${RESET}"
echo ""
echo -e "${AMBER}Manual step required:${RESET}"
echo "  Go to: https://supabase.com/dashboard/project/obfqhbiglcxcwlljzqbr/sql"
echo "  Run the SQL functions from CLAUDE.md:"
echo "    - place_bid()"
echo "    - close_auction()"
echo "    - award_haul_job()"
echo "  And the RLS policies listed at the bottom of CLAUDE.md"
echo ""
read -p "Press ENTER once SQL functions are created... "
echo ""

# ── ALL DONE ─────────────────────────────────────────────────────────────────
echo -e "${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   ${GREEN}IRONBID MCP Setup Complete!${RESET}${BOLD}           ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""
echo "Next steps:"
echo -e "  ${TEAL}npm run dev${RESET}           → Start dev server at http://localhost:3000"
echo -e "  ${TEAL}npm run db:studio${RESET}     → Browse data in Drizzle Studio"
echo -e "  ${TEAL}npm run worker:bids${RESET}   → Start bid processing worker"
echo -e "  ${TEAL}claude${RESET}                → Open Claude Code with Supabase MCP active"
echo ""
echo "Claude Code can now directly:"
echo "  ✓ Query and update your Supabase database"
echo "  ✓ Generate and run migrations"
echo "  ✓ Inspect table schemas and data"
echo "  ✓ Debug RLS policies"
echo ""
