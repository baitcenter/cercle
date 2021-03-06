defmodule CercleApi.CardService do
  @moduledoc """
  Service to handle card events
  """

  use CercleApi.Web, :model
  alias CercleApi.{Repo, Card, Board, Contact, TimelineEvent}

  def payload_data(card) do
    board = Repo.get(Board, card.board_id)
    %{
      id: card.id,
      name: card.name,
      status: card.status,
      board: %{
        id: board.id,
        name: board.name
      },
      contacts: contacts_payload(card)
    }
  end

  def event_payload(card, data \\ %{}) do
    with card <- Repo.preload(card, [:board, :board_column]),
           do: Map.merge(data,
                 %{
                   id: card.id,
                   name: card.name,
                   status: card.status,
                   board: %{id: card.board.id, name: card.board.name},
                   board_column: %{
                     id: card.board_column.id,
                     name: card.board_column.name
                   },
                   contacts: contacts_payload(card)
                 })
  end

  def contacts_payload(card) do
    Enum.map(Card.contacts(card), fn(c) ->
      %{id: c.id, first_name: c.first_name, last_name: c.last_name}
    end)
  end

  def event_changeset(user, event, card, metadata \\ %{}) do
    with contact_id <- List.first(card.contact_ids || []),
      do: %TimelineEvent{}
      |> TimelineEvent.changeset(%{
            event_name: event, card_id: card.id, content: event,
            user_id: user.id, company_id: card.company_id,
            metadata: metadata
                                 }
      )
      |> Ecto.Changeset.put_change(:contact_id, contact_id)

  end


  def insert(user, card) do
    event = "card.created"

    payload = %{
      event: event,
      data: payload_data(card)
    }

    with channel <- "cards:"  <> to_string(card.id),
      do: CercleApi.Endpoint.broadcast!(
            channel, "card:created", %{
              "card" => CercleApi.APIV2.CardView.card_json(card)
            }
          )

    changeset = event_changeset(user, event, card,
      event_payload(card, %{action: :create_card}))
    with {:ok, tm_event} <- Repo.insert(changeset),
      do: CercleApi.TimelineEventService.create(tm_event)

    Board
    |> Repo.get(card.board_id)
    |> Repo.preload([board_columns: Board.preload_query])
    |> CercleApi.BoardNotificationService.update_notification


  end

  def update(user, card, previous_card \\ %{}) do
    event = "card.updated"

    payload = %{
      event: event,
      data: payload_data(card)
    }
    CercleApi.ActivityService.add(card)
    with channel <- "cards:" <> to_string(card.id),
         card_contacts <- CercleApi.Card.contacts(card),
      do: CercleApi.Endpoint.broadcast!(
            channel, "card:updated", %{
              "card" => CercleApi.APIV2.CardView.card_json(card),
              "card_contacts" => card_contacts,
              "board" => card.board,
              "board_columns" => card.board.board_columns
            }
          )

    event_dataset = %{action: :update_card, previous: event_payload(previous_card)}
    changeset = event_changeset(
      user, event, card,
      event_payload(card, event_dataset)
    )

    if card.board_column_id != previous_card.board_column_id do
      with {:ok, tm_event} <- Repo.insert(changeset),
          event <- Repo.preload(tm_event, [:card, :user]),
        do: CercleApi.TimelineEventService.update(event)
    end

    Board
    |> Repo.get(card.board_id)
    |> Repo.preload([board_columns: Board.preload_query])
    |> CercleApi.BoardNotificationService.update_notification


  end

  def delete(card) do
    event = "card.deleted"

    payload = %{
      event: event,
      data: payload_data(card)
    }
    CercleApi.ActivityService.delete("card", card.id)


  end
end
