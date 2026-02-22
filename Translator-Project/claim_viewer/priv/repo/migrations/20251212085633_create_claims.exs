defmodule ClaimViewer.Repo.Migrations.CreateClaimsTable do
  use Ecto.Migration

  def change do
    create table(:claims) do
      add :raw_json, :map

      timestamps()
    end
  end
end
