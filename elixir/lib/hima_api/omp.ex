defmodule HimaApi.Omp do
  @moduledoc """
  鸿蒙智行车联网 HTTP 客户端（对应 Python 版 common.py）。

    * OMP 会话续期（user/refresh、vehicle/refresh、vehicle/auth）
    * 车辆云只读数据（车辆列表、dynamic-infos 状态查询）
    * 品牌路由（SERES→apig / CHERY→chssatsp / …）+ 各品牌 TLS 验证
      （池配置见 HimaApi.HTTP，运行时复用 TeslaMate.HTTP）
  """

  alias TeslaMate.HTTP, as: H

  import Bitwise

  require Logger

  @ua "X-Car-APP-Android-3.0.2.300"

  @omp "https://omp.uopes.cn"
  @vehicle_auth @omp <> "/xcar/omp/xbs/account/vehicle/auth"
  @user_refresh @omp <> "/xcar/omp/xbs/account/user/refresh"
  @user_kickout @omp <> "/xcar/omp/xbs/account/user/kickout"
  @vehicle_refresh @omp <> "/xcar/omp/xbs/account/vehicle/refresh"

  # 按品牌分组的车辆云地址（来自官方 APK assets/config.json）
  @brands %{
    "SERES" => "https://apig.fgaiservice.com",
    "CHERY" => "https://apir.chssatsp.icvcs.com",
    "BJEV" => "https://apir.bjevssa.icvcs.com",
    "JAC" => "https://apir.jacssa.icvcs.com",
    "SRIH" => "https://api-app.srih.icvcs.com"
  }

  # 官方 App 的 dynamic-infos 查询类别键（只读查询模式：body 全为空串）
  @dynamic_keys ~w(airConditionPlan charge departurePlan door fuel hvac lamp location
                   seat sentryPlan tire vehicleStatus warmCoolingBox welcome window)

  @doc "企业码 → 车辆云 base URL（未知品牌回退 SERES）。"
  def brand_host(enterprise) do
    ec = (enterprise || "SERES") |> String.upcase()

    Enum.find_value(@brands, Map.get(@brands, "SERES"), fn {key, host} ->
      if String.contains?(ec, key), do: host
    end)
  end

  @doc "设备 ID = 大写 SHA-256(稳定串)，同机多次运行一致。"
  def device_id do
    str = System.get_env("HIMA_DEVICE_STR", "teslamate-hima")

    :crypto.hash(:sha256, str)
    |> Base.encode16()
    |> String.upcase()
  end

  @doc "优先使用凭据包携带的设备 ID（与签发 token 时一致）。"
  def device_id(%{"deviceId" => id}) when is_binary(id) and id != "", do: id
  def device_id(_bundle), do: device_id()

  def device_model(%{"deviceModel" => model}) when is_binary(model) and model != "", do: model

  def device_model(_bundle) do
    System.get_env("HIMA_DEVICE_MODEL", "Pixel 7")
  end

  def device(bundle \\ %{}) do
    %{"type" => "1", "id" => device_id(bundle), "model" => device_model(bundle)}
  end

  @doc "OMP 请求头。"
  def omp_headers(opts \\ []) do
    [
      {"accept", "*/*"},
      {"accept-language", "zh-cn"},
      {"content-type", "application/json"},
      {"pkgname", "app.huawei.auto"},
      {"traceid", trace_id()},
      {"user-agent", @ua},
      {"xid", Keyword.get(opts, :session_key, "") || ""},
      {"uid", Keyword.get(opts, :user_id, "") || ""},
      {"ec", Keyword.get(opts, :ec, "") || ""},
      {"devicemodel", Keyword.get(opts, :device_model, "Pixel 7") || "Pixel 7"}
    ]
  end

  @doc "车辆云请求头。X-Created 必须用本地时间，UTC 会被网关判定异常并注销 token。"
  def ivcs_headers(token, vehicle_id, bundle \\ %{}) do
    {{y, mo, d}, {h, mi, s}} = :calendar.local_time()
    ms = rem(System.system_time(:millisecond), 1000)

    created =
      :io_lib.format("~4..0B~2..0B~2..0B~2..0B~2..0B~2..0B~3..0B", [
        y,
        mo,
        d,
        h,
        mi,
        s,
        ms
      ])
      |> IO.iodata_to_binary()

    headers = [
      {"authorization", token},
      {"x-nonce", uuid4()},
      {"x-created", created},
      {"x-device-id", device_id(bundle)},
      {"x-app-id", "0"},
      {"x-client-model", device_model(bundle)},
      {"x-client-language", "zh-Hans"},
      {"x-client-type", "2"},
      {"x-client-version", "HUAWEI_IVCS_APP_3.002.300"},
      {"accept", "*/*"},
      {"accept-language", "zh-Hans-CN;q=1"},
      {"content-type", "application/json"},
      {"user-agent", @ua}
    ]

    if vehicle_id, do: [{"x-vehicle-id", to_string(vehicle_id)} | headers], else: headers
  end

  # ---------- 会话续期（OMP） ----------

  @doc "用户会话续期：at/rt → 新 sessionKey + 新 oauthToken。需带当前会话的 xid/uid。"
  def user_refresh(%{"userAccessToken" => at, "userRefreshToken" => rt} = bundle) do
    body = %{"at" => at, "rt" => rt, "clientType" => "android", "device" => device(bundle)}

    headers =
      omp_headers(
        session_key: bundle["sessionKey"],
        user_id: bundle["userId"],
        ec: bundle["enterpriseCode"],
        device_model: device_model(bundle)
      )

    with {:ok, resp} <- request(:post, @user_refresh, headers, body),
         {:ok, payload} <- omp_payload(resp),
         {:ok, payload} <- validate_user_refresh(payload) do
      {:ok, payload}
    end
  end

  @doc "踢掉同账号其他在线设备，把 sessionKeyStatus 转为 0（手机端会掉线）。"
  def user_kickout(%{"sessionKey" => sk, "userId" => uid} = bundle) do
    headers =
      omp_headers(
        session_key: sk,
        user_id: uid,
        device_model: device_model(bundle)
      )

    with {:ok, resp} <-
           request(:post, @user_kickout, headers, %{"deviceInfo" => device(bundle)}) do
      omp_payload(resp)
    end
  end

  @doc "车辆 token 续期：靠 OMP 会话签发新 token（不直接传 refreshToken）。"
  def vehicle_refresh(%{"sessionKey" => sk, "userId" => uid, "enterpriseCode" => ec} = bundle) do
    body = %{"tokenType" => 1, "deviceInfo" => device(bundle), "requireAccountId" => false}

    headers =
      omp_headers(
        session_key: sk,
        user_id: uid,
        ec: ec,
        device_model: device_model(bundle)
      )

    with {:ok, resp} <- request(:post, @vehicle_refresh, headers, body) do
      omp_payload(resp)
    end
  end

  @doc "车辆认证：会话 → 该企业租户的车辆 token 列表（续期链路兜底）。"
  def vehicle_auth(%{"sessionKey" => sk, "userId" => uid, "enterpriseCode" => ec} = bundle) do
    headers =
      omp_headers(
        session_key: sk,
        user_id: uid,
        ec: ec,
        device_model: device_model(bundle)
      )

    with {:ok, resp} <- request(:post, @vehicle_auth, headers, %{"deviceInfo" => device(bundle)}) do
      omp_payload(resp)
    end
  end

  # ---------- 车辆云只读数据 ----------

  @doc "账户车辆列表（车辆 token 作用域 = 该品牌租户）。"
  def vehicles_list(%{"vehicleAccessToken" => token, "enterpriseCode" => ec} = bundle) do
    request(
      :get,
      brand_host(ec) <> "/vcam/v1/accounts/vehicles",
      ivcs_headers(token, nil, bundle)
    )
    |> ivcs_list()
  end

  @doc "车辆管理列表（OMP）：含车型/颜色/项目等档案信息；仅列表阶段兜底使用。"
  def vehicle_management_list(%{"sessionKey" => sk, "userId" => uid} = bundle) do
    headers =
      omp_headers(
        session_key: sk,
        user_id: uid,
        device_model: device_model(bundle)
      )

    body = %{"refreshFlag" => false, "deviceInfo" => device(bundle)}

    with {:ok, resp} <-
           request(:post, @omp <> "/xcar/omp/xbs/vehicle/management/list", headers, body) do
      omp_payload(resp)
    end
  end

  @doc "实时状态快照（官方查询模式：15 个类别键全空串）。"
  def dynamic_infos(%{"vehicleAccessToken" => token, "enterpriseCode" => ec} = bundle, vehicle_id) do
    body = Map.new(@dynamic_keys, &{&1, ""})

    request(
      :post,
      brand_host(ec) <> "/vctrl/v2/controls/dynamic-infos",
      ivcs_headers(token, vehicle_id, bundle),
      body
    )
    |> ivcs_payload()
  end

  # ---------- 内部 ----------

  defp omp_payload(body) when is_map(body) do
    if body["code"] in [0, 200] do
      case body["data"] do
        data when is_map(data) and map_size(data) > 0 -> {:ok, data}
        _ -> {:ok, body}
      end
    else
      {:error, {:omp, body["code"], body["msg"] || body["resultCode"]}}
    end
  end

  defp omp_payload(other), do: {:error, {:unexpected, other}}

  defp ivcs_list({:ok, %{"data" => list}}) when is_list(list), do: {:ok, list}
  defp ivcs_list({:ok, list}) when is_list(list), do: {:ok, list}

  defp ivcs_list({:ok, %{"code" => code} = body})
       when code in [100_011, "100011", 10011, "10011"] do
    {:error, {:omp, code, body["msg"] || body["message"]}}
  end

  defp ivcs_list({:ok, other}), do: {:error, {:unexpected, other}}
  defp ivcs_list({:error, reason}), do: {:error, reason}

  defp ivcs_payload({:ok, %{"data" => data}}) when is_map(data) and map_size(data) > 0,
    do: {:ok, data}

  defp ivcs_payload({:ok, %{"code" => code} = body})
       when code in [100_011, "100011", 10011, "10011"] do
    {:error, {:omp, code, body["msg"] || body["message"]}}
  end

  defp ivcs_payload({:ok, body}), do: {:ok, body}
  defp ivcs_payload({:error, reason}), do: {:error, reason}

  defp request(method, url, headers, body \\ nil) do
    req =
      if body do
        Finch.build(method, url, headers, Jason.encode!(body))
      else
        Finch.build(method, url, headers)
      end

    case Finch.request(req, H) do
      {:ok, %Finch.Response{status: status, body: resp_body}} when status in 200..299 ->
        case Jason.decode(resp_body) do
          {:ok, json} -> {:ok, json}
          _ -> {:ok, resp_body}
        end

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        if status == 401, do: Logger.warning("HIMA OMP 401")
        {:error, {:http, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_user_refresh(%{"sessionKey" => sk, "oauthToken" => %{}} = payload)
       when is_binary(sk) and sk != "",
       do: {:ok, payload}

  defp validate_user_refresh(_), do: {:error, :invalid_user_refresh_response}

  defp uuid4 do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0B-~4.16.0B-~4.16.0B-~4.16.0B-~12.16.0B", [
      a,
      b,
      c ||| (0x4000 &&& 0xFFFF),
      d ||| (0x8000 &&& 0xFFFF),
      e
    ])
    |> IO.iodata_to_binary()
    |> String.upcase()
  end

  defp trace_id do
    seq = :rand.uniform(100_000) - 1
    ms = rem(System.system_time(:millisecond), 1000)
    rnd = for _ <- 1..4, into: "", do: <<Enum.random(?A..?Z)>> <> ""

    seq
    |> Integer.to_string()
    |> String.pad_leading(5, "0")
    |> Kernel.<>(ms |> Integer.to_string() |> String.pad_leading(3, "0"))
    |> Kernel.<>(rnd)
  end
end
