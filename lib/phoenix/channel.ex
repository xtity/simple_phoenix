defmodule Phoenix.Channel do

  @moduledoc """
  Defines a Phoenix Channel.

  Channels provide a means for bidirectional communication from clients that
  integrate with the `Phoenix.PubSub` layer for soft-realtime functionality.

  ## Topics & Callbacks
  When clients join a channel, they do so by subscribing to a topic.
  Topics are string identifiers in the `Phoenix.PubSub` layer that allow
  multiple processes to subscribe and broadcast messages about a given topic.
  Everytime you join a Channel, you need to choose which particular topic you
  want to listen to. The topic is just an identifier, but by convention it is
  often made of two parts: `"topic:subtopic"`. Using the `"topic:subtopic"`
  approach pairs nicely with the `Phoenix.Router.channel/3` macro to match
  topic patterns in your router to your channel handlers:

      socket "/ws", MyApp do
        channel "rooms:*", RoomChannel
      end

  Any topic coming into the router with the `"rooms:"` prefix, would dispatch
  to `MyApp.RoomChannel` in the above example. Topics can also be pattern
  matched in your channels' `join/3` callback to pluck out the scoped pattern:

      # handles the special `"lobby"` subtopic
      def join("rooms:lobby", _auth_message, socket) do
        {:ok, socket}
      end

      # handles any other subtopic as the room ID, ie `"rooms:12"`, `"rooms:34"`
      def join("rooms:" <> room_id, auth_message, socket) do
        {:ok, socket}
      end

  ### Authorization
  Clients must join a channel to send and receive PubSub events on that channel.
  Your channels must implement a `join/3` callback that authorizes the socket
  for the given topic. It is common for clients to send up authorization data,
  such as HMAC'd tokens for this purpose.

  To authorize a socket in `join/3`, return `{:ok, socket}`.
  To refuse authorization in `join/3, return `:ignore`.


  ### Incoming Events
  After a client has successfully joined a channel, incoming events from the
  client are routed through the channel's `handle_in/3` callbacks. Within these
  callbacks, you can perform any action. Typically you'll either forward a
  message to all listeners with `Phoenix.Channel.broadcast!/3`, or push a message
  directly down the socket with `Phoenix.Channel.push/3`.
  Incoming callbacks must return the `socket` to maintain ephemeral state.

  Here's an example of receiving an incoming `"new_msg"` event from one client,
  and broadcasting the message to all topic subscribers for this socket.

      def handle_in("new_msg", %{"uid" => uid, "body" => body}, socket) do
        broadcast! socket, "new_msg", %{uid: uid, body: body}
        {:noreply, socket}
      end

  You can also push a message directly down the socket:

      # client asks for their current rank, push sent directly as a new event.
      def handle_in("current:rank", socket) do
        push socket, "current:rank", %{val: Game.get_rank(socket.assigns[:user])}
        {:noreply, socket}
      end


  ### Synchronous Replies
  In addition to pushing messages out when you receive a `handle_in` event,
  you can also reply directly to a client event for request/response style
  messaging. This is useful when a client must know the result of an operation
  or to simply ack messages.

  For example, imagine creating a resource and replying with the created record:

      def handle_in("create:post", attrs, socket) do
        changeset = Post.changeset(%Post{}, attrs)

        if changeset.valid? do
          Repo.insert(changeset)
          {:reply, {:ok, changeset}, socket}
        else
          {:reply, {:error, changeset.errors}, socket}
        end
      end

  Alternatively, you may just want to ack the status of the operation:

      def handle_in("create:post", attrs, socket) do
        changeset = Post.changeset(%Post{}, attrs)

        if changeset.valid? do
          Repo.insert(changeset)
          {:reply, :ok, socket}
        else
          {:reply, :error, socket}
        end
      end


  ### Outgoing Events

  When an event is broadcasted with `Phoenix.Channel.broadcast/3`, each channel
  subscriber's `handle_out/3` callback is triggered where the event can be
  relayed as is, or customized on a socket by socket basis to append extra
  information, or conditionally filter the message from being delivered.

      def handle_in("new_msg", %{"uid" => uid, "body" => body}, socket) do
        broadcast! socket, "new_msg", %{uid: uid, body: body}
        {:noreply, socket}
      end

      # for every socket subscribing to this topic, append an `is_editable`
      # value for client metadata.
      def handle_out("new_msg", msg, socket) do
        push socket, "new_msg", Dict.merge(msg,
          is_editable: User.can_edit_message?(socket.assigns[:user], msg)
        )
        {:noreply, socket}
      end

      # do not send broadcasted `"user:joined"` events if this socket's user
      # is ignoring the user who joined.
      def handle_out("user:joined", msg, socket) do
        unless User.ignoring?(socket.assigns[:user], msg.user_id) do
          push socket, "user:joined", msg
        end
        {:noreply, socket}
      end

   By default, unhandled outgoing events are forwarded to each client as a push,
   but you'll need to define the catch-all clause yourself once you define an
   `handle_out/3` clause.


  ## Broadcasting to an external topic
  In some cases, you will want to broadcast messages without the context of a `socket`.
  This could be for broadcasting from within your channel to an external topic, or
  broadcasting from elsewhere in your application like a Controller or GenServer.
  For these cases, you can broadcast from your Endpoint. Its configured PubSub
  server will be used:

      # within channel
      def handle_in("new_msg", %{"uid" => uid, "body" => body}, socket) do
        broadcast! socket, "new_msg", %{uid: uid, body: body}
        MyApp.Endpoint.broadcast! "rooms:superadmin", "new_msg", %{uid: uid, body: body}
        {:noreply, socket}
      end

      # within controller
      def create(conn, params) do
        ...
        MyApp.Endpoint.broadcast! "rooms:" <> rid, "new_msg", %{uid: uid, body: body}
        MyApp.Endpoint.broadcast! "rooms:superadmin", "new_msg", %{uid: uid, body: body}
        redirect conn, to: "/"
      end

  """

  use Behaviour
  alias Phoenix.PubSub
  alias Phoenix.Socket
  alias Phoenix.Socket.Message

  defcallback join(topic :: binary, auth_msg :: map, Socket.t) :: {:ok, Socket.t} |
                                                                  :ignore

  defcallback terminate(msg :: map, Socket.t) :: :ok | {:error, reason :: term}

  defcallback handle_in(event :: String.t, msg :: map, Socket.t) :: {:noreply, Socket.t} |
                                                                    {:reply, {status :: atom, response :: map}, Socket.t} |
                                                                    {:reply, status :: atom, Socket.t} |
                                                                    {:stop, reason :: term, Socket.t} |
                                                                    {:stop, reason :: term, reply :: {status :: atom, response :: map}, Socket.t} |
                                                                    {:stop, reason :: term, reply :: status :: atom, Socket.t}

  defcallback handle_out(event :: String.t, msg :: map, Socket.t) :: {:noreply, Socket.t} |
                                                                     {:error, reason :: term, Socket.t} |
                                                                     {:stop, reason :: term, Socket.t}

  defcallback handle_info(msg :: map, Socket.t) :: {:noreply, Socket.t} |
                                                   {:error, reason :: term, Socket.t} |
                                                   {:stop, reason :: term, Socket.t}

  defmacro __using__(_) do
    quote do
      @behaviour unquote(__MODULE__)

      import unquote(__MODULE__)
      import Phoenix.Socket

      def terminate(_reason, _socket), do: :ok

      def handle_in(_event, _message, socket), do: {:noreply, socket}

      def handle_out(event, message, socket) do
        push(socket, event, message)
        {:noreply, socket}
      end

      def handle_info(_message, socket), do: {:noreply, socket}

      defoverridable handle_info: 2, handle_out: 3, handle_in: 3, terminate: 2
    end
  end

  @doc """
  Broadcast event, serializable as JSON to a channel.

  ## Examples

      iex> Channel.broadcast "rooms:global", "new_message", %{id: 1, content: "hello"}
      :ok
      iex> Channel.broadcast socket, "new_message", %{id: 1, content: "hello"}
      :ok

  """
  def broadcast(%Socket{joined: true} = socket, event, msg) do
    broadcast(socket.pubsub_server, socket, event, msg)
  end
  def broadcast(%Socket{joined: _}, _event, _msg) do
    raise_not_joined()
  end
  def broadcast(server, topic, event, message) when is_binary(topic) do
    broadcast_from server, :none, topic, event, message
  end
  def broadcast(server, %Socket{} = socket, event, message) do
    broadcast_from server, :none, socket.topic, event, message
    :ok
  end

  @doc """
  Same as `Phoenix.Channel.broadcast/4`, but
  raises `Phoenix.PubSub.BroadcastError` if broadcast fails.
  """
  def broadcast!(%Socket{joined: true} = socket, event, msg) do
    broadcast!(socket.pubsub_server, socket, event, msg)
  end
  def broadcast!(%Socket{joined: _}, _event, _msg) do
    raise_not_joined()
  end
  def broadcast!(server, topic, event, message) when is_binary(topic) do
    broadcast_from! server, :none, topic, event, message
  end
  def broadcast!(server, socket = %Socket{}, event, message) do
    broadcast_from! server, :none, socket.topic, event, message
    :ok
  end

  @doc """
  Broadcast event from pid, serializable as JSON to channel.
  The broadcasting socket `from`, does not receive the published message.
  The event's message must be a map serializable as JSON.

  ## Examples

      iex> Channel.broadcast_from self, "rooms:global", "new_message", %{id: 1, content: "hello"}
      :ok

  """
  def broadcast_from(%Socket{} = socket, event, msg) do
    broadcast_from(socket.pubsub_server, socket, event, msg)
  end
  def broadcast_from(pubsub_server, %Socket{joined: true} = socket, event, message) do
    broadcast_from(pubsub_server, self, socket.topic, event, message)
    :ok
  end
  def broadcast_from(_pubsub_server, %Socket{joined: _}, _event, _message) do
    raise_not_joined()
  end
  def broadcast_from(pubsub_server, from, topic, event, message) when is_map(message) do
    PubSub.broadcast_from pubsub_server, from, topic, {:socket_broadcast, %Message{
      topic: topic,
      event: event,
      payload: message
    }}
  end
  def broadcast_from(_, _, _, _, _), do: raise_invalid_message

  @doc """
  Same as `Phoenix.Channel.broadcast_from/4`, but
  raises `Phoenix.PubSub.BroadcastError` if broadcast fails.
  """
  def broadcast_from!(%Socket{} = socket, event, msg) do
    broadcast_from!(socket.pubsub_server, socket, event, msg)
  end
  def broadcast_from!(pubsub_server, %Socket{joined: true} = socket, event, message) do
    broadcast_from!(pubsub_server, self, socket.topic, event, message)
    :ok
  end
  def broadcast_from!(_pubsub_server, %Socket{joined: _}, _event, _message) do
    raise_not_joined()
  end
  def broadcast_from!(pubsub_server, from, topic, event, message) when is_map(message) do
    PubSub.broadcast_from! pubsub_server, from, topic, {:socket_broadcast, %Message{
      topic: topic,
      event: event,
      payload: message
    }}
  end
  def broadcast_from!(_, _, _, _, _), do: raise_invalid_message

  @doc """
  Sends Dict, JSON serializable message to socket.
  """
  def push(%Socket{joined: true} = socket, event, message) when is_map(message) do
    send socket.transport_pid, {:socket_push, %Message{
      topic: socket.topic,
      event: event,
      payload: message
    }}
    :ok
  end
  def push(_socket, _event, message) when is_map(message) do
    raise_not_joined()
  end
  def push(_, _, _), do: raise_invalid_message()

  defp raise_invalid_message, do: raise "Message argument must be a map"
  defp raise_not_joined do
    raise """
    `push` and `broadcast` can only be called after the socket has finished joining.
    To push a message on join, send to self and handle in handle_info/2, ie:

        def join(topic, auth_msg, socket) do
          ...
          send(self, :after_join)
          {:ok, socket}
        end

        def handle_info(:after_join, socket) do
          push socket, "feed", %{list: feed_items(socket)}
          {:noreply, socket}
        end

    """
  end
end
