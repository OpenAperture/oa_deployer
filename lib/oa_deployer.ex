defmodule OaDeployer do
  alias OaDeployer.Util

  @spec main([String.t]) :: String.t
  def main(args) do
    try do
      _main(args)
    rescue
      e in RuntimeError ->
        IO.puts "\n#{inspect e}"
        exit({:shutdown, 1})
    end
  end

  @spec _main([String.t], atom) :: String.t
  def _main(args, http \\ HTTPoison) do
    {parsed_args, project_repo_list, _} = OptionParser.parse(args,
      strict: [action: :string, server_url: :string, hash: :string, branch: :string],
      aliases: [a: :action, s: :server_url, h: :hash, n: :branch])
    milestones = case Keyword.get(parsed_args, :action, nil) do
      "build"      -> ["build"]
      "deploy"     -> ["build", "deploy"]
      "deploy_ecs" -> ["build", "deploy_ecs"]
      action       -> Util.exit_with_error "Invalid action: #{action}"
    end
    oa_url = case Keyword.get(parsed_args, :server_url, nil) do
      nil -> "https://openaperture-mgr.psft.co"
      url -> url
    end
    auth_request_json = %{
      grant_type: "client_credentials",
      client_id: Application.get_env(:oa_deployer, :oauth_user),
      client_secret: Application.get_env(:oa_deployer, :oauth_pass)
    }
    |> Poison.encode
    |> case do
      {:error, reason} -> Util.exit_with_error "Failed to encode payload: #{inspect reason}"
      {:ok, json} -> json
    end
    headers = [{"Content-Type", "application/json"}]
    auth_token = case http.post(Application.get_env(:oa_deployer, :oauth_url), auth_request_json, headers, []) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}}      -> Poison.decode!("#{body}")["access_token"]
      {:ok, %HTTPoison.Response{status_code: s_code}}   -> Util.exit_with_error "Failed to retrieve OAuth header: Status code: #{s_code}"
      {:error, %HTTPoison.Error{id: _, reason: reason}} -> Util.exit_with_error "Failed to retrieve OAuth header: #{inspect reason}"
    end

    workflow_request = %{deployment_repo: List.first(project_repo_list),
                         deployment_repo_git_ref: Keyword.get(parsed_args, :branch, "master"),
                         source_repo_git_ref: Keyword.get(parsed_args, :hash, nil),
                         milestones: milestones}
    workflow_json = case Poison.encode(workflow_request) do
      {:error, reason} -> Util.exit_with_error "Failed to encode payload: #{inspect reason}"
      {:ok, json} -> json
    end

    headers = [{"Authorization", "Bearer access_token=#{auth_token}"}, {"Content-Type", "application/json"}]
    workflow_id = case http.post("#{oa_url}/workflows", workflow_json, headers, []) do
      {:ok, %HTTPoison.Response{status_code: 201, headers: headers}}      -> headers |> get_header("location") |> Util.after_last_forward_slash
      {:ok, %HTTPoison.Response{status_code: 401}}      -> Util.exit_with_error "Authentication error (401) contacting server"
      {:ok, %HTTPoison.Response{status_code: s_code}}   -> Util.exit_with_error "Workflow Creation Request Failed - Status code: #{s_code}"
      {:error, %HTTPoison.Error{reason: reason}} -> Util.exit_with_error "Workflow Creation Request Failed: (#{inspect reason})"
    end
    IO.puts "Created workflow #{workflow_id}"
    execute_json = case Poison.encode(%{force_build: false}) do
      {:error, reason} -> Util.exit_with_error "Failed to encode payload: #{inspect reason}"
      {:ok, json} -> json
    end

    case http.post("#{oa_url}/workflows/#{workflow_id}/execute", execute_json, headers, []) do
      {:ok, %HTTPoison.Response{status_code: 202}}      -> nil
      {:ok, %HTTPoison.Response{status_code: 204}}      -> nil
      {:ok, %HTTPoison.Response{status_code: 401}}      -> Util.exit_with_error "Authentication error (401) contacting server"
      {:ok, %HTTPoison.Response{status_code: s_code}}   -> Util.exit_with_error "Workflow Execution Request Failed - Status code: #{s_code}"
      {:error, %HTTPoison.Error{id: _, reason: reason}} -> Util.exit_with_error "Workflow Execution Request Failed - unexpected return code from server:  (#{inspect reason})"
    end
    IO.puts "Workflow #{workflow_id} execution started"
    check_until_complete(oa_url, auth_token, workflow_id, 0, 0, nil, http)
  end

  @spec check_until_complete(String.t, String.t, String.t, integer, integer, String.t :: nil, atom) :: String.t
  defp check_until_complete(oa_url, auth_token, workflow_id, error_count, timeout_cnt, current_step, http) do
    endpoint = "#{oa_url}/workflows/#{workflow_id}"
    case http.get(endpoint, [{"Authorization", "Bearer access_token=#{auth_token}"}]) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        response = Poison.decode!(body)
        case {response["workflow_completed"], response["workflow_error"]} do
          {true, false} ->
            IO.puts("Completed milestone #{current_step} in #{response["workflow_step_durations"][current_step]}")
            IO.puts "Workflow #{workflow_id} Completed"
            workflow_id
          {true, true}  ->
            workflow_error_msg = case response["workflow_error"] do
              nil -> ""
              _   -> response["event_log"] |> Poison.decode! |> Enum.reduce "", &"#{&2}\n#{&1}"
            end
            Util.exit_with_error "Failed on milestone milestone #{response["current_step"]} in #{response["elapsed_workflow_time"]}:\n\nWorkflow Log\n-----\n#{workflow_error_msg}"
          _ ->
            case response["current_step"] do
              ""   -> IO.puts("Workflow has been created, but not started: #{inspect response["workflow_step_durations"]}, #{inspect response["current_step"]}...")
              curr ->
                case current_step do
                  nil   -> IO.puts("Started milestone #{curr}")
                  ^curr -> IO.puts("Milestone #{curr} in progress...")
                  _     -> IO.puts("Completed milestone #{current_step} in #{response["workflow_step_durations"][current_step]}, starting milestone #{curr}")
                end
            end
            case timeout_cnt do
              x when x < 120 ->
                :timer.sleep 10000
                check_until_complete(oa_url, auth_token, workflow_id, 0, timeout_cnt+1, response["current_step"], http)
              _ -> Util.exit_with_error "Failed - a timeout has occurred"
            end
        end

      {:ok, %HTTPoison.Response{status_code: status_code}} ->
        case error_count do
          5 -> Util.exit_with_error "#{endpoint} status code: #{status_code}"
          _ ->
            IO.puts "#{endpoint} returned an http status of #{status_code}, retrying..."
            :timer.sleep 5000
            check_until_complete(oa_url, auth_token, workflow_id, error_count+1, timeout_cnt+1, current_step, http)
        end
      {:error, %HTTPoison.Error{id: _, reason: reason}} ->
        case error_count do
          5 -> Util.exit_with_error "#{endpoint} error: #{inspect reason}"
          _ ->
            IO.puts "#{endpoint} has failed: #{inspect reason}, retrying"
            :timer.sleep 5000
            check_until_complete(oa_url, auth_token, workflow_id, error_count+1, timeout_cnt+1, current_step, http)
        end
    end
  end

  @spec get_header(list, String.t) :: String.t
  def get_header(headers, key) do
    headers
    |> Enum.filter(fn({k, _}) -> k == key end)
    |> hd
    |> elem(1)
  end

end
