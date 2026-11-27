defmodule HimaApi.Auth do
  @moduledoc """
  鸿蒙智行凭据包与 TeslaMate token 的适配层。

  与 TeslaMate 的 token 存储约定：

    * `%TeslaApi.Auth{token: ...}`          – base64(规范化的 JSON 凭据包)
    * `%TeslaApi.Auth{refresh_token: ...}`  – 固定为 `"HIMA"`（占位，续期不依赖它）
    * `%TeslaApi.Auth{expires_in: ...}`     – 车辆 token 剩余秒数，驱动官方 75% 定时刷新

  登录页把凭据包粘贴到 Access Token、`HIMA` 粘贴到 Refresh Token 即可。
  凭据包可以是最初的扁平 JSON，也可以是带 `vehicle`/`account`/`session`
  分组的 v1 结构；解析时统一压平并只保留续期需要的字段。

  续期链：`vehicle/refresh`（优先）→ `user/refresh` + `vehicle/refresh`。
  OMP 10011（sessionKey 过期）会先刷新用户会话；只有 10022
  （用户 refreshToken 失效）才需要重新登录。不会主动 `vehicle/auth`
  或 `kickout`，避免把手机顶下线。

  续期由 `TeslaMate.Api` 既有的启动/定时/401 调度驱动，本模块不启动进程。
  实际签发时间写入凭据包 `vehicleTokenIssuedAt`，10 分钟内重复调用直接
  复用现有 token；失败用 60 秒全局冷却，避免 401 抖动时连续撞接口。
  """

  alias TeslaApi.Auth
  alias TeslaApi.Error
  alias HimaApi.Omp

  require Logger

  @required_keys ~w(enterpriseCode vehicleAccessToken sessionKey userId
                    userAccessToken userRefreshToken vin)

  # 没有到期时间时给一个保守的周期；实际取数遇到 401 会立即触发续期。
  @default_expires_in 24 * 60 * 60

  # hima-info 建议用户会话每 6~12 小时滚动一次；TeslaMate 在 75% 处续期，
  # 因此把 expires_in 上限压到 12 小时（实际约 9 小时续期一次），避免
  # userRefreshToken 先失效导致必须重新登录。
  @max_refresh_interval 12 * 60 * 60

  # 两次实际签发之间的最小间隔：HIMA 每次签发都会注销同账号旧 token。
  @issue_cooldown_seconds 10 * 60

  # 普通续期失败的短冷却，避免 401 抖动时连续撞接口。
  @error_cooldown_ms 60_000
  @error_key {__MODULE__, :refresh_error}

  @doc "解析凭据包：接受 base64 或明文 JSON（容忍换行/空格等粘贴杂质）。"
  def parse_bundle(raw) when is_binary(raw) do
    cleaned = String.replace(raw, ~r/\s+/, "")

    case decode_json(raw) || decode_json(cleaned) do
      {:ok, %{} = map} ->
        {:ok, normalize_bundle(map)}

      _ ->
        with {:ok, bin} <- decode_base64(cleaned),
             {:ok, %{} = map} <- Jason.decode(bin) do
          {:ok, normalize_bundle(map)}
        else
          _ -> {:error, "凭据包不是有效 JSON 或 base64"}
        end
    end
  end

  def parse_bundle(_), do: {:error, "凭据包为空"}

  defp decode_json(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> nil
    end
  end

  def encode_bundle(%{} = bundle) do
    bundle |> Jason.encode!() |> Base.encode64()
  end

  @doc "凭据包 → `%TeslaApi.Auth{}`。"
  def from_bundle(raw) do
    with {:ok, bundle} <- parse_bundle(raw),
         :ok <- validate(bundle) do
      expires_in =
        case vehicle_expiry(bundle) do
          nil -> @default_expires_in
          expiry -> max(expiry - System.system_time(:second), 60)
        end
        |> min(@max_refresh_interval)

      {:ok,
       %Auth{
         token: encode_bundle(bundle),
         refresh_token: "HIMA",
         expires_in: expires_in
       }}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, %Error{reason: :invalid_tokens, message: reason}}
    end
  end

  @doc """
  对应 `TeslaApi.Auth.refresh/1`。

  登录提交（`expires_in == nil`）只做解析/校验，不发网络请求；启动恢复和
  定时刷新（`expires_in` 有值）由 `TeslaMate.Api` 串行调用，不需要额外进程。
  """
  def refresh(%Auth{token: bundle_b64, expires_in: nil}) do
    :ok = invalidate()

    with {:ok, bundle} <- parse_bundle(bundle_b64),
         :ok <- validate(bundle) do
      from_bundle(encode_bundle(bundle))
    else
      {:error, reason} ->
        {:error, %Error{reason: :invalid_tokens, message: error_message(reason)}}
    end
  end

  def refresh(%Auth{} = auth), do: refresh_chain(auth)

  @doc "按车辆 token → 用户会话的顺序续期；由 `TeslaMate.Api` 串行调用。"
  def refresh_chain(%Auth{token: bundle_b64}) do
    with {:ok, bundle} <- parse_bundle(bundle_b64) do
      cond do
        error = cached_error() ->
          {:error, error}

        cooldown?(bundle) ->
          cooldown_reply(bundle)

        true ->
          do_refresh_chain(bundle)
      end
    else
      {:error, reason} ->
        {:error, %Error{reason: :unknown, message: error_message(reason)}}
    end
  end

  @doc "取数遇到 401 时调用：清掉错误冷却，允许下一次续期重试。"
  def invalidate do
    clear_error()
  end

  @doc "校验必需字段。"
  def validate(bundle) do
    case Enum.reject(@required_keys, &present?(bundle[&1])) do
      [] -> :ok
      missing -> {:error, "凭据包缺少字段: #{Enum.join(missing, ", ")}"}
    end
  end

  # ---------- 续期 ----------

  defp build_auth(bundle), do: from_bundle(encode_bundle(bundle))

  defp do_refresh_chain(bundle) do
    case refresh_vehicle_first(bundle) do
      {:ok, new_bundle} ->
        Logger.info("HIMA 凭据已续期（车辆 token）")
        clear_error()
        build_auth(new_bundle)

      {:error, v_error} ->
        # 10011 通常是 20 分钟 sessionKey 过期，先刷新用户会话再重试；
        # 只有 user/refresh 返回 10022（用户 refreshToken 失效）才需要重新登录。
        Logger.info("HIMA 车辆续期失败，先刷新用户会话: #{error_message(v_error)}")

        case refresh_user_then_vehicle(bundle) do
          {:ok, new_bundle} ->
            Logger.info("HIMA 凭据已续期（用户会话 + 车辆 token）")
            clear_error()
            build_auth(new_bundle)

          {:ok, new_bundle, :user_only} ->
            Logger.warning("HIMA 用户会话已续期；车辆 token 暂未续期，稍后重试")
            clear_error()
            build_auth(new_bundle)

          {:error, %Error{reason: :invalid_tokens} = u_error} ->
            cache_error(u_error)

          {:error, u_error} ->
            cache_error(%Error{
              reason: :unknown,
              message:
                "vehicle_refresh: #{error_message(v_error)} / user_refresh: #{error_message(u_error)}"
            })
        end
    end
  end

  defp cooldown?(bundle) do
    case normalize_expiry(bundle["vehicleTokenIssuedAt"]) do
      nil ->
        false

      issued ->
        System.system_time(:second) - issued < @issue_cooldown_seconds
    end
  end

  defp cooldown_reply(bundle) do
    now = System.system_time(:second)

    case vehicle_expiry(bundle) do
      expiry when is_integer(expiry) and expiry > now + 60 ->
        Logger.debug("HIMA 签发冷却中，复用现有车辆 token")
        build_auth(bundle)

      _ ->
        {:error, %Error{reason: :unknown, message: "HIMA 签发冷却中，稍后自动重试"}}
    end
  end

  defp cached_error do
    case :persistent_term.get(@error_key, nil) do
      {error, ts} ->
        if System.monotonic_time(:millisecond) - ts < @error_cooldown_ms do
          error
        else
          clear_error()
          nil
        end

      nil ->
        nil
    end
  end

  defp cache_error(%Error{} = error) do
    :persistent_term.put(@error_key, {error, System.monotonic_time(:millisecond)})
    {:error, error}
  end

  defp clear_error do
    :persistent_term.erase(@error_key)
    :ok
  end

  defp refresh_vehicle_first(bundle), do: refresh_vehicle(bundle)

  defp refresh_vehicle(bundle) do
    with {:ok, payload} <- Omp.vehicle_refresh(bundle),
         {:ok, token} <- extract_token(payload, bundle) do
      {:ok, apply_vehicle_refresh(bundle, token)}
    else
      {:error, reason} -> {:error, refresh_error(reason)}
    end
  end

  defp refresh_user_then_vehicle(bundle) do
    case Omp.user_refresh(bundle) do
      {:ok, user} ->
        bundle = apply_user_refresh(bundle, user)

        case maybe_kickout(bundle, user) do
          {:ok, bundle} ->
            Logger.info("HIMA 用户会话已续期，刷新车辆 token")
            refresh_vehicle_with_fallbacks(bundle)

          {:error, error} ->
            {:error, error}
        end

      {:error, reason} ->
        {:error, refresh_error(reason)}
    end
  end

  defp refresh_vehicle_with_fallbacks(bundle) do
    case refresh_vehicle(bundle) do
      {:ok, new_bundle} ->
        {:ok, new_bundle}

      {:error, %Error{reason: :session_expired} = v_error} ->
        Logger.warning("HIMA 车辆续期返回 10011，踢掉其他设备后重试")

        case kickout_and_retry(bundle) do
          {:ok, new_bundle} -> {:ok, new_bundle}
          {:error, retry_error} -> refresh_vehicle_auth_or_user_only(bundle, v_error, retry_error)
        end

      {:error, v_error} ->
        refresh_vehicle_auth_or_user_only(bundle, v_error, nil)
    end
  end

  defp refresh_vehicle_auth_or_user_only(bundle, v_error, retry_error) do
    Logger.warning(
      "HIMA 车辆 token 续期失败: #{error_message(v_error)}" <>
        if(retry_error, do: " / #{error_message(retry_error)}", else: "")
    )

    if auth_error?(v_error) or auth_error?(retry_error) do
      case issue_vehicle_auth(bundle) do
        {:ok, new_bundle} ->
          Logger.info("HIMA 车辆 token 已通过 vehicle/auth 重新签发")
          {:ok, new_bundle}

        {:error, a_error} ->
          Logger.warning("HIMA vehicle/auth 也失败: #{error_message(a_error)}；保留用户会话")
          {:ok, bundle, :user_only}
      end
    else
      # 网络/服务端临时错误：不要为了续期去顶掉其他设备，保留刚拿到的用户会话。
      {:ok, bundle, :user_only}
    end
  end

  defp auth_error?(%Error{reason: reason}),
    do: reason in [:invalid_tokens, :session_expired, :unauthorized]

  defp auth_error?(_), do: false

  defp kickout_and_retry(bundle) do
    case Omp.user_kickout(bundle) do
      {:ok, payload} ->
        bundle = apply_kickout(bundle, payload)
        refresh_vehicle(bundle)

      {:error, reason} ->
        {:error, refresh_error(reason)}
    end
  end

  defp issue_vehicle_auth(bundle) do
    with {:ok, payload} <- Omp.vehicle_auth(bundle),
         {:ok, token} <- extract_token(payload, bundle) do
      {:ok, apply_vehicle_refresh(bundle, token)}
    else
      {:error, reason} -> {:error, refresh_error(reason)}
    end
  end

  # user/refresh 返回 sessionKeyStatus=1 时，当前设备未受信；
  # 按用户授权踢掉其他在线设备，把会话转成受信。
  defp maybe_kickout(bundle, user) do
    if untrusted_session?(user) do
      Logger.warning("HIMA 会话未受信，踢掉其他在线设备")

      case Omp.user_kickout(bundle) do
        {:ok, payload} ->
          if untrusted_session?(payload) do
            {:error, %Error{reason: :session_expired, message: "user/kickout 后会话仍未受信"}}
          else
            {:ok, apply_kickout(bundle, payload)}
          end

        {:error, reason} ->
          {:error, refresh_error(reason)}
      end
    else
      {:ok, bundle}
    end
  end

  defp untrusted_session?(payload) do
    info =
      case payload do
        %{"userInfo" => %{} = info} -> info
        _ -> %{}
      end

    status = info["sessionKeyStatus"] || payload["sessionKeyStatus"]
    to_string(status || "") == "1"
  end

  defp apply_kickout(bundle, payload) do
    info =
      case payload do
        %{"userInfo" => %{} = info} -> info
        _ -> %{}
      end

    bundle
    |> put_present("sessionKey", payload["sessionKey"] || info["sessionKey"])
    |> put_present("userId", info["userId"] || payload["userId"])
  end

  defp extract_token(payload, bundle) do
    if is_map(payload) do
      cond do
        is_list(payload["vehicleTokenInfoList"]) ->
          case select_token(payload["vehicleTokenInfoList"], bundle) do
            nil -> {:error, :no_vehicle_token}
            token -> {:ok, token}
          end

        is_map(payload["vehicleTokenInfo"]) ->
          {:ok, payload["vehicleTokenInfo"]}

        is_binary(payload["accessToken"]) ->
          {:ok, payload}

        true ->
          {:error, :no_vehicle_token}
      end
    else
      {:error, :no_vehicle_token}
    end
  end

  defp select_token(tokens, bundle) do
    vehicle_id = bundle["vehicleId"]
    account_id = bundle["accountId"]
    enterprise = bundle["enterpriseCode"]

    Enum.find(tokens, &same_id?(&1["vehicleId"], vehicle_id)) ||
      Enum.find(tokens, &same_id?(&1["accountId"], account_id)) ||
      Enum.find(tokens, &(&1["enterpriseCode"] == enterprise)) ||
      List.first(tokens)
  end

  defp same_id?(nil, _expected), do: false
  defp same_id?(_actual, nil), do: false
  defp same_id?(actual, expected), do: to_string(actual) == to_string(expected)

  defp apply_user_refresh(bundle, user) do
    oauth = user["oauthToken"] || %{}

    bundle
    |> put_present("sessionKey", user["sessionKey"] || oauth["sessionKey"])
    |> put_present("userId", user["userId"] || get_in(user, ["userInfo", "userId"]))
    |> put_present("userAccessToken", oauth["accessToken"])
    |> put_present("userRefreshToken", oauth["refreshToken"])
    |> put_present("accountId", user["accountId"])
  end

  defp apply_vehicle_refresh(bundle, token) do
    access = token["accessToken"] || token["vehicleToken"]

    bundle
    |> put_present("enterpriseCode", token["enterpriseCode"])
    |> put_present("accountId", token["accountId"])
    |> put_present("vehicleAccessToken", access)
    |> put_present("vehicleTokenExpiresAt", token_expiry(token))
    |> mark_issued(access)
  end

  defp mark_issued(bundle, access) when is_binary(access) and access != "" do
    Map.put(bundle, "vehicleTokenIssuedAt", System.system_time(:second))
  end

  defp mark_issued(bundle, _access), do: bundle

  # `expiresAt` is an absolute timestamp; `expiresIn` (when present) is a
  # duration in seconds. Treating the latter as an epoch would schedule a
  # refresh every 45 seconds and hammer the token endpoint.
  defp token_expiry(token) do
    case normalize_expiry(token["expiresAt"]) do
      nil ->
        now = System.system_time(:second)

        case to_number(token["expiresIn"]) do
          n when is_number(n) and n > 10_000_000_000 -> div(trunc(n), 1000)
          n when is_number(n) and n > 0 -> now + trunc(n)
          _ -> now + @default_expires_in
        end

      expiry ->
        expiry
    end
  end

  defp to_number(value) when is_number(value), do: value

  defp to_number(value) when is_binary(value) do
    case Float.parse(value) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp to_number(_), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # ---------- 凭据包规范化 ----------

  # v1：{"version": 1, "vehicle": {...}, "account": {...}, "session": {...}}
  defp normalize_bundle(%{"version" => version} = bundle) when version in [1, "1"] do
    vehicle = bundle["vehicle"] || %{}
    account = bundle["account"] || %{}
    session = bundle["session"] || %{}

    nested =
      %{
        "enterpriseCode" => account["enterpriseCode"],
        "accountId" => account["accountId"],
        "vehicleAccessToken" => account["vehicleAccessToken"],
        "vehicleTokenExpiresAt" => account["vehicleTokenExpiresAt"],
        "vehicleId" => vehicle["id"] || vehicle["vehicleId"],
        "vehicleIdStr" => vehicle["idStr"] || vehicle["vehicleIdStr"],
        "vin" => vehicle["vin"],
        "plateNo" => vehicle["plateNo"],
        "vehicleName" => vehicle["name"] || vehicle["vehicleName"],
        "vehicleAliasName" => vehicle["aliasName"] || vehicle["vehicleAliasName"],
        "model" => vehicle["model"],
        "modelName" => vehicle["modelName"],
        "projectName" => vehicle["projectName"] || vehicle["marketingName"],
        "colorName" => vehicle["colorName"],
        "brandName" => vehicle["brandName"],
        "trimBadging" => vehicle["trimBadging"],
        "wheelType" => vehicle["wheelType"],
        "efficiency" => vehicle["efficiency"] || vehicle["avgEgyCnse"],
        "sessionKey" => session["sessionKey"],
        "userId" => session["userId"],
        "userAccessToken" => session["userAccessToken"],
        "userRefreshToken" => session["userRefreshToken"],
        "deviceId" => session["deviceId"],
        "deviceModel" => session["deviceModel"]
      }
      |> reject_blank()

    bundle
    |> Map.drop(["version", "vehicle", "account", "session"])
    |> Map.merge(nested)
  end

  defp normalize_bundle(%{} = bundle), do: bundle

  defp reject_blank(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  # ---------- 到期时间 ----------

  defp vehicle_expiry(bundle) do
    case normalize_expiry(bundle["vehicleTokenExpiresAt"]) do
      nil -> extract_cms_exp(bundle["vehicleAccessToken"])
      expiry -> expiry
    end
  end

  defp normalize_expiry(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> normalize_expiry(int)
      :error -> nil
    end
  end

  defp normalize_expiry(value) when is_number(value) and value > 0 do
    # 兼容毫秒时间戳
    if value > 10_000_000_000, do: div(trunc(value), 1000), else: trunc(value)
  end

  defp normalize_expiry(_), do: nil

  defp extract_cms_exp(token) when is_binary(token) and token != "" do
    with {:ok, der} <- decode_base64(token),
         {pos, _len} <- :binary.match(der, ~s("exp":)) do
      rest = binary_part(der, pos, byte_size(der) - pos)
      rest = binary_part(rest, 6, byte_size(rest) - 6)

      digits =
        rest
        |> :binary.bin_to_list()
        |> Enum.take_while(&(&1 in ?0..?9))
        |> List.to_string()

      case Integer.parse(digits) do
        {n, _} when n > 0 -> normalize_expiry(n)
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp extract_cms_exp(_), do: nil

  # ---------- 工具 ----------

  defp decode_base64(value) do
    cleaned = String.replace(value, ~r/\s+/, "")

    padded =
      cleaned <> String.duplicate("=", rem(4 - rem(byte_size(cleaned), 4), 4))

    case Base.decode64(padded) do
      {:ok, bin} ->
        {:ok, bin}

      :error ->
        cleaned
        |> String.replace("+", "-")
        |> String.replace("/", "_")
        |> Base.url_decode64(padding: false)
    end
  end

  defp present?(value), do: not is_nil(value) and value != ""

  defp refresh_error({:omp, 10022, _message}) do
    %Error{reason: :invalid_tokens, message: "凭据包已失效，请重新登录"}
  end

  # 10011 / 100011 / 100015 = sessionKey 过期或会话被注销，通常可先用
  # user/refresh 恢复；不要映射成 :invalid_tokens，否则 TeslaMate.Api 会清掉登录态。
  defp refresh_error({:omp, code, _message})
       when code in [10011, "10011", 100_011, "100011", 100_015, "100015"] do
    %Error{reason: :session_expired, message: "登录会话已过期，正在尝试刷新用户会话"}
  end

  defp refresh_error({:http, 401, _body}), do: %Error{reason: :unauthorized}

  defp refresh_error({:omp, code, message}) do
    %Error{reason: :unknown, message: "HIMA #{code}: #{message}"}
  end

  defp refresh_error({:http, status, _body}) do
    %Error{reason: :unknown, message: "HIMA HTTP #{status}"}
  end

  defp refresh_error(%Error{} = error), do: error
  defp refresh_error(reason), do: %Error{reason: :unknown, message: error_message(reason)}

  defp error_message(%Error{} = error), do: Exception.message(error)
  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: inspect(reason, limit: 3)
end
