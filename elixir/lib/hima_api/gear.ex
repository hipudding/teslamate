defmodule HimaApi.Gear do
  @moduledoc """
  `gearSignal`（数字枚举）→ TeslaMate 的 `shift_state`。

  官方 App 的枚举值：

    * 13 = R
    * 14 = D
    * 15 = P
    * 0  = N（仅在车辆移动时可信；静止时 0 表示未知/熄火）

  未知值返回 nil，不参与 TeslaMate 的状态机判定。
  """

  @doc "gearSignal → shift_state；未知值返回 nil。"
  def shift(signal, moving? \\ false) do
    case int(signal) do
      13 -> "R"
      14 -> "D"
      15 -> "P"
      0 -> if(moving?, do: "N")
      _ -> nil
    end
  end

  defp int(value) when is_integer(value), do: value
  defp int(value) when is_float(value), do: trunc(value)

  defp int(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp int(_), do: nil
end
