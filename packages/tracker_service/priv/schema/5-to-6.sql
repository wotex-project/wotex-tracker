INSERT INTO records(scope, kind, id, generation, document)
SELECT i.scope, 'alerts',
  'alert-' || printf('%019d', 9223372036854775807 - i.generation) || '-' || i.id,
  i.generation,
  json_object('public', json_object(
    'schema', 'wtr.alert.v1',
    'id', 'alert-' || printf('%019d', 9223372036854775807 - i.generation) || '-' || i.id,
    'event_id', i.id,
    'event', json_remove(json(i.document),
      '$.from_observation_id',
      '$.to_observation_id',
      '$.from_observation_identity',
      '$.to_observation_identity',
      '$.from_evidence_id',
      '$.to_evidence_id',
      '$.from_position_evidence_id',
      '$.to_position_evidence_id',
      '$.movement_position_evidence_id',
      '$.armed_evidence_id',
      '$.owner_presence_evidence_id',
      '$.from_sample_identity',
      '$.to_sample_identity',
      '$.from_position_bundle_identity',
      '$.to_position_bundle_identity',
      '$.armed_fact_identity',
      '$.owner_presence_fact_identity',
      '$.motion_state_identity',
      '$.from_decision_identity',
      '$.to_decision_identity'
    ),
    'rule', json_object('kind', i.kind, 'id', i.rule_id),
    'mode', i.mode,
    'physical_action_dispatch', i.action,
    'created_at', i.created_at,
    'generation', CAST(i.generation AS TEXT),
    'acknowledgement', json('null')
  ))
FROM rule_event_intents AS i;
PRAGMA user_version = 6;
