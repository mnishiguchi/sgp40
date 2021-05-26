defmodule SGP40 do
  @moduledoc """
  Use Sensirion SGP40 air quality sensor in Elixir
  """

  use GenServer, restart: :transient

  require Logger

  @typedoc """
  SGP40 GenServer start_link options
  * `:name` - A name for the `GenServer`
  * `:bus_name` - Which I2C bus to use (defaults to `"i2c-1"`)
  * `:bus_address` - The address of the SGP40 (defaults to `0x59`)
  * `:humidity_rh` - Relative humidity in percent for compensation
  * `:temperature_c` - Temperature in degree Celsius for compensation
  """
  @type options() ::
          [
            {:name, GenServer.name()}
            | {:bus_name, bus_name}
            | {:bus_address, bus_address}
            | {:humidity_rh, number}
            | {:temperature_c, number}
          ]

  @type bus_name :: binary
  @type bus_address :: 0..127

  defmodule State do
    @moduledoc false
    defstruct [:humidity_rh, :last_measurement, :serial_id, :temperature_c, :transport]
  end

  @default_bus_name "i2c-1"
  @default_bus_address 0x59
  @polling_interval_ms 1000
  @default_humidity_rh 50
  @default_temperature_c 25

  @doc """
  Start a new GenServer for interacting with the SGP40 sensor.
  Normally, you'll want to pass the `:bus_name` option to specify the I2C
  bus going to the SGP40.
  """
  @spec start_link(options()) :: GenServer.on_start()
  def start_link(init_arg \\ []) do
    name = Keyword.get(init_arg, :name)
    GenServer.start_link(__MODULE__, init_arg, name: name)
  end

  @doc """
  Measure the current air quality.
  """
  @spec measure(GenServer.server()) :: {:ok, integer} | {:error, any}
  def measure(server \\ __MODULE__) do
    GenServer.call(server, :measure)
  end

  @doc """
  Update relative ambient humidity (RH %) and ambient temperature (degree C)
  for the humidity compensation.
  """
  @spec update_rht(GenServer.server(), number, number) :: :ok
  def update_rht(server \\ __MODULE__, humidity_rh, temperature_c)
      when is_number(humidity_rh) and is_number(temperature_c) do
    GenServer.cast(server, {:update_rht, humidity_rh, temperature_c})
  end

  @impl GenServer
  def init(init_arg) do
    bus_name = Keyword.get(init_arg, :bus_name, @default_bus_name)
    bus_address = Keyword.get(init_arg, :bus_address, @default_bus_address)
    humidity_rh = Keyword.get(init_arg, :humidity_rh, @default_humidity_rh)
    temperature_c = Keyword.get(init_arg, :temperature_c, @default_temperature_c)

    Logger.info(
      "[SGP40] Starting on bus #{bus_name} at address #{inspect(bus_address, base: :hex)}"
    )

    case SGP40.Transport.I2C.start_link(bus_name: bus_name, bus_address: bus_address) do
      {:ok, transport} ->
        {:ok, serial_id} = SGP40.Comm.serial_id(transport)

        state = %State{
          humidity_rh: humidity_rh,
          last_measurement: nil,
          serial_id: serial_id,
          temperature_c: temperature_c,
          transport: transport
        }

        {:ok, state, {:continue, :init_sensor}}

      _error ->
        {:stop, :device_not_found}
    end
  end

  @impl GenServer
  def handle_continue(:init_sensor, state) do
    Logger.info("[SGP40] Initializing sensor #{state.serial_id}")

    state = read_and_maybe_put_measurement(state)
    Process.send_after(self(), :schedule_measurement, @polling_interval_ms)

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:schedule_measurement, state) do
    state = read_and_maybe_put_measurement(state)
    Process.send_after(self(), :schedule_measurement, @polling_interval_ms)

    {:noreply, state}
  end

  defp read_and_maybe_put_measurement(state) do
    with {:ok, sraw} <-
           SGP40.Comm.measure_raw_with_rht(
             state.transport,
             state.humidity_rh,
             state.temperature_c
           ),
         {:ok, voc_index} <- SGP40.VocIndex.process(sraw) do
      timestamp_ms = System.monotonic_time(:millisecond)
      measurement = %SGP40.Measurement{timestamp_ms: timestamp_ms, voc_index: voc_index}

      %{state | last_measurement: measurement}
    else
      {:error, reason} ->
        Logger.error("[SGP40] Measurement failed: #{inspect(reason)}")
        state
    end
  end

  @impl GenServer
  def handle_call(:measure, _from, state) do
    {:reply, {:ok, state.last_measurement}, state}
  end

  @impl GenServer
  def handle_cast({:update_rht, humidity_rh, temperature_c}, state) do
    state = %{state | humidity_rh: humidity_rh, temperature_c: temperature_c}

    {:noreply, state}
  end

  defdelegate get_states, to: SGP40.VocIndex
  defdelegate set_states(args), to: SGP40.VocIndex
  defdelegate set_tuning_params(args), to: SGP40.VocIndex
end
