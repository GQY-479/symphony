Application.put_env(
  :symphony_elixir,
  :workflow_file_path,
  "/mnt/c/Users/GQY47/coding/Symphony/elixir/WORKFLOW.local.md"
)

Application.put_env(:symphony_elixir, :server_port_override, 4002)

{:ok, _} = Application.ensure_all_started(:symphony_elixir)

Process.sleep(:infinity)
