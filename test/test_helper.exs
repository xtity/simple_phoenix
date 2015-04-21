Code.require_file("router_helper.exs", __DIR__)

# Starts web server applications
Application.ensure_all_started(:cowboy)

# Used whenever a router fails. We default to simply
# rendering a short string.
defmodule Phoenix.ErrorView do
  def render(template, _assigns) do
    "#{template} from Phoenix.ErrorView"
  end
end

# Start transport levels
{:ok, _pid} = Phoenix.PubSub.PG2.start_link(:phx_pub, [])
Process.flag(:trap_exit, true)

options = case :redo.start_link(:undefined) do
  {:ok, _} -> []
         _ -> [exclude: [:redis]]
end

Process.flag(:trap_exit, false)
ExUnit.start(options)
