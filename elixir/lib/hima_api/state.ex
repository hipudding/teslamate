defmodule HimaApi.State do
  @moduledoc """
  HIMA `dynamic-infos` 快照 → TeslaMate 的 `TeslaApi.Vehicle` 状态结构。

  单位约定（TeslaMate 内部沿用特斯拉原生单位）：

    * speed / odometer / 续航：英里（输入 km ÷ 1.609344）
    * 温度：°C（HIMA 的 0.1°C 整数 ÷ 10）
    * 胎压：bar
    * 时间戳：毫秒（TeslaMate 的 parse_timestamp/1 按毫秒解析）

  能力缺口（实时行车功率、电表电量、软件版本、OTA 等）保持 nil，
  TeslaMate 对 nil 有完整的容忍路径。
  """

  alias TeslaApi.Vehicle, as: TV
  alias TeslaApi.Vehicle.State.{Charge, Climate, Drive, VehicleConfig, VehicleState}
  alias HimaApi.Gear

  @km_to_miles 1 / 1.609344
  @charging_statuses [2, 3, 6, 10, 11, 12, 13, 14, 15, 16, 17, 18, 25]
  @complete_statuses [4, 7]
  @starting_statuses [1]
  @error_statuses [5]

  @doc "车辆元信息 + dynamic-infos → %TeslaApi.Vehicle{}（含全部状态块）。"
  def build(%TV{} = meta, dynamic) when is_map(dynamic) do
    vs = section(dynamic, "vehicleStatus")
    ch = section(dynamic, "charge")
    hv = section(dynamic, "hvac")
    loc = section(dynamic, "location")
    door = section(dynamic, "door")
    tire = section(dynamic, "tire")
    win = section(dynamic, "window")
    seat = section(dynamic, "seat")

    timestamp = timestamp(dynamic, loc, vs)
    charging_state = charging_state(ch)

    # TeslaMate inserts a position when the vehicle becomes online; without
    # coordinates that insert fails. Treat a fix-less snapshot as asleep.
    online? =
      coordinates?(loc["location"]) and
        (int(vs["connectStatus"]) == 1 or charging_state in ["Starting", "Charging"] or
           moving?(vs))

    %TV{
      meta
      | state: if(online?, do: "online", else: "asleep"),
        charge_state: charge_state(ch, door, timestamp),
        climate_state: climate_state(vs, hv, ch, door, seat, timestamp),
        drive_state: drive_state(vs, loc, timestamp),
        vehicle_config: vehicle_config(meta, vs, door, win, seat),
        vehicle_state: vehicle_state(meta, vs, door, tire, win, timestamp)
    }
  end

  # ---------- charge_state ----------

  defp charge_state(ch, door, timestamp) do
    status = charging_status(ch)
    gun = gun_connected?(ch)
    current = first_positive([ch["dcChargeCurrent"], ch["acChargeCurrent"], ch["chargeCurrent"]])
    voltage = first_positive([ch["chargeVoltage"], ch["chargerVolt"], ch["chargerInputVolt"]])

    power =
      case num(ch["chargePower"]) do
        power when is_number(power) and power > 0 ->
          power

        _ when is_number(current) and is_number(voltage) and current > 0 and voltage > 0 ->
          Float.round(voltage * current / 1000, 3)

        _ when status in @charging_statuses ->
          0.0

        _ ->
          nil
      end

    %Charge{
      battery_level: int(ch["soc"]),
      usable_battery_level: int(ch["soc"]),
      charging_state: charging_state(ch),
      charger_power: power,
      charger_voltage: voltage,
      charger_actual_current: if(is_number(current) and current > 0, do: current),
      charger_phases: charger_phases(ch),
      charge_energy_added: nil,
      charge_rate: nil,
      time_to_full_charge: time_to_full_charge(ch["remainChargeTime"]),
      charge_port_door_open: bool01(door["chargeHood"]),
      conn_charge_cable: cable_state(gun),
      charge_limit_soc: positive_int(ch["maxSocPercent"]),
      charge_limit_soc_max: positive_int(ch["maxSocPercent"]),
      ideal_battery_range:
        range_miles(ch, [
          "vcuCltcRemainingMileage",
          "vcuSumRemainingMileage",
          "vcuWltcRemainingMileage",
          "vcuNedcRemainingMileage"
        ]),
      est_battery_range:
        range_miles(ch, [
          "vcuSumRemainingMileage",
          "vcuCltcRemainingMileage",
          "vcuWltcRemainingMileage",
          "vcuNedcRemainingMileage"
        ]),
      battery_range:
        range_miles(ch, [
          "vcuWltcRemainingMileage",
          "vcuNedcRemainingMileage",
          "vcuCltcRemainingMileage",
          "vcuSumRemainingMileage"
        ]),
      fast_charger_present: fast_charger?(ch, gun),
      fast_charger_type: if(fast_charger?(ch, gun), do: "GB/T"),
      scheduled_charging_pending: bool01(ch["chargeReservedStatusDisplay"]),
      battery_heater_on: bool01(ch["isChargeKeepWarm"]),
      timestamp: timestamp
    }
  end

  defp charging_status(ch) do
    max(int(ch["acChargeStatus"]) || 0, int(ch["dcChargeStatus"]) || 0)
  end

  defp charging_state(ch) do
    status = charging_status(ch)
    gun = gun_connected?(ch)

    cond do
      status in @charging_statuses -> "Charging"
      status in @complete_statuses -> "Complete"
      status in @starting_statuses and gun -> "Starting"
      status in @error_statuses -> "Stopped"
      gun -> "Stopped"
      status == 0 -> if(unknown_charge?(ch), do: nil, else: "Disconnected")
      true -> "Disconnected"
    end
  end

  defp unknown_charge?(ch) do
    is_nil(ch["acChargeStatus"]) and is_nil(ch["dcChargeStatus"]) and
      is_nil(ch["chargeConStatus"]) and is_nil(ch["dcChargeGunConnectStatus"])
  end

  defp gun_connected?(ch) do
    ac = int(ch["chargeConStatus"])
    dc = int(ch["dcChargeGunConnectStatus"])

    cond do
      ac in [2, 3, 4, 6] -> true
      dc in [2, 3, 4] -> true
      is_nil(ac) and is_nil(dc) -> nil
      true -> false
    end
  end

  defp cable_state(true), do: "Connected"
  defp cable_state(false), do: "Disconnected"
  defp cable_state(nil), do: nil

  defp charger_phases(ch) do
    cond do
      is_number(num(ch["chargerInputIl3"])) and num(ch["chargerInputIl3"]) > 0 -> 3
      is_number(num(ch["chargerInputIl2"])) and num(ch["chargerInputIl2"]) > 0 -> 2
      is_number(num(ch["chargeVoltage"])) -> 1
      true -> nil
    end
  end

  defp time_to_full_charge(minutes) do
    case num(minutes) do
      minutes when is_number(minutes) and minutes > 0 -> Float.round(minutes / 60, 2)
      _ -> nil
    end
  end

  defp fast_charger?(ch, gun) do
    dc_status = int(ch["dcChargeStatus"]) || 0
    type = int(ch["chargeType"])

    dc_status in @charging_statuses or dc_status in @complete_statuses or type in [2, 3] or
      (match?(true, gun) and int(ch["dcChargeGunConnectStatus"]) in [2, 3, 4])
  end

  # ---------- climate_state ----------

  defp climate_state(vs, hv, ch, door, seat, timestamp) do
    %Climate{
      inside_temp: temp(hv["insideTemp"]),
      outside_temp: temp(hv["outsideTemp"]),
      driver_temp_setting: set_temp(hv["driverSetTemp"]),
      passenger_temp_setting: set_temp(hv["remoteTemp"]),
      is_climate_on: bool01(hv["acStatus"]),
      is_auto_conditioning_on: bool01(hv["autoModeSts"]),
      is_front_defroster_on: bool01(hv["defrostStatus"]),
      is_rear_defroster_on: bool01(hv["backDefrostStatus"]),
      is_preconditioning: nil,
      fan_status: nil,
      battery_heater: bool01(ch["isChargeKeepWarm"]),
      battery_heater_no_power: nil,
      steering_wheel_heater: bool01(vs["steeringWheelHeater"]),
      side_mirror_heaters: mirror_heaters(door),
      seat_heater_left: seat_heat(seat, "leftFront"),
      seat_heater_right: seat_heat(seat, "rightFront"),
      seat_heater_rear_left: seat_heat(seat, "leftBack"),
      seat_heater_rear_center: seat_heat(seat, "midBack"),
      seat_heater_rear_right: seat_heat(seat, "rightBack"),
      seat_heater_rear_left_back: seat_heat(seat, "leftThird"),
      seat_heater_rear_right_back: seat_heat(seat, "rightThird"),
      climate_keeper_mode: keeper_mode(vs["petsModeStatus"]),
      timestamp: timestamp
    }
  end

  defp mirror_heaters(door) do
    values = [
      int(door["leftExteriorMirrorHeatStatus"]),
      int(door["rightExteriorMirrorHeatStatus"])
    ]

    cond do
      Enum.any?(values, &(&1 == 1)) -> true
      Enum.any?(values, &is_integer/1) -> false
      true -> nil
    end
  end

  defp seat_heat(seat, key) do
    case seat[key] do
      %{} = status -> int(status["heatStatus"])
      _ -> nil
    end
  end

  defp keeper_mode(1), do: "dog"
  defp keeper_mode(0), do: "off"
  defp keeper_mode(_), do: nil

  # ---------- drive_state ----------

  defp drive_state(vs, loc, timestamp) do
    pos = loc["location"] || %{}
    {latitude, longitude} = coordinates(pos)
    moving? = moving?(vs)

    %Drive{
      latitude: latitude,
      longitude: longitude,
      heading: num(loc["direction"]),
      speed: miles(vs["speed"]),
      shift_state: Gear.shift(vs["gearSignal"], moving?),
      # HIMA 云端没有实时行车功率，保持 nil（不伪造 0）
      power: nil,
      gps_as_of: seconds(loc["lastUpdatedAt"]),
      timestamp: timestamp
    }
  end

  defp coordinates(pos) do
    latitude = num(pos["latitude"])
    longitude = num(pos["longitude"])

    if is_number(latitude) and is_number(longitude) and {latitude, longitude} != {0, 0} do
      {latitude, longitude}
    else
      {nil, nil}
    end
  end

  defp coordinates?(pos) when is_map(pos) do
    match?({lat, lon} when is_number(lat) and is_number(lon), coordinates(pos))
  end

  defp coordinates?(_pos), do: false

  defp moving?(vs) do
    int(vs["vehicleMoveStatus"]) == 1 or (is_number(num(vs["speed"])) and num(vs["speed"]) > 0)
  end

  # ---------- vehicle_config ----------

  defp vehicle_config(meta, _vs, door, win, seat) do
    profile = meta.profile || %{}

    %VehicleConfig{
      car_type: "HIMA",
      charge_port_type: "GB/T",
      exterior_color: profile[:exterior_color],
      trim_badging: profile[:trim_badging],
      wheel_type: profile[:wheel_type],
      sun_roof_installed: if(present?(win["sunroof"]), do: 1),
      rear_seat_heaters: if(present?(seat["leftBack"]) or present?(seat["rightBack"]), do: 1),
      can_actuate_trunks: present?(door["trunk"]),
      motorized_charge_port: present?(door["chargeHood"])
    }
  end

  # ---------- vehicle_state ----------

  defp vehicle_state(meta, vs, door, tire, win, timestamp) do
    doors = door["doors"] || []
    windows = win["windows"] || []
    degrees = win["openDegree"] || []

    %VehicleState{
      api_version: 1,
      timestamp: timestamp,
      locked: lock_state(door["centerLock"]),
      odometer: miles(vs["totalMileage"]),
      sentry_mode: bool01(vs["sentryModeStatus"]),
      sentry_mode_available: present?(vs["sentryModeStatus"]),
      service_mode: bool01(vs["repairModeStatus"]),
      vehicle_name: meta.display_name,
      car_version: nil,
      software_update: nil,
      df: door_value(doors, 0),
      pf: door_value(doors, 1),
      dr: door_value(doors, 2),
      pr: door_value(doors, 3),
      ft: hood_value(door["frondHood"] || door["oilHood"]),
      rt: hood_value(door["trunk"]),
      fd_window: window_value(windows, degrees, 0),
      fp_window: window_value(windows, degrees, 1),
      rd_window: window_value(windows, degrees, 2),
      rp_window: window_value(windows, degrees, 3),
      sun_roof_percent_open: percent(win["sunroofOpenDegree"]),
      sun_roof_state: sunroof_state(win["sunroof"]),
      tpms_pressure_fl: pressure(tire["leftFront"]),
      tpms_pressure_fr: pressure(tire["rightFront"]),
      tpms_pressure_rl: pressure(tire["leftBack"]),
      tpms_pressure_rr: pressure(tire["rightBack"]),
      tpms_soft_warning_fl: soft_warning(tire["leftFront"]),
      tpms_soft_warning_fr: soft_warning(tire["rightFront"]),
      tpms_soft_warning_rl: soft_warning(tire["leftBack"]),
      tpms_soft_warning_rr: soft_warning(tire["rightBack"])
    }
  end

  # centerLock: 0=锁闭，1=开锁（HIMA 与特斯拉语义相反）
  defp lock_state(0), do: true
  defp lock_state(1), do: false
  defp lock_state(_), do: nil

  defp door_value(doors, index) when is_list(doors) do
    case Enum.at(doors, index) |> int() do
      1 -> 1
      0 -> 0
      _ -> nil
    end
  end

  defp door_value(_doors, _index), do: nil

  defp hood_value(value) do
    case int(value) do
      1 -> 1
      3 -> 1
      0 -> 0
      _ -> nil
    end
  end

  defp window_value(windows, _degrees, index) when is_list(windows) and windows != [] do
    case Enum.at(windows, index) |> int() do
      1 -> 1
      3 -> 1
      0 -> 0
      2 -> 0
      _ -> nil
    end
  end

  defp window_value(_windows, degrees, index) when is_list(degrees) do
    case Enum.at(degrees, index) do
      degree when is_number(degree) -> if(degree > 0, do: 1, else: 0)
      _ -> nil
    end
  end

  defp window_value(_windows, _degrees, _index), do: nil

  defp percent(value) do
    case num(value) do
      value when is_number(value) and value > 0 and value <= 1 -> round(value * 100)
      value when is_number(value) -> round(value)
      _ -> nil
    end
  end

  defp sunroof_state(0), do: "closed"
  defp sunroof_state(1), do: "open"
  defp sunroof_state(2), do: "vent"
  defp sunroof_state(3), do: "vent"
  defp sunroof_state(4), do: "vent"
  defp sunroof_state(_), do: nil

  # ---------- 时间戳 ----------

  defp timestamp(dynamic, loc, vs) do
    first_timestamp([
      dynamic["lastUpdatedAt"],
      loc["lastUpdatedAt"],
      loc["gpsTime"],
      vs["lastUpdatedAt"]
    ]) || System.system_time(:millisecond)
  end

  defp first_timestamp(values) do
    Enum.find_value(values, &to_ms/1)
  end

  defp to_ms(value) when is_number(value) and value > 10_000_000_000, do: trunc(value)

  defp to_ms(value) when is_number(value) and value > 1_000_000_000,
    do: trunc(value) * 1000

  defp to_ms(_), do: nil

  defp seconds(value) do
    case to_ms(value) do
      nil -> nil
      ms -> div(ms, 1000)
    end
  end

  # ---------- 数值转换 ----------

  defp section(map, key) do
    case map[key] do
      %{} = section -> section
      _ -> %{}
    end
  end

  defp num(value) when is_number(value), do: value

  defp num(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp num(_), do: nil

  defp int(value) when is_integer(value), do: value
  defp int(value) when is_float(value), do: trunc(value)

  defp int(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp int(_), do: nil

  defp positive_int(value) do
    case int(value) do
      number when is_integer(number) and number > 0 -> number
      _ -> nil
    end
  end

  defp first_positive(values) do
    Enum.find_value(values, fn value ->
      case num(value) do
        number when is_number(number) and number > 0 -> number
        _ -> nil
      end
    end)
  end

  defp temp(value) do
    case num(value) do
      value when is_number(value) -> Float.round(value / 10, 1)
      _ -> nil
    end
  end

  # 设定温度可能是 0.1°C 整数（250）或已换算的 Double（25.0）
  defp set_temp(value) do
    case num(value) do
      value when is_number(value) and value > 80 -> Float.round(value / 10, 1)
      value when is_number(value) and value > 0 -> Float.round(value * 1.0, 1)
      _ -> nil
    end
  end

  defp miles(value) do
    case num(value) do
      value when is_number(value) -> Float.round(value * @km_to_miles, 6)
      _ -> nil
    end
  end

  defp range_miles(ch, keys) do
    keys
    |> Enum.find_value(&valid_number(ch[&1]))
    |> miles()
  end

  defp valid_number(value) do
    case num(value) do
      value when is_number(value) and value not in [-1, 65535] and value > 0 -> value
      _ -> nil
    end
  end

  defp pressure(tire) when is_map(tire) do
    case num(tire["pressure"]) do
      value when is_number(value) and value > 20 -> Float.round(value / 100, 3)
      value when is_number(value) and value > 0 -> Float.round(value * 1.0, 3)
      _ -> nil
    end
  end

  defp pressure(_), do: nil

  defp soft_warning(tire) when is_map(tire) do
    case tire["leakageStatus"] do
      1 -> true
      0 -> false
      _ -> nil
    end
  end

  defp soft_warning(_), do: nil

  defp bool01(nil), do: nil
  defp bool01(0), do: false
  defp bool01(_), do: true

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true
end
