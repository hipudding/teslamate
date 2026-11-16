defmodule TeslaMate.VehicleApi do
  @moduledoc """
  Vehicle data source abstraction.

  TeslaMate's vehicle logger talks to this façade instead of a concrete API
  client. `VEHICLE_API_BACKEND` selects the implementation at runtime:

    * `tesla` (default) – `TeslaApi.Adapter`
    * `hima`            – `HimaApi.Adapter` (鸿蒙智行 / 问界 / 智界)

  All adapters return the same `TeslaApi.*` structs, so the rest of TeslaMate
  (polling, drive/charge logging, MQTT, UI) stays backend-agnostic.
  """

  alias TeslaApi.{Auth, Error, Vehicle}

  @type id :: integer() | String.t()
  @type receiver :: fun()

  @callback refresh_auth(Auth.t()) :: {:ok, Auth.t()} | {:error, Error.t()}
  @callback list_vehicles(Auth.t()) :: {:ok, [Vehicle.t()]} | {:error, Error.t()}
  @callback get_vehicle(Auth.t(), id()) :: {:ok, Vehicle.t()} | {:error, Error.t()}
  @callback get_vehicle_with_state(Auth.t(), id()) ::
              {:ok, Vehicle.t()} | {:error, Error.t()}
  @callback start_stream(Auth.t(), id(), receiver()) :: {:ok, pid()} | {:error, term()}
  @callback disconnect_stream(pid()) :: :ok
  @callback supports_streaming?() :: boolean()

  @backend_key :vehicle_api_backend

  def backend do
    Application.get_env(:teslamate, @backend_key, TeslaApi.Adapter)
  end

  def hima?, do: backend() == HimaApi.Adapter

  def refresh_auth(%Auth{} = auth), do: backend().refresh_auth(auth)

  def list_vehicles(%Auth{} = auth), do: backend().list_vehicles(auth)

  def get_vehicle(%Auth{} = auth, id), do: backend().get_vehicle(auth, id)

  def get_vehicle_with_state(%Auth{} = auth, id),
    do: backend().get_vehicle_with_state(auth, id)

  def start_stream(%Auth{} = auth, id, receiver),
    do: backend().start_stream(auth, id, receiver)

  def disconnect_stream(pid), do: backend().disconnect_stream(pid)

  def supports_streaming?, do: backend().supports_streaming?()
end
