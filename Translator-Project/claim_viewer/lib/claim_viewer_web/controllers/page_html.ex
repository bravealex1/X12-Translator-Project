defmodule ClaimViewerWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use ClaimViewerWeb, :html

  embed_templates "page_html/*"

  def human_label(key) do
    %{
      "controlNumber" => "Control Number",
      "referenceId" => "Reference ID",
      "payerId" => "Payer ID",
      "totalCharge" => "Total Charge",
      "serviceDate" => "Service Date",
      "firstName" => "First Name",
      "lastName" => "Last Name",
      "groupNumber" => "Group Number",
      "planType" => "Plan Type",
      "taxId" => "Tax ID",
      "clearinghouseClaimNumber" => "Claim Number",
      "dob" => "Date of Birth",
      "npi" => "NPI",
      "onsetDate" => "Onset Date",
      "placeOfService" => "Place of Service",
      "serviceType" => "Service Type",
      "unitQualifier" => "Unit Qualifier",
      "lineNumber" => "Line #",
      "procedureCode" => "Procedure Code"
    }[key] ||
      key
      |> Macro.underscore()
      |> String.replace("_"," ")
      |> String.capitalize()
  end

  def format_date(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} ->
        month = case date.month do
          1 -> "January"
          2 -> "February"
          3 -> "March"
          4 -> "April"
          5 -> "May"
          6 -> "June"
          7 -> "July"
          8 -> "August"
          9 -> "September"
          10 -> "October"
          11 -> "November"
          12 -> "December"
        end
        "#{month} #{date.day}, #{date.year}"
      _ ->
        date_string
    end
  end

  def format_date(nil), do: ""
  def format_date(other), do: to_string(other)

  # Format phone number to US style: (555) 666-7770
  def format_phone(nil), do: ""
  def format_phone(""), do: ""
  def format_phone(phone) when is_binary(phone) do
    # Remove all non-digits
    digits = String.replace(phone, ~r/\D/, "")

    case String.length(digits) do
      10 ->
        # Format as (XXX) XXX-XXXX
        area = String.slice(digits, 0, 3)
        prefix = String.slice(digits, 3, 3)
        line = String.slice(digits, 6, 4)
        "(#{area}) #{prefix}-#{line}"

      11 ->
        # If it starts with 1, remove it and format
        if String.starts_with?(digits, "1") do
          format_phone(String.slice(digits, 1..-1//1))
        else
          phone
        end

      _ ->
        # Return as-is if not 10 or 11 digits
        phone
    end
  end
  def format_phone(phone), do: to_string(phone)
end
