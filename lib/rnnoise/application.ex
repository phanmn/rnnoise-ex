defmodule Rnnoise.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [Rnnoise.Model]
    Supervisor.start_link(children, strategy: :one_for_one, name: Rnnoise.Supervisor)
  end
end
