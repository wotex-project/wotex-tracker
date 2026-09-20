defmodule Wotex.Tracker.UI.AccessibilityAudit do
  @moduledoc false

  @controls ~w(input select textarea)
  @references ~w(aria-labelledby aria-describedby)

  def audit(html) when is_binary(html) do
    tree =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.to_tree(skip_whitespace_nodes: true)

    nodes = flatten(tree)

    ids = attribute_values(nodes, "id")
    id_set = MapSet.new(ids)
    labelled = label_targets(nodes)
    wrapped = wrapped_controls(tree)

    errors =
      []
      |> require_count(nodes, "html", 1)
      |> require_count(nodes, "main", 1)
      |> require_count(nodes, "h1", 1)
      |> document_language(nodes)
      |> heading_order(nodes)
      |> duplicate_ids(ids)
      |> broken_references(nodes, id_set)
      |> unlabelled_controls(nodes, labelled, wrapped)
      |> unnamed_actions(nodes)
      |> uncaptioned_tables(nodes)
      |> inaccessible_graphics(nodes)
      |> unnamed_regions(nodes)

    case Enum.reverse(errors) do
      [] -> :ok
      failures -> {:error, failures}
    end
  end

  defp flatten(tree), do: Enum.flat_map(tree, &flatten_node/1)

  defp flatten_node({tag, attributes, children}) when is_binary(tag) do
    node = %{tag: tag, attributes: Map.new(attributes), children: children}
    [node | flatten(children)]
  end

  defp flatten_node(_), do: []

  defp require_count(errors, nodes, tag, expected) do
    count = Enum.count(nodes, &(&1.tag == tag))

    if count == expected,
      do: errors,
      else: ["expected #{expected} #{tag}, found #{count}" | errors]
  end

  defp duplicate_ids(errors, ids) do
    duplicates =
      ids
      |> Enum.frequencies()
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    if duplicates == [],
      do: errors,
      else: ["duplicate ids: #{Enum.join(duplicates, ", ")}" | errors]
  end

  defp document_language(errors, nodes) do
    case Enum.find(nodes, &(&1.tag == "html")) do
      %{attributes: %{"lang" => language}} when language != "" -> errors
      _ -> ["html has no language" | errors]
    end
  end

  defp heading_order(errors, nodes) do
    {_previous, failures} =
      Enum.reduce(nodes, {0, errors}, fn node, {previous, nested} ->
        case heading_level(node.tag) do
          nil ->
            {previous, nested}

          level when previous > 0 and level > previous + 1 ->
            {level, ["heading order jumps from h#{previous} to h#{level}" | nested]}

          level ->
            {level, nested}
        end
      end)

    failures
  end

  defp heading_level("h" <> level) when level in ~w(1 2 3 4 5 6),
    do: String.to_integer(level)

  defp heading_level(_), do: nil

  defp broken_references(errors, nodes, ids) do
    Enum.reduce(nodes, errors, fn node, failures ->
      Enum.reduce(@references, failures, &reference_errors(node, &1, &2, ids))
    end)
  end

  defp reference_errors(node, attribute, errors, ids) do
    references =
      node.attributes
      |> Map.get(attribute, "")
      |> String.split()

    missing = Enum.reject(references, &MapSet.member?(ids, &1))

    if missing == [],
      do: errors,
      else: [describe(node) <> " has broken #{attribute}: #{Enum.join(missing, ", ")}" | errors]
  end

  defp unlabelled_controls(errors, nodes, labelled, wrapped) do
    Enum.reduce(nodes, errors, fn node, failures ->
      if node.tag in @controls and not hidden?(node) and
           not accessible_control?(node, labelled, wrapped),
         do: [describe(node) <> " has no accessible label" | failures],
         else: failures
    end)
  end

  defp accessible_control?(node, labelled, wrapped) do
    id = node.attributes["id"]

    MapSet.member?(wrapped, node) or (is_binary(id) and MapSet.member?(labelled, id)) or
      present?(node.attributes["aria-label"]) or present?(node.attributes["aria-labelledby"])
  end

  defp wrapped_controls(tree), do: tree |> wrapped_controls(false) |> MapSet.new()

  defp wrapped_controls(nodes, inside_label) do
    Enum.flat_map(nodes, fn
      {tag, attributes, children} when is_binary(tag) ->
        current = %{tag: tag, attributes: Map.new(attributes), children: children}
        own = if inside_label and tag in @controls, do: [current], else: []
        own ++ wrapped_controls(children, inside_label or tag == "label")

      _ ->
        []
    end)
  end

  defp hidden?(%{tag: "input", attributes: %{"type" => "hidden"}}), do: true
  defp hidden?(_), do: false

  defp unnamed_actions(errors, nodes) do
    Enum.reduce(nodes, errors, fn node, failures ->
      if node.tag in ~w(a button) and not accessible_name?(node),
        do: [describe(node) <> " has no accessible name" | failures],
        else: failures
    end)
  end

  defp uncaptioned_tables(errors, nodes) do
    Enum.reduce(nodes, errors, fn node, failures ->
      if node.tag == "table" and not descendant?(node.children, "caption"),
        do: [describe(node) <> " has no caption" | failures],
        else: failures
    end)
  end

  defp inaccessible_graphics(errors, nodes) do
    Enum.reduce(nodes, errors, fn node, failures ->
      invalid =
        case node.tag do
          "img" ->
            not Map.has_key?(node.attributes, "alt")

          "svg" ->
            node.attributes["aria-hidden"] != "true" and
              (node.attributes["role"] != "img" or not accessible_name?(node))

          _ ->
            false
        end

      if invalid,
        do: [describe(node) <> " has no accessible alternative" | failures],
        else: failures
    end)
  end

  defp unnamed_regions(errors, nodes) do
    Enum.reduce(nodes, errors, fn node, failures ->
      if node.attributes["role"] == "region" and not accessible_name?(node),
        do: [describe(node) <> " region has no accessible name" | failures],
        else: failures
    end)
  end

  defp accessible_name?(node) do
    present?(node.attributes["aria-label"]) or present?(node.attributes["aria-labelledby"]) or
      present?(text(node.children))
  end

  defp label_targets(nodes) do
    nodes
    |> Enum.filter(&(&1.tag == "label"))
    |> attribute_values("for")
    |> MapSet.new()
  end

  defp attribute_values(nodes, attribute) do
    nodes
    |> Enum.map(& &1.attributes[attribute])
    |> Enum.filter(&present?/1)
  end

  defp descendant?(children, tag),
    do: Enum.any?(flatten(children), &(&1.tag == tag))

  defp text(children) do
    children
    |> Enum.map_join(" ", fn
      value when is_binary(value) -> value
      {_tag, _attributes, nested} -> text(nested)
      _ -> ""
    end)
    |> String.trim()
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp describe(node) do
    case node.attributes["id"] do
      nil -> node.tag
      id -> node.tag <> "#" <> id
    end
  end
end
