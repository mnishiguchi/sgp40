defmodule SGP40.VocIndex do
  @moduledoc """
  Process the raw output of the SGP40 sensor into the VOC Index.
  """

  use GenServer, restart: :permanent

  require Logger

  @doc """
  Initialize the VOC algorithm parameters. Call this once at the beginning or
  whenever the sensor stopped measurements.
  """
  @spec start_link(any) :: GenServer.on_start()
  def start_link(_args \\ []) do
    case GenServer.start_link(__MODULE__, nil, name: __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      # Stop this process and let the supervisor restart so that we can
      # re-initialize the VOC algorithm.
      {:error, {:already_started, pid}} -> GenServer.stop(pid, :normal)
    end
  end

  @doc """
  Calculate the VOC index value from the raw sensor value.
  """
  @spec process(0..0xFFFF) :: {:ok, 1..500} | {:error, any}
  def process(sraw) do
    GenServer.call(__MODULE__, {:process, sraw})
  end

  @doc """
  Get current algorithm states. Retrieved values can be used in
  `set_states/1` to resume operation after a short interruption,
  skipping initial learning phase. This feature can only be used after at least
  3 hours of continuous operation.
  """
  @spec get_states :: {:ok, %{mean: integer, std: integer}} | {:error, any}
  def get_states() do
    GenServer.call(__MODULE__, :get_states)
  end

  @doc """
  Set previously retrieved algorithm states to resume operation after a short
  interruption, skipping initial learning phase. This feature should not be
  used after inerruptions of more than 10 minutes. Call this once after
  `start_link/1` and the optional `set_tuning_params/1`, if
  desired. Otherwise, the algorithm will start with initial learning phase.
  """
  @spec set_states(%{mean: integer, std: integer}) :: {:ok, binary} | {:error, any}
  def set_states(args) do
    GenServer.call(__MODULE__, {:set_states, args})
  end

  @doc """
  Set parameters to customize the VOC algorithm. Call this once after
  `start_link/1`, if desired. Otherwise, the default values will be used.
  """
  @spec set_tuning_params(%{
          required(:voc_index_offset) => 0..0x7FFF_FFFF,
          required(:learning_time_hours) => 0..0x7FFF_FFFF,
          required(:gating_max_duration_minutes) => 0..0x7FFF_FFFF,
          required(:std_initial) => 0..0x7FFF_FFFF
        }) :: {:ok, binary} | {:error, any}
  def set_tuning_params(args) do
    GenServer.call(__MODULE__, {:set_tuning_params, args})
  end

  @impl GenServer
  @spec init(any) :: {:ok, %{port: port}}
  def init(_args) do
    port =
      Port.open({:spawn_executable, executable_filename()}, [
        {:args, []},
        {:line, 1024},
        :use_stdio,
        :stderr_to_stdout,
        :exit_status
      ])

    {:ok, %{port: port}}
  end

  defp executable_filename do
    :code.priv_dir(:sgp40) |> Path.join("sgp40") |> String.to_charlist()
  end

  @impl GenServer
  def handle_call({:process, sraw}, _, state) do
    command = "process #{sraw}\n"

    case send_port_command(state.port, command) do
      {:ok, vox_index} ->
        {:reply, {:ok, String.to_integer(vox_index)}, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_call(:get_states, _, state) do
    command = "get_states\n"

    case send_port_command(state.port, command) do
      {:ok, data} ->
        ["mean:" <> mean, "std:" <> std] = String.split(String.trim(data), ",", trim: true)
        parsed = %{mean: String.to_integer(mean), std: String.to_integer(std)}
        {:reply, {:ok, parsed}, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_call({:set_states, %{mean: _, std: _} = args}, _, state) do
    command = "set_states #{args.mean} #{args.std}\n"
    result = send_port_command(state.port, command)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_call(
        {:set_tuning_params,
         %{
           voc_index_offset: _,
           learning_time_hours: _,
           gating_max_duration_minutes: _,
           std_initial: _
         } = args},
        _,
        state
      ) do
    stringified_args =
      [
        "#{args.voc_index_offset}",
        "#{args.learning_time_hours}",
        "#{args.gating_max_duration_minutes}",
        "#{args.std_initial}"
      ]
      |> Enum.join(" ")

    command = "tuning_params #{stringified_args}\n"
    result = send_port_command(state.port, command)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_info({_port, {:exit_status, exit_status}}, state) do
    {:stop, "SGP40 OS process died with status: #{inspect(exit_status)}", state}
  end

  #
  # Private Helpers
  #

  defp send_port_command(port, command) do
    Port.command(port, command)
    receive_from_port(port)
  end

  defp receive_from_port(port) do
    receive do
      {^port, {:data, {_, 'OK: ' ++ response}}} ->
        {:ok, to_string(response)}

      {^port, {:data, {_, 'OK'}}} ->
        :ok

      {^port, {:data, {_, 'ERR: ' ++ response}}} ->
        {:error, to_string(response)}

      {^port, {:exit_status, exit_status}} ->
        raise "SGP40 OS process died with status: #{inspect(exit_status)}"
    after
      500 -> raise "timeout waiting for SGP40 OS process to reply"
    end
  end
end
