defmodule Phoenix.HTML.Engine do
  @moduledoc """
  This is an implementation of EEx.Engine and
  Phoenix format encoder that guarantees templates are
  HTML Safe.
  """

  use EEx.Engine
  alias Phoenix.HTML

  @doc false
  def encode_to_iodata(body), do: {:ok, encode_to_iodata!(body)}

  @doc false
  def encode_to_iodata!({:safe, body}), do: body
  def encode_to_iodata!(other), do: HTML.Safe.to_iodata(other)

  @doc false
  def handle_body(body), do: body

  @doc false
  def handle_text(buffer, text) do
    quote do
      {:safe, [unquote(unwrap(buffer))|unquote(text)]}
    end
  end

  @doc false
  def handle_expr(buffer, "=", expr) do
    line   = line_from_expr(expr)
    expr   = expr(expr)
    buffer = unwrap(buffer)
    {:safe, quote do
      buff = unquote(buffer)
      [buff|unquote(to_safe(expr, line))]
     end}
  end

  @doc false
  def handle_expr(buffer, "", expr) do
    expr   = expr(expr)
    buffer = unwrap(buffer)

    quote do
      buff = unquote(buffer)
      unquote(expr)
      buff
    end
  end

  defp line_from_expr({_, meta, _}) when is_list(meta), do: Keyword.get(meta, :line)
  defp line_from_expr(_), do: nil

  # We can do the work at compile time
  defp to_safe(literal, _line) when is_binary(literal) or is_atom(literal) or is_number(literal) do
    HTML.Safe.to_iodata(literal)
  end

  # We can do the work at runtime
  defp to_safe(literal, line) when is_list(literal) do
    quote line: line, do: HTML.Safe.to_iodata(unquote(literal))
  end

  # We need to check at runtime and we do so by
  # optimizing common cases.
  defp to_safe(expr, line) do
    quote line: line do
      case unquote(expr) do
        {:safe, data} -> data
        bin when is_binary(bin) -> HTML.Safe.BitString.to_iodata(bin)
        other -> HTML.Safe.to_iodata(other)
      end
    end
  end

  defp expr(expr) do
    Macro.prewalk(expr, &EEx.Engine.handle_assign/1)
  end

  defp unwrap({:safe, value}), do: value
  defp unwrap(value), do: value
end
