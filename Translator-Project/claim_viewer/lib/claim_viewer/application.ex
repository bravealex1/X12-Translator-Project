defmodule ClaimViewer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ClaimViewerWeb.Telemetry,
      ClaimViewer.Repo,
      {DNSCluster, query: Application.get_env(:claim_viewer, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ClaimViewer.PubSub},
      # Start a worker by calling: ClaimViewer.Worker.start_link(arg)
      # {ClaimViewer.Worker, arg},
      # Start to serve requests, typically the last entry
      ClaimViewerWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ClaimViewer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ClaimViewerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
