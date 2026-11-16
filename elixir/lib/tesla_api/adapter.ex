defmodule TeslaApi.Adapter do
  @moduledoc "Tesla backend for `TeslaMate.VehicleApi`."

  @behaviour TeslaMate.VehicleApi

  alias TeslaApi.{Auth, Vehicle}

  @impl true
  def refresh_auth(%Auth{} = auth), do: TeslaApi.Auth.refresh(auth)

  @impl true
  def list_vehicles(%Auth{} = auth), do: Vehicle.list(auth)

  @impl true
  def get_vehicle(%Auth{} = auth, id), do: Vehicle.get(auth, id)

  @impl true
  def get_vehicle_with_state(%Auth{} = auth, id), do: Vehicle.get_with_state(auth, id)

  @impl true
  def start_stream(%Auth{} = auth, vehicle_id, receiver) do
    TeslaApi.Stream.start_link(auth: auth, vehicle_id: vehicle_id, receiver: receiver)
  end

  @impl true
  def disconnect_stream(pid) when is_pid(pid), do: TeslaApi.Stream.disconnect(pid)

  @impl true
  def supports_streaming?, do: true
end
