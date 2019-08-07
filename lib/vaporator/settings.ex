defmodule Vaporator.Settings do
  @default_settings [
    wireless: [ssid: nil, psk: nil, key_mgmt: :NONE],
    client: [sync_dirs: [], poll_interval: 600_000, sync_enabled?: true],
    cloud: [provider: %Vaporator.Cloud.Dropbox{}]
  ]

  @required_settings [:ssid, :key_mgmt, :sync_dirs, :provider]

  def init do
    Enum.map(
      @default_settings,
      fn {k, v} ->
        put(k, v, overwrite: false)
      end
    )
  end

  def exists?(setting) do
    case PersistentStorage.get(:settings, setting) do
      nil -> false
      _ -> true
    end
  end

  def set? do
    set?(@default_settings)
  end

  defp set?(settings) do
    set?(settings, [])
  end

  defp set?([], result) do
    false not in List.flatten(result)
  end

  defp set?(settings, result) do
    [h | t] = settings
    set?(h, t, result)
  end

  defp set?({setting, details}, t, result) do
    all_set? =
      details
      |> Enum.filter(fn {k, _} -> k in @required_settings end)
      |> Enum.map(fn {k, v} -> v != get!(setting, k) end)
    
    set?(t, [all_set? | result])
  end

  @doc """
  Retrives current settings
  """
  def get do
    @default_settings
    |> Keyword.keys()
    |> get_by_keys()
  end

  def get(setting) do
    if exists?(setting) do
      PersistentStorage.get(:settings, setting)
    else
      []
    end
  end

  def get(setting, key) do
    Keyword.fetch(get(setting), key)
  end

  def get!(setting, key) do
    Keyword.fetch!(get(setting), key)
  end

  def get_by_keys(keys) when is_list(keys) do
    Enum.map(keys, fn k -> {k, get(k)} end)
  end

  @doc """
  Updates settings

  Returns `:ok`
  """
  def put(setting, value) do
    PersistentStorage.put(:settings, setting, value)
  end

  def put(setting, value, overwrite: true), do: put(setting, value)

  def put(setting, value, overwrite: false) do
    if exists?(setting) do
      :noop
    else
      put(setting, value)
    end
  end

  def put(setting, key, value) do
    new_value =
      PersistentStorage.get(:settings, setting)
      |> Keyword.replace!(key, value)

    put(setting, new_value)
  end
end
