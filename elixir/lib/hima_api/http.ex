defmodule HimaApi.HTTP do
  @moduledoc """
  鸿蒙智行车辆云的 Finch 池配置。

  信任锚 = 各品牌 CA（来自官方 APK 内置证书，priv/hima_certs/）。
  车辆云（apig.fgaiservice.com / *.icvcs.com）只发叶子证书、中间 CA 不公开，
  因此不能用系统根证书验证——用品牌 CA 作为信任锚正是官方 App 的信任模型。

  这里只提供池配置，由 `TeslaMate.HTTP` 在启动时合并，不单独启动进程。
  OMP（omp.uopes.cn）使用公共证书链，走默认池。
  """

  @brand_hosts ~w(
    https://apig.fgaiservice.com
    https://apir.chssatsp.icvcs.com
    https://apir.bjevssa.icvcs.com
    https://apir.jacssa.icvcs.com
    https://api-app.srih.icvcs.com
  )

  @ca_files ~w(brand-seres.pem brand-chery.pem brand-bjev.pem brand-jac.pem brand-saic.pem)

  @doc "全部品牌 CA 证书（DER 列表），作为 TLS 信任锚。"
  def cacerts do
    dir = Application.app_dir(:teslamate, "priv/hima_certs")

    certs =
      @ca_files
      |> Enum.map(&Path.join(dir, &1))
      |> Enum.filter(&File.exists?/1)
      |> Enum.flat_map(fn file ->
        file
        |> File.read!()
        |> :public_key.pem_decode()
        |> Enum.map(fn {_, cert, _} -> cert end)
      end)

    case certs do
      [] -> raise "HIMA CA 证书缺失，请检查 #{dir}"
      certs -> certs
    end
  end

  @doc "品牌车辆云的 Finch 池配置（合并进 TeslaMate.HTTP）。"
  def pools do
    conn_opts = [conn_opts: [transport_opts: [cacerts: cacerts()]]]
    Map.new(@brand_hosts, &{&1, conn_opts})
  end
end
