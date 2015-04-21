Code.require_file "http_client.exs", __DIR__

defmodule Phoenix.Integration.EndpointTest do
  # This test case needs to be sync because we rely on
  # log capture which is global.
  use ExUnit.Case
  import RouterHelper, only: [capture_log: 1]

  alias Phoenix.Integration.AdapterTest.ProdEndpoint
  alias Phoenix.Integration.AdapterTest.DevEndpoint

  Application.put_env(:endpoint_int, ProdEndpoint,
      http: [port: "4807"], url: [host: "example.com"], server: true)
  Application.put_env(:endpoint_int, DevEndpoint,
      http: [port: "4808"], debug_errors: true)

  defmodule Router do
    use Plug.Router

    plug :match
    plug :dispatch

    get "/" do
      send_resp conn, 200, "ok"
    end

    get "/router/oops" do
      _ = conn
      raise "oops"
    end

    match _ do
      raise Phoenix.Router.NoRouteError, conn: conn, router: __MODULE__
    end

    # A wrapper to around the endpoint call to extract information.
    defmacro __before_compile__(_) do
      quote do
        defoverridable [call: 2]

        def call(conn, opts) do
          # Assert we never have a lingering sent message in the inbox
          refute_received {:plug_conn, :sent}

          try do
            super(conn, opts)
          after
            # When we pipe downstream, downstream will always render,
            # either because the router is responding or because the
            # endpoint error layer is kicking in.
            assert_received {:plug_conn, :sent}
            send self(), {:plug_conn, :sent}
          end
        end
      end
    end
  end

  for mod <- [ProdEndpoint, DevEndpoint] do
    defmodule mod do
      use Phoenix.Endpoint, otp_app: :endpoint_int
      plug :router, Router
      @before_compile Router

      def call(conn, opts) do
        if conn.path_info == ~w(oops) do
          raise "oops"
        end
        super(conn, opts)
      end
    end
  end

  @prod 4807
  @dev  4808

  alias Phoenix.Integration.HTTPClient

  test "adapters starts on configured port and serves requests and stops for prod" do
    # Has server: true
    capture_log fn -> ProdEndpoint.start_link end

    # Requests
    {:ok, resp} = HTTPClient.request(:get, "http://127.0.0.1:#{@prod}", %{})
    assert resp.status == 200
    assert resp.body == "ok"

    {:ok, resp} = HTTPClient.request(:get, "http://127.0.0.1:#{@prod}/unknown", %{})
    assert resp.status == 404
    assert resp.body == "404.html from Phoenix.ErrorView"

    assert capture_log(fn ->
      {:ok, resp} = HTTPClient.request(:get, "http://127.0.0.1:#{@prod}/oops", %{})
      assert resp.status == 500
      assert resp.body == "500.html from Phoenix.ErrorView"
    end) =~ "** (RuntimeError) oops"

    assert capture_log(fn ->
      {:ok, resp} = HTTPClient.request(:get, "http://127.0.0.1:#{@prod}/router/oops", %{})
      assert resp.status == 500
      assert resp.body == "500.html from Phoenix.ErrorView"
    end) =~ "** (RuntimeError) oops"

    shutdown(ProdEndpoint)
    {:error, _reason} = HTTPClient.request(:get, "http://127.0.0.1:#{@prod}", %{})
  end

  test "adapters starts on configured port and serves requests and stops for dev" do
    # Has server: false
    DevEndpoint.start_link
    {:error, _reason} = HTTPClient.request(:get, "http://127.0.0.1:#{@dev}", %{})
    shutdown(DevEndpoint)

    # Toggle globally
    serve_endpoints(true)
    on_exit(fn -> serve_endpoints(false) end)
    capture_log fn -> DevEndpoint.start_link end

    # Requests
    {:ok, resp} = HTTPClient.request(:get, "http://127.0.0.1:#{@dev}", %{})
    assert resp.status == 200
    assert resp.body == "ok"

    {:ok, resp} = HTTPClient.request(:get, "http://127.0.0.1:#{@dev}/unknown", %{})
    assert resp.status == 404
    assert resp.body =~ "NoRouteError at GET /unknown"

    assert capture_log(fn ->
      {:ok, resp} = HTTPClient.request(:get, "http://127.0.0.1:#{@dev}/oops", %{})
      assert resp.status == 500
      assert resp.body =~ "RuntimeError at GET /oops"
    end) =~ "** (RuntimeError) oops"

    assert capture_log(fn ->
      {:ok, resp} = HTTPClient.request(:get, "http://127.0.0.1:#{@dev}/router/oops", %{})
      assert resp.status == 500
      assert resp.body =~ "RuntimeError at GET /router/oops"
    end) =~ "** (RuntimeError) oops"
  end

  defp serve_endpoints(bool) do
    Application.put_env(:phoenix, :serve_endpoints, bool)
  end

  defp shutdown(endpoint) do
    pid = Process.whereis(endpoint)
    Process.unlink(pid)
    Process.exit(pid, :shutdown)
    wait_until_dead(endpoint)
  end

  defp wait_until_dead(endpoint) do
    if Process.whereis(endpoint) do
      wait_until_dead(endpoint)
    end
  end
end
