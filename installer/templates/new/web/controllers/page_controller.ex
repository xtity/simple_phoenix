defmodule <%= application_module %>.PageController do
  use <%= application_module %>.Web, :controller

  plug :action

  def index(conn, _params) do
    render conn, "index.html"
  end
end
