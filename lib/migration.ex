defmodule Pointers.Migration do
  @moduledoc "Helpers for writing Pointer-aware migrations."

  import Ecto.Query, only: [from: 2]
  import Ecto.Migration
  alias Pointers.{Pointer, Table, ULID}

  defdelegate init_pointers_ulid_extra(), to: ULID.Migration

  @type pointer_type :: :strong | :weak | :unbreakable

  @doc "Creates a strong, weak or unbreakable pointer depending on `type`."
  @spec pointer(type :: pointer_type) :: term
  @spec pointer(module :: atom, type :: pointer_type) :: term
  def pointer(table \\ Pointer, type)
  def pointer(table, :strong), do: strong_pointer(table)
  def pointer(table, :weak), do: weak_pointer(table)
  def pointer(table, :unbreakable), do: unbreakable_pointer(table)

  @doc """
  A reference to a pointer for use with 'add/3`. A strong pointer will
  be deleted when the thing it's pointing to is deleted.
  """
  def strong_pointer(table \\ Pointer) do
    references(table.__schema__(:source),
      type: :uuid,
      on_update: :update_all,
      on_delete: :delete_all
    )
  end

  @doc """
  A reference to a pointer for use with 'add/3`. A weak pointer will
  be set null when the thing it's pointing to is deleted.
  """
  def weak_pointer(table \\ Pointer) do
    references(table.__schema__(:source),
      type: :uuid,
      on_update: :update_all,
      on_delete: :nilify_all
    )
  end

  @doc """
  A reference to a pointer for use with 'add/3`. An unbreakable
  pointer will prevent the thing it's pointing to from being deleted.
  """
  def unbreakable_pointer(table \\ Pointer) do
    references(table.__schema__(:source),
      type: :uuid,
      on_update: :update_all,
      on_delete: :restrict
    )
  end

  defp table_name(name) when is_atom(name), do: Atom.to_string(name)
  defp table_name(name) when is_binary(name), do: name

  config = Application.get_env(:pointers, __MODULE__, [])
  @trigger_function Keyword.get(config, :trigger_function, "insert_pointer")
  @trigger_prefix Keyword.get(config, :trigger_prefix, "insert_pointer_")

  @doc """
  Adds a pointer primary key to the table.
  Not required if you are using `create_pointable_table`
  """
  @spec add_pointer_pk() :: nil
  def add_pointer_pk(), do: add(:id, :uuid, primary_key: true)

  @spec add_pointer_ref_pk() :: nil
  def add_pointer_ref_pk(),
    do: add(:id, strong_pointer(), primary_key: true)

  @doc "Creates a pointable table along with its trigger."
  @spec create_pointable_table(name :: binary, id :: binary, body :: term) :: term
  @spec create_pointable_table(name :: binary, id :: binary, opts :: Keyword.t(), body :: term) ::
          term
  defmacro create_pointable_table(name, id, opts \\ [], body) do
    ULID.cast!(id)
    opts = [primary_key: false] ++ opts

    quote do
      Pointers.Migration.insert_table_record(unquote(id), unquote(name))
      table = Ecto.Migration.table(unquote(name), unquote(opts))

      Ecto.Migration.create_if_not_exists table do
        Pointers.Migration.add_pointer_pk()
        unquote(body)
      end

      Pointers.Migration.create_pointer_trigger(unquote(name))
    end
  end

  @doc "Drops a pointable table"
  @spec drop_pointable_table(name :: binary, id :: binary) :: nil
  def drop_pointable_table(name, id) do
    drop_pointer_trigger(name)
    delete_table_record(id)
    drop_table(name)
  end

  @doc "Creates a mixin table - one with a ULID primary key and no trigger"
  defmacro create_mixin_table(name, opts \\ [], body) do
    opts = [primary_key: false] ++ opts

    quote do
      table = Ecto.Migration.table(unquote(name), unquote(opts))

      Ecto.Migration.create_if_not_exists table do
        Pointers.Migration.add_pointer_ref_pk()
        unquote(body)
      end
    end
  end

  @doc "Drops a mixin table. Actually just a simple cascading drop"
  @spec drop_mixin_table(name :: binary) :: nil
  def drop_mixin_table(name), do: drop_table(name)

  @doc """
  When migrating up: initialises the pointers database.
  When migrating down: deinitialises the pointers database.
  """
  @spec init_pointers() :: nil
  def init_pointers(), do: init_pointers(direction())

  @doc """
  Given `:up`: initialises the pointers database.
  Given `:down`: deinitialises the pointers database.
  """
  @spec init_pointers(direction :: :up | :down) :: nil
  def init_pointers(:up) do
    create_if_not_exists table(Table.__schema__(:source), primary_key: false) do
      add_pointer_pk()
      add(:table, :text, null: false)
    end

    create_if_not_exists table(Pointer.__schema__(:source), primary_key: false) do
      add_pointer_pk()

      ref =
        references(Table.__schema__(:source),
          on_delete: :delete_all,
          on_update: :update_all,
          type: :uuid
        )

      add(:table_id, ref, null: false)
    end

    create_if_not_exists(unique_index(Table.__schema__(:source), :table))
    create_if_not_exists(index(Pointer.__schema__(:table), :table_id))
    flush()
    insert_table_record(Table.__pointable__(:table_id), Table.__schema__(:source))
    create_pointer_trigger_function()
    flush()
    create_pointer_trigger(Table.__schema__(:source))
  end

  def init_pointers(:down) do
    drop_pointer_trigger(Table.__schema__(:source))
    drop_pointer_trigger_function()
    drop_if_exists(index(Pointer.__schema__(:table), :table_id))
    drop_if_exists(index(Table.__schema__(:source), :table))
    drop_table(Pointer.__schema__(:table))
    drop_table(Table.__schema__(:source))
  end

  @doc false
  def create_pointer_trigger_function() do
    :ok =
      execute("""
      create or replace function #{@trigger_function}() returns trigger as $$
      declare table_id uuid;
      begin
        select id into table_id from #{Table.__schema__(:source)}
          where #{Table.__schema__(:source)}.table = TG_TABLE_NAME;
        if table_id is null then
          raise exception 'Table % does not participate in the pointers abstraction', TG_TABLE_NAME;
        end if;
        insert into #{Pointer.__schema__(:table)} (id, table_id) values (NEW.id, table_id)
        on conflict do nothing;
        return NEW;
      end;
      $$ language plpgsql
      """)
  end

  @doc false
  def drop_pointer_trigger_function() do
    execute("drop function if exists #{@trigger_function}() cascade")
  end

  @doc false
  def create_pointer_trigger(table) do
    table = table_name(table)
    # because there is no create trigger if not exists
    drop_pointer_trigger(table)

    execute("""
    create trigger "#{@trigger_prefix}#{table}"
    before insert on "#{table}"
    for each row
    execute procedure #{@trigger_function}()
    """)
  end

  @doc false
  def drop_pointer_trigger(table) do
    table = table_name(table)

    execute("""
    drop trigger if exists "#{@trigger_prefix}#{table}" on "#{table}"
    """)
  end

  # Insert a Table record. Not required when using `create_pointable_table`
  @doc false
  def insert_table_record(id, name) do
    {:ok, id} = Pointers.ULID.dump(Pointers.ULID.cast!(id))
    name = table_name(name)
    opts = [on_conflict: [set: [id: id]], conflict_target: [:table]]
    repo().insert_all(Table.__schema__(:source), [%{id: id, table: name}], opts)
  end

  # Delete a Table record. Not required when using `drop_pointable_table`
  @doc false
  def delete_table_record(id) do
    {:ok, id} = Pointers.ULID.dump(Pointers.ULID.cast!(id))
    repo().delete_all(from(t in Table.__schema__(:source), where: t.id == ^id))
  end

  def drop_table(name), do: execute("drop table if exists #{name} cascade")
end
