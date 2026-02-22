defmodule ClaimViewer.Claims do
  @moduledoc """
  ClaimViewer.Claims  –  Field Extraction Logic
  ═══════════════════════════════════════════════

  After a claim file is uploaded and translated to a section-array (either
  directly from JSON or via the X12 parser), this module pulls out the key
  fields we want to store as searchable database columns.

  Why store fields separately?
  ─────────────────────────────
  The full claim JSON is stored in the `raw_json` column as a JSONB array.
  Querying inside JSONB with ILIKE is slow.  By copying a handful of fields
  into their own text/date columns we can search with fast index-backed
  WHERE clauses.

  Example section-array structure (what `sections` looks like here):
      [
        %{"section" => "subscriber", "data" => %{"firstName" => "Jane", ...}},
        %{"section" => "payer",      "data" => %{"name" => "BlueCross", ...}},
        %{"section" => "claim",      "data" => %{"clearinghouseClaimNumber" => "CLM001", ...}},
        %{"section" => "service_Lines", "data" => [%{"serviceDate" => "2023-04-15", ...}]},
        ...
      ]
  """

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Walk the sections array and return a map of searchable field values.

  The returned map matches the column names in the `claims` table so it can
  be merged directly into the changeset attrs in `PageController.upload/2`.
  """
  def extract_search_fields(sections) when is_list(sections) do
    %{
      # Patient (subscriber) name and date of birth
      patient_first_name: get_in_section(sections, "subscriber", ["firstName"]),
      patient_last_name:  get_in_section(sections, "subscriber", ["lastName"]),
      patient_dob:        get_in_section(sections, "subscriber", ["dob"]),

      # Insurance payer
      payer_name:         get_in_section(sections, "payer", ["name"]),

      # Billing provider (the practice or hospital submitting the claim)
      billing_provider_name: get_in_section(sections, "billing_Provider", ["name"]),

      # Pay-To provider (where the payment should actually go)
      pay_to_provider_name:  get_in_section(sections, "Pay_To_provider", ["name"]),

      # Rendering provider (the clinician who saw the patient)
      rendering_provider_name: get_in_section(sections, "renderingProvider", ["firstName"]),
      rendering_provider_npi:  get_in_section(sections, "renderingProvider", ["npi"]),

      # Clearinghouse claim reference number (used for claim-number searches)
      clearinghouse_claim_number:
        get_in_section(sections, "claim", ["clearinghouseClaimNumber"])
    }
  end

  # Guard clause: return an empty map if sections is not a list
  def extract_search_fields(_), do: %{}


  @doc """
  Extract the date of the first service line and return it as an `%Date{}`.

  This value is stored in the `date_of_service` column so users can filter
  claims by service date range without querying inside the JSONB array.

  Returns `nil` if there are no service lines or the date is missing/invalid.
  """
  def extract_date_of_service(sections) do
    sections
    |> Enum.find(fn s -> get_section_name(s) == "service_Lines" end)
    |> case do
      nil -> nil
      section ->
        data = get_section_data(section)
        [first_line | _] = data
        # Parse "YYYY-MM-DD" string into an Elixir %Date{} struct
        Date.from_iso8601!(first_line["serviceDate"])
    end
  end


  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Navigate to a specific section by name and then follow a key path inside
  # its "data" map.
  #
  # Example:
  #   get_in_section(sections, "payer", ["name"])
  #   → finds the section where section["section"] == "payer"
  #   → returns section["data"]["name"]
  defp get_in_section(sections, section_name, path) do
    sections
    |> Enum.find(fn s -> get_section_name(s) == section_name end)
    |> case do
      nil     -> nil
      section -> get_in(get_section_data(section), path)
    end
  end

  # Extract the section name, supporting both map and keyword-list formats
  defp get_section_name(%{"section" => name}), do: name
  defp get_section_name(s) when is_list(s),    do: Keyword.get(s, :section)

  # Extract the section data payload, supporting both map and keyword-list formats
  defp get_section_data(%{"data" => data}), do: data
  defp get_section_data(s) when is_list(s),  do: Keyword.get(s, :data)
end
