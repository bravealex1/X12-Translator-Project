# Claim Viewer

I built this app to make healthcare claims easy to ingest, review, search, and export.

The main idea is simple:
- I can upload either a raw X12 837 file or a pre-translated JSON file.
- If I upload X12, the app automatically runs a bundled Python parser and converts it to the JSON shape the UI expects.
- I store the full claim payload plus extracted searchable fields in PostgreSQL.
- I can search claims quickly, open a claim detail page, and export a claim to PDF or CSV.

## What This Project Does

- Dashboard with high-level claim metrics:
  - total claims
  - claims uploaded this month
  - claims older than 30 days
  - approved vs pending counts
  - approved revenue total
- Upload flow for:
  - JSON claims (`.json`)
  - X12 claims (`.txt`, `.edi`, `.x12`, `.837`)
- Search screen with filters for:
  - patient first and last name
  - payer
  - billing provider
  - rendering provider NPI
  - clearinghouse claim number
  - date-of-service range
- Claim detail view (section-by-section JSON display)
- Export options:
  - PDF
  - CSV

## Stack

- Elixir `~> 1.15`
- Phoenix `~> 1.8.1`
- Ecto + PostgreSQL
- Python 3 (for X12 parsing)
- Tailwind + esbuild
- `pdf_generator` + `wkhtmltopdf` (PDF export)

## Prerequisites

Before I run this project locally, I make sure I have:
- Elixir and Erlang/OTP installed
- PostgreSQL running locally
- Python 3 available on `PATH` (`python3`)
- `wkhtmltopdf` installed if I want PDF export

## Local Setup (Step by Step)

1. Go into the app directory:

```bash
cd /Users/qiuhaozhu/Desktop/X12_Combined/Translator-Project/claim_viewer
```

2. Update database credentials in:

`config/dev.exs`

The repo is currently configured with placeholder values:
- `username: "xxx"`
- `password: "xxx"`

I replace those with my local PostgreSQL credentials.

3. Install deps, create/migrate DB, and build assets:

```bash
mix setup
```

4. Start the Phoenix server:

```bash
mix phx.server
```

5. Open:

[http://localhost:4000](http://localhost:4000)

## How I Use the App

### 1) Dashboard (`GET /`)

I land on the dashboard first. From there I can:
- view claim metrics
- jump to search
- upload a new claim

Approval logic used by the dashboard:
- A claim is treated as approved only if all claim indicator values are one of `Y`, `A`, or `I`, and the indicator set is not empty.

### 2) Upload (`POST /upload`)

I upload either JSON or X12.

Upload behavior:
- JSON input: decoded directly
- X12 input: translated through `priv/python/parser_for_viewer.py`
- After parsing, the app extracts searchable fields and date of service, then inserts everything into the `claims` table.

### 3) Search (`GET /search`)

Search notes:
- text filters are case-insensitive (`ILIKE`) except rendering provider NPI, which is exact-match
- pagination is 10 results per page
- date filter is based on `date_of_service`
- text search only runs when at least one text input has 2+ characters (or a date range is supplied)

### 4) Claim Detail (`GET /claims/:id`)

I can open a single claim and inspect each section with pretty-printed JSON.

### 5) Exports

- PDF: `GET /claims/:id/export`
- CSV: `GET /claims/:id/export/csv`

## X12 Translation Flow

When I upload an X12 file, the controller does this:
1. Detect file type by extension (or content fallback)
2. Call Python parser:
   - script: `priv/python/parser_for_viewer.py`
   - command pattern: `python3 parser_for_viewer.py <input> <output>`
3. Read the generated JSON
4. Normalize wrapper shape if needed (`[[...]]` becomes `[...]`)
5. Save claim data + extracted fields

The parser itself supports files with or without ISA envelope and handles common encodings.

## Data Model (Claim Record)

Each claim stores:
- Full original section data (`raw_json`) for complete detail rendering
- Extracted searchable fields for fast filtering:
  - patient names and DOB
  - payer name
  - billing/pay-to/rendering provider fields
  - rendering provider NPI
  - clearinghouse claim number
  - date of service

## Important Files

- `lib/claim_viewer_web/router.ex`: all browser routes
- `lib/claim_viewer_web/controllers/page_controller.ex`: dashboard/search/upload/export logic
- `lib/claim_viewer/claims.ex`: field extraction logic
- `lib/claim_viewer/claim.ex`: Ecto schema + changeset
- `priv/python/parser_for_viewer.py`: X12 parser used during upload
- `config/dev.exs`: local DB config
- `config/config.exs`: app-wide config (including PDF generator path)

## Useful Commands

```bash
# full local setup
mix setup

# start server
mix phx.server

# run tests
mix test

# reset DB
mix ecto.reset

# project quality checks (compile warnings as errors + format + tests)
mix precommit
```

Optional parser debugging command:

```bash
python3 priv/python/parser_for_viewer.py path/to/input.edi /tmp/claim_viewer_out.json
```

## PDF Export Notes

PDF export depends on `wkhtmltopdf`.

If PDF export fails, I check:
1. `wkhtmltopdf` is installed
2. `config/config.exs` has a valid `:pdf_generator` `wkhtml_path` for my OS
3. I restart the Phoenix server after changing config

## Troubleshooting

### Database connection fails

- Verify `config/dev.exs` credentials
- Ensure PostgreSQL service is running
- Re-run `mix ecto.create`

### Upload fails for X12

- Confirm `python3` exists: `python3 --version`
- Confirm parser exists at `priv/python/parser_for_viewer.py`
- Recheck input file extension/content

### Upload fails for JSON

- Confirm the JSON is valid
- Expected shape is a section list (or wrapper list containing that list)

### PDF export fails

- Install/fix `wkhtmltopdf`
- Verify `wkhtml_path` config

## Production Runtime Config

For production, runtime variables are loaded in:

`config/runtime.exs`

At minimum I set:
- `DATABASE_URL`
- `SECRET_KEY_BASE`
- optionally `PHX_SERVER=true` (for releases)
