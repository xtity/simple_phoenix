defmodule Phoenix.Router.ConsoleFormatterTest do
  use ExUnit.Case, async: true
  alias Phoenix.Router.ConsoleFormatter

  defmodule RouterTestSingleRoutes do
    use Phoenix.Router

    socket "/ws" do
    end

    get "/", Phoenix.PageController, :index, as: :page
    post "/images", Phoenix.ImageController, :upload, as: :upload_image
    delete "/images", Phoenix.ImageController, :delete, as: :remove_image
  end

  test "format multiple routes" do
    assert draw(RouterTestSingleRoutes) == """
      web_socket_path  GET      /ws       Phoenix.Transports.WebSocket.upgrade/2
      web_socket_path  POST     /ws       Phoenix.Transports.WebSocket.upgrade/2
     long_poller_path  OPTIONS  /ws/poll  Phoenix.Transports.LongPoller.options/2
     long_poller_path  GET      /ws/poll  Phoenix.Transports.LongPoller.poll/2
     long_poller_path  POST     /ws/poll  Phoenix.Transports.LongPoller.publish/2
            page_path  GET      /         Phoenix.PageController.index/2
    upload_image_path  POST     /images   Phoenix.ImageController.upload/2
    remove_image_path  DELETE   /images   Phoenix.ImageController.delete/2
    """
  end

  defmodule RouterTestResources do
    use Phoenix.Router
    resources "/images", Phoenix.ImageController
  end

  test "format resource routes" do
    assert draw(RouterTestResources) == """
    image_path  GET     /images           Phoenix.ImageController.index/2
    image_path  GET     /images/:id/edit  Phoenix.ImageController.edit/2
    image_path  GET     /images/new       Phoenix.ImageController.new/2
    image_path  GET     /images/:id       Phoenix.ImageController.show/2
    image_path  POST    /images           Phoenix.ImageController.create/2
    image_path  PATCH   /images/:id       Phoenix.ImageController.update/2
                PUT     /images/:id       Phoenix.ImageController.update/2
    image_path  DELETE  /images/:id       Phoenix.ImageController.delete/2
    """
  end

  defp draw(router) do
    ConsoleFormatter.format(router)
  end
end
