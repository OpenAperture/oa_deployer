defmodule OaDeployer.Util do
  
  def after_last_forward_slash(str) do
    String.split(str, ~r{/}) |> List.last
  end

  def exit_with_error(error) do
    raise error
  end

  def exit_with_success(msg) do
    IO.puts "\n#{msg}"
    #exit(:normal)
  end
end