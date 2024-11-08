defmodule Indexer.Fetcher.Arbitrum.DataBackfill do
  use Indexer.Fetcher, restart: :transient
  use Spandex.Decorators

  import Indexer.Fetcher.Arbitrum.Utils.Logging, only: [log_warning: 1]

  require Logger

  alias Indexer.BufferedTask
  alias Indexer.Fetcher.Arbitrum.Utils.Db, as: ArbitrumDbUtils
  alias Indexer.Fetcher.Arbitrum.Workers.Backfill

  @behaviour BufferedTask

  # Will do one block range at a time
  @default_max_batch_size 1
  @default_max_concurrency 1

  # the flush interval is small enought to pickup the next block range or retry
  # the same block range without with low latency. In case if retry must happen
  # due to unindexed blocks discovery, run callback will have its own timer
  # management to make sure that the same unindexed block range is not tried to
  # be processed multiple times during short period of time
  @flush_interval :timer.seconds(2)

  def child_spec([init_options, gen_server_options]) do
    {json_rpc_named_arguments, mergeable_init_options} = Keyword.pop(init_options, :json_rpc_named_arguments)

    unless json_rpc_named_arguments do
      raise ArgumentError,
            ":json_rpc_named_arguments must be provided to `#{__MODULE__}.child_spec` " <>
              "to allow for json_rpc calls when running."
    end

    indexer_first_block = Application.get_all_env(:indexer)[:first_block]
    rollup_chunk_size = Application.get_all_env(:indexer)[Indexer.Fetcher.Arbitrum][:rollup_chunk_size]
    backfill_blocks_depth = Application.get_all_env(:indexer)[__MODULE__][:backfill_blocks_depth]
    recheck_interval = Application.get_all_env(:indexer)[__MODULE__][:recheck_interval]

    buffered_task_init_options =
      defaults()
      |> Keyword.merge(mergeable_init_options)
      |> Keyword.merge(
        state: %{
          config: %{
            rollup_rpc: %{
              json_rpc_named_arguments: json_rpc_named_arguments,
              chunk_size: rollup_chunk_size,
              first_block: indexer_first_block
            },
            backfill_blocks_depth: backfill_blocks_depth,
            recheck_interval: recheck_interval
          }
        }
      )

    Supervisor.child_spec({BufferedTask, [{__MODULE__, buffered_task_init_options}, gen_server_options]},
      id: __MODULE__
    )
  end

  def handle_info(:request_shutdown, state) do
    {:stop, :normal, state}
  end

  # init callback will wait for appearance of the first new indexed block in the
  # database, adds to the buffer the block number predcesing the indexed one
  # and finishes.

  @impl BufferedTask
  def init(initial, reducer, _) do
    time_of_start = DateTime.utc_now()

    reducer.({:wait_for_new_block, time_of_start}, initial)
  end

  @impl BufferedTask
  def run(entries, state)

  def run([{:wait_for_new_block, time_of_start}], _) do
    case ArbitrumDbUtils.closest_block_after_timestamp(time_of_start) do
      {:ok, block} ->
        BufferedTask.buffer(__MODULE__, [{:backfill, {0, block - 1}}], false)
        :ok

      {:error, _} ->
        :retry
    end
  end

  def run([{:backfill, {timeout, end_block}}], state) do
    now = DateTime.to_unix(DateTime.utc_now(), :millisecond)

    if timeout > now do
      :retry
    else
      case Backfill.discover_blocks(end_block, state) do
        {:ok, start_block} ->
          if start_block >= state.config.rollup_rpc.first_block do
            BufferedTask.buffer(__MODULE__, [{:backfill, {0, start_block - 1}}], false)
            :ok
          else
            # will it work?
            GenServer.stop(__MODULE__, :normal)
            :ok
          end

        {:error, :discover_blocks_error} ->
          :retry

        {:error, :not_indexed_blocks} ->
          {:retry, [{:backfill, {now + state.recheck_interval, end_block}}]}
      end
    end
  end

  def run(entries, _) do
    log_warning("Unexpected entry in buffer: #{inspect(entries)}")
    :retry
  end

  # Following outcomes of run callback are possible depending on the result of Indexer.Fetcher.Arbitrum.Workers.Backfill.discover_blocks:
  # - {:ok, end_block} ->
  #   - add to the buffer the tuple with 0 as timeout and the end block of the next block range to process
  # - {:error, :discover_blocks_error} ->
  #   - return retry to re-process the same block range
  # - {:error, :not_indexed_blocks} ->
  #   - return retry but the task is redefined to have the timeout adjusted by recheck interval

  defp defaults do
    [
      flush_interval: @flush_interval,
      max_concurrency: @default_max_concurrency,
      max_batch_size: @default_max_batch_size,
      poll: false,
      task_supervisor: __MODULE__.TaskSupervisor,
      metadata: [fetcher: :data_backfill]
    ]
  end
end