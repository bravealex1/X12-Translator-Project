defmodule ClaimViewer.Claims.Claim do
  @moduledoc """
  Ecto schema for the `claims` database table.

  Each row represents one healthcare claim that was uploaded to the system.
  The claim can originate from either a pre-translated JSON file or a raw
  X12 EDI file that was translated automatically on upload.

  TWO KINDS OF DATA ARE STORED
  ─────────────────────────────
  1. `raw_json`  – the complete claim as a JSON array of section objects.
                   This is what gets displayed on the claim detail page.
                   It contains everything: patient demographics, service lines,
                   diagnosis codes, provider info, indicators, etc.

  2. Extracted search fields (all the other columns) – key values copied out
                   of raw_json and stored as first-class database columns so
                   that searching is fast (indexed text / date columns instead
                   of JSONB queries).

  RELATIONSHIP TO THE X12 TRANSLATOR
  ─────────────────────────────────────
  When a raw X12 file is uploaded, `PageController.upload/2` calls the Python
  parser (`priv/python/parser_for_viewer.py`) to produce the section-array JSON.
  `ClaimViewer.Claims.extract_search_fields/1` then walks that array and
  populates the search columns before `Repo.insert!/1` writes the row here.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "claims" do
    # ── Full claim data ──────────────────────────────────────────────────────
    # Stored as a PostgreSQL JSONB array of section objects.
    # Shape:  [%{"section" => "subscriber", "data" => %{...}}, ...]
    field :raw_json, {:array, :map}

    # ── Searchable fields (extracted from raw_json on upload) ────────────────
    # Stored as plain text/date columns for efficient WHERE-clause queries.

    # Patient (the insured person receiving care)
    field :patient_first_name, :string
    field :patient_last_name,  :string
    field :patient_dob,        :date       # "YYYY-MM-DD" from raw_json["subscriber"]["dob"]

    # Insurance payer
    field :payer_name, :string

    # Billing provider (practice / hospital that submitted the claim)
    field :billing_provider_name, :string
    field :billing_provider_npi,  :string

    # Pay-To provider (may differ from billing provider)
    field :pay_to_provider_name, :string
    field :pay_to_provider_npi,  :string

    # Rendering provider (the clinician who performed the service)
    field :rendering_provider_name, :string
    field :rendering_provider_npi,  :string  # 10-digit NPI, searched with exact match

    # Clearinghouse reference number assigned during EDI submission
    field :clearinghouse_claim_number, :string

    # Date of the first service line – used for date-range filtering
    field :date_of_service, :date

    # Automatically managed created_at / updated_at timestamps
    timestamps()
  end

  @doc """
  Build an Ecto changeset.

  All fields are optional – `cast/3` will silently ignore any keys that are
  nil or missing from `attrs`, so partial updates work without extra guards.
  """
  def changeset(claim, attrs) do
    claim
    |> cast(attrs, [
      :raw_json,
      :patient_first_name,
      :patient_last_name,
      :patient_dob,
      :payer_name,
      :billing_provider_name,
      :billing_provider_npi,
      :pay_to_provider_name,
      :pay_to_provider_npi,
      :rendering_provider_name,
      :rendering_provider_npi,
      :clearinghouse_claim_number,
      :date_of_service
    ])
  end
end
