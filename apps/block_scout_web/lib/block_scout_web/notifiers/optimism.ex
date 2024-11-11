defmodule BlockScoutWeb.Notifiers.Optimism do
  @moduledoc """
  Module to handle and broadcast OP related events.
  """

  alias BlockScoutWeb.Endpoint

  require Logger

  def handle_event({:chain_event, :new_optimism_batches, :realtime, batches}) do
    batches
    |> Enum.sort_by(& &1.internal_id, :asc)
    |> Enum.each(fn batch ->
      Endpoint.broadcast("optimism:new_batch", "new_optimism_batch", %{
        batch: batch
      })
    end)
  end

  def handle_event({:chain_event, :new_optimism_deposits, :realtime, deposits}) do
    deposits_count = Enum.count(deposits)

    Endpoint.broadcast("optimism:new_deposits", "new_optimism_deposits", %{
      deposits: deposits_count
    })

    Endpoint.broadcast("optimism_deposits:new_deposits", "deposits", %{
      deposits: deposits_count
    })
  end

  def handle_event(event) do
    Logger.warning("Unknown broadcasted event #{inspect(event)}.")
    nil
  end
end
