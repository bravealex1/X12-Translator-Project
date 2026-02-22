defmodule ClaimViewer.Repo do
  use Ecto.Repo,
    otp_app: :claim_viewer,
    adapter: Ecto.Adapters.Postgres
end
