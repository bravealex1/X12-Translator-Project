defmodule ClaimViewerWeb.PageController do
  @moduledoc """
  PageController – the brain of the Claim Viewer web application.

  This controller handles every user interaction:

    • Dashboard  (GET /)          – shows claim statistics at a glance
    • Search     (GET /search)    – lets users find claims by patient, payer, etc.
    • Show       (GET /claims/:id)– displays the full detail of one claim
    • Upload     (POST /upload)   – accepts a raw X12 *or* JSON file, translates
                                    X12 to JSON automatically, then stores the
                                    claim in the database
    • Export PDF (GET /claims/:id/export)     – downloads a PDF of one claim
    • Export CSV (GET /claims/:id/export/csv) – downloads a CSV of one claim

  HOW X12 TRANSLATION WORKS BEHIND THE SCENES
  ────────────────────────────────────────────
  When a user uploads an X12 file the controller calls a small Python script
  (priv/python/parser_for_viewer.py) that is bundled inside this application.
  The script reads the raw EDI segments and writes a clean JSON file to a
  temporary directory.  The controller then reads that JSON, extracts the
  searchable fields, and stores everything in PostgreSQL.

  The user just clicks "Upload" – they never need to run the Python script
  manually or know anything about X12 segments.
  """

  use ClaimViewerWeb, :controller

  alias ClaimViewer.Repo
  alias ClaimViewer.Claims
  alias ClaimViewer.Claims.Claim
  import Ecto.Query


  # ─────────────────────────────────────────────────────────────────────────
  # Python script path
  # ─────────────────────────────────────────────────────────────────────────
  #
  # We bundle the Python parser inside the Phoenix app at:
  #   priv/python/parser_for_viewer.py
  #
  # Using :code.priv_dir/1 finds that directory at *runtime* regardless of
  # where the application is deployed – no hardcoded paths needed.
  #
  defp parser_script_path do
    :claim_viewer
    |> :code.priv_dir()
    |> Path.join("python/parser_for_viewer.py")
  end


  # =========================================================================
  # PRIVATE HELPERS
  # =========================================================================

  # ── File-type detection ──────────────────────────────────────────────────
  #
  # Decides whether an uploaded file is a JSON file or an X12 EDI file.
  # Checks the file extension first; if the extension is unknown, peeks at
  # the file contents to make a best guess.
  #
  defp detect_file_type(path, filename) do
    ext =
      filename
      |> Path.extname()
      |> String.downcase()

    cond do
      # Known JSON extension → treat as JSON
      ext in [".json"] ->
        :json

      # Known X12 extensions → send to the translator
      ext in [".txt", ".edi", ".x12", ".837"] ->
        :x12

      # Unknown extension → peek inside the file
      true ->
        case File.read(path) do
          {:ok, contents} ->
            trimmed = String.trim_leading(contents)

            cond do
              # JSON starts with { or [
              String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[") ->
                :json

              # X12 always starts with an ISA segment
              String.contains?(trimmed, "ISA*") or String.contains?(trimmed, "ISA~") ->
                :x12

              # Default to JSON if we can't tell
              true ->
                :json
            end

          {:error, _} ->
            :json
        end
    end
  end


  # ── X12 → JSON translation ───────────────────────────────────────────────
  #
  # Called whenever an X12 file is uploaded.
  #
  # Steps:
  #   1. Locate the bundled Python parser script.
  #   2. Write the parser output to a unique temp file (avoids conflicts when
  #      multiple users upload simultaneously).
  #   3. Run:  python3 parser_for_viewer.py <input_x12> <output_json>
  #   4. Read and decode the JSON output.
  #   5. Delete the temp file (clean up after ourselves).
  #
  defp translate_x12_to_sections(path) do
    script = parser_script_path()

    if File.exists?(script) do
      # Unique temp file so concurrent uploads don't overwrite each other
      tmp_output =
        Path.join(System.tmp_dir!(), "claim_#{System.unique_integer([:positive])}_viewer.json")

      # Run the Python translator; merge stderr into stdout so we can show
      # the user a helpful message if something goes wrong.
      {output, exit_code} =
        System.cmd("python3", [script, path, tmp_output], stderr_to_stdout: true)

      cond do
        exit_code != 0 ->
          # Translation failed – pass the error message back to the controller
          {:error,
           "Could not translate X12 file (exit #{exit_code}). " <>
             "Details: #{truncate_output(output)}"}

        true ->
          # Translation succeeded – read and parse the output JSON
          case File.read(tmp_output) do
            {:ok, contents} ->
              # Always delete the temp file whether decode succeeds or not
              File.rm(tmp_output)

              case Jason.decode(contents) do
                {:ok, decoded} ->
                  # Unwrap single-claim wrappers: [[...sections...]] → [...sections...]
                  sections =
                    case decoded do
                      [first | _] when is_list(first) -> first
                      other -> other
                    end

                  {:ok, sections}

                {:error, decode_error} ->
                  {:error, "Translator produced invalid JSON: #{truncate_output(inspect(decode_error))}"}
              end

            {:error, reason} ->
              {:error, "Could not read translator output: #{inspect(reason)}"}
          end
      end
    else
      {:error,
       "Python parser not found at #{script}. " <>
         "Make sure priv/python/parser_for_viewer.py exists."}
    end
  end


  # ── File loading ─────────────────────────────────────────────────────────
  #
  # Entry point for both upload paths (JSON and X12).
  # Returns {:ok, sections} or {:error, message}.
  #
  defp load_claim_sections(path, filename) do
    case detect_file_type(path, filename) do
      :json ->
        # Read and decode a JSON file that is already in the viewer format
        case File.read(path) do
          {:ok, contents} ->
            case Jason.decode(contents) do
              {:ok, decoded} ->
                sections =
                  case decoded do
                    [first | _] when is_list(first) -> first
                    other -> other
                  end
                {:ok, sections}

              {:error, decode_error} ->
                {:error, "File is not valid JSON: #{inspect(decode_error)}"}
            end

          {:error, reason} ->
            {:error, "Could not read file: #{inspect(reason)}"}
        end

      :x12 ->
        # Translate the X12 file to JSON first, then return the sections
        translate_x12_to_sections(path)
    end
  end


  # ── Output truncation ─────────────────────────────────────────────────────
  # Keep error messages readable.  2000 chars is enough to show a full Python
  # traceback plus our diagnostic message without flooding the flash banner.
  defp truncate_output(text) when is_binary(text), do: String.slice(text, 0, 2000)
  defp truncate_output(term), do: term |> inspect() |> String.slice(0, 2000)


  # =========================================================================
  # CONTROLLER ACTIONS
  # =========================================================================

  # ── Dashboard ─────────────────────────────────────────────────────────────
  #
  # Shows high-level statistics about all claims in the database:
  # total count, approved revenue, pending count, old claims, etc.
  #
  def dashboard(conn, _params) do
    total_claims = Repo.aggregate(Claim, :count, :id)

    # Load all claims to compute approval status and revenue.
    # (For very large datasets consider a dedicated SQL query instead.)
    claims = Repo.all(Claim)

    {approved_count, approved_revenue} =
      claims
      |> Enum.filter(fn claim ->
        # A claim is "approved" when ALL indicator flags are Y / A / I
        indicators =
          get_in(
            claim.raw_json,
            [Access.filter(fn s -> s["section"] == "claim" end), "data", "indicators"]
          )
          |> List.first() || %{}

        Enum.all?(Map.values(indicators), fn v -> v in ["Y", "A", "I"] end) and
          indicators != %{}
      end)
      |> Enum.reduce({0, 0}, fn claim, {count, revenue} ->
        charge =
          get_in(
            claim.raw_json,
            [Access.filter(fn s -> s["section"] == "claim" end), "data", "totalCharge"]
          )
          |> List.first() || 0

        {count + 1, revenue + charge}
      end)

    pending_count = total_claims - approved_count

    # Claims uploaded more than 30 days ago
    thirty_days_ago =
      NaiveDateTime.utc_now() |> NaiveDateTime.add(-30 * 24 * 60 * 60, :second)

    old_claims =
      Repo.all(from c in Claim, where: c.inserted_at < ^thirty_days_ago) |> length()

    # Claims uploaded this calendar month
    now = NaiveDateTime.utc_now()
    first_day = %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 0}}

    this_month_count =
      Repo.aggregate(from(c in Claim, where: c.inserted_at >= ^first_day), :count, :id)

    render(conn, :dashboard,
      total_claims: total_claims,
      approved_count: approved_count,
      approved_revenue: approved_revenue,
      pending_count: pending_count,
      old_claims: old_claims,
      this_month_count: this_month_count
    )
  end


  # ── Search ────────────────────────────────────────────────────────────────
  #
  # Reads search parameters from the query string, builds a dynamic Ecto
  # query, and renders the results table.
  #
  # Supports: patient name, payer, billing provider, rendering provider NPI,
  #           claim number, and service date range.
  #
  def home(conn, params) do
    # Extract and trim every search parameter (empty string = not set)
    first            = params |> Map.get("patient_first", "")   |> String.trim()
    last             = params |> Map.get("patient_last", "")    |> String.trim()
    payer            = params |> Map.get("payer", "")           |> String.trim()
    billing_provider = params |> Map.get("billing_provider", "") |> String.trim()
    rendering_provider = params |> Map.get("rendering_provider", "") |> String.trim()
    claim_number     = params |> Map.get("claim_number", "")    |> String.trim()
    service_from     = params |> Map.get("service_from", "")    |> String.trim()
    service_to       = params |> Map.get("service_to", "")      |> String.trim()

    page =
      case Integer.parse(Map.get(params, "page", "1")) do
        {num, _} -> num
        :error   -> 1
      end

    # Only run a DB query if at least one field has a meaningful value
    has_search? =
      valid_search?(first) or
        valid_search?(last) or
        valid_search?(payer) or
        valid_search?(billing_provider) or
        valid_search?(rendering_provider) or
        valid_search?(claim_number) or
        service_from != "" or
        service_to != ""

    per_page = 10
    offset   = (page - 1) * per_page

    {claims, total_count} =
      if has_search? do
        # Start with all claims and layer on filters one at a time.
        # Each maybe_* helper adds a WHERE clause only if the value is present.
        query =
          from(c in Claim)
          |> maybe_full_name(first, last)
          |> maybe_like(:payer_name, payer)
          |> maybe_like(:billing_provider_name, billing_provider)
          |> maybe_exact(:rendering_provider_npi, rendering_provider)
          |> maybe_like(:clearinghouse_claim_number, claim_number)
          |> maybe_date_range(service_from, service_to)
          |> order_by([c], desc: c.inserted_at)

        total  = Repo.aggregate(query, :count, :id)
        claims = query |> limit(^per_page) |> offset(^offset) |> Repo.all()

        {claims, total}
      else
        {[], 0}
      end

    total_pages = if total_count > 0, do: ceil(total_count / per_page), else: 0

    render(conn, :home,
      claims: claims,
      show_results: has_search?,
      patient_first: first,
      patient_last: last,
      payer: payer,
      billing_provider: billing_provider,
      rendering_provider: rendering_provider,
      claim_number: claim_number,
      service_from: service_from,
      service_to: service_to,
      page: page,
      total_pages: total_pages,
      total_count: total_count,
      json: nil,
      claim_id: nil
    )
  end


  # ── Show ──────────────────────────────────────────────────────────────────
  #
  # Loads a single claim from the database by its ID and renders the full
  # detail view.  The raw_json column contains the section array that the
  # template iterates over.
  #
  def show(conn, %{"id" => id}) do
    claim = Repo.get!(Claim, id)

    render(conn, :home,
      claims: [],
      show_results: false,
      patient_first: "",
      patient_last: "",
      payer: "",
      billing_provider: "",
      rendering_provider: "",
      claim_number: "",
      service_from: "",
      service_to: "",
      page: 1,
      total_pages: 0,
      total_count: 0,
      json: claim.raw_json,
      claim_id: id
    )
  end


  # ── Upload ────────────────────────────────────────────────────────────────
  #
  # Main file upload handler.  Accepts both JSON and X12 EDI files.
  #
  # When a JSON file is uploaded:
  #   → decode it directly
  #
  # When an X12 EDI file is uploaded:
  #   → call the bundled Python parser (priv/python/parser_for_viewer.py)
  #   → the parser translates X12 segments into clean JSON sections
  #   → continue with the same JSON flow
  #
  # After obtaining the sections:
  #   1. Extract searchable text fields (patient name, payer, NPI, etc.)
  #   2. Extract the first date of service for date-range filtering
  #   3. Insert everything into the claims table in PostgreSQL
  #   4. Redirect the user to the home page with a success flash
  #
  def upload(conn, %{"file" => %Plug.Upload{path: path, filename: filename}}) do
    case load_claim_sections(path, filename) do
      {:ok, sections} ->
        # Pull out the fields we store separately for fast searching
        search_fields = Claims.extract_search_fields(sections)

        date_of_service =
          try do
            Claims.extract_date_of_service(sections)
          rescue
            _ -> nil
          end

        attrs =
          %{raw_json: sections, date_of_service: date_of_service}
          |> Map.merge(search_fields)

        %Claim{} |> Claim.changeset(attrs) |> Repo.insert!()

        # Tell the user it worked, then send them to /search so they can
        # immediately find and review the claim they just uploaded.
        patient =
          [attrs[:patient_first_name], attrs[:patient_last_name]]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" ")
          |> String.trim()

        flash_msg =
          if patient != "",
            do: "Claim uploaded successfully for #{patient}.",
            else: "Claim uploaded and translated successfully."

        conn
        |> put_flash(:info, flash_msg)
        |> redirect(to: "/search")

      {:error, message} ->
        conn
        |> put_flash(:error, message)
        |> redirect(to: "/")
    end
  end

  # Fallback: user submitted the upload form without selecting a file
  def upload(conn, _params) do
    conn
    |> put_flash(:error, "Please select a file to upload (JSON or X12).")
    |> redirect(to: "/")
  end


  # ── Export PDF ────────────────────────────────────────────────────────────
  #
  # Renders the claim as an HTML document and converts it to PDF using the
  # wkhtmltopdf system tool (via the pdf_generator Hex library).
  # Install wkhtmltopdf first:  brew install wkhtmltopdf
  #
  def export_pdf(conn, %{"id" => id}) do
    claim = Repo.get!(Claim, id)

    html_content = """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="UTF-8">
      <style>
        body { font-family: Arial, sans-serif; padding: 30px; color: #333; }
        h1 { color: #38bdf8; border-bottom: 3px solid #38bdf8; padding-bottom: 10px; }
        h2 { color: #38bdf8; font-size: 18px; margin-top: 30px; border-bottom: 1px solid #ccc; padding-bottom: 5px; }
        table { width: 100%; border-collapse: collapse; margin-top: 15px; }
        th, td { border: 1px solid #ddd; padding: 10px; text-align: left; font-size: 13px; }
        th { background: #f0f0f0; font-weight: bold; }
        .field { margin: 8px 0; }
        .field strong { color: #555; }
        .summary { background: #f9f9f9; padding: 20px; border-radius: 8px; margin-bottom: 30px; }
      </style>
    </head>
    <body>
      <h1>CLAIM REPORT</h1>
      #{render_claim_summary(claim.raw_json)}
      #{render_claim_sections(claim.raw_json)}
    </body>
    </html>
    """

    case ensure_pdf_generator_started() do
      :ok ->
        case PdfGenerator.generate(html_content, page_size: "A4") do
          {:ok, pdf_path} ->
            pdf_binary = File.read!(pdf_path)
            File.rm(pdf_path)

            conn
            |> put_resp_content_type("application/pdf")
            |> put_resp_header("content-disposition", ~s(attachment; filename="claim_#{id}.pdf"))
            |> send_resp(200, pdf_binary)

          {:error, reason} ->
            conn
            |> put_flash(:error, "Failed to generate PDF: #{inspect(reason)}")
            |> redirect(to: "/claims/#{id}")
        end

      {:error, message} ->
        conn
        |> put_flash(:error, message)
        |> redirect(to: "/claims/#{id}")
    end
  end

  defp ensure_pdf_generator_started do
    try do
      case Application.ensure_all_started(:pdf_generator) do
        {:ok, _started} ->
          :ok

        {:error, {_app, _reason}} ->
          {:error,
           "PDF export requires wkhtmltopdf. Install it (`brew install wkhtmltopdf`) and restart the server."}
      end
    rescue
      _ ->
        {:error,
         "PDF export requires wkhtmltopdf. Install it (`brew install wkhtmltopdf`) and restart the server."}
    end
  end


  # ── Export CSV ────────────────────────────────────────────────────────────
  #
  # Builds a plain-text CSV that mirrors the structured view the browser
  # shows – one section per block, service lines as individual rows.
  #
  def export_csv(conn, %{"id" => id}) do
    claim = Repo.get!(Claim, id)

    # Pull the key sections for the summary header
    subscriber      = Enum.find(claim.raw_json, fn s -> s["section"] == "subscriber" end) || %{}
    subscriber_data = subscriber["data"] || %{}

    payer      = Enum.find(claim.raw_json, fn s -> s["section"] == "payer" end) || %{}
    payer_data = payer["data"] || %{}

    claim_section = Enum.find(claim.raw_json, fn s -> s["section"] == "claim" end) || %{}
    claim_data    = claim_section["data"] || %{}

    service_lines_section =
      Enum.find(claim.raw_json, fn s ->
        String.downcase(s["section"] || "") |> String.contains?("service")
      end) || %{}
    service_data = service_lines_section["data"] || []

    # Derive service date range from the service lines
    service_dates =
      if is_list(service_data) and service_data != [] do
        service_data |> Enum.map(fn l -> l["serviceDate"] end) |> Enum.reject(&is_nil/1)
      else
        []
      end

    first_date = if service_dates != [], do: Enum.min(service_dates), else: nil
    last_date  = if service_dates != [], do: Enum.max(service_dates), else: nil

    # Determine approval status from claim-level indicators
    indicators   = claim_data["indicators"] || %{}
    all_approved = Enum.all?(Map.values(indicators), fn v -> v in ["Y", "A", "I"] end)
    status       = if all_approved and indicators != %{}, do: "Approved", else: "Pending Review"

    csv_content = """
CLAIM SUMMARY
=============
Patient: #{subscriber_data["firstName"]} #{subscriber_data["lastName"]} (DOB: #{format_date_plain(subscriber_data["dob"])})
Payer: #{payer_data["name"]}
Claim #: #{claim_data["clearinghouseClaimNumber"] || claim_data["id"]}
Service Dates: #{if first_date && last_date do
  if first_date == last_date, do: format_date_plain(first_date),
  else: "#{format_date_plain(first_date)} - #{format_date_plain(last_date)}"
else
  ""
end}
Total Charge: $#{format_number(claim_data["totalCharge"])}
Status: #{status}


#{build_all_sections_csv(claim.raw_json)}

Generated: #{DateTime.utc_now() |> DateTime.to_string()}
"""

    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header("content-disposition", ~s(attachment; filename="claim_#{id}.csv"))
    |> send_resp(200, csv_content)
  end

  # Render every section as a labelled block for the CSV
  defp build_all_sections_csv(sections) do
    sections
    |> Enum.map(fn section ->
      section_name =
        (section["section"] || "") |> String.replace("_", " ") |> String.upcase()

      data = section["data"] || %{}

      "#{section_name}\n#{String.duplicate("-", String.length(section_name))}\n#{render_section_csv(data)}\n"
    end)
    |> Enum.join("\n")
  end

  defp render_section_csv(data) when is_map(data) and data != %{} do
    data
    |> Map.to_list()
    |> Enum.reject(fn {k, _} -> k in ["indicators"] end)
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map(fn {k, v} -> "#{format_label_nice(k)}: #{format_value_plain(v)}" end)
    |> Enum.join("\n")
  end

  defp render_section_csv(data) when is_list(data) and data != [] do
    data
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {row, idx} ->
      ["Line #{idx}:"] ++
        (row
         |> Enum.reject(fn {k, _} -> k == "lineNumber" end)
         |> Enum.map(fn {k, v} ->
           value =
             case v do
               nil -> ""
               vv when is_binary(vv) and k == "serviceDate" -> format_date_plain(vv)
               vv when is_number(vv) -> to_string(vv)
               vv -> to_string(vv)
             end

           "  #{format_label_nice(k)}: #{value}"
         end)) ++ [""]
    end)
    |> Enum.join("\n")
  end

  defp render_section_csv(_), do: ""


  # =========================================================================
  # FORMAT HELPERS  (shared by CSV and PDF export)
  # =========================================================================

  defp format_label_nice(key) when is_binary(key) do
    key |> String.replace("_", " ") |> String.split() |> Enum.map(&String.capitalize/1) |> Enum.join(" ")
  end
  defp format_label_nice(key), do: to_string(key)

  defp format_value_plain(value) when is_map(value) do
    value |> Enum.map(fn {k, v} -> "  #{k}: #{v}" end) |> Enum.join("\n")
  end
  defp format_value_plain(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> format_date_plain(date)
      _           -> value
    end
  end
  defp format_value_plain(value), do: to_string(value)

  # Date formatted without comma (for plain-text fields)
  defp format_date_plain(nil), do: ""
  defp format_date_plain(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, d} -> format_date_plain(d)
      _        -> date
    end
  end
  defp format_date_plain(%Date{} = date), do: Calendar.strftime(date, "%B %d %Y")

  defp format_number(nil), do: "0.00"
  defp format_number(num) when is_number(num),
    do: :erlang.float_to_binary(num * 1.0, decimals: 2)
  defp format_number(num), do: to_string(num)


  # =========================================================================
  # QUERY HELPERS
  # ─────────────────────────────────────────────────────────────────────────
  # Each helper adds a WHERE clause to the running Ecto query only when the
  # supplied value is non-empty.  This lets us build the search query
  # incrementally without complex branching.
  # =========================================================================

  # Minimum length before we bother querying (avoids trivially broad searches)
  defp valid_search?(value), do: String.length(value) >= 2

  # ILIKE = case-insensitive "contains" search  (PostgreSQL specific)
  defp maybe_like(query, _field, ""), do: query
  defp maybe_like(query, field, value) do
    where(query, [c], ilike(field(c, ^field), ^"%#{value}%"))
  end

  # Exact match (used for NPI – a 10-digit identifier)
  defp maybe_exact(query, _field, ""), do: query
  defp maybe_exact(query, field, value) do
    where(query, [c], field(c, ^field) == ^value)
  end

  # Name search: if both first and last are present, require both;
  # otherwise require whichever is set.
  defp maybe_full_name(query, first, last) do
    cond do
      first != "" and last != "" ->
        where(query, [c],
          ilike(c.patient_first_name, ^"%#{first}%") and
            ilike(c.patient_last_name, ^"%#{last}%")
        )

      first != "" ->
        where(query, [c], ilike(c.patient_first_name, ^"%#{first}%"))

      last != "" ->
        where(query, [c], ilike(c.patient_last_name, ^"%#{last}%"))

      true ->
        query
    end
  end

  # Date range filtering against the date_of_service column
  defp maybe_date_range(query, "", ""), do: query

  defp maybe_date_range(query, from, "") do
    case Date.from_iso8601(from) do
      {:ok, from_date} -> where(query, [c], c.date_of_service >= ^from_date)
      _                -> query
    end
  end

  defp maybe_date_range(query, "", to) do
    case Date.from_iso8601(to) do
      {:ok, to_date} -> where(query, [c], c.date_of_service <= ^to_date)
      _              -> query
    end
  end

  defp maybe_date_range(query, from, to) do
    case {Date.from_iso8601(from), Date.from_iso8601(to)} do
      {{:ok, from_date}, {:ok, to_date}} ->
        where(query, [c],
          not is_nil(c.date_of_service) and
            c.date_of_service >= ^from_date and
            c.date_of_service <= ^to_date
        )

      _ ->
        query
    end
  end


  # =========================================================================
  # PDF RENDERING HELPERS
  # Converts the raw_json section array into HTML strings for wkhtmltopdf.
  # =========================================================================

  defp render_claim_summary(sections) do
    subscriber  = Enum.find(sections, fn s -> s["section"] == "subscriber" end) || %{}
    sub_data    = subscriber["data"] || %{}
    payer       = Enum.find(sections, fn s -> s["section"] == "payer" end) || %{}
    payer_data  = payer["data"] || %{}
    claim       = Enum.find(sections, fn s -> s["section"] == "claim" end) || %{}
    claim_data  = claim["data"] || %{}

    """
    <div class="summary">
      <h2 style="margin-top:0;">CLAIM SUMMARY</h2>
      <div class="field"><strong>Patient:</strong> #{sub_data["firstName"]} #{sub_data["lastName"]}</div>
      <div class="field"><strong>Payer:</strong> #{payer_data["name"]}</div>
      <div class="field"><strong>Claim #:</strong> #{claim_data["clearinghouseClaimNumber"]}</div>
      <div class="field"><strong>Total Charge:</strong> $#{claim_data["totalCharge"]}</div>
    </div>
    """
  end

  defp render_claim_sections(sections) do
    sections
    |> Enum.map(fn section ->
      section_name =
        (section["section"] || "") |> String.replace("_", " ") |> String.upcase()

      "<h2>#{section_name}</h2>\n#{render_section_data(section["data"] || %{})}"
    end)
    |> Enum.join("\n")
  end

  defp render_section_data(data) when is_map(data) and data != %{} do
    data
    |> Enum.reject(fn {k, _} -> k in ["indicators"] end)
    |> Enum.map(fn {k, v} ->
      value =
        if is_map(v),
          do: v |> Enum.map(fn {kk, vv} -> "#{kk}: #{vv}" end) |> Enum.join(", "),
          else: v

      ~s(<div class="field"><strong>#{format_label(k)}:</strong> #{value}</div>)
    end)
    |> Enum.join("\n")
  end

  defp render_section_data(data) when is_list(data) and data != [] do
    keys = Map.keys(List.first(data))

    """
    <table>
      <thead>
        <tr>#{keys |> Enum.map(&"<th>#{format_label(&1)}</th>") |> Enum.join("")}</tr>
      </thead>
      <tbody>
        #{data |> Enum.map(fn row ->
          "<tr>#{keys |> Enum.map(&"<td>#{row[&1]}</td>") |> Enum.join("")}</tr>"
        end) |> Enum.join("\n")}
      </tbody>
    </table>
    """
  end

  defp render_section_data(_), do: ""

  defp format_label(key) when is_binary(key) do
    key |> String.replace("_", " ") |> String.capitalize()
  end
  defp format_label(key), do: to_string(key)
end
