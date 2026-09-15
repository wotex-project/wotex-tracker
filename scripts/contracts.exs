defmodule WotexTracker.Contracts do
  @moduledoc false
  @statuses ~w(not-started in-progress implemented accepted blocked)
  @evidence ~w(research fixture integration hardware-qualified)
  @targets ~w(core_library headless_service tracking_hardware shared_application analytics pi5_headless pi5_panel ios_companion integrated_product)

  def check(root) do
    with {:ok, catalogue} <- parse(File.read!(Path.join(root, "docs/specs/catalogue.yaml"))),
         :ok <- validate(catalogue, root) do
      check_links(root)
    end
  end

  def parse(source) do
    case :yamerl_constr.string(String.to_charlist(source),
           str_node_as_binary: true,
           keep_duplicate_keys: true
         ) do
      [document] -> normalize(document)
      _ -> {:error, :document_count}
    end
  catch
    _, _ -> {:error, :invalid_yaml}
  end

  def validate(catalogue, root) when is_map(catalogue) do
    if shape?(catalogue),
      do: validate_entries(catalogue, root),
      else: {:error, :invalid_catalogue}
  end

  def validate(_, _), do: {:error, :invalid_catalogue}

  defp shape?(catalogue) do
    is_list(catalogue["contracts"]) and is_list(catalogue["delivery_targets"]) and
      is_list(catalogue["executed_evidence"]) and is_map(catalogue["initial_profiles"]) and
      Enum.all?(catalogue["contracts"], fn entry ->
        is_map(entry) and is_binary(entry["file"]) and is_list(entry["depends_on"])
      end) and
      Enum.all?(catalogue["delivery_targets"], fn entry ->
        is_map(entry) and is_list(entry["contracts"]) and is_list(entry["requires"]) and
          is_list(entry["evidence_refs"])
      end) and Enum.all?(Map.values(catalogue["initial_profiles"]), &is_map/1)
  end

  defp validate_entries(catalogue, root) do
    contracts = catalogue["contracts"]
    targets = catalogue["delivery_targets"]

    with true <- is_map(catalogue) and is_list(contracts) and is_list(targets),
         :ok <- unique_ids(contracts),
         :ok <- unique_ids(targets),
         true <- Enum.sort(Enum.map(targets, & &1["id"])) == Enum.sort(@targets),
         true <- catalogue["implementation_status"] in @statuses,
         :ok <- references(contracts, targets),
         :ok <- evidence(catalogue, root),
         true <-
           Enum.all?(contracts, &File.regular?(Path.join([root, "docs/specs", &1["file"]]))),
         true <- Enum.all?(targets, &(&1["required_for_product"] === true)),
         :ok <- acyclic(targets) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_catalogue}
    end
  end

  defp normalize(pairs) when is_list(pairs) and pairs != [] do
    if Enum.all?(pairs, &match?({_, _}, &1)) do
      Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        with false <- Map.has_key?(acc, key), {:ok, admitted} <- normalize(value) do
          {:cont, {:ok, Map.put(acc, key, admitted)}}
        else
          true -> {:halt, {:error, :duplicate_key}}
          error -> {:halt, error}
        end
      end)
    else
      map_values(pairs)
    end
  end

  defp normalize(value), do: {:ok, value}

  defp map_values(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case normalize(value) do
        {:ok, admitted} -> {:cont, {:ok, [admitted | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp unique_ids(entries) do
    ids = Enum.map(entries, & &1["id"])

    if Enum.all?(ids, &(is_binary(&1) and &1 != "")) and
         length(Enum.uniq(ids)) == length(ids),
       do: :ok,
       else: {:error, :duplicate_or_missing_id}
  end

  defp references(contracts, targets) do
    contract_ids = Enum.map(contracts, & &1["id"])
    target_ids = Enum.map(targets, & &1["id"])

    valid =
      Enum.all?(contracts, fn entry ->
        Enum.all?(entry["depends_on"], &(&1 in ["wotex" | contract_ids]))
      end) and
        Enum.all?(targets, fn entry ->
          Enum.all?(entry["contracts"], &(&1 in contract_ids)) and
            Enum.all?(entry["requires"], &(&1 in target_ids))
        end)

    if valid, do: :ok, else: {:error, :unresolved_reference}
  end

  defp evidence(catalogue, root) do
    entries = catalogue["delivery_targets"] ++ Map.values(catalogue["initial_profiles"])
    all_refs = catalogue["executed_evidence"]

    valid =
      Enum.all?(all_refs, &File.regular?(Path.join(root, &1))) and
        Enum.all?(entries, fn entry ->
          refs = entry["evidence_refs"]

          promoted =
            entry["implementation_status"] in ~w(implemented accepted) or
              entry["current_evidence"] in ~w(fixture integration hardware-qualified)

          entry["implementation_status"] in @statuses and
            (not Map.has_key?(entry, "current_evidence") or entry["current_evidence"] in @evidence) and
            is_list(refs) and Enum.all?(refs, &(&1 in all_refs)) and
            (not promoted or refs != [])
        end)

    if valid, do: :ok, else: {:error, :invalid_evidence}
  end

  defp acyclic(targets) do
    edges = Map.new(targets, &{&1["id"], &1["requires"]})

    if Enum.any?(Map.keys(edges), &cycle?(&1, edges, [])),
      do: {:error, :delivery_cycle},
      else: :ok
  end

  defp cycle?(id, edges, ancestors) do
    id in ancestors or Enum.any?(edges[id], &cycle?(&1, edges, [id | ancestors]))
  end

  defp check_links(root) do
    files =
      Enum.map(~w(README.md CONTRIBUTING.md SECURITY.md), &Path.join(root, &1)) ++
        Path.wildcard(Path.join(root, "docs/**/*.md"))

    missing =
      for file <- files,
          [_, link] <- Regex.scan(~r/\]\(([^\s)]+)(?:\s+[^)]*)?\)/, File.read!(file)),
          not String.starts_with?(link, ["https:", "http:", "mailto:", "#"]),
          path = link |> String.split("#") |> hd() |> URI.decode(),
          not File.exists?(Path.expand(path, Path.dirname(file))),
          do: {Path.relative_to(file, root), link}

    if missing == [], do: :ok, else: {:error, {:missing_links, missing}}
  end
end
