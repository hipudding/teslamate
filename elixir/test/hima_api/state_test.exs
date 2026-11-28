defmodule HimaApi.StateTest do
  use ExUnit.Case, async: true

  alias HimaApi.State

  defp meta do
    %TeslaApi.Vehicle{id: 1, display_name: "test", profile: %{}}
  end

  test "maps HIMA unknown sentinels to nil" do
    dynamic = %{
      "vehicleStatus" => %{
        "soc" => -1,
        "totalMileage" => -1,
        "speed" => -1,
        "connectStatus" => 0,
        "status" => 2,
        "lastUpdatedAt" => 1_700_000_000_000,
        "avgEgyCnse" => 16.0
      },
      "charge" => %{
        "soc" => -1,
        "vcuCltcRemainingMileage" => -1,
        "vcuSumRemainingMileage" => -1,
        "vcuWltcRemainingMileage" => -1,
        "vcuNedcRemainingMileage" => -1,
        "maxSocPercent" => 90,
        "chargePower" => 0.0,
        "chargeVoltage" => 0.0,
        "chargeCurrent" => 0.0
      },
      "hvac" => %{
        "insideTemp" => 65535,
        "outsideTemp" => -1,
        "driverSetTemp" => 0.0,
        "remoteTemp" => 65535
      },
      "location" => %{
        "location" => %{"latitude" => 22.0, "longitude" => 113.0},
        "direction" => -1,
        "lastUpdatedAt" => 1_700_000_000_000
      },
      "seat" => %{"leftFront" => %{"heatStatus" => -1}},
      "door" => %{"centerLock" => 0},
      "tire" => %{},
      "window" => %{}
    }

    vehicle = State.build(meta(), dynamic)

    assert vehicle.state == "asleep"
    assert vehicle.charge_state.battery_level == nil
    assert vehicle.charge_state.usable_battery_level == nil
    assert vehicle.charge_state.ideal_battery_range == nil
    assert vehicle.charge_state.est_battery_range == nil
    assert vehicle.charge_state.battery_range == nil
    assert vehicle.charge_state.charge_limit_soc == 90
    assert vehicle.drive_state.speed == nil
    assert vehicle.drive_state.heading == nil
    assert vehicle.vehicle_state.odometer == nil
    assert vehicle.climate_state.inside_temp == nil
    assert vehicle.climate_state.outside_temp == nil
    assert vehicle.climate_state.driver_temp_setting == nil
    assert vehicle.climate_state.passenger_temp_setting == nil
    assert vehicle.climate_state.seat_heater_left == nil
  end

  test "keeps valid zero SoC and normal temperatures" do
    dynamic = %{
      "vehicleStatus" => %{
        "soc" => 0,
        "totalMileage" => 100,
        "speed" => 30,
        "connectStatus" => 1,
        "status" => 1,
        "lastUpdatedAt" => 1_700_000_000_000,
        "avgEgyCnse" => 16.0
      },
      "charge" => %{
        "soc" => 0,
        "vcuCltcRemainingMileage" => 300,
        "maxSocPercent" => 90,
        "chargePower" => 0.0,
        "chargeVoltage" => 0.0,
        "chargeCurrent" => 0.0
      },
      "hvac" => %{
        "insideTemp" => 200,
        "outsideTemp" => 0,
        "driverSetTemp" => 250,
        "remoteTemp" => 220
      },
      "location" => %{
        "location" => %{"latitude" => 22.0, "longitude" => 113.0},
        "direction" => 90,
        "lastUpdatedAt" => 1_700_000_000_000
      },
      "seat" => %{"leftFront" => %{"heatStatus" => 2}},
      "door" => %{"centerLock" => 0},
      "tire" => %{},
      "window" => %{}
    }

    vehicle = State.build(meta(), dynamic)

    assert vehicle.charge_state.battery_level == 0
    assert vehicle.charge_state.usable_battery_level == 0
    assert vehicle.charge_state.ideal_battery_range > 0
    assert vehicle.drive_state.heading == 90
    assert vehicle.climate_state.inside_temp == 20.0
    assert vehicle.climate_state.outside_temp == 0.0
    assert vehicle.climate_state.driver_temp_setting == 25.0
    assert vehicle.climate_state.passenger_temp_setting == 22.0
    assert vehicle.climate_state.seat_heater_left == 2
    assert is_number(vehicle.vehicle_state.odometer)
    assert is_number(vehicle.drive_state.speed)
  end
end
