defmodule HimaApi.Vehicle do
  @moduledoc """
  鸿蒙智行车辆接口（实现 `TeslaMate.VehicleApi` 的 HIMA 后端）。

  一个 TeslaMate 实例只管理一辆 HIMA 车：凭据包自带车辆身份
  （`vehicleId` / `vin`），因此列表阶段不需要每次访问车辆云。
  只有凭据包缺少车辆身份时，才回退到 `vcam/v1/accounts/vehicles`。

  取数只有一个接口 `dynamic-infos`。TeslaMate 在 `:start` 状态会先
  `get/2` 再 `get_with_state/2`，两者通过进程内 1 秒缓存合并成一次请求。
  """

  alias TeslaApi.{Auth, Error}
  alias TeslaApi.Vehicle, as: TV
  alias HimaApi.{Omp, State}
  alias HimaApi.Auth, as: HimaAuth

  require Logger

  @dynamic_cache_ms 1_000
  @default_name "鸿蒙智行"
  @invalid_token_codes [100_011, "100011", 10011, "10011", 100_015, "100015"]

  @doc "账户车辆列表；凭据包有车辆身份时不发网络请求。"
  def list(%Auth{token: raw}) do
    with {:ok, bundle} <- HimaAuth.parse_bundle(raw) do
      case vehicle_from_bundle(bundle) do
        %TV{} = vehicle ->
          {:ok, [enrich_profile(vehicle, bundle)]}

        nil ->
          list_from_cloud(bundle)
      end
    else
      {:error, reason} -> normalize_error({:error, reason})
    end
  end

  @doc "轻量查询：返回车辆（含实时状态快照，实际与 get_with_state/2 同一次请求）。"
  def get(%Auth{token: raw}, id) do
    with {:ok, bundle} <- HimaAuth.parse_bundle(raw),
         {:ok, dynamic} <- fetch_dynamic(bundle, id) do
      {:ok, State.build(vehicle_from_id(bundle, id), dynamic)}
    else
      {:error, reason} -> normalize_error({:error, reason})
    end
  end

  @doc "完整状态查询（TeslaMate 的 vehicle_data）；与 get/2 共用同一快照。"
  def get_with_state(%Auth{} = auth, id), do: get(auth, id)

  # ---------- 车辆元信息 ----------

  defp list_from_cloud(bundle) do
    case Omp.vehicles_list(bundle) do
      {:ok, []} ->
        {:ok, []}

      {:ok, items} when is_list(items) ->
        items = Enum.map(items, &vehicle_from_item(&1, bundle))
        vehicle = select(items, bundle)
        {:ok, [enrich_profile(vehicle, bundle)]}

      {:error, reason} ->
        normalize_error({:error, reason})
    end
  end

  defp select([vehicle | _] = vehicles, bundle) do
    vin = bundle["vin"]

    vehicle =
      case vin && Enum.find(vehicles, &(&1.vin == vin)) do
        %TV{} = match -> match
        _ -> vehicle
      end

    if length(vehicles) > 1 do
      Logger.warning("HIMA 凭据包未包含车辆身份，账号下有 #{length(vehicles)} 辆车，使用 #{vehicle.display_name}")
    end

    vehicle
  end

  defp vehicle_from_bundle(bundle) do
    case parse_id(bundle["vehicleId"] || bundle["vehicleIdStr"]) do
      nil ->
        nil

      id ->
        %TV{
          id: id,
          vehicle_id: id,
          vin: blank_to_nil(bundle["vin"]),
          state: "asleep",
          display_name: bundle_name(bundle),
          option_codes: [],
          in_service: false,
          profile: bundle_profile(bundle)
        }
    end
  end

  defp vehicle_from_item(item, bundle) when is_map(item) do
    id = parse_id(item["vehicleId"] || item["vehicleIdStr"] || bundle["vehicleId"])

    %TV{
      id: id || 0,
      vehicle_id: id || 0,
      vin: blank_to_nil(item["vin"]) || blank_to_nil(bundle["vin"]),
      state: "asleep",
      display_name:
        blank_to_nil(item["plateNo"]) || blank_to_nil(item["vehicleAliasName"]) ||
          bundle_name(bundle),
      option_codes: [],
      in_service: false,
      profile: bundle_profile(bundle) |> Map.merge(item_profile(item))
    }
  end

  defp vehicle_from_id(bundle, id) do
    id = parse_id(id) || parse_id(bundle["vehicleId"] || bundle["vehicleIdStr"]) || 0

    %TV{
      id: id,
      vehicle_id: id,
      vin: blank_to_nil(bundle["vin"]),
      state: "asleep",
      display_name: bundle_name(bundle),
      option_codes: [],
      in_service: false,
      profile: bundle_profile(bundle)
    }
  end

  defp bundle_name(bundle) do
    blank_to_nil(bundle["plateNo"]) || blank_to_nil(bundle["vehicleAliasName"]) ||
      blank_to_nil(bundle["vehicleName"]) || @default_name
  end

  # ---------- 车型档案 ----------

  defp bundle_profile(bundle) do
    %{
      model: blank_to_nil(bundle["model"]) || blank_to_nil(bundle["modelName"]),
      trim_badging: blank_to_nil(bundle["trimBadging"]),
      marketing_name: blank_to_nil(bundle["projectName"]),
      exterior_color: blank_to_nil(bundle["colorName"]),
      wheel_type: blank_to_nil(bundle["wheelType"]),
      efficiency: efficiency(bundle["efficiency"] || bundle["avgEgyCnse"])
    }
    |> reject_nil()
  end

  defp item_profile(item) do
    %{
      model: blank_to_nil(item["modelName"]) || blank_to_nil(item["brandName"]),
      marketing_name: blank_to_nil(item["projectName"]),
      exterior_color: blank_to_nil(item["colorName"])
    }
    |> reject_nil()
  end

  # 凭据包没有车型时，启动阶段用 OMP 车辆管理列表补齐（不参与轮询）。
  defp enrich_profile(%TV{profile: profile} = vehicle, bundle) when is_map(profile) do
    if profile[:model] do
      vehicle
    else
      case Omp.vehicle_management_list(bundle) do
        {:ok, %{"vehicleMargeInfoList" => items}} when is_list(items) ->
          base = management_base(items, vehicle)
          %{vehicle | profile: Map.merge(profile, item_profile(base))}

        {:error, reason} ->
          Logger.debug("HIMA 车型档案获取失败: #{inspect(reason)}")
          vehicle

        _ ->
          vehicle
      end
    end
  end

  defp enrich_profile(vehicle, _bundle), do: vehicle

  defp management_base(items, vehicle) do
    Enum.find_value(items, %{}, fn item ->
      base = item["vehicleBaseInfo"] || %{}

      if parse_id(base["vehicleId"]) == vehicle.id do
        base
      end
    end)
  end

  # ---------- 动态数据 ----------

  # `TeslaMate.Api` 在同一进程内依次调用 get/2 和 get_with_state/2；
  # 进程字典缓存把这两次调用合并成一次 dynamic-infos 请求。
  defp fetch_dynamic(bundle, id) do
    now = System.monotonic_time(:millisecond)
    token = bundle["vehicleAccessToken"]
    key = {__MODULE__, :dynamic}

    case Process.get(key) do
      {^id, ^token, ts, result} when now - ts < @dynamic_cache_ms ->
        result

      _ ->
        result = Omp.dynamic_infos(bundle, id)
        Process.put(key, {id, token, now, result})
        result
    end
  end

  # ---------- 错误规整 ----------

  defp normalize_error({:error, %Error{} = error}), do: {:error, error}

  defp normalize_error({:error, {:http, 401, _body}}) do
    invalidate()
    {:error, %Error{reason: :unauthorized}}
  end

  defp normalize_error({:error, {:omp, code, message}}) when code in @invalid_token_codes do
    invalidate()
    {:error, %Error{reason: :unauthorized, message: message}}
  end

  defp normalize_error({:error, {:omp, 10022, message}}) do
    {:error, %Error{reason: :invalid_tokens, message: message || "凭据包已失效，请重新登录"}}
  end

  defp normalize_error({:error, {:omp, code, message}}) do
    {:error, %Error{reason: :unknown, message: "HIMA #{code}: #{message}"}}
  end

  defp normalize_error({:error, {:http, status, body}}) do
    {:error, %Error{reason: :unknown, message: "HIMA HTTP #{status}: #{inspect(body)}"}}
  end

  defp normalize_error({:error, reason}) do
    {:error, %Error{reason: :unknown, message: inspect(reason)}}
  end

  defp invalidate, do: HimaAuth.invalidate()

  # ---------- 工具 ----------

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_id(id) when is_float(id), do: trunc(id)
  defp parse_id(_), do: nil

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value) when is_binary(value), do: value
  defp blank_to_nil(value), do: to_string(value)

  defp reject_nil(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # kWh/100km → kWh/km（TeslaMate Car.efficiency 的单位）
  defp efficiency(value) do
    case number(value) do
      value when is_number(value) and value > 1 -> Float.round(value / 100, 4)
      value when is_number(value) and value > 0 -> value
      _ -> nil
    end
  end

  defp number(value) when is_number(value), do: value

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _} -> number
      :error -> nil
    end
  end

  defp number(_), do: nil
end
