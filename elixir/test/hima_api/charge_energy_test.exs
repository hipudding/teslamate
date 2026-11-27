defmodule HimaApi.ChargeEnergyTest do
  use ExUnit.Case, async: false

  alias HimaApi.ChargeEnergy

  setup do
    id = System.unique_integer([:positive])
    on_exit(fn -> :persistent_term.erase({ChargeEnergy, id}) end)
    %{id: id}
  end

  defp charge(range), do: %{"vcuCltcRemainingMileage" => range}

  test "accumulates range delta from the first charging snapshot", %{id: id} do
    assert ChargeEnergy.estimate(id, charge(500), "Charging", 0.16, 1000) == 0.0
    assert ChargeEnergy.estimate(id, charge(520), "Charging", 0.16, 6000) == 3.2
    assert ChargeEnergy.estimate(id, charge(530), "Charging", 0.16, 11_000) == 4.8
  end

  test "is idempotent for the same snapshot timestamp", %{id: id} do
    assert ChargeEnergy.estimate(id, charge(500), "Charging", 0.16, 1000) == 0.0
    assert ChargeEnergy.estimate(id, charge(520), "Charging", 0.16, 6000) == 3.2
    assert ChargeEnergy.estimate(id, charge(999), "Charging", 0.16, 6000) == 3.2
  end

  test "never decreases when range fluctuates", %{id: id} do
    ChargeEnergy.estimate(id, charge(500), "Charging", 0.16, 1000)
    assert ChargeEnergy.estimate(id, charge(540), "Charging", 0.16, 6000) == 6.4
    assert ChargeEnergy.estimate(id, charge(530), "Charging", 0.16, 11_000) == 6.4
  end

  test "keeps the final value while plugged and resets on disconnect", %{id: id} do
    ChargeEnergy.estimate(id, charge(500), "Charging", 0.16, 1000)
    assert ChargeEnergy.estimate(id, charge(520), "Charging", 0.16, 6000) == 3.2
    assert ChargeEnergy.estimate(id, charge(520), "Complete", 0.16, 11_000) == 3.2
    assert ChargeEnergy.estimate(id, charge(520), "Disconnected", 0.16, 16_000) == nil
    assert ChargeEnergy.estimate(id, charge(600), "Charging", 0.16, 21_000) == 0.0
    assert ChargeEnergy.estimate(id, charge(610), "Charging", 0.16, 26_000) == 1.6
  end

  test "keeps the baseline until efficiency becomes available", %{id: id} do
    assert ChargeEnergy.estimate(id, charge(500), "Charging", nil, 1000) == 0.0
    assert ChargeEnergy.estimate(id, charge(520), "Charging", nil, 6000) == 0.0
    assert ChargeEnergy.estimate(id, charge(520), "Charging", 0.16, 11_000) == 3.2
  end

  test "returns nil without an active charging session", %{id: id} do
    assert ChargeEnergy.estimate(id, charge(500), nil, 0.16, 1000) == nil
    assert ChargeEnergy.estimate(id, charge(500), "Disconnected", 0.16, 1000) == nil
  end
end
