defmodule Gingko.Release do
  @moduledoc false

  @secret_key_file "secret.key"
  @key_bytes 64

  @spec ensure_secret_key_base!() :: String.t()
  def ensure_secret_key_base! do
    case System.get_env("SECRET_KEY_BASE") do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        read_or_generate_secret!()
    end
  end

  defp read_or_generate_secret! do
    home = Gingko.Settings.home()
    path = Path.join(home, @secret_key_file)
    File.mkdir_p!(home)

    case File.read(path) do
      {:ok, key} when byte_size(key) > 0 ->
        String.trim(key)

      _ ->
        key = :crypto.strong_rand_bytes(@key_bytes) |> Base.encode64()
        File.write!(path, key)
        key
    end
  end
end
