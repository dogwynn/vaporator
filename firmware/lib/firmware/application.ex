defmodule Firmware.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    dhcp_options = [
      gateway: "192.168.254.0",
      netmask: "255.255.255.0",
      range: {"192.168.254.1", "192.168.254.10"},
      domain_servers: ["192.168.254.1"]
    ]

    opts = [strategy: :one_for_one, name: Firmware.Supervisor]
    children =
      [
        NervesHub.Supervisor,
        {DHCPServer, ["eth0", dhcp_options]}
      ]

    Supervisor.start_link(children, opts)
  end

  def target() do
    Application.get_env(:firmware, :target)
  end
end