defmodule ClaimViewer.Repo.Migrations.AddDateOfServiceToClaims do
  use Ecto.Migration

  def change do
    alter table(:claims) do
      add :date_of_service, :date
    end
  end
end
