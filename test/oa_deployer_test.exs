defmodule OaDeployerTest do
  use ExUnit.Case

  defmodule SuccessHttpMock do
    def post(url, _body, headers, _opts) do
      auth_url = Application.get_env(:oa_deployer, :oauth_url)
      case url do
        ^auth_url ->
          {:ok, %HTTPoison.Response{status_code: 200, body: "{\"access_token\":\"abc123\"}"}}
        "http://myoaserver.co/workflows" ->
          assert OaDeployer.get_header(headers, "Authorization") == "Bearer access_token=abc123"
          {:ok, %HTTPoison.Response{status_code: 201, headers: [{"location", "abc123/workflows/12345"}]}}
        "http://myoaserver.co/workflows/12345/execute" ->
          assert OaDeployer.get_header(headers, "Authorization") == "Bearer access_token=abc123"
          {:ok, %HTTPoison.Response{status_code: 202}}
      end
    end

    def get(_url, headers, _opts) do
      assert OaDeployer.get_header(headers, "Authorization") == "Bearer access_token=abc123"
      {:ok, %HTTPoison.Response{status_code: 200, body: "{\"workflow_completed\":true,\"workflow_error\":false}"}}
    end
  end

  test "Success" do
    assert OaDeployer._main(["-a", "build", "-s", "http://myoaserver.co", "http://mygithubrepo.com"], SuccessHttpMock) == "12345"
  end

  defmodule AuthFailureHttpMock do
    def post(_url, _body, _headers, _opts), do: {:ok, %HTTPoison.Response{status_code: 401}}
  end

  test "Auth Failure" do
    assert_raise RuntimeError, "Failed to retrieve OAuth header: Status code: 401",
      fn -> OaDeployer._main(["-a", "build", "-s", "http://myoaserver.co", "http://mygithubrepo.com"], AuthFailureHttpMock) end
  end

  defmodule OaFailureHttpMock do
    def post(url, _body, headers, _opts) do
      auth_url = Application.get_env(:oa_deployer, :oauth_url)
      case url do
        ^auth_url ->
          {:ok, %HTTPoison.Response{status_code: 200, body: "{\"access_token\":\"abc123\"}"}}
        "http://myoaserver.co/workflows" ->
          assert OaDeployer.get_header(headers, "Authorization") == "Bearer access_token=abc123"
          {:error, %HTTPoison.Error{reason: "bad news bears"}}
      end
    end
  end

  test "oa server error" do
    assert_raise RuntimeError, "Workflow Creation Request Failed: (\"bad news bears\")",
      fn -> OaDeployer._main(["-a", "build", "-s", "http://myoaserver.co", "http://mygithubrepo.com"], OaFailureHttpMock) end
  end
end
