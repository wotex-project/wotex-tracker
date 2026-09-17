defmodule Wotex.Tracker.Service.RuleEventProjection do
  @moduledoc false

  # Rule event intents retain complete references privately. Public events keep
  # rule, status, time and trip/fence context but omit caller capture IDs,
  # evidence IDs and digests of private evidence, samples, facts and decisions.
  @private ~w(
    from_observation_id to_observation_id
    from_observation_identity to_observation_identity
    from_evidence_id to_evidence_id
    from_position_evidence_id to_position_evidence_id
    movement_position_evidence_id armed_evidence_id owner_presence_evidence_id
    from_sample_identity to_sample_identity
    from_position_bundle_identity to_position_bundle_identity
    armed_fact_identity owner_presence_fact_identity motion_state_identity
    from_decision_identity to_decision_identity
  )

  def public(event) when is_map(event), do: Map.drop(event, @private)

  def private_fields, do: @private
end
