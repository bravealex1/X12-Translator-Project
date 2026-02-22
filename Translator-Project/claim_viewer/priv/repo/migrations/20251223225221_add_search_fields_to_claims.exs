defmodule ClaimViewer.Repo.Migrations.AddSearchFieldsToClaims do
  use Ecto.Migration

  def change do
    alter table(:claims) do
      add :patient_first_name, :string
      add :patient_last_name, :string
      add :patient_dob, :date

      add :payer_name, :string

      add :billing_provider_name, :string
      add :billing_provider_npi, :string

      add :pay_to_provider_name, :string
      add :pay_to_provider_npi, :string

      add :rendering_provider_name, :string
      add :rendering_provider_npi, :string

      add :clearinghouse_claim_number, :string
    end

    create index(:claims, [:patient_last_name])
    create index(:claims, [:patient_first_name])
    create index(:claims, [:patient_dob])
    create index(:claims, [:payer_name])
    create index(:claims, [:billing_provider_name])
    create index(:claims, [:billing_provider_npi])
    create index(:claims, [:rendering_provider_npi])
  end
end
