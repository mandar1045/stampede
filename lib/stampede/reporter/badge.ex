defmodule Stampede.Reporter.Badge do
  @moduledoc false

  # A flat badge in the style of shields.io. Text widths are estimated from
  # Verdana's widths at 11px, close enough for short labels.

  @narrow ~c"ijl.,:;'!| "
  @wide ~c"mwMW"

  def render(left, right, color) do
    left_width = width(left)
    right_width = width(right)
    total = left_width + right_width
    label = escape("#{left}: #{right}")

    """
    <svg xmlns="http://www.w3.org/2000/svg" width="#{total}" height="20" role="img" aria-label="#{label}">
    <title>#{label}</title>
    <linearGradient id="s" x2="0" y2="100%"><stop offset="0" stop-color="#bbb" stop-opacity=".1"/><stop offset="1" stop-opacity=".1"/></linearGradient>
    <clipPath id="r"><rect width="#{total}" height="20" rx="3" fill="#fff"/></clipPath>
    <g clip-path="url(#r)"><rect width="#{left_width}" height="20" fill="#555"/><rect x="#{left_width}" width="#{right_width}" height="20" fill="#{color}"/><rect width="#{total}" height="20" fill="url(#s)"/></g>
    <g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="11">
    #{text(left, left_width / 2)}
    #{text(right, left_width + right_width / 2)}
    </g>
    </svg>
    """
  end

  defp text(text, x) do
    text = escape(text)

    ~s(<text x="#{x}" y="15" fill="#010101" fill-opacity=".3">#{text}</text>) <>
      ~s(<text x="#{x}" y="14">#{text}</text>)
  end

  defp width(text) do
    widths =
      for char <- String.to_charlist(text) do
        cond do
          char in @narrow -> 3.6
          char in @wide -> 9.5
          char in ?A..?Z -> 7.4
          char in ?0..?9 -> 7.0
          true -> 6.3
        end
      end

    round(Enum.sum(widths) + 10)
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
