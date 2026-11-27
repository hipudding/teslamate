defmodule HimaApi.ChargeEnergy do
  @moduledoc """
  充电电量（电池侧）估算。

  HIMA `dynamic-infos` 没有累计充电电量字段。这里在充电会话内用
  “续航增量 × 平均能耗” 估算累计 `charge_energy_added`，写入
  `TeslaApi.Vehicle.State.Charge`；TeslaMate 现有的 `charges` /
  `charging_processes` 统计无需修改。

  状态保存在 `:persistent_term`（每辆车一个 key），不引入额外进程。
  估算只在充电会话期间使用；断开后清除，下一次充电重新取基线。
  """

  @range_keys ~w(vcuCltcRemainingMileage vcuSumRemainingMileage vcuWltcRemainingMileage vcuNedcRemainingMileage)
  @charging_states ~w(Starting Charging)
  @finished_states ~w(Complete Stopped)

  @doc """
  返回当前充电会话累计估算电量（kWh）。

  `charging_state` 是 `HimaApi.State` 计算出的状态字符串；
  `efficiency` 是 `avgEgyCnse / 100`（kWh/km），可以为 nil。
  """
  def estimate(vehicle_id, charge, charging_state, efficiency, timestamp) do
    key = key(vehicle_id)
    state = :persistent_term.get(key, nil)

    cond do
      charging_state == nil ->
        energy(state)

      charging_state == "Disconnected" ->
        reset(key, state)
        nil

      charging_state in @charging_states ->
        charge_iteration(key, state, charge, efficiency, timestamp, charging_state)

      charging_state in @finished_states ->
        finish_iteration(key, state, timestamp, charging_state)

      true ->
        energy(state)
    end
  end

  defp charge_iteration(key, state, charge, efficiency, timestamp, status) do
    stale? = state && state.last_ts && timestamp && timestamp < state.last_ts
    same? = state && state.last_ts && timestamp && timestamp == state.last_ts

    cond do
      stale? ->
        energy(state)

      same? ->
        energy(state)

      state && state.phase in [:charging, :finished] && is_number(state.baseline_km) ->
        state = advance(state, range_km(charge), efficiency, timestamp, status)
        :persistent_term.put(key, state)
        energy(state)

      true ->
        state = %{
          phase: :charging,
          baseline_km: range_km(charge),
          last_energy: 0.0,
          last_ts: timestamp,
          last_status: status
        }

        :persistent_term.put(key, state)
        energy(state)
    end
  end

  defp finish_iteration(_key, nil, _timestamp, _status), do: nil

  defp finish_iteration(key, state, timestamp, status) do
    stale? = state.last_ts && timestamp && timestamp < state.last_ts
    same? = state.last_ts && timestamp && timestamp == state.last_ts

    if stale? or same? do
      energy(state)
    else
      state = %{
        state
        | phase: :finished,
          last_ts: timestamp || state.last_ts,
          last_status: status
      }

      :persistent_term.put(key, state)
      energy(state)
    end
  end

  defp advance(state, range, efficiency, timestamp, status) do
    last_energy =
      if is_number(range) and is_number(efficiency) and efficiency > 0 do
        max(state.last_energy, max(0.0, (range - state.baseline_km) * efficiency))
      else
        state.last_energy
      end

    %{state | phase: :charging, last_energy: last_energy, last_ts: timestamp, last_status: status}
  end

  defp energy(%{phase: phase, last_energy: energy})
       when phase in [:charging, :finished] and is_number(energy),
       do: Float.round(energy, 3)

  defp energy(_), do: nil

  defp reset(_key, nil), do: :ok
  defp reset(key, _state), do: :persistent_term.erase(key)

  defp range_km(charge) do
    Enum.find_value(@range_keys, fn key ->
      case num(charge[key]) do
        value when is_number(value) and value > 0 and value not in [65535] -> value
        _ -> nil
      end
    end)
  end

  defp num(value) when is_number(value), do: value

  defp num(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _} -> number
      :error -> nil
    end
  end

  defp num(_), do: nil

  defp key(vehicle_id), do: {__MODULE__, vehicle_id || :unknown}
end
