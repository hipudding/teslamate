defmodule HimaApi.Adapter do
  @moduledoc """
  HIMA backend for `TeslaMate.VehicleApi`.

  HIMA has no push/streaming API; TeslaMate's regular polling cadence is used.
  One TeslaMate instance owns exactly one HIMA vehicle (the one identified by
  the pasted credential bundle).
  """

  @behaviour TeslaMate.VehicleApi

  alias TeslaApi.Auth

  @impl true
  def refresh_auth(%Auth{} = auth), do: HimaApi.Auth.refresh(auth)

  @impl true
  def list_vehicles(%Auth{} = auth), do: HimaApi.Vehicle.list(auth)

  @impl true
  def get_vehicle(%Auth{} = auth, id), do: HimaApi.Vehicle.get(auth, id)

  @impl true
  def get_vehicle_with_state(%Auth{} = auth, id),
    do: HimaApi.Vehicle.get_with_state(auth, id)

  @impl true
  def start_stream(_auth, _vehicle_id, _receiver), do: {:error, :streaming_not_supported}

  @impl true
  def disconnect_stream(_pid), do: :ok

  @impl true
  def supports_streaming?, do: false
end
