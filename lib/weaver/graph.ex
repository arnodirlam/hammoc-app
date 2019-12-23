defmodule Weaver.Graph do
  use GenServer

  alias Weaver.Ref

  @timeout :timer.seconds(60)
  @call_timeout :timer.seconds(75)
  @indexes [
    "id: string @index(hash,trigram) @upsert ."
  ]

  def start_link(_args) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def store(tuples) do
    GenServer.call(__MODULE__, {:store, tuples}, @call_timeout)
  end

  def store!(tuples) do
    case store(tuples) do
      {:ok, result} -> result
      {:error, e} -> raise e
    end
  end

  def count(id, relation) do
    GenServer.call(__MODULE__, {:count, id, relation}, @call_timeout)
  end

  def count!(id, relation) do
    case count(id, relation) do
      {:ok, result} -> result
      {:error, e} -> raise e
    end
  end

  def reset() do
    GenServer.call(__MODULE__, :reset)
  end

  def reset!() do
    case reset() do
      :ok -> :ok
      {:error, e} -> raise e
    end
  end

  @impl GenServer
  def init(_args) do
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:store, tuples}, _from, state) do
    varnames = varnames_for(tuples)
    query = upsert_query_for(varnames) |> IO.inspect(label: "UPSERT QUERY")

    statement =
      tuples
      |> Enum.map(fn {subject, predicate, object} ->
        sub = property(subject, varnames)
        obj = property(object, varnames)
        "#{sub} <#{predicate}> #{obj} ."
      end)
      |> IO.inspect(label: "UPSERT STATE")
      |> Enum.join("\n")

    result =
      Dlex.mutate(Dlex, %{query: query}, statement, timeout: @timeout)
      |> IO.inspect(label: "UPSERT")

    {:reply, result, state}
  end

  def handle_call({:count, id, relation}, _from, state) do
    query = ~s"""
    {
      countRelation(func: eq(id, #{inspect(id)})) {
        c : count(#{relation})
      }
    }
    """

    result =
      case Dlex.query(Dlex, query, %{}, timeout: @timeout) do
        {:ok, %{"countRelation" => [%{"c" => count}]}} -> {:ok, count}
        {:ok, %{"countRelation" => []}} -> {:ok, nil}
        {:error, e} -> {:error, e}
      end

    {:reply, result, state}
  end

  def handle_call(:reset, _from, _uids) do
    result =
      with {:ok, _result} <- Dlex.alter(Dlex, %{drop_all: true}),
           {:ok, _result} <- Dlex.alter(Dlex, Enum.join(@indexes, "\n")) do
        :ok
      end

    {:reply, result, %{}}
  end

  @doc ~S"""
  Generates a upsert query for dgraph.

  ## Examples

      iex> %{
      ...>   Weaver.Ref.new("id1") => "a",
      ...>   Weaver.Ref.new("id2") => "b",
      ...>   Weaver.Ref.new("id3") => "c"
      ...> }
      ...> |> Weaver.Graph.upsert_query_for()
      "{ a as var(func: eq(id, \"id1\"))
      b as var(func: eq(id, \"id2\"))
      c as var(func: eq(id, \"id3\")) }"
  """
  def upsert_query_for(varnames) do
    query_body =
      varnames
      |> Enum.map(fn {%Ref{id: id}, var} ->
        ~s|#{var} as var(func: eq(id, "#{id}"))|
      end)
      |> Enum.join("\n")

    "{ #{query_body} }"
  end

  @doc """
  Assigns a unique variable name to be used in dgraph upserts according to a sequence.

  ## Examples

      iex> [
      ...>   {Weaver.Ref.new("id1"), :follows, Weaver.Ref.new("id2")},
      ...>   {Weaver.Ref.new("id1"), :name, "Kiara"},
      ...>   {Weaver.Ref.new("id2"), :name, "Greg"},
      ...>   {Weaver.Ref.new("id3"), :name, "Sia"}
      ...> ]
      ...> |> Weaver.Graph.varnames_for()
      %{
        Weaver.Ref.new("id1") => "a",
        Weaver.Ref.new("id2") => "b",
        Weaver.Ref.new("id3") => "c"
      }
  """
  def varnames_for(tuples) do
    tuples
    |> Enum.flat_map(fn
      {sub = %Ref{}, _pred, obj = %Ref{}} -> [sub, obj]
      {sub = %Ref{}, _pred, _obj} -> [sub]
      _ -> []
    end)
    |> Enum.reduce(%{}, fn id, map ->
      Map.put_new(map, id, varname(map_size(map)))
    end)
  end

  defp property(ref = %Ref{}, varnames) do
    with {:ok, var} <- Map.fetch(varnames, ref) do
      "uid(#{var})"
    end
  end

  defp property(int, _varnames) when is_integer(int) do
    ~s|"#{int}"^^<xs:int>|
  end

  defp property(other, _varnames), do: inspect(other)

  @doc """
  Generates a variable name from a number.

  ## Examples

      iex> Weaver.Graph.varname(4)
      "aa"

      iex> Weaver.Graph.varname(5)
      "ab"

      iex> Weaver.Graph.varname(6)
      "ac"

      iex> Weaver.Graph.varname(7)
      "ad"

      iex> Weaver.Graph.varname(8)
      "ba"

      iex> Weaver.Graph.varname(19)
      "dd"

      iex> Weaver.Graph.varname(20)
      "aaa"

      iex> Weaver.Graph.varname(83)
      "ddd"

      iex> Weaver.Graph.varname(84)
      "aaaa"
  """
  def varname(0), do: "a"
  def varname(1), do: "b"
  def varname(2), do: "c"
  def varname(3), do: "d"

  def varname(n) do
    varname(div(n, 4) - 1) <> varname(rem(n, 4))
  end
end