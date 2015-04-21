Code.require_file "websocket_client.exs", __DIR__
Code.require_file "http_client.exs", __DIR__

defmodule Phoenix.Integration.ChannelTest do
  use ExUnit.Case, async: false
  use RouterHelper

  alias Phoenix.Integration.WebsocketClient
  alias Phoenix.Integration.HTTPClient
  alias Phoenix.Socket.Message
  alias __MODULE__.Endpoint

  @port 5807
  @window_ms 200
  @pubsub_window_ms 1000
  @ensure_window_timeout_ms trunc(@window_ms * 2.5)

  Application.put_env(:channel_app, Endpoint, [
    https: false,
    http: [port: @port],
    secret_key_base: String.duplicate("abcdefgh", 8),
    debug_errors: false,
    transports: [
      longpoller_window_ms: @window_ms,
      longpoller_pubsub_timeout_ms: @pubsub_window_ms,
      origins: ["//example.com"]],
    server: true,
    pubsub: [adapter: Phoenix.PubSub.PG2, name: :int_pub]
  ])

  defmodule RoomChannel do
    use Phoenix.Channel

    def join(_topic, message, socket) do
      Process.flag(:trap_exit, true)
      send(self, {:after_join, message})
      {:ok, socket}
    end

    def handle_info({:after_join, message}, socket) do
      broadcast socket, "user:entered", %{user: message["user"]}
      push socket, "joined", %{status: "connected"}
      {:noreply, socket}
    end

    def handle_in("new:msg", message, socket) do
      broadcast! socket, "new:msg", message
      {:noreply, socket}
    end

    def handle_in("boom", _message, _socket) do
      raise "boom"
    end

    def terminate(_reason, socket) do
      push socket, "you:left", %{message: "bye!"}
      :ok
    end
  end

  defmodule Router do
    use Phoenix.Router

    def call(conn, opts) do
      Logger.disable(self)
      super(conn, opts)
    end

    socket "/ws" do
      channel "rooms:*", RoomChannel
    end
  end

  defmodule Endpoint do
    use Phoenix.Endpoint, otp_app: :channel_app

    plug Plug.Parsers,
      parsers: [:urlencoded, :json],
      pass: "*/*",
      json_decoder: Poison

    plug Plug.Session,
      store: :cookie,
      key: "_integration_test",
      encryption_salt: "yadayada",
      signing_salt: "yadayada"

    plug Router
  end

  setup_all do
    capture_log fn -> Endpoint.start_link end
    :ok
  end

  ## Websocket Transport

  test "adapter handles websocket join, leave, and event messages" do
    {:ok, sock} = WebsocketClient.start_link(self, "ws://127.0.0.1:#{@port}/ws")

    WebsocketClient.join(sock, "rooms:lobby", %{})
    assert_receive %Message{event: "phx_reply", payload: %{"ref" => "1", "response" => %{}, "status" => "ok"}, ref: nil, topic: "rooms:lobby"}

    assert_receive %Message{event: "joined", payload: %{"status" => "connected"}}
    assert_receive %Message{event: "user:entered", payload: %{"user" => nil}, ref: nil, topic: "rooms:lobby"}

    WebsocketClient.send_event(sock, "rooms:lobby", "new:msg", %{body: "hi!"})
    assert_receive %Message{event: "new:msg", payload: %{"body" => "hi!"}}

    WebsocketClient.leave(sock, "rooms:lobby", %{})
    assert_receive %Message{event: "you:left", payload: %{"message" => "bye!"}}
    assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}
    assert_receive %Message{event: "phx_close", payload: %{}}

    WebsocketClient.send_event(sock, "rooms:lobby", "new:msg", %{body: "Should ignore"})
    refute_receive %Message{}
  end

  test "websocket adapter sends phx_error if a channel server abnormally exits" do
    {:ok, sock} = WebsocketClient.start_link(self, "ws://127.0.0.1:#{@port}/ws")

    WebsocketClient.join(sock, "rooms:lobby", %{})
    assert_receive %Message{event: "phx_reply", payload: %{"ref" => "1", "response" => %{}, "status" => "ok"}}
    assert_receive %Message{event: "joined"}
    assert_receive %Message{event: "user:entered"}

    WebsocketClient.send_event(sock, "rooms:lobby", "boom", %{})
    assert_receive %Message{event: "phx_error", payload: %{}, topic: "rooms:lobby"}
  end

  test "adapter handles refuses websocket events that haven't joined" do
    {:ok, sock} = WebsocketClient.start_link(self, "ws://127.0.0.1:#{@port}/ws")

    WebsocketClient.send_event(sock, "rooms:lobby", "new:msg", %{body: "hi!"})
    refute_receive {:socket_push, %Message{}}
  end

  test "websocket refuses unallowed origins" do
    assert {:ok, _} = WebsocketClient.start_link(self, "ws://127.0.0.1:#{@port}/ws",
                                                 [{"origin", "https://example.com"}])
    refute {:ok, _} = WebsocketClient.start_link(self, "ws://127.0.0.1:#{@port}/ws",
                                                 [{"origin", "http://notallowed.com"}])
  end

  ## Longpoller Transport

  @doc """
  Helper method to maintain token session state when making HTTP requests.

  Returns a response with body decoded into JSON map.
  """
  def poll(method, path, params, json \\ nil) do
    headers = %{"content-type" => "application/json"}
    body = Poison.encode!(json)
    url = "http://127.0.0.1:#{@port}#{path}?" <> URI.encode_query(params)

    {:ok, resp} = HTTPClient.request(method, url, headers, body)

    if resp.body != "" do
      put_in resp.body, Poison.decode!(resp.body)
    else
      resp
    end
  end

  test "adapter handles longpolling join, leave, and event messages" do
    # create session
    resp = poll :get, "/ws/poll", %{}, %{}
    session = Map.take(resp.body, ["token", "sig"])
    assert resp.body["token"]
    assert resp.body["sig"]
    assert resp.body["status"] == 410
    assert resp.status == 200

    # join
    resp = poll :post, "/ws/poll", session, %{
      "topic" => "rooms:lobby",
      "event" => "phx_join",
      "ref" => "123",
      "payload" => %{}
    }
    assert resp.body["status"] == 200

    # poll with messsages sends buffer
    resp = poll(:get, "/ws/poll", session)
    session = Map.take(resp.body, ["token", "sig"])
    assert resp.body["status"] == 200
    [phx_reply, status_msg, user_entered] = resp.body["messages"]
    assert phx_reply == %{"event" => "phx_reply", "payload" => %{"ref" => "123", "response" => %{}, "status" => "ok"}, "ref" => nil, "topic" => "rooms:lobby"}
    assert status_msg == %{"event" => "joined", "payload" => %{"status" => "connected"}, "ref" => nil, "topic" => "rooms:lobby"}
    assert user_entered == %{"event" => "user:entered", "payload" => %{"user" => nil}, "ref" => nil, "topic" => "rooms:lobby"}


    # poll without messages sends 204 no_content
    resp = poll(:get, "/ws/poll", session)
    session = Map.take(resp.body, ["token", "sig"])
    assert resp.body["status"] == 204

    # messages are buffered between polls
    Endpoint.broadcast! "rooms:lobby", "user:entered", %{name: "José"}
    Endpoint.broadcast! "rooms:lobby", "user:entered", %{name: "Sonny"}
    resp = poll(:get, "/ws/poll", session)
    session = Map.take(resp.body, ["token", "sig"])
    assert resp.body["status"] == 200
    assert Enum.count(resp.body["messages"]) == 2
    assert Enum.map(resp.body["messages"], &(&1["payload"]["name"])) == ["José", "Sonny"]

    # poll without messages sends 204 no_content
    resp = poll(:get, "/ws/poll", session)
    session = Map.take(resp.body, ["token", "sig"])
    assert resp.body["status"] == 204

    resp = poll(:get, "/ws/poll", session)
    session = Map.take(resp.body, ["token", "sig"])
    assert resp.body["status"] == 204

    # generic events
    Phoenix.PubSub.subscribe(:int_pub, self, "rooms:lobby")
    resp = poll :post, "/ws/poll", Map.take(resp.body, ["token", "sig"]), %{
      "topic" => "rooms:lobby",
      "event" => "new:msg",
      "ref" => "123",
      "payload" => %{"body" => "hi!"}
    }
    assert resp.body["status"] == 200
    assert_receive {:socket_broadcast, %Message{event: "new:msg", payload: %{"body" => "hi!"}}}
    resp = poll(:get, "/ws/poll", session)
    session = Map.take(resp.body, ["token", "sig"])
    assert resp.body["status"] == 200

    # unauthorized events
    capture_log fn ->
      Phoenix.PubSub.subscribe(:int_pub, self, "rooms:private-room")
      resp = poll :post, "/ws/poll", session, %{
        "topic" => "rooms:private-room",
        "event" => "new:msg",
        "ref" => "123",
        "payload" => %{"body" => "this method shouldn't send!'"}
      }
      assert resp.body["status"] == 401
      refute_receive {:socket_broadcast, %Message{event: "new:msg"}}


      ## multiplexed sockets

      # join
      resp = poll :post, "/ws/poll", session, %{
        "topic" => "rooms:room123",
        "event" => "phx_join",
        "ref" => "123",
        "payload" => %{}
      }
      assert resp.body["status"] == 200
      Endpoint.broadcast! "rooms:lobby", "new:msg", %{body: "Hello lobby"}
      # poll
      resp = poll(:get, "/ws/poll", session)
      session = Map.take(resp.body, ["token", "sig"])
      assert resp.body["status"] == 200
      assert Enum.count(resp.body["messages"]) == 4
      assert Enum.at(resp.body["messages"], 0)["event"] == "phx_reply"
      assert Enum.at(resp.body["messages"], 1)["payload"]["status"] == "connected"
      assert Enum.at(resp.body["messages"], 2)["event"] == "user:entered"
      assert Enum.at(resp.body["messages"], 3)["payload"]["body"] == "Hello lobby"


      ## Server termination handling

      # 410 from crashed/terminated longpoller server when polling
      :timer.sleep @ensure_window_timeout_ms
      resp = poll(:get, "/ws/poll", session)
      session = Map.take(resp.body, ["token", "sig"])
      assert resp.body["status"] == 410

      # join
      resp = poll :post, "/ws/poll", session, %{
        "topic" => "rooms:lobby",
        "event" => "phx_join",
        "ref" => "123",
        "payload" => %{}
      }
      assert resp.body["status"] == 200
      Phoenix.PubSub.subscribe(:int_pub, self, "rooms:lobby")
      :timer.sleep @ensure_window_timeout_ms
      resp = poll :post, "/ws/poll", session, %{
        "topic" => "rooms:lobby",
        "event" => "new:msg",
        "ref" => "123",
        "payload" => %{"body" => "hi!"}
      }
      assert resp.body["status"] == 410
      refute_receive {:socket_push, %Message{event: "new:msg", payload: %{"body" => "hi!"}}}

      # 410 from crashed/terminated longpoller server when publishing
      # create new session
      resp = poll :post, "/ws/poll", %{"token" => "foo", "sig" => "bar"}, %{}
      assert resp.body["status"] == 410
    end
  end

  test "longpoller refuses unallowed origins" do
    conn = conn(:get, "/ws/poll")
           |> put_req_header("origin", "https://example.com")
           |> Endpoint.call([])
    assert Poison.decode!(conn.resp_body)["status"] == 410

    conn = conn(:get, "/ws/poll")
           |> put_req_header("origin", "http://notallowed.com")
           |> Endpoint.call([])
    assert Poison.decode!(conn.resp_body)["status"] == 403
  end

  test "longpoller adapter sends phx_error if a channel server abnormally exits" do
    # create session
    resp = poll :get, "/ws/poll", %{}, %{}
    session = Map.take(resp.body, ["token", "sig"])
    assert resp.body["status"] == 410
    assert resp.status == 200
    # join
    resp = poll :post, "/ws/poll", session, %{
      "topic" => "rooms:lobby",
      "event" => "phx_join",
      "ref" => "123",
      "payload" => %{}
    }
    assert resp.body["status"] == 200
    assert resp.status == 200
    # poll
    resp = poll :post, "/ws/poll", session, %{
      "topic" => "rooms:lobby",
      "event" => "boom",
      "ref" => "123",
      "payload" => %{}
    }
    assert resp.body["status"] == 200
    assert resp.status == 200

    resp = poll(:get, "/ws/poll", session)

    [_phx_reply, _joined, _user_entered, _you_left_msg, chan_error] = resp.body["messages"]

    assert chan_error ==
      %{"event" => "phx_error", "payload" => %{}, "topic" => "rooms:lobby", "ref" => nil}
  end

  test "longpoller adapter sends phx_close if a channel server normally exits" do
    # create session
    resp = poll :get, "/ws/poll", %{}, %{}
    session = Map.take(resp.body, ["token", "sig"])
    assert resp.body["status"] == 410
    assert resp.status == 200
    # join
    resp = poll :post, "/ws/poll", session, %{
      "topic" => "rooms:lobby",
      "event" => "phx_join",
      "ref" => "1",
      "payload" => %{}
    }
    assert resp.body["status"] == 200
    assert resp.status == 200

    # poll
    resp = poll :post, "/ws/poll", session, %{
      "topic" => "rooms:lobby",
      "event" => "phx_leave",
      "ref" => "2",
      "payload" => %{}
    }
    assert resp.body["status"] == 200
    assert resp.status == 200

    # leave
    resp = poll(:get, "/ws/poll", session)
    assert resp.body["messages"] == [
      %{"event" => "phx_reply", "payload" => %{"ref" => "1", "response" => %{}, "status" => "ok"}, "ref" => nil, "topic" => "rooms:lobby"},
      %{"event" => "joined", "payload" => %{"status" => "connected"}, "ref" => nil, "topic" => "rooms:lobby"},
      %{"event" => "user:entered", "payload" => %{"user" => nil}, "ref" => nil, "topic" => "rooms:lobby"},
      %{"event" => "phx_reply", "payload" => %{"ref" => "2", "response" => %{}, "status" => "ok"}, "ref" => nil, "topic" => "rooms:lobby"},
      %{"event" => "you:left", "payload" => %{"message" => "bye!"}, "ref" => nil, "topic" => "rooms:lobby"},
      %{"event" => "phx_close", "payload" => %{}, "ref" => nil, "topic" => "rooms:lobby"}
    ]
  end
end
