UPDATE events SET document = json_remove(document,
  '$.data.from_observation_id',
  '$.data.to_observation_id',
  '$.data.from_observation_identity',
  '$.data.to_observation_identity',
  '$.data.from_evidence_id',
  '$.data.to_evidence_id',
  '$.data.from_position_evidence_id',
  '$.data.to_position_evidence_id',
  '$.data.movement_position_evidence_id',
  '$.data.armed_evidence_id',
  '$.data.owner_presence_evidence_id',
  '$.data.from_sample_identity',
  '$.data.to_sample_identity',
  '$.data.from_position_bundle_identity',
  '$.data.to_position_bundle_identity',
  '$.data.armed_fact_identity',
  '$.data.owner_presence_fact_identity',
  '$.data.motion_state_identity',
  '$.data.from_decision_identity',
  '$.data.to_decision_identity'
)
WHERE json_extract(document, '$.type') = 'tracker.event';
PRAGMA user_version = 5;
